import Foundation
import Synchronization
import CryptoKit
#if !OMNIFLOW_STANDALONE_CHECKS && !APPSTORE
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

struct MetalAgentReply: Sendable {
    struct Call: Sendable {
        var name: String
        var argumentsJSON: String
    }
    var text: String = ""
    var calls: [Call] = []
}

protocol MetalAgentRuntime: Sendable {
    func prewarm() async throws
    func unload() async
    func generate(instructions: String, prompt: String, toolsJSON: Data,
                  onPartial: (@Sendable (String) async -> Void)?) async throws -> MetalAgentReply
    func generateConversation(instructions: String, messagesJSON: Data, toolsJSON: Data,
                              onPartial: (@Sendable (String) async -> Void)?) async throws -> MetalAgentReply
}

extension MetalAgentRuntime {
    // A runtime must explicitly support structured history. Never silently flatten it.
    func generateConversation(instructions: String, messagesJSON: Data, toolsJSON: Data,
                              onPartial: (@Sendable (String) async -> Void)? = nil) async throws -> MetalAgentReply {
        throw MetalAgentError.unavailable
    }
}

#if OMNIFLOW_STANDALONE_CHECKS || APPSTORE
// Legacy swiftc checks exercise host logic without package dependencies, and the App Store
// build does not link MLX at all (it cannot obtain the model). The direct build always compiles
// the real runtime; this stand-in cannot infer or dispatch.
actor MLXAgentRuntime: MetalAgentRuntime {
    static let shared = MLXAgentRuntime()
    func prewarm() async throws { throw MetalAgentError.unavailable }
    func unload() async {}
    func generate(instructions: String, prompt: String, toolsJSON: Data,
                  onPartial: (@Sendable (String) async -> Void)?) async throws -> MetalAgentReply {
        throw MetalAgentError.unavailable
    }
}
#else
/// In-process inference only. There is no server, shell, downloader or tool executor here.
actor MLXAgentRuntime: MetalAgentRuntime {
    static let shared = MLXAgentRuntime()
    private let directory: URL
    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?
    private var active: Task<MetalAgentReply, Error>?
    private var unloading = false
    private var epoch = UUID()

    init(directory: URL = MLXAgentModel.directory) { self.directory = directory }

    func prewarm() async throws {
        guard !unloading else { throw MetalAgentError.unavailable }
        if container != nil { return }
        let current = epoch
        if let loading {
            let loaded = try await loading.value
            try Task.checkCancellation()
            guard !unloading, epoch == current else { throw CancellationError() }
            container = loaded
            return
        }
        let directory = directory.resolvingSymlinksInPath()
        let task = Task.detached(priority: .utility) {
            try MLXAgentModel.verify(directory)
            try Task.checkCancellation()
            // Swift Testing's host is outside the test bundle. Resolve the package
            // resource explicitly before any MLX call initializes Metal.
            var shaderURL: URL?
            let bundles = [Bundle.main, Bundle(for: MLXBundleAnchor.self)] + Bundle.allBundles
            for bundle in bundles {
                let roots = [bundle.resourceURL, bundle.bundleURL, bundle.bundleURL.deletingLastPathComponent()].compactMap { $0 }
                if let library = roots.lazy.compactMap({ root in
                    Bundle(url: root.appendingPathComponent("mlx-swift_Cmlx.bundle"))?
                        .url(forResource: "default", withExtension: "metallib")
                }).first {
                    shaderURL = library
                    break
                }
            }
            guard let shaderURL else { throw MetalAgentError.unavailable }
            MLX.GPU.metallib = shaderURL
            MLX.Memory.cacheLimit = 256 * 1024 * 1024
            let model = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalGLMTokenizerLoader())
            try Task.checkCancellation()
            return model
        }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        try Task.checkCancellation()
        guard !unloading, epoch == current else { throw CancellationError() }
        container = loaded
    }

    func unload() async {
        unloading = true
        epoch = UUID()
        loading?.cancel(); active?.cancel()
        if let active { _ = await active.result }
        if let loading { _ = await loading.result }
        let wasLoaded = container != nil
        container = nil
        if wasLoaded { MLX.Memory.clearCache() }
        unloading = false
    }

    func generate(instructions: String, prompt: String, toolsJSON: Data,
                  onPartial: (@Sendable (String) async -> Void)?) async throws -> MetalAgentReply {
        try await generateInput(instructions: instructions, prompt: prompt, conversationJSON: nil,
                                toolsJSON: toolsJSON, onPartial: onPartial)
    }

    /// Native conversation entry point used by the matched tool-loop qualification.
    /// Callers supply host-owned roles; never infer roles from user-authored JSON.
    func generateConversation(instructions: String, messagesJSON: Data, toolsJSON: Data,
                              onPartial: (@Sendable (String) async -> Void)? = nil) async throws -> MetalAgentReply {
        try await generateInput(instructions: instructions, prompt: "", conversationJSON: messagesJSON,
                                toolsJSON: toolsJSON, onPartial: onPartial)
    }

    private func generateInput(instructions: String, prompt: String, conversationJSON: Data?, toolsJSON: Data,
                               onPartial: (@Sendable (String) async -> Void)?) async throws -> MetalAgentReply {
        try await prewarm()
        try Task.checkCancellation()
        guard active == nil else { throw MetalAgentError.busy }
        guard !unloading, let container else { throw MetalAgentError.unavailable }
        let work = Task {
            try await Self.run(container: container, instructions: instructions, prompt: prompt,
                               toolsJSON: toolsJSON, conversationJSON: conversationJSON, onPartial: onPartial)
        }
        active = work
        let timedOut = Mutex(false)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            timedOut.withLock { $0 = true }
            work.cancel()
        }
        defer { deadline.cancel(); active = nil }
        return try await withTaskCancellationHandler {
            do {
                let result = try await work.value
                try Task.checkCancellation()
                if timedOut.withLock({ $0 }) { throw MetalAgentError.timedOut }
                return result
            } catch {
                try Task.checkCancellation()
                if timedOut.withLock({ $0 }) { throw MetalAgentError.timedOut }
                throw error
            }
        } onCancel: { work.cancel() }
    }

    private static func run(container: ModelContainer, instructions: String, prompt: String, toolsJSON: Data, conversationJSON: Data?,
                            onPartial: (@Sendable (String) async -> Void)?) async throws -> MetalAgentReply {
        // JSONSerialization's containers are bridged through JSONValue, never unchecked Sendable.
        let values = try JSONDecoder().decode([[String: MLXLMCommon.JSONValue]].self, from: toolsJSON)
        let tools = values.map { $0.mapValues(\.mlxSendableValue) }
        let start = ContinuousClock.now
        let (stream, worker) = try await container.perform { context in
            let conversation: [[String: any Sendable]]
            if let conversationJSON {
                conversation = try JSONDecoder().decode([[String: MLXLMCommon.JSONValue]].self, from: conversationJSON)
                    .map { $0.mapValues(\.mlxSendableValue) }
            } else { conversation = [["role": "user", "content": prompt]] }
            let input = try await context.processor.prepare(input: UserInput(messages: [
                ["role": "system", "content": instructions]
            ] + conversation, tools: tools.isEmpty ? nil : tools, additionalContext: ["enable_thinking": false]))
            try Task.checkCancellation()
            guard input.text.tokens.size + 4096 <= 202_752 else { throw AtlasContextError.requestTooLarge }
            let parameters = GenerateParameters(maxTokens: 4096, temperature: 0,
                prefill: .init(stepSize: 1024), seed: 42,
                toolCallPolicy: .init(recovery: .disabled, validation: .strict))
            let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
            return generateTask(promptTokenCount: input.text.tokens.size,
                modelConfiguration: context.configuration, tokenizer: context.tokenizer,
                iterator: iterator, tools: tools, toolCallPolicy: parameters.toolCallPolicy)
        }
        // Cancel and JOIN the GPU worker before returning, unloading, or accepting another request.
        return try await withTaskCancellationHandler {
            do {
                var reply = MetalAgentReply()
                var filter = MLXAnswerFilter()
                var completed = false
                var lastUpdate = ContinuousClock.now
                for await event in stream {
                    try Task.checkCancellation()
                    guard start.duration(to: .now) < .seconds(120) else { throw MetalAgentError.timedOut }
                    switch event {
                    case .chunk(let text):
                        try filter.append(text)
                        reply.text = filter.visible
                        if reply.calls.isEmpty, !reply.text.isEmpty, lastUpdate.duration(to: .now) >= .milliseconds(60) {
                            await onPartial?(reply.text); lastUpdate = .now
                        }
                    case .toolCall(let call):
                        guard reply.calls.count < 8 else { throw MetalAgentError.multipleProposals }
                        let data = try JSONEncoder().encode(call.function.arguments)
                        guard data.count <= 16000 else { throw AtlasBridgeError.invalidFrame }
                        reply.calls.append(.init(name: call.function.name, argumentsJSON: String(decoding: data, as: UTF8.self)))
                    case .rejectedToolCall: throw MetalAgentError.invalidProposal
                    case .info(let info):
                        guard info.stopReason == .stop else {
                            if info.stopReason == .cancelled { throw CancellationError() }
                            throw MetalAgentError.incomplete
                        }
                        completed = true
                    }
                }
                await worker.value
                try Task.checkCancellation()
                guard completed else { throw MetalAgentError.incomplete }
                try filter.finish()
                reply.text = filter.visible
                if reply.calls.isEmpty { await onPartial?(reply.text) }
                return reply
            } catch {
                worker.cancel(); await worker.value
                throw error
            }
        } onCancel: { worker.cancel() }
    }
}

