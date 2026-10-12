// Native Atlas runtime: the Atlas SDK agent loop.
//
// Port of sdk/go/pkg/agent/loop.go from the canonical Atlas Go SDK
// (MIT, Copyright Quandry Labs) at revision
// 49104b74160ee24cc350eee461df6378e51cccd3 (version 3.5.7). Semantics kept:
// step budget, stop conditions (timeout, token/cost budgets, three
// unrecoverable errors, custom), one assistant message plus one tool message
// per execution, read-only tools parallelised when enabled, and retries with
// 2s/4s/8s exponential backoff that stop on cancellation.
import Foundation

public enum AtlasStopCondition: String, Sendable {
    case stop, maxSteps = "max_steps", maxTokens = "max_tokens", maxCost = "max_cost", timeout, error
    case userStop = "user_stop", goalComplete = "goal_complete", resourceLimit = "resource_limit", custom
}

public struct AtlasToolExecution: Sendable {
    public var id: String
    public var name: String
    public var arguments: [String: AtlasJSON]
    public var result: String
    public var duration: Duration
    public var success: Bool
    public var error: String
    public var parallel: Bool
    public var retries: Int
}

public struct AtlasAgentStep: Sendable {
    public var step: Int
    public var role: String
    public var content: String
    public var toolCalls: [AtlasToolExecution]
    public var tokensUsed: Int
    public var cost: Double
    public var timestamp: Date
}

public struct AtlasStepError: Sendable {
    public var step: Int
    public var error: String
    public var recoverable: Bool
}

public struct AtlasAgentState: Sendable {
    public var steps: [AtlasAgentStep] = []
    public var totalTokens = 0
    public var totalCost = 0.0
    public var totalDuration: Duration = .zero
    public var toolCalls: [AtlasToolExecution] = []
    public var stopCondition: AtlasStopCondition?
    public var currentGoal = ""
    public var errors: [AtlasStepError] = []
}

public struct AtlasToolSchema: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: AtlasJSON?
}

public struct AtlasToolCallData: Sendable {
    public var name: String
    public var arguments: [String: AtlasJSON]
    public var id: String
    public var modelName: String? = nil
    public var modelArgumentsJSON: String? = nil
}

public struct AtlasGenerateResult: Sendable {
    public var content: String
    public var toolCalls: [AtlasToolCallData]
    public var tokensUsed = 0
    public var cost = 0.0
}

/// An executable tool. Tools are Sendable because the SDK may run read-only
/// calls concurrently when `parallelExecution` is enabled.
public protocol AtlasAgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// Optional JSON Schema advertised to the model (SDK `SchemaProvider`).
    var inputSchema: AtlasJSON? { get }
    nonisolated(nonsending) func execute(_ arguments: [String: AtlasJSON]) async throws -> String
}

public protocol AtlasAgentProvider: AnyObject {
    nonisolated(nonsending) func generate(_ messages: [AtlasRuntimeMessage], tools: [AtlasToolSchema]) async throws -> AtlasGenerateResult
}

/// Wraps a provider failure; mirrors Go's `provider error: %w`.
public struct AtlasProviderError: Error, Sendable, CustomStringConvertible {
    public let underlying: any Error
    public var description: String { "provider error: \(underlying)" }
}

public struct AtlasAgentLoopConfig {
    public var maxSteps = 10
    public var maxTokens: Int?
    public var maxCost: Double?
    public var timeout: Duration?
    public var temperature = 0.7
    public var parallelExecution = false
    public var maxParallelTools = 5
    public var autoRecovery = false
    public var maxRetries = 0
    public var onStep: ((AtlasAgentStep, AtlasAgentState) -> Void)?
    public var onToolCall: ((AtlasToolExecution) -> Void)?
    public var onStop: ((AtlasStopCondition, AtlasAgentState) -> Void)?
    public var shouldStop: ((AtlasAgentState) -> AtlasStopCondition?)?
    /// Backoff before retry n (1-based); the SDK uses min(1000·2ⁿ, 10000) ms.
    public var backoff: (Int) -> Duration = { .milliseconds(min(1000 * (1 << $0), 10000)) }
    public init() {}
}

public struct AtlasAgentResult: Sendable {
    public var text: String
    public var toolCalls: [AtlasToolExecution]
    public var finishReason: AtlasStopCondition
    public var steps: [AtlasAgentStep]
    public var state: AtlasAgentState
    public var summary: String
}

/// The SDK `AgentLoop`. One instance runs in one isolation domain; `execute`
/// inherits its caller's executor (the run's actor).
public final class AtlasAgentEngine {
    let provider: any AtlasAgentProvider
    let tools: [String: any AtlasAgentTool]
    var config: AtlasAgentLoopConfig
    private(set) var state = AtlasAgentState()
    /// Cancellation probe (the Go context); defaults to task cancellation.
    var isCancelled: () -> Bool = { Task.isCancelled }

