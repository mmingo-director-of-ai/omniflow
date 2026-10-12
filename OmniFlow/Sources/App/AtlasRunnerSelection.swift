import Foundation

/// Chooses the Atlas runtime for assistant questions and MCP catalog review.
/// The in-process native runtime is the default. The bundled Go helper stays
/// for one release as a rollback path behind a hidden debug default:
/// `defaults write com.mengohlabs.NotchLee omniflow.atlas.useGoHelper -bool YES`.
@MainActor
enum AtlasRunnerSelection {
    static let goHelperDefaultsKey = "omniflow.atlas.useGoHelper"

    static var useGoHelper: Bool { UserDefaults.standard.bool(forKey: goHelperDefaultsKey) }

    /// Local stdio servers run through the sandboxed in-process launcher.
    static var stdioLauncher: AtlasStdioLauncher? { AtlasRuntimeEnvironment.stdioLauncher ?? AtlasStdioTransport.launcher }

    static func runner(executable: URL? = AtlasBridge.helperURL, identity: AtlasBuildIdentity? = AtlasBridge.buildIdentity) -> any AtlasRunner<AtlasFrame> {
        if useGoHelper { return GoHelperAtlasRunner(executable: executable, identity: identity) }
        return NativeAtlasRunner<AtlasFrame>(launcher: stdioLauncher, mapError: AtlasBridgeError.remoteCode, timedOut: AtlasBridgeError.timedOut,
                                             onEvent: { tool, success in Task { await LocalTelemetry.shared.event("atlas.tool.\(tool)", success: success) } })
    }

    static func catalog(server: MCPServerConfiguration) async throws -> MCPCatalog {
        if useGoHelper { return try await AtlasBridge.catalog(server: server) }
        return try await NativeAtlasRunner<AtlasFrame>.catalog(server: server, as: MCPCatalog.self, launcher: stdioLauncher,
            authorize: MCPAuthorization.configure, mapError: AtlasBridgeError.remoteCode, timedOut: AtlasBridgeError.timedOut)
    }

    static var status: String {
        useGoHelper ? AtlasBridge.status + " · Go helper" : NativeAtlasRunner<AtlasFrame>.status
    }

    static var sdkVersion: String {
        useGoHelper ? (AtlasBridge.buildIdentity?.version ?? "unknown") : AtlasRuntimeIdentity.version
    }

    /// App launch: the Go helper needs its launch-only broker for local
    /// servers; the native runtime launches them itself.
    static func launch() {
        AtlasRuntimeEnvironment.stdioLauncher = AtlasStdioTransport.launcher
        if useGoHelper { LocalMCPLauncher.shared.start() }
    }

    static func shutdown() {
        LocalMCPLauncher.shared.stop()
        Task { await MCPConnectionPool.shared.closeAll() }
    }

    /// Opens remote MCP sessions and lists their catalogs while the user is
    /// still speaking, so the first question skips the handshakes. Only
    /// servers whose sign-in is already available are warmed; nothing is
    /// called and no approval is used.
    static func prewarmConnections(_ servers: [MCPServerConfiguration]) {
        guard !useGoHelper else { return }
        let remote = servers.filter { $0.enabled && $0.isRemote }
        guard !remote.isEmpty else { return }
        Task {
            guard let configured = try? await MCPAuthorization.configure(remote, requireAuthentication: false),
                  let data = try? JSONEncoder().encode(configured),
                  let runtime = try? JSONDecoder().decode([AtlasMCPServerConfig].self, from: data) else { return }
            await MCPConnectionPool.shared.prewarm(runtime)
        }
    }
}

/// The Go `NotchLeeAtlas` helper behind the runner interface (rollback path).
@MainActor
struct GoHelperAtlasRunner: AtlasRunner {
    typealias Frame = AtlasFrame
    let executable: URL?
    let identity: AtlasBuildIdentity?

    func run<Tool: Encodable, Server: Codable & Sendable>(
        prompt: String, tools: [Tool], servers: [Server], mode: String?, question: String?, discoveryQuery: String?,
        workspace: URL?, resume: Bool, timeout: Double, requireAuthentication: Bool,
        authorize: (@MainActor ([Server], Bool) async throws -> [Server])?,
        onModel: @escaping Handler, onTool: @escaping Handler) async throws -> AtlasRuntimeResult {
        // AtlasBridge authorizes servers itself.
        guard let tools = tools as? [AtlasToolDefinition], let servers = servers as? [MCPServerConfiguration] else {
            throw AtlasBridgeError.invalidFrame
        }
        let result = try await AtlasBridge().run(prompt: prompt, tools: tools, servers: servers, mode: mode, question: question,
            discoveryQuery: discoveryQuery, executable: executable, identity: identity, workspace: workspace, resume: resume,
            timeout: timeout, requireAuthentication: requireAuthentication, onModel: onModel, onTool: onTool)
        return AtlasRuntimeResult(text: result.text, steps: result.steps, toolCount: result.toolCount)
    }
}
