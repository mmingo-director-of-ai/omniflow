import Foundation
import FoundationModels
import Testing
@testable import OmniFlowApp

/// Opt-in real transport/proposal smoke. No real tool can execute: wrappers only record proposals.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIFLOW_GLM_LIVE"] == "1"))
func metalAgentLocalIntegration() async throws {
    let agent = AtlasMetalAgent()
    defer { agent.stop() }
    async let first: Void = agent.prewarm()
    async let second: Void = agent.prewarm()
    _ = try await (first, second)
    let proposal = AtlasToolProposal()
    let tool = AtlasProposedTool<MacContextTool.Arguments>(name: "getMacContext", description: "Get live battery information. Use topic battery.", proposal: proposal)
    do {
        _ = try await agent.respond(instructions: "Use getMacContext to answer live battery questions. Never invent the battery level.",
            prompt: "What is my current battery level?", tools: [tool])
        Issue.record("Expected the proposal boundary")
    } catch {
        if await proposal.call == nil { throw error }
    }
    let call = await proposal.call
    #expect(call?.name == "getMacContext")
    #expect(call?.argumentsJSON.contains("battery") == true)
    let answer = try await agent.respond(instructions: "Answer only from the supplied tool result.",
        prompt: "Battery tool result: charge is 73 percent. What is the battery level?", tools: [])
    #expect(answer.contains("73"))
}

@MainActor @Test func metalWarmupCoalescesAndRetriesFailure() async throws {
    let state = MetalWarmupState()
    let agent = scriptedMetalAgent(transport: { endpoint, payload in
        if endpoint == "show" {
            return ["modelfile": "FROM /models/sha256-9eba2761cf0b88b8bc11a065a7b5b47f1b13ce820e8e492cb1010b450f9ec950"]
        }
        state.loads += 1
        #expect(payload["prompt"] as? String == "")
        try await Task.sleep(for: .milliseconds(30))
        if state.fail { throw URLError(.cannotConnectToHost) }
        return ["done": true]
    })
    async let a: Void = agent.prewarm()
    async let b: Void = agent.prewarm()
    do { _ = try await (a, b); Issue.record("Expected a warmup error") } catch { }
    #expect(state.loads == 1)
    state.fail = false
    try await agent.prewarm()
    #expect(state.loads == 2)
}

@MainActor @Test func metalRejectsUnadvertisedToolBeforeDispatch() async throws {
    let agent = scriptedMetalAgent(transport: { endpoint, _ in
        switch endpoint {
        case "show": return ["modelfile": "FROM /models/sha256-9eba2761cf0b88b8bc11a065a7b5b47f1b13ce820e8e492cb1010b450f9ec950"]
        case "generate": return ["done": true]
        default: return ["done": true, "message": ["tool_calls": [["function": ["name": "runShell", "arguments": ["command": "bad"]]]]]]
        }
    })
    await #expect(throws: (any Error).self) {
        try await agent.respond(instructions: "", prompt: "", tools: [])
    }
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIFLOW_GLM_LIVE"] == "1"))
func metalAgentThroughAtlasRunner() async throws {
    let agent = AtlasMetalAgent()
    defer { agent.stop() }
    var environment = AtlasAssistant.environment()
    var calls = 0
    environment.tools = [AtlasHostTool<MacContextTool.Arguments>(name: "getMacContext", description: "Read battery charge from this Mac.", call: { _ in
        calls += 1
        return "Battery charge is 73 percent. " + String(repeating: "No other battery data. ", count: 1400)
    })]
    environment.promptByteBudget = { try AtlasMetalAgent.promptBudget(instructions: $0, tools: $1) }
    environment.respond = { try await agent.respond(instructions: $0, prompt: $1, tools: $2) }
    let runner = NativeAtlasRunner<AtlasFrame>(pool: MCPConnectionPool(), launcher: nil,
        mapError: AtlasBridgeError.remoteCode, timedOut: AtlasBridgeError.timedOut)
    let answer = try await AtlasModelHost.answer("Read my current battery level and tell me the percentage.", environment: environment,
        runner: runner, servers: [])
    #expect(calls > 0)
    #expect(answer.contains("73"))
}

@MainActor private final class MetalWarmupState {
    var loads = 0
    var fail = true
}

