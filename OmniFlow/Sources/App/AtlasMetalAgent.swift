import Foundation
import FoundationModels
import Combine

/// Optional app-owned MLX inference. Atlas owns every tool execution.
@MainActor
final class AtlasMetalAgent {
    static let shared = AtlasMetalAgent()
    #if APPSTORE
    // The App Store build has no MLX runtime; a preference carried over from a direct build must not select it.
    static var enabled: Bool { false }
    #else
    static var enabled: Bool { AgentPreferences.shared.enabled && AgentPreferences.shared.useStrongerModel }
    #endif
    static let maximumContextTokens = 202_752
    static let responseTokens = 4096
    private static let framingReserve = 2048
    private let runtime: any MetalAgentRuntime
    private var warming: Task<Void, Error>?
    private var releasing: Task<Void, Never>?
    private var requestTask: Task<MetalAgentReply, Error>?
    private var epoch = UUID()

    init(runtime: any MetalAgentRuntime = MLXAgentRuntime.shared) { self.runtime = runtime }

    func start() {
        guard Self.enabled else { return }
        Task { [weak self] in
            do { try await self?.prewarm() }
            catch is CancellationError { }
            catch { await LocalTelemetry.shared.event("agent.mlx.prewarm", success: false) }
        }
    }

    func stop() { deactivate() }

    func deactivate() {
        epoch = UUID()
        warming?.cancel()
        requestTask?.cancel()
        guard releasing == nil else { return }
        let runtime = runtime
        releasing = Task {
            await runtime.unload()
            releasing = nil
        }
    }

    func prewarm() async throws {
        if let releasing { await releasing.value }
        try Task.checkCancellation()
        if let warming { try await warming.value; return }
        let runtime = runtime
        let task = Task { try await runtime.prewarm() }
        warming = task
        defer { warming = nil }
        try await task.value
        try Task.checkCancellation()
    }

    func respond(instructions: String, prompt: String, tools: [any Tool], onPartial: (@MainActor (String) -> Void)? = nil) async throws -> String {
        try await respondInput(instructions: instructions, prompt: prompt, messagesJSON: nil, tools: tools, onPartial: onPartial)
    }

    func respondConversation(instructions: String, messagesJSON: Data, tools: [any Tool],
                             onPartial: (@MainActor (String) -> Void)? = nil) async throws -> String {
        try await respondInput(instructions: instructions, prompt: "", messagesJSON: messagesJSON, tools: tools, onPartial: onPartial)
    }

