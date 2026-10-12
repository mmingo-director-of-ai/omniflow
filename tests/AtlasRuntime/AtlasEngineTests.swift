// SDK loop and planner behaviour (loop.go / planning.go) outside the host.
import Foundation
import Testing
import Synchronization
@testable import OmniFlowApp

final class ScriptedProvider: AtlasAgentProvider {
    var responses: [AtlasGenerateResult]
    var seen: [[AtlasRuntimeMessage]] = []
    init(_ responses: [AtlasGenerateResult]) { self.responses = responses }
    nonisolated(nonsending) func generate(_ messages: [AtlasRuntimeMessage], tools: [AtlasToolSchema]) async throws -> AtlasGenerateResult {
        seen.append(messages)
        return responses.isEmpty ? AtlasGenerateResult(content: "done", toolCalls: []) : responses.removeFirst()
    }
}

final class SleepingTool: AtlasAgentTool {
    let name: String
    var description: String { name }
    var inputSchema: AtlasJSON? { nil }
    let failures: Mutex<Int>
    init(name: String, failures: Int = 0) { self.name = name; self.failures = Mutex(failures) }
    nonisolated(nonsending) func execute(_ arguments: [String: AtlasJSON]) async throws -> String {
        let fail = failures.withLock { remaining -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if fail { throw AtlasRuntimeError("transient") }
        try await Task.sleep(for: .milliseconds(200))
        return "\(name) ok"
    }
}

struct AtlasEngineTests {
    func call(_ name: String, _ id: String) -> AtlasToolCallData { AtlasToolCallData(name: name, arguments: [:], id: id) }

    @Test func messagesStopConditionsAndRetries() async throws {
        let provider = ScriptedProvider([AtlasGenerateResult(content: "thinking", toolCalls: [call("flaky", "c1")])])
        var config = AtlasAgentLoopConfig()
        config.backoff = { _ in .milliseconds(1) }
        let calls = Mutex(0)
        config.onToolCall = { _ in calls.withLock { $0 += 1 } }
        let engine = AtlasAgentEngine(provider: provider, tools: ["flaky": SleepingTool(name: "flaky", failures: 2)], config: config)
        let result = try await engine.execute(prompt: "goal")
        #expect(result.finishReason == .stop && result.text == "done" && result.steps.count == 2 && result.toolCalls.count == 1)
        #expect(result.toolCalls[0].success && result.toolCalls[0].retries == 2 && calls.withLock { $0 } == 1)
        // One assistant message, then one tool message keyed by the call id.
        let second = provider.seen[1]
        #expect(second.map(\.role) == ["user", "assistant", "tool"] && second[2].toolCallId == "c1" && second[2].content == "flaky ok")
        #expect(result.summary.hasPrefix("Completed in 2 steps, with 1 tool calls"))
    }

    @Test func failedToolsRenderGoMapAndUnknownTools() async throws {
        let provider = ScriptedProvider([AtlasGenerateResult(content: "", toolCalls: [call("missing", "c1")])])
        let engine = AtlasAgentEngine(provider: provider, tools: [:], config: AtlasAgentLoopConfig())
        let result = try await engine.execute(prompt: "goal")
        #expect(provider.seen[1].last?.content == "map[error:Unknown tool: missing]" && !result.toolCalls[0].success)
    }

    @Test func maxStepsAndParallelReadTools() async throws {
        var config = AtlasAgentLoopConfig()
        config.maxSteps = 2
        config.parallelExecution = true
        let provider = ScriptedProvider(Array(repeating: AtlasGenerateResult(content: "", toolCalls: [call("get_a", "a"), call("list_b", "b"), call("read_c", "c")]), count: 3))
        let engine = AtlasAgentEngine(provider: provider, tools: ["get_a": SleepingTool(name: "get_a"), "list_b": SleepingTool(name: "list_b"),
                                                                  "read_c": SleepingTool(name: "read_c")], config: config)
        let started = ContinuousClock.now
        let result = try await engine.execute(prompt: "goal")
        #expect(result.finishReason == .maxSteps && result.toolCalls.count == 6)
        #expect(result.toolCalls.map(\.id) == ["a", "b", "c", "a", "b", "c"] && result.toolCalls.allSatisfy(\.parallel))
        #expect(ContinuousClock.now - started < .milliseconds(1000), "read-only calls did not run concurrently")
        #expect(AtlasAgentEngine.analyzeDependencies([call("write_x", "w"), call("get_y", "g")]).dependent.map(\.name) == ["write_x"])
    }

    @Test func plannerDecomposesVerifiesAndSchedules() throws {
        let planner = AtlasPlanner()
        var plan = try planner.plan(goal: "Investigate and fix the outage", availableTools: ["search_logs", "get_status", "update_config", "verify_health"])
        #expect(plan.steps.map(\.description) == ["Gather information about: Investigate and fix the outage", "Analyze gathered information",
                                                  "Assess the situation", "Execute remediation actions", "Verify remediation success"])
        #expect(plan.steps[0].tools == ["search_logs", "get_status"] && plan.steps[3].dependencies == [plan.steps[0].id])
        #expect(planner.verify(plan, availableTools: ["search_logs"]).valid)
        #expect(planner.executableSteps(plan).count == 2)
        let first = plan.steps[0].id
        planner.startStep(&plan, first)
        planner.completeStep(&plan, first, result: "ok")
        #expect(plan.status == .inProgress && planner.nextStep(plan)?.id == plan.steps[1].id)
        planner.failStep(&plan, plan.steps[1].id, error: "x")
        #expect(planner.retryStep(&plan, plan.steps[1].id) && plan.metadata.failedSteps == 0)
        var cyclic = plan
        cyclic.steps[0].dependencies = [cyclic.steps[1].id]
        #expect(!planner.verify(cyclic, availableTools: []).valid)
        #expect(planner.cancelPlan(plan.id) && planner.plan(id: plan.id)?.status == .cancelled)
    }
}