@MainActor @Test func metalAgentPreferencesAreOptInAndPreserveExistingChoice() throws {
    let name = "agent-options-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let fresh = AgentPreferences(defaults: defaults)
    #expect(!fresh.enabled)
    #expect(!fresh.useStrongerModel)
    defaults.set(true, forKey: "omniflow.agent.glmMetal")
    let existing = AgentPreferences(defaults: defaults)
    #expect(existing.enabled && existing.useStrongerModel)
    existing.setEnabled(false)
    let reopened = AgentPreferences(defaults: defaults)
    #expect(!reopened.enabled)
    #expect(reopened.useStrongerModel)
    reopened.setStrongerModel(false)
    reopened.setEnabled(true)
    let standard = AgentPreferences(defaults: defaults)
    #expect(standard.enabled && !standard.useStrongerModel)
}

@MainActor @Test func metalOptOutRequestsModelUnload() async throws {
    var unloaded = false
    let runtime = ScriptedMetalRuntime(transport: { _, _ in ["done": true] })
    runtime.onUnload = { unloaded = true }
    let agent = AtlasMetalAgent(runtime: runtime)
    agent.deactivate()
    for _ in 0..<100 {
        if unloaded { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(unloaded)
}

@MainActor @Test func metalContextCompactsBeforeTransportAdmission() async throws {
    let instructions = String(repeating: "Instruction. ", count: 300)
    let budget = try AtlasMetalAgent.promptBudget(instructions: instructions, tools: [])
    let source = String(repeating: "This is source evidence. ", count: 10000)
    let result = String(decoding: try JSONSerialization.data(withJSONObject: [
        "text": source, "startByte": 0, "endByte": source.utf8.count,
        "payload": ["id": "p1", "source": "test", "sha256": String(repeating: "a", count: 64),
                    "bytes": source.utf8.count, "chunks": 1, "kind": "text"]
    ]), as: UTF8.self)
    let slice = try await AtlasContextWindow().prepare(messages: [
        AtlasMessage(role: "user", content: "PINNED_USER_REQUEST"),
        AtlasMessage(role: "assistant", content: "Read the document"),
        AtlasMessage(role: "tool", content: result)
    ], archived: 0, capacity: budget, fixedTokens: 0, responseTokens: 0, finalStep: false,
        question: "PINNED_USER_REQUEST", count: { $0.utf8.count })
    #expect(slice.prompt.utf8.count < budget)
    #expect(slice.prompt.contains("PINNED_USER_REQUEST"))
    #expect(slice.prompt.contains("source evidence"))
    #expect(slice.prompt.utf8.count < source.utf8.count)
    #expect(throws: AtlasContextError.self) {
        try AtlasMetalAgent.promptBudget(instructions: String(repeating: "x", count: AtlasMetalAgent.maximumContextTokens), tools: [])
    }
}

/// Full Mac inventory and cursor context, with only inference replaced by a deterministic transport.
/// This checks host admission and runner wiring; it is not a live-model quality test.
@MainActor @Test(arguments: ["Hello", "Explain what a phishing email is.", "Help me plan tomorrow."])
func metalChatUsesProviderBudgetWithMacInventory(question: String) async throws {
    var requests = 0
    let agent = scriptedMetalAgent(transport: { endpoint, payload in
        switch endpoint {
        case "show": return ["modelfile": "FROM /models/sha256-9eba2761cf0b88b8bc11a065a7b5b47f1b13ce820e8e492cb1010b450f9ec950"]
        case "generate": return ["done": true]
        default:
            requests += 1
            let messages = try #require(payload["messages"] as? [[String: String]])
            #expect(messages.last?["content"]?.contains(question) == true)
            #expect((payload["tools"] as? [[String: Any]])?.isEmpty == false)
            return ["done": true, "message": ["content": "Verified test answer"]]
        }
    })
    defer { agent.stop() }
    var environment = AtlasAssistant.environment(cursorContext: String(repeating: "Visible context. ", count: 280), question: question)
    environment.promptByteBudget = { try AtlasMetalAgent.promptBudget(instructions: $0, tools: $1) }
    environment.respond = { try await agent.respond(instructions: $0, prompt: $1, tools: $2) }
    let runner = NativeAtlasRunner<AtlasFrame>(pool: MCPConnectionPool(), launcher: nil,
        mapError: AtlasBridgeError.remoteCode, timedOut: AtlasBridgeError.timedOut)
    let answer = try await AtlasModelHost.answer(question, environment: environment, runner: runner, servers: [])
    #expect(answer == "Verified test answer")
    #expect(requests == 1)
}

@MainActor @Test func metalToolRoundTripRetainsEvidenceAndExecutesOnce() async throws {
    var requests = 0
    var executions = 0
    let agent = scriptedMetalAgent(transport: { endpoint, payload in
        switch endpoint {
        case "show": return ["modelfile": "FROM /models/sha256-9eba2761cf0b88b8bc11a065a7b5b47f1b13ce820e8e492cb1010b450f9ec950"]
        case "generate": return ["done": true]
        default:
            requests += 1
            if requests == 1 {
                #expect(executions == 0)
                return ["done": true, "message": ["tool_calls": [["function": [
                    "name": "getMacContext", "arguments": ["topic": "battery", "timeZone": NSNull()]
                ]]]]]
            }
            let messages = try #require(payload["messages"] as? [[String: String]])
            let prompt = messages.last?["content"] ?? ""
            #expect(prompt.contains("73 percent"), Comment(rawValue: String(prompt.prefix(7000))))
            return ["done": true, "message": ["content": "Your battery is at 73 percent."]]
        }
    })
    defer { agent.stop() }
    var environment = AtlasAssistant.environment()
    environment.tools = [AtlasHostTool<MacContextTool.Arguments>(name: "getMacContext", description: "Read battery charge.", call: { _ in
        executions += 1
        return "Battery charge is 73 percent. " + String(repeating: "No other battery data. ", count: 1400)
    })]
    environment.promptByteBudget = { try AtlasMetalAgent.promptBudget(instructions: $0, tools: $1) }
    environment.respond = { try await agent.respond(instructions: $0, prompt: $1, tools: $2) }
    let runner = NativeAtlasRunner<AtlasFrame>(pool: MCPConnectionPool(), launcher: nil,
        mapError: AtlasBridgeError.remoteCode, timedOut: AtlasBridgeError.timedOut)
    let answer = try await AtlasModelHost.answer("What is my battery charge?", environment: environment, runner: runner, servers: [])
    #expect(answer.contains("73"))
    #expect(executions == 1)
    #expect(requests == 2)
}

@MainActor @Test func metalContextGrowsPastFormerByteLimit() throws {
    #expect(try AtlasMetalAgent.promptBudget(instructions: "", tools: []) > 180_000)

}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIFLOW_GLM_LIVE"] == "1"))
func metalLivePromptExceedsFormerLimit() async throws {
    let agent = AtlasMetalAgent()
    defer { agent.stop() }
    let prompt = String(repeating: "Reference padding; no action required.\n", count: 850) + "\nReply with the word READY."
    #expect(prompt.utf8.count > 24_000)
    let answer = try await agent.respond(instructions: "Follow the final user request. Give a short answer.", prompt: prompt, tools: [])
    #expect(answer.uppercased().contains("READY"))
}

@Test func assistantHTMLIsPassiveAndKeepsFormatting() {
    let value = AssistantMarkup.formatted("<h2>Heading</h2><p>Hello <strong>world</strong>.</p><script>alert(1)</script><iframe src='https://tracker'>hidden</iframe><img src='https://tracker'><a href='javascript:alert(1)'>Bad link</a><a href='https://example.com'>Good link</a>")
    #expect(value.contains("## Heading"))
    #expect(value.contains("**world**"))
    #expect(value.contains("[Good link](https://example.com)"))
    #expect(!value.contains("alert"))
    #expect(!value.contains("tracker"))
    #expect(!value.contains("hidden"))
    #expect(value.contains("Bad link"))
    #expect(!AssistantMarkup.html("<a href='file:///etc/passwd'>File</a>").contains("file:"))
    let code = "```html\n<script>alert(1)</script>\n```"
    #expect(AssistantMarkup.formatted(code).contains(code))
    #expect(AssistantMarkup.html("<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>").contains("| 1 | 2 |"))
}

@Test func metalStreamHidesThinkingAndRequiresCompletion() throws {
    var filter = MLXAnswerFilter()
    try filter.append("<thi")
    #expect(filter.visible.isEmpty)
    try filter.append("nk>private reasoning</thi")
    #expect(filter.visible.isEmpty)
    try filter.append("nk>Hello world")
    try filter.finish()
    #expect(filter.visible == "Hello world")
    var cut = MLXAnswerFilter()
    try cut.append("<think>unfinished")
    #expect(throws: (any Error).self) { try cut.finish() }
}

@Test func conversationArchiveSurvivesWorkingWindowAndRestores() throws {
    var chat = AssistantConversation()
    for i in 0..<8 {
        let request = chat.begin(question: "Question \(i)", scope: "project")
        chat.complete(request, answer: "Answer \(i)", succeeded: true)
    }
    #expect(chat.archive.count == 8)
    #expect(chat.turns.count == 4)
    let next = chat.begin(question: "Continue", scope: "project", fullContext: true)
    #expect(next.turns.count == 8)
    chat.cancel()
    #expect(chat.archive.count == 8)
    var reopened = AssistantConversation()
    reopened.restore(chat.archive, scope: "project")
    #expect(reopened.archive == chat.archive)
    reopened.reset(scope: "project")
    #expect(reopened.archive.isEmpty)
}

@Test func savedConversationGroupsTurnsAndKeepsLegacyRecords() throws {
    let id = UUID()
    let first = ConversationRecord(question: "First", answer: "One", conversationID: id)
    let second = ConversationRecord(question: "Second", answer: "Two", conversationID: id)
    let legacy = try JSONDecoder().decode(ConversationRecord.self, from: JSONEncoder().encode(ConversationRecord(question: "Old", answer: "Saved")))
    let ambient = ConversationRecord(question: "", answer: "Notification", source: "ambient")
    let grouped = ConversationThread.group([first, second, legacy, ambient])
    #expect(grouped.count == 2)
    #expect(grouped.first(where: { $0.id == id })?.records.count == 2)
}

@Test func dailyDictationsKeepBothVersionsAndLocalMidnight() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
    let before = ISO8601DateFormatter().date(from: "2026-10-07T14:59:00Z")!
    let after = before.addingTimeInterval(120)
    let a = DictationEntry(date: before, raw: "original", text: "Edited.", note: "", destination: "Notes")
    let b = DictationEntry(date: after, raw: "next", text: "Next.", note: "", destination: "Notes")
    let days = DictationDay.group([a, b], calendar: calendar)
    #expect(days.count == 2)
    #expect(days.last?.entries.first?.raw == "original")
    #expect(days.last?.entries.first?.text == "Edited.")
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIFLOW_GLM_LIVE"] == "1"))
func metalLiveConversationRetainsSubjectAndStreams() async throws {
    let agent = AtlasMetalAgent()
    defer { agent.stop() }
    var environment = AtlasAssistant.environment()
    environment.promptByteBudget = { try AtlasMetalAgent.promptBudget(instructions: $0, tools: $1) }
    environment.respondStreaming = { try await agent.respond(instructions: $0, prompt: $1, tools: $2, onPartial: $3) }
    let question = "For this conversation our project label is amber-lantern. Acknowledge briefly; do not save it or use tools."
    let first = try await AtlasModelHost.answer(question, environment: environment,
        runner: NativeAtlasRunner<AtlasFrame>(pool: MCPConnectionPool(), launcher: nil), servers: [])
    var partials: [String] = []
    let start = Date()
    var firstToken: Double?
    let second = try await AtlasModelHost.answer("What project label did I just give you? Reply with the label only, using our conversation.", environment: environment,
        runner: NativeAtlasRunner<AtlasFrame>(pool: MCPConnectionPool(), launcher: nil), servers: [],
        conversation: [.init(question: question, answer: first)], onPartial: {
            if firstToken == nil { firstToken = Date().timeIntervalSince(start) }
            partials.append($0)
        })
    #expect(second.localizedCaseInsensitiveContains("amber-lantern"))
    #expect(!partials.isEmpty)
    #expect(partials.allSatisfy { second.hasPrefix($0) })
    print("GLM follow-up first text: \(firstToken ?? -1)s; total: \(Date().timeIntervalSince(start))s")
}

@MainActor @Test func metalConnectionFailureHasActionableError() async throws {
    let agent = scriptedMetalAgent(transport: { _, _ in throw MetalAgentError.modelMissing })
    do {
        _ = try await agent.respond(instructions: "", prompt: "Hello", tools: [])
        Issue.record("Expected a local service error")
    } catch let error as MetalAgentError {
        #expect(error.localizedDescription.contains("model is missing"))
    }
    let cancelled = scriptedMetalAgent(transport: { _, _ in throw CancellationError() })
    await #expect(throws: CancellationError.self) {
        try await cancelled.respond(instructions: "", prompt: "Hello", tools: [])
    }
}