#endif

/// Hide any unexpected thinking spans, including delimiters split across streamed chunks.
/// Reject unfinished/private-only generations and raw tool markup rather than rendering it.
struct MLXAnswerFilter {
    private var pending = ""
    private var thinking = false
    private var bytes = 0
    private(set) var visible = ""
    mutating func append(_ text: String) throws {
        bytes += text.utf8.count
        guard bytes <= 1_048_576 else { throw MetalAgentError.incomplete }
        pending += text
        while !pending.isEmpty {
            let marker = thinking ? "</think>" : "<think>"
            if let range = pending.range(of: marker) {
                if !thinking { visible += pending[..<range.lowerBound] }
                pending = String(pending[range.upperBound...]); thinking.toggle()
            } else {
                var hold = 0
                for n in 1..<marker.count where pending.hasSuffix(marker.prefix(n)) { hold = n }
                if !thinking { visible += pending.dropLast(hold) }
                pending = String(pending.suffix(hold)); break
            }
        }
        guard !visible.contains("<tool_call>"), !visible.contains("</think>") else { throw MetalAgentError.incomplete }
    }
    mutating func finish() throws {
        guard !thinking, pending.isEmpty else { throw MetalAgentError.incomplete }
    }
}

#if !OMNIFLOW_STANDALONE_CHECKS && !APPSTORE
private final class MLXBundleAnchor: NSObject {}

private struct LocalGLMTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LocalGLMTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}
private struct LocalGLMTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

private extension MLXLMCommon.JSONValue {
    var mlxSendableValue: any Sendable {
        switch self {
        case .null: NSNull()
        case .bool(let v): v
        case .int(let v): v
        case .double(let v): v
        case .string(let v): v
        case .array(let v): v.map(\.mlxSendableValue)
        case .object(let v): v.mapValues(\.mlxSendableValue)
        }
    }
}

#endif
