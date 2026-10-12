// Native Atlas runtime: the host adapter that drives the SDK loop (port of
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
// main.go's `bridge`, `hostTool`, `localTool` and `serve`). Models stay in the
// host: every generation, bounded analysis pass and native tool is a frame
// callback, exactly as the Go helper exchanged them over its private pipes.
import Foundation

let atlasMaxSteps = 128
let atlasRunTimeout: Duration = .seconds(3600)

/// Delivers model/analysis/tool frames to the host and returns its reply.
public typealias AtlasRuntimeHost = @Sendable (AtlasRuntimeFrame) async throws -> AtlasRuntimeFrame
/// Receives content-free execution events (tool name, step, success).
public typealias AtlasRuntimeEvents = @Sendable (AtlasRuntimeFrame) -> Void

public final class AtlasRuntimeSession {
    var previousOperation = ""
    var previousError = ""
    var requestID = ""
    var sequence = 0
    var step = 0
    var tools: [String: any AtlasAgentTool] = [:]
    var store: AtlasPayloadStore!
    var mcp: AtlasMCPHost!
    var mcpDiscovery: [AtlasRuntimeDiscovery] = []
    var discoveryDone = false
    var discoveryQuery = ""
    var memory: AtlasTaskJournal!
    private(set) var cancelled = false
    let host: AtlasRuntimeHost
    let events: AtlasRuntimeEvents
    let pool: MCPConnectionPool
    let launcher: AtlasStdioLauncher?
    var discoveryTimeout = 20.0
    /// Test hook replacing a local tool's implementation (Go tests build a
    /// `localTool` with a fixture `execute`).
    var localToolOverride: ((String, [String: AtlasJSON]) throws -> String)?

    public init(host: @escaping AtlasRuntimeHost, events: @escaping AtlasRuntimeEvents = { _ in },
                pool: MCPConnectionPool = .shared, launcher: AtlasStdioLauncher? = nil) {
        self.host = host; self.events = events; self.pool = pool; self.launcher = launcher
    }

    /// A broken host transport is terminal; never retry it as a tool failure.
    /// Cancelling the current task mirrors cancelling the Go run context.
    func cancel(currentTask: Bool = true) {
        cancelled = true
        if currentTask { withUnsafeCurrentTask { $0?.cancel() } }
    }

    var isCancelled: Bool { cancelled || Task.isCancelled }

    func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    func stamp(_ frame: AtlasRuntimeFrame) -> AtlasRuntimeFrame {
        var frame = frame
        frame.version = AtlasRuntimeIdentity.protocolVersion
        frame.requestID = requestID
        return frame.normalized()
    }

    nonisolated(nonsending) func exchange(_ frame: AtlasRuntimeFrame) async throws -> AtlasRuntimeFrame {
        do {
            try checkCancelled()
            sequence += 1
            var request = frame
            request.id = String(sequence)
            let reply = try await host(stamp(request))
            if reply.type == "cancel" && reply.requestID == requestID { throw CancellationError() }
            guard reply.version == AtlasRuntimeIdentity.protocolVersion, reply.type == "reply", reply.requestID == requestID, reply.id == request.id else {
                throw AtlasRuntimeError("reply_mismatch")
            }
            if let error = reply.error, !error.isEmpty { throw AtlasRuntimeError("host_failed") }
            try checkCancelled()
            return reply
        } catch {
            cancel()
            throw error
        }
    }

    func send(_ frame: AtlasRuntimeFrame) { events(stamp(frame)) }

    // MARK: Provider (Go Generate)

    final class Provider: AtlasAgentProvider {
        unowned let session: AtlasRuntimeSession
        init(_ session: AtlasRuntimeSession) { self.session = session }
        nonisolated(nonsending) func generate(_ messages: [AtlasRuntimeMessage], tools: [AtlasToolSchema]) async throws -> AtlasGenerateResult {
            try await session.generate(messages)
        }
    }