    private func respondInput(instructions: String, prompt: String, messagesJSON: Data?, tools: [any Tool],
                              onPartial: (@MainActor (String) -> Void)?) async throws -> String {
        try Task.checkCancellation()
        guard requestTask == nil else { throw MetalAgentError.busy }
        let current = epoch
        let definitions = try Self.toolDefinitions(tools)
        guard (messagesJSON?.count ?? prompt.utf8.count) < (try Self.promptBudget(instructions: instructions, tools: tools)) else {
            throw AtlasContextError.requestTooLarge
        }
        try await prewarm()
        try Task.checkCancellation()
        guard epoch == current else { throw CancellationError() }
        // A second request may have arrived while the shared warmup was in flight.
        guard requestTask == nil else { throw MetalAgentError.busy }
        let runtime = runtime
        let task = Task { [weak self] in
            let partial: @Sendable (String) async -> Void = { [weak self] text in
                await MainActor.run {
                    guard let self, self.epoch == current, !Task.isCancelled else { return }
                    onPartial?(text)
                }
            }
            if let messagesJSON {
                return try await runtime.generateConversation(instructions: instructions +
                    "\nYou may propose up to eight independent calls together. Wait for results before calls that depend on them. Preserve all qualifications and conditions when summarizing.",
                    messagesJSON: messagesJSON, toolsJSON: definitions, onPartial: partial)
            }
            return try await runtime.generate(instructions: instructions +
                "\nPropose at most one tool call per response. Wait for its result before proposing another tool call.",
                prompt: prompt, toolsJSON: definitions, onPartial: partial)
        }
        requestTask = task
        defer { requestTask = nil }
        let reply = try await withTaskCancellationHandler {
            let reply = try await task.value
            try Task.checkCancellation()
            return reply
        } onCancel: { task.cancel() }
        guard epoch == current else { throw CancellationError() }
        if !reply.calls.isEmpty {
            guard reply.calls.count <= (messagesJSON == nil ? 1 : 8) else { throw MetalAgentError.multipleProposals }
            // Resolve every name before touching even the proposal recorder.
            let selected: [any AtlasProposalRecordingTool] = try reply.calls.map { call in
                guard let tool = tools.first(where: { $0.name == call.name }) as? any AtlasProposalRecordingTool,
                      call.argumentsJSON.utf8.count <= 16000 else { throw AtlasBridgeError.invalidFrame }
                return tool
            }
            guard let recorder = selected.first?.proposal,
                  selected.allSatisfy({ $0.proposal === recorder }) else { throw AtlasBridgeError.invalidFrame }
            await recorder.beginBatch()
            do {
                for (call, tool) in zip(reply.calls, selected) {
                    try Task.checkCancellation()
                    await recorder.identifyModelCall(.init(name: call.name, argumentsJSON: call.argumentsJSON))
                    do { try await Self.propose(tool, json: call.argumentsJSON) }
                    catch is AtlasProposalBoundary { continue }
                    throw AtlasBridgeError.invalidFrame
                }
                try Task.checkCancellation()
                guard epoch == current else { throw CancellationError() }
                try await recorder.commitBatch(expected: reply.calls.count)
            } catch {
                await recorder.discardBatch()
                throw error
            }
            throw AtlasProposalBoundary()
        }
        guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MetalAgentError.incomplete }
        return reply.text
    }

    /// Conservative admission for Atlas compaction; MLX additionally counts the rendered tokens.
    static func promptBudget(instructions: String, tools: [any Tool]) throws -> Int {
        let remaining = maximumContextTokens - responseTokens - framingReserve - instructions.utf8.count - (try toolDefinitions(tools).count)
        guard remaining > 384 else { throw AtlasContextError.toolBudgetTooLarge }
        return remaining
    }

    private static func toolDefinitions(_ tools: [any Tool]) throws -> Data {
        let definitions: [[String: Any]] = try tools.map { tool in
            ["type": "function", "function": ["name": tool.name, "description": tool.description,
                "parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.parameters))]]
        }
        return try JSONSerialization.data(withJSONObject: definitions, options: [.sortedKeys])
    }

    private static func propose<T: Tool>(_ tool: T, json: String) async throws {
        _ = try await tool.call(arguments: T.Arguments(GeneratedContent(json: json)))
    }
}

enum MetalAgentError: LocalizedError {
    case unavailable, modelMissing, unverifiedModel, busy, incomplete, timedOut, multipleProposals, invalidProposal
    var errorDescription: String? {
        switch self {
        case .multipleProposals: "The model proposed several actions together. Ask it to complete one step at a time."
        case .invalidProposal: "The model proposed an invalid tool request. No action was taken."
        case .unavailable: "The local MLX agent is unavailable. Try again after the model finishes loading."
        case .modelMissing: "The GLM model is missing. Install the verified MLX model in OmniFlow’s Models folder, or reconnect its model drive."
        case .unverifiedModel: "The local GLM files failed verification. Reinstall the verified MLX model before using the stronger agent."
        case .busy: "The local agent is finishing another request. Try again shortly."
        case .incomplete: "The local model did not finish its answer. Try a more focused request."
        case .timedOut: "The local model took too long to answer. Try again with a more focused request."
        }
    }
}

/// Fresh installations opt into the agent and the larger model separately.
@MainActor
final class AgentPreferences: ObservableObject {
    static let shared = AgentPreferences { applyRuntime() }
    @Published private(set) var enabled: Bool
    @Published private(set) var useStrongerModel: Bool
    private let defaults: UserDefaults
    private let changed: @MainActor () -> Void

    init(defaults: UserDefaults = .standard, changed: @escaping @MainActor () -> Void = {}) {
        self.defaults = defaults
        self.changed = changed
        let strong = defaults.bool(forKey: "omniflow.agent.glmMetal")
        useStrongerModel = strong
        // Preserve a previous explicit GLM opt-in, including this Mac's build-314 setting.
        if defaults.object(forKey: "omniflow.agent.enabled") == nil && strong {
            defaults.set(true, forKey: "omniflow.agent.enabled")
        }
        enabled = defaults.bool(forKey: "omniflow.agent.enabled")
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: "omniflow.agent.enabled")
        changed()
    }

    func setStrongerModel(_ value: Bool) {
        guard useStrongerModel != value else { return }
        useStrongerModel = value
        defaults.set(value, forKey: "omniflow.agent.glmMetal")
        changed()
    }

    private static func applyRuntime() {
        VoiceAssistant.shared.cancel()
        VoiceAssistant.shared.registerShortcut()
        if shared.enabled { AtlasRunnerSelection.launch(); WakeListener.shared.retry() }
        else { AtlasRunnerSelection.shutdown(); WakeListener.shared.stop() }
        if AtlasMetalAgent.enabled { AtlasMetalAgent.shared.start() }
        else { AtlasMetalAgent.shared.deactivate() }
    }
}