@MainActor private final class MetalDiscoveryRunner: AtlasRunner {
    typealias Frame = AtlasFrame
    func run<Tool: Encodable, Server: Codable & Sendable>(
        prompt: String, tools: [Tool], servers: [Server], mode: String?, question: String?, discoveryQuery: String?,
        workspace: URL?, resume: Bool, timeout: Double, requireAuthentication: Bool,
        authorize: (@MainActor ([Server], Bool) async throws -> [Server])?,
        onModel: @escaping Handler, onTool: @escaping Handler) async throws -> AtlasRuntimeResult {
        var frame = AtlasFrame(type: "model")
        frame.step = 1
        frame.messages = [AtlasMessage(role: "user", content: prompt)]
        frame.mcpDiscovery = [.init(server: "s1", name: "Project wiki", error: nil, toolCount: 1, hasMore: false,
            tools: [.init(name: "wiki", description: "Search and read project notes and documents")])]
        let result = try await onModel(frame)
        #expect(result.toolCalls == nil, "General chat must reach the selected planner before a remote lookup")
        return AtlasRuntimeResult(text: result.content ?? "", steps: 1, toolCount: 0)
    }
}

@MainActor @Test func metalPlannerReceivesChatWithConnectedServices() async throws {
    var environment = AtlasAssistant.environment()
    var reachedPlanner = false
    environment.promptByteBudget = { try AtlasMetalAgent.promptBudget(instructions: $0, tools: $1) }
    environment.respond = nil
    environment.respondStreaming = { _, prompt, tools, _ in
        reachedPlanner = true
        #expect(prompt.contains("amber-lantern"))
        #expect(tools.contains { $0.name == "selectMCPTool" })
        return "# Amber Lantern\n- First point\n- Second point"
    }
    var server = MCPServerConfiguration()
    server.name = "Project wiki"; server.enabled = true
    server.allowedTools = [.init(name: "wiki", digest: "fixture")]
    let answer = try await AtlasModelHost.answer(
        "For this chat the project label is amber-lantern. Reply with a heading and two bullets. Do not use tools.",
        environment: environment, runner: MetalDiscoveryRunner(), servers: [server])
    #expect(reachedPlanner)
    #expect(answer.hasPrefix("# Amber Lantern"))
}