    nonisolated(nonsending) func generate(_ incoming: [AtlasRuntimeMessage]) async throws -> AtlasGenerateResult {
        step += 1
        // Continue only local analysis of the already-fetched payload. Never replay
        // the MCP operation when a model window or an analysis batch ends.
        if let job = memory.jobs[memory.active], !job.complete, previousError.isEmpty, step < atlasMaxSteps {
            return AtlasGenerateResult(content: "", toolCalls: [AtlasToolCallData(name: "memory",
                arguments: ["operation": .string("analyze"), "id": .string(job.id), "query": .string(job.goal)], id: "call_\(step)")])
        }
        if !discoveryDone {
            discoveryDone = true
            mcpDiscovery = await mcp.discover(discoveryQuery, timeout: discoveryTimeout)
        }
        // Tool results have durable run-scoped payload IDs. Carry a recent window;
        // older evidence remains accessible through payload.list/search/read.
        var messages = incoming
        var archived = 0
        // Retain complete assistant/call/result groups, never orphan batch results.
        let assistantIndices = messages.indices.filter { messages[$0].role == "assistant" }
        if assistantIndices.count > 4 {
            let keepFrom = assistantIndices[assistantIndices.count - 4]
            archived = keepFrom - 1
            messages = [messages[0]] + messages[keepFrom...]
        }
        let payloadReady = store.entries.values.contains { $0.text && $0.chunks > 0 && $0.kind != "schema" }
        var frame = AtlasRuntimeFrame(type: "model")
        frame.memory = memory.view(store.question)
        frame.messages = messages
        frame.archivedMessages = archived
        frame.step = step
        frame.finalStep = step == atlasMaxSteps
        frame.payloadReady = payloadReady
        frame.previousOperation = previousOperation
        frame.previousError = previousError
        frame.mcpTool = mcp.selectedTool()
        frame.mcpDiscovery = mcpDiscovery
        let reply = try await exchange(frame)
        let content = reply.content ?? ""
        let calls = reply.toolCalls ?? []
        guard content.utf8.count <= 16000, calls.count <= 8 else { throw AtlasRuntimeError("response_limit") }
        var result = AtlasGenerateResult(content: content, toolCalls: [])
        for (index, call) in calls.enumerated() {
            guard call.argumentsJSON.utf8.count <= 16000 else { throw AtlasRuntimeError("invalid_arguments") }
            guard step != atlasMaxSteps else { throw AtlasRuntimeError("step_limit") }
            guard tools[call.name] != nil else { throw AtlasRuntimeError("tool_denied") }
            guard let arguments = (try? AtlasJSON.parse(call.argumentsJSON))?.dictionary else { throw AtlasRuntimeError("invalid_arguments") }
            var proposal = AtlasToolCallData(name: call.name, arguments: arguments, id: "call_\(step)_\(index)")
            proposal.modelName = call.modelName
            proposal.modelArgumentsJSON = call.modelArgumentsJSON
            result.toolCalls.append(proposal)
        }
        if result.toolCalls.isEmpty && result.content.isEmpty { throw AtlasRuntimeError("empty_answer") }
        return result
    }

    // MARK: Tools

    /// A native tool executed by the host (getMacContext and inspectLocalFiles
    /// on the Mac, recallSavedMemory, or any tool the platform declares at
    /// start). Its output becomes run-scoped evidence.
    /// Invariant: the session disables parallel execution, so tool calls never
    /// overlap and the unchecked Sendable conformance is never exercised.
    final class HostTool: AtlasAgentTool, @unchecked Sendable {
        unowned let session: AtlasRuntimeSession
        let definition: AtlasRuntimeToolDefinition
        let schema: [String: AtlasJSON]
        init(_ session: AtlasRuntimeSession, _ definition: AtlasRuntimeToolDefinition, _ schema: [String: AtlasJSON]) {
            self.session = session; self.definition = definition; self.schema = schema
        }
        var name: String { definition.name }
        var description: String { definition.description }
        var inputSchema: AtlasJSON? { .object(schema) }

        nonisolated(nonsending) func execute(_ arguments: [String: AtlasJSON]) async throws -> String {
            try await session.executeHostTool(self, arguments)
        }
    }