    public init(provider: any AtlasAgentProvider, tools: [String: any AtlasAgentTool], config: AtlasAgentLoopConfig) {
        var config = config
        if config.maxSteps == 0 { config.maxSteps = 10 }
        if config.temperature == 0 { config.temperature = 0.7 }
        if config.maxParallelTools == 0 { config.maxParallelTools = 5 }
        self.provider = provider; self.tools = tools; self.config = config
    }

    public nonisolated(nonsending) func execute(prompt: String, messages: [AtlasRuntimeMessage] = []) async throws -> AtlasAgentResult {
        let started = ContinuousClock.now
        state = AtlasAgentState()
        state.currentGoal = prompt
        var conversation = [AtlasRuntimeMessage(role: "user", content: prompt)] + messages
        var step = 0
        loop: while step < config.maxSteps {
            step += 1
            if let condition = checkStopConditions(started) {
                state.stopCondition = condition
                break loop
            }
            if isCancelled() {
                state.stopCondition = .userStop
                break loop
            }
            let response: AtlasGenerateResult
            do {
                response = try await provider.generate(conversation, tools: toolSchemas())
            } catch {
                state.stopCondition = .error
                throw AtlasProviderError(underlying: error)
            }
            state.totalTokens += response.tokensUsed
            state.totalCost += response.cost
            var assistant = AtlasAgentStep(step: step, role: "assistant", content: response.content, toolCalls: [],
                                           tokensUsed: response.tokensUsed, cost: response.cost, timestamp: Date())
            if response.toolCalls.isEmpty {
                state.steps.append(assistant)
                state.stopCondition = .stop
                break loop
            }
            let executions = await executeToolCalls(response.toolCalls, step: step)
            assistant.toolCalls = executions
            // One assistant message, then one tool message per execution keyed by id.
            let historyCalls = response.toolCalls.map { call in
                var history = AtlasRuntimeToolCall(name: call.name, argumentsJSON: AtlasJSON.object(call.arguments).goText)
                history.id = call.id
                history.modelName = call.modelName
                history.modelArgumentsJSON = call.modelArgumentsJSON
                return history
            }
            conversation.append(AtlasRuntimeMessage(role: "assistant", content: response.content, toolCalls: historyCalls))
            for execution in executions {
                conversation.append(AtlasRuntimeMessage(role: "tool", content: execution.result, toolCallId: execution.id))
            }
            state.steps.append(assistant)
            state.toolCalls += executions
            config.onStep?(assistant, state)
        }
        if state.stopCondition == nil { state.stopCondition = .maxSteps }
        state.totalDuration = .now - started
        let condition = state.stopCondition!
        config.onStop?(condition, state)
        return AtlasAgentResult(text: state.steps.last?.content ?? "", toolCalls: state.toolCalls, finishReason: condition,
                                steps: state.steps, state: state, summary: summary())
    }