/// In-memory fixture for provider/Atlas checks. No network protocol or model is involved.
@MainActor private func scriptedMetalAgent(
    transport: @escaping @MainActor (String, [String: Any]) async throws -> [String: Any]
) -> AtlasMetalAgent {
    AtlasMetalAgent(runtime: ScriptedMetalRuntime(transport: transport))
}

@MainActor private final class ScriptedMetalRuntime: MetalAgentRuntime {
    let transport: @MainActor (String, [String: Any]) async throws -> [String: Any]
    init(transport: @escaping @MainActor (String, [String: Any]) async throws -> [String: Any]) { self.transport = transport }
    func prewarm() async throws { _ = try await transport("generate", ["prompt": ""]) }
    var onUnload: (@MainActor () -> Void)?
    func unload() async { onUnload?() }
    func generate(instructions: String, prompt: String, toolsJSON: Data,
                  onPartial: (@Sendable (String) async -> Void)?) async throws -> MetalAgentReply {
        let response = try await transport("chat", ["messages": [["role": "system", "content": instructions],
            ["role": "user", "content": prompt]], "tools": try JSONSerialization.jsonObject(with: toolsJSON)])
        guard response["done"] as? Bool == true, response["done_reason"] as? String != "length",
              let message = response["message"] as? [String: Any] else { throw AtlasBridgeError.invalidFrame }
        let calls = try (message["tool_calls"] as? [[String: Any]] ?? []).map { item -> MetalAgentReply.Call in
            let function = try #require(item["function"] as? [String: Any])
            let name = try #require(function["name"] as? String)
            let data = try JSONSerialization.data(withJSONObject: function["arguments"] ?? [:])
            return .init(name: name, argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        return .init(text: message["content"] as? String ?? "", calls: calls)
    }
}
