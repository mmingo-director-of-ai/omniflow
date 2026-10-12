// Native Atlas runtime: in-process replacement for the NotchLeeAtlas helper.
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
//
// `NativeAtlasRunner` mirrors `AtlasBridge.run`'s parameters, callback frames
// and limits, so the assistant can switch from the Go subprocess to this
// runtime by replacing one call expression (docs/omniflow/atlas-swift-port.md).
// Frames, tools and server configurations transcode through their shared JSON
// shape, so this module does not depend on the App's types.
import Foundation
import Synchronization

/// Process-wide configuration supplied by the platform shell.
public enum AtlasRuntimeEnvironment {
    private static let launcherStorage = Mutex<AtlasStdioLauncher?>(nil)

    /// The sandboxed local MCP launcher (macOS direct distribution only).
    /// Without it, an enabled local server fails the run with `mcp_launcher_unavailable`.
    public static var stdioLauncher: AtlasStdioLauncher? {
        get { launcherStorage.withLock { $0 } }
        set { launcherStorage.withLock { $0 = newValue } }
    }
}

public struct AtlasRuntimeResult: Sendable {
    public let text: String
    public let steps: Int
    public let toolCount: Int
}

/// Executes one Atlas run off the main actor. The SDK loop, payload store,
/// task journal and MCP host live in this actor's isolation; host callbacks
/// are awaited on their own (main) actor.
public actor AtlasAgentLoop {
    private let pool: MCPConnectionPool
    private let launcher: AtlasStdioLauncher?

    public init(pool: MCPConnectionPool = .shared, launcher: AtlasStdioLauncher? = AtlasRuntimeEnvironment.stdioLauncher) {
        self.pool = pool
        self.launcher = launcher
    }

    /// Runs a validated start frame and returns the `done` frame.
    public func execute(_ start: AtlasRuntimeFrame, host: @escaping AtlasRuntimeHost,
                        events: @escaping AtlasRuntimeEvents = { _ in }) async throws -> AtlasRuntimeFrame {
        let session = AtlasRuntimeSession(host: host, events: events, pool: pool, launcher: launcher)
        return try await session.serve(start)
    }
}

/// What the assistant needs from an Atlas runner (the AtlasBridge surface).
/// `NativeAtlasRunner` implements it on macOS and iOS; the macOS app also has
/// a Go-helper implementation kept as a rollback path.
@MainActor
public protocol AtlasRunner<Frame> {
    associatedtype Frame: Codable & Sendable
    typealias Handler = @MainActor (Frame) async throws -> Frame

    func run<Tool: Encodable, Server: Codable & Sendable>(
        prompt: String, tools: [Tool], servers: [Server], mode: String?, question: String?, discoveryQuery: String?,
        workspace: URL?, resume: Bool, timeout: Double, requireAuthentication: Bool,
        authorize: (@MainActor ([Server], Bool) async throws -> [Server])?,
        onModel: @escaping Handler, onTool: @escaping Handler) async throws -> AtlasRuntimeResult
}

@MainActor
public final class NativeAtlasRunner<Frame: Codable & Sendable>: AtlasRunner {
    public typealias Handler = @MainActor (Frame) async throws -> Frame
    public static var maximumSteps: Int { atlasMaxSteps }
    public static var status: String { "Atlas \(AtlasRuntimeIdentity.version) · Apple on-device model" }

    /// Codes the Go helper's `main` exposed to the host; everything else
    /// collapsed to `atlas_run_failed` so no prompt, path or argument leaks.
    public static var exposedCodes: Set<String> { atlasSafeMCPHTTPCodes }

    private let pool: MCPConnectionPool
    private let launcher: AtlasStdioLauncher?
    private let mapError: @Sendable (String) -> any Error
    private let timedOut: any Error
    private let onEvent: (@MainActor (String, Bool) -> Void)?
    private let requestID = UUID().uuidString

    /// - Parameters:
    ///   - mapError: converts a fixed failure code into the host's error
    ///     (e.g. `AtlasBridgeError.remoteCode`).
    ///   - timedOut: the error for an exceeded run or callback deadline.
    ///   - onEvent: content-free tool telemetry (tool name, success).
    public init(pool: MCPConnectionPool = .shared, launcher: AtlasStdioLauncher? = AtlasRuntimeEnvironment.stdioLauncher,
                mapError: @escaping @Sendable (String) -> any Error = { AtlasRuntimeError($0) },
                timedOut: any Error = AtlasRuntimeError("atlas_run_timeout"),
                onEvent: (@MainActor (String, Bool) -> Void)? = nil) {
        self.pool = pool; self.launcher = launcher; self.mapError = mapError; self.timedOut = timedOut; self.onEvent = onEvent
    }

    nonisolated private static func transcode<Source: Encodable, Target: Decodable>(_ value: Source, as type: Target.Type) throws -> Target {
        try JSONDecoder().decode(Target.self, from: JSONEncoder().encode(value))
    }