    func toolSchemas() -> [AtlasToolSchema] {
        tools.values.map { AtlasToolSchema(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
    }

    /// Read-like tool names may run in parallel; everything else runs in order.
    static func analyzeDependencies(_ calls: [AtlasToolCallData]) -> (independent: [AtlasToolCallData], dependent: [AtlasToolCallData]) {
        let reads = ["get", "read", "list", "search", "query", "fetch", "find", "show"]
        var independent: [AtlasToolCallData] = [], dependent: [AtlasToolCallData] = []
        for call in calls {
            if reads.contains(where: { call.name.contains($0) }) { independent.append(call) } else { dependent.append(call) }
        }
        return (independent, dependent)
    }

    nonisolated(nonsending) func executeToolCalls(_ calls: [AtlasToolCallData], step: Int) async -> [AtlasToolExecution] {
        var executions: [AtlasToolExecution] = []
        // With parallelism disabled, preserve proposal order across stateful tools.
        // A name containing "read" is not authority to reorder or overlap it.
        if !config.parallelExecution {
            for call in calls {
                if isCancelled() { break }
                executions.append(await executeTool(call, step: step, parallel: false))
            }
            return executions
        }
        let (independent, dependent) = Self.analyzeDependencies(calls)
        if config.parallelExecution && independent.count > 1 {
            executions += await executeParallel(independent, step: step)
        } else {
            for call in independent { executions.append(await executeTool(call, step: step, parallel: false)) }
        }
        for call in dependent { executions.append(await executeTool(call, step: step, parallel: false)) }
        return executions
    }

    /// Runs every call concurrently, bounded by `maxParallelTools`, keeping
    /// emission order. Tool callbacks and state updates stay on this isolation.
    nonisolated(nonsending) func executeParallel(_ calls: [AtlasToolCallData], step: Int) async -> [AtlasToolExecution] {
        let limit = config.maxParallelTools > 0 ? config.maxParallelTools : calls.count
        let tools = tools
        var outcomes = [(Result<String, any Error>, Duration)?](repeating: nil, count: calls.count)
        await withTaskGroup(of: (Int, Result<String, any Error>, Duration).self) { group in
            var next = 0
            func add() {
                guard next < calls.count else { return }
                let index = next, call = calls[index]
                next += 1
                group.addTask {
                    let started = ContinuousClock.now
                    guard let tool = tools[call.name] else { return (index, .failure(AtlasRuntimeError("unknown_tool")), .zero) }
                    do { return (index, .success(try await tool.execute(call.arguments)), .now - started) } catch {
                        return (index, .failure(error), .now - started)
                    }
                }
            }
            for _ in 0..<min(limit, calls.count) { add() }
            while let (index, result, duration) = await group.next() {
                outcomes[index] = (result, duration)
                add()
            }
        }
        // Failed parallel calls fall back to the sequential retry policy.
        var executions: [AtlasToolExecution] = []
        for (index, call) in calls.enumerated() {
            if case let (.success(value), duration)? = outcomes[index] {
                let execution = AtlasToolExecution(id: call.id.isEmpty ? Self.generatedID() : call.id, name: call.name, arguments: call.arguments,
                                                   result: value, duration: duration, success: true, error: "", parallel: true, retries: 0)
                config.onToolCall?(execution)
                executions.append(execution)
            } else {
                executions.append(await executeTool(call, step: step, parallel: true, firstAttemptDone: true))
            }
        }
        return executions
    }

    nonisolated(nonsending) func executeTool(_ call: AtlasToolCallData, step: Int, parallel: Bool, firstAttemptDone: Bool = false) async -> AtlasToolExecution {
        let id = call.id.isEmpty ? Self.generatedID() : call.id
        let started = ContinuousClock.now
        guard let tool = tools[call.name] else {
            let message = "Unknown tool: \(call.name)"
            return AtlasToolExecution(id: id, name: call.name, arguments: call.arguments, result: "map[error:\(message)]",
                                      duration: .now - started, success: false, error: message, parallel: parallel, retries: 0)
        }
        let maxRetries = config.maxRetries == 0 ? 3 : config.maxRetries
        var retries = firstAttemptDone ? 1 : 0
        var lastError = ""
        while retries <= maxRetries {
            if isCancelled() {
                lastError = "context canceled"
                recordError(step, lastError, recoverable: false)
                break
            }
            do {
                let result = try await tool.execute(call.arguments)
                let execution = AtlasToolExecution(id: id, name: call.name, arguments: call.arguments, result: result,
                                                   duration: .now - started, success: true, error: "", parallel: parallel, retries: retries)
                config.onToolCall?(execution)
                return execution
            } catch {
                retries += 1
                lastError = Self.message(error)
                recordError(step, lastError, recoverable: retries <= maxRetries)
                if retries <= maxRetries {
                    // Exponential backoff, interrupted immediately by cancellation.
                    do { try await Task.sleep(for: config.backoff(retries)) } catch {
                        lastError = "context canceled"
                        recordError(step, lastError, recoverable: false)
                        retries = maxRetries + 1
                    }
                    if isCancelled() && retries <= maxRetries {
                        lastError = "context canceled"
                        recordError(step, lastError, recoverable: false)
                        retries = maxRetries + 1
                    }
                }
            }
        }
        return AtlasToolExecution(id: id, name: call.name, arguments: call.arguments, result: "map[error:\(lastError)]",
                                  duration: .now - started, success: false, error: lastError, parallel: parallel, retries: retries)
    }

    static func message(_ error: any Error) -> String {
        if error is CancellationError { return "context canceled" }
        if let error = error as? AtlasRuntimeError { return error.code }
        return String(describing: error)
    }

    func checkStopConditions(_ started: ContinuousClock.Instant) -> AtlasStopCondition? {
        if let timeout = config.timeout, .now - started > timeout { return .timeout }
        if let maxTokens = config.maxTokens, state.totalTokens >= maxTokens { return .maxTokens }
        if let maxCost = config.maxCost, state.totalCost >= maxCost { return .maxCost }
        if state.errors.filter({ !$0.recoverable }).count >= 3 { return .error }
        return config.shouldStop?(state)
    }

    func recordError(_ step: Int, _ message: String, recoverable: Bool) {
        state.errors.append(AtlasStepError(step: step, error: message, recoverable: recoverable))
    }

    func summary() -> String {
        var parts = ["Completed in \(state.steps.count) steps", "with \(state.toolCalls.count) tool calls"]
        if state.totalTokens > 0 { parts.append("\(state.totalTokens) tokens used") }
        if state.totalCost > 0 { parts.append(String(format: "$%.4f cost", state.totalCost)) }
        if !state.errors.isEmpty { parts.append("\(state.errors.count) errors encountered") }
        parts.append("stopped due to \(state.stopCondition?.rawValue ?? "")")
        return parts.joined(separator: ", ")
    }

    static func generatedID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0..<9).map { _ in letters.randomElement()! })
        return "call_\(DispatchTime.now().uptimeNanoseconds)_\(suffix)"
    }
}