    nonisolated(nonsending) func executeHostTool(_ tool: HostTool, _ arguments: [String: AtlasJSON]) async throws -> String {
        var frame = AtlasRuntimeFrame(type: "tool")
        frame.tool = tool.name
        frame.argumentsJSON = jsonText(.object(arguments))
        let reply = try await exchange(frame)
        let content = reply.content ?? ""
        previousOperation = tool.name
        previousError = ""
        var source = "native:" + tool.name
        if let operation = arguments["operation"]?.stringValue { source += ":" + AtlasUTF8.prefix(operation, 32) }
        if let path = arguments["path"]?.stringValue { source += ":" + AtlasUTF8.prefix(path, 512) }
        let entry = try store.put(source, Array(content.utf8), isText: true)
        return store.preview(entry)
    }

    /// A tool implemented by the runtime itself (mcp, payload, memory).
    final class LocalTool: AtlasAgentTool, @unchecked Sendable {
        unowned let session: AtlasRuntimeSession
        let name: String
        let description: String
        var inputSchema: AtlasJSON? { nil }
        init(_ session: AtlasRuntimeSession, _ name: String, _ description: String) {
            self.session = session; self.name = name; self.description = description
        }
        nonisolated(nonsending) func execute(_ arguments: [String: AtlasJSON]) async throws -> String {
            try await session.executeLocalTool(name, arguments)
        }
    }

    nonisolated(nonsending) func executeLocalTool(_ name: String, _ arguments: [String: AtlasJSON]) async throws -> String {
        if let operation = arguments["operation"]?.stringValue, operation.utf8.count < 32 {
            previousOperation = name + "." + operation
        }
        previousError = ""
        let value: String
        do {
            if let localToolOverride { value = try localToolOverride(name, arguments) } else {
            switch name {
            case "mcp": value = try await mcp.execute(arguments)
            case "payload": value = try store.execute(arguments)
            default: value = try await memory.execute(arguments)
            }
            }
        } catch {
            previousError = Self.safeToolError(error)
            if isCancelled { throw CancellationError() }
            // Errors are fixed host codes, never server-supplied text or credentials.
            return jsonText(.object(["trust": .string("untrusted_data"), "error": .string(Self.safeToolError(error)), "complete": .bool(false)]))
        }
        if name == "mcp", let status = try? AtlasJSON.parse(value), status["isError"]?.boolValue == true {
            previousError = "mcp_tool_reported_error"
        }
        return value
    }

    static func safeToolError(_ error: any Error) -> String {
        guard let code = (error as? AtlasRuntimeError)?.code, code.utf8.count <= 100,
              code.unicodeScalars.allSatisfy({ $0 == "_" || ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else {
            return "local_tool_failed"
        }
        return code
    }

    // MARK: Serve

    /// Host tools per run. The Go helper accepted exactly the Mac set (2–3).
    static let maximumHostTools = 8

    /// Names the runtime or the model host already use. A host tool may not
    /// shadow them: `mcp`, `payload` and `memory` are runtime tools, and the
    /// rest are the on-device model's proposal functions for MCP and analysis.
    static let reservedToolNames: Set<String> = ["mcp", "payload", "memory", "selectMCPTool", "callSelectedMCPTool",
                                                 "mcpResources", "analyzeStoredSource"]

    /// An identifier (ASCII letter, then letters, digits or underscore; at
    /// most 64 bytes) that is not reserved.
    static func validHostToolName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), !reservedToolNames.contains(name), let first = name.utf8.first else { return false }
        func letter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
        return letter(first) && name.utf8.allSatisfy { letter($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "_") }
    }

    /// Validates a start frame and runs it to completion (Go `serve` after the
    /// handshake). Returns the `done` frame; throws a fixed error otherwise.
    nonisolated(nonsending) public func serve(_ start: AtlasRuntimeFrame) async throws -> AtlasRuntimeFrame {
        let mode = start.mode ?? ""
        let tools = start.tools ?? []
        let servers = start.servers ?? []
        let persistent = start.persistent ?? false, resume = start.resume ?? false
        let requestID = start.requestID ?? "", prompt = start.prompt ?? ""
        let question = start.question ?? "", discovery = start.discoveryQuery ?? ""
        guard start.version == AtlasRuntimeIdentity.protocolVersion, start.type == "start", (1...64).contains(requestID.utf8.count),
              (1...64000).contains(prompt.utf8.count), mode == "catalog" || (0...Self.maximumHostTools).contains(tools.count),
              question.utf8.count <= 8000, discovery.utf8.count <= 8000,
              !persistent || (!(start.storeDirectory ?? "").isEmpty && mode.isEmpty),
              !resume || (persistent && servers.isEmpty && mode.isEmpty) else {
            throw AtlasRuntimeError("invalid_start")
        }
        self.requestID = requestID
        discoveryQuery = discovery.isEmpty ? question : discovery
        store = try AtlasPayloadStore(directory: start.storeDirectory)
        store.persistent = persistent
        defer { store.close() }
        store.question = question
        if persistent { try store.enablePersistence(resume: resume) }
        memory = AtlasTaskJournal(session: self)
        if resume { try memory.restore() }
        mcp = try AtlasMCPHost(configs: servers, store: store, pool: pool, launcher: launcher)
        do {
            let result = try await run(mode: mode, tools: tools, prompt: prompt)
            await mcp.close()
            return result
        } catch {
            await mcp.close()
            throw error
        }
    }