    public func run<Tool: Encodable, Server: Codable & Sendable>(
        prompt: String, tools: [Tool], servers: [Server] = [], mode: String? = nil, question: String? = nil,
        discoveryQuery: String? = nil, workspace: URL? = nil, resume: Bool = false, timeout: Double = 3605,
        requireAuthentication: Bool = false, authorize: (@MainActor ([Server], Bool) async throws -> [Server])? = nil,
        onModel: @escaping Handler, onTool: @escaping Handler) async throws -> AtlasRuntimeResult {
        guard prompt.utf8.count <= 64000, (discoveryQuery?.utf8.count ?? 0) <= 8000 else { throw mapError("invalid_frame") }
        let configured = try await authorize?(servers, requireAuthentication) ?? servers
        try Task.checkCancellation()
        guard !resume || (workspace != nil && servers.isEmpty && mode == nil) else { throw mapError("invalid_frame") }
        var start = AtlasRuntimeFrame(type: "start")
        start.version = AtlasRuntimeIdentity.protocolVersion
        start.requestID = requestID
        start.prompt = prompt
        start.question = question
        start.discoveryQuery = discoveryQuery
        start.mode = mode
        do {
            start.tools = try Self.transcode(tools, as: [AtlasRuntimeToolDefinition].self)
            start.servers = try Self.transcode(configured, as: [AtlasMCPServerConfig].self)
        } catch { throw mapError("invalid_frame") }
        let directory: URL
        if let workspace {
            directory = workspace
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchlee-payloads-" + requestID, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch { throw mapError("payload_directory_unavailable") }
        }
        defer { if workspace == nil { try? FileManager.default.removeItem(at: directory) } }
        start.storeDirectory = directory.path
        start.persistent = workspace != nil
        start.resume = resume

        let requestID = requestID
        let mapError = mapError
        let timedOut = timedOut
        // Like AtlasBridge, the first host callback failure ends the run with
        // that error, even when the SDK loop would treat it as a tool failure.
        let hostFailure = Mutex<(any Error)?>(nil)
        let host: AtlasRuntimeHost = { frame in
            let handler = frame.type == "tool" ? onTool : onModel
            guard ["model", "analysis", "tool"].contains(frame.type) else { throw AtlasRuntimeError("invalid_frame") }
            do {
                let request = try Self.transcode(frame, as: Frame.self)
                let reply = try await atlasWithDeadline(150, timeout: AtlasRuntimeError("atlas_callback_timeout")) { try await handler(request) }
                var decoded = try Self.transcode(reply, as: AtlasRuntimeFrame.self)
                decoded.type = "reply"
                decoded.id = frame.id
                decoded.version = AtlasRuntimeIdentity.protocolVersion
                decoded.requestID = requestID
                return decoded
            } catch {
                let recorded: any Error = (error as? AtlasRuntimeError)?.code == "atlas_callback_timeout" ? timedOut
                    : error is DecodingError || error is EncodingError ? mapError("invalid_frame") : error
                // Cancellation is the run's own (deadline or caller), not a host failure.
                if !(error is CancellationError) { hostFailure.withLock { if $0 == nil { $0 = recorded } } }
                throw error
            }
        }
        let onEvent = onEvent
        // Telemetry names only tools this run declared, plus the runtime's own.
        let eventTools = Set(["mcp", "payload", "memory"] + (start.tools ?? []).map(\.name))
        let events: AtlasRuntimeEvents = { frame in
            guard let tool = frame.tool, eventTools.contains(tool) else { return }
            let success = frame.success == true
            if let onEvent { Task { @MainActor in onEvent(tool, success) } }
        }
        let loop = AtlasAgentLoop(pool: pool, launcher: launcher)
        let done: AtlasRuntimeFrame
        do {
            let frozen = start
            done = try await atlasWithDeadline(timeout, timeout: AtlasRuntimeError("atlas_run_timeout")) {
                try await loop.execute(frozen, host: host, events: events)
            }
        } catch {
            if error is CancellationError, Task.isCancelled { throw error }
            if let failure = hostFailure.withLock({ $0 }) { throw failure }
            throw Self.hostError(error, mapError: mapError, timedOut: timedOut)
        }
        guard done.stopReason == "stop", let text = done.content, !text.isEmpty, let steps = done.steps, (1...atlasMaxSteps).contains(steps),
              (0..<atlasMaxSteps).contains(done.toolCount ?? -1) else {
            throw mapError("invalid_frame")
        }
        return AtlasRuntimeResult(text: text, steps: steps, toolCount: done.toolCount ?? 0)
    }

    /// Cancellation stays a CancellationError and timeouts use the host's
    /// timeout error. Only the codes the Go helper exposed pass through;
    /// everything else is generic so no prompt, path or argument can leak.
    nonisolated static func hostError(_ error: any Error, mapError: (String) -> any Error, timedOut: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? AtlasRuntimeError {
            if error.code == "atlas_run_timeout" { return timedOut }
            if atlasSafeMCPHTTPCodes.contains(error.code) { return mapError(error.code) }
        }
        return mapError("atlas_run_failed")
    }

    /// Discover one server's catalog for user review (AtlasBridge.catalog).
    public static func catalog<Server: Codable & Sendable, Catalog: Decodable>(
        server: Server, as type: Catalog.Type, pool: MCPConnectionPool = .shared,
        launcher: AtlasStdioLauncher? = AtlasRuntimeEnvironment.stdioLauncher,
        authorize: (@MainActor ([Server], Bool) async throws -> [Server])? = nil,
        mapError: @escaping @Sendable (String) -> any Error = { AtlasRuntimeError($0) },
        timedOut: any Error = AtlasRuntimeError("atlas_run_timeout")) async throws -> Catalog {
        let runner = NativeAtlasRunner<AtlasRuntimeFrame>(pool: pool, launcher: launcher, mapError: mapError, timedOut: timedOut)
        let result = try await runner.run(prompt: "Discover configured MCP tools for user review.", tools: [AtlasRuntimeToolDefinition](),
            servers: [server], mode: "catalog", timeout: 35, requireAuthentication: true, authorize: authorize,
            onModel: { _ in throw mapError("invalid_frame") }, onTool: { _ in throw mapError("invalid_frame") })
        do { return try JSONDecoder().decode(Catalog.self, from: Data(result.text.utf8)) } catch { throw mapError("invalid_frame") }
    }
}