    private nonisolated(nonsending) func run(mode: String, tools definitions: [AtlasRuntimeToolDefinition], prompt: String) async throws -> AtlasRuntimeFrame {
        for server in mcp.configs where server.enabled && !server.isHTTP && launcher == nil {
            throw AtlasRuntimeError("mcp_launcher_unavailable")
        }
        if mode == "catalog" {
            guard mcp.configs.count == 1 else { throw AtlasRuntimeError("catalog_requires_one_server") }
            var done = AtlasRuntimeFrame(type: "done")
            done.content = try await mcp.catalog(mcp.configs[0].id)
            done.steps = 1
            done.toolCount = 0
            done.stopReason = "stop"
            return stamp(done)
        }
        guard mode.isEmpty else { throw AtlasRuntimeError("unknown_mode") }
        // The host declares its own read tools (the Mac's context and file
        // tools, or none on iOS). Only declared names can later be dispatched;
        // the provider still rejects any undeclared call with tool_denied.
        for definition in definitions {
            guard Self.validHostToolName(definition.name) else { throw AtlasRuntimeError("tool_denied") }
            guard tools[definition.name] == nil else { throw AtlasRuntimeError("duplicate_tool") }
            guard let schema = (try? AtlasJSON.parse(definition.inputSchemaJSON))?.dictionary, schema["type"]?.stringValue == "object" else {
                throw AtlasRuntimeError("invalid_schema")
            }
            tools[definition.name] = HostTool(self, definition, schema)
        }
        tools["mcp"] = LocalTool(self, "mcp", "Discover approved MCP tools, inspect their schemas, call them, and read approved resources.")
        tools["payload"] = LocalTool(self, "payload", "Search or read run-scoped evidence outside the model context window.")
        tools["memory"] = LocalTool(self, "memory", "Preserve exact findings, retrieve earlier notes, and analyze large stored sources in successive bounded passes.")
        var config = AtlasAgentLoopConfig()
        config.maxSteps = atlasMaxSteps
        config.timeout = atlasRunTimeout
        config.parallelExecution = false
        config.autoRecovery = false
        config.onToolCall = { [unowned self] execution in
            do { try store.persistIndex() } catch { cancel() }
            // Discovery receipts must not imply that a named MCP tool ran.
            let operation = execution.arguments["operation"]?.stringValue
            let invoked = execution.name != "mcp" || operation == "call" || operation == "readResource"
            let success = execution.success && previousError.isEmpty
            if invoked && execution.name != "memory" && execution.name != "payload" {
                do { try memory.receipt(execution.name, execution.arguments, success: success) } catch { cancel() }
            }
            // Counts and status only. Neither arguments nor results go to telemetry.
            var event = AtlasRuntimeFrame(type: "event")
            event.tool = execution.name
            event.step = step
            event.success = success
            send(event)
        }
        let engine = AtlasAgentEngine(provider: Provider(self), tools: tools, config: config)
        engine.isCancelled = { [unowned self] in isCancelled }
        let result = try await engine.execute(prompt: prompt)
        guard result.finishReason == .stop else { throw AtlasRuntimeError("incomplete_run") }
        var done = AtlasRuntimeFrame(type: "done")
        done.content = result.text
        done.steps = result.steps.count
        done.toolCount = result.toolCalls.count
        done.stopReason = result.finishReason.rawValue
        return stamp(done)
    }
}
