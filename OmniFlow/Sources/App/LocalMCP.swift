import Foundation
import Combine
import FoundationModels

@Generable
struct MCPDiscoveryArguments {
    @Generable enum Operation { case tools, schema, servers, resources, readResource }
    var operation: Operation
    @Guide(description: "Required configured server id such as s1. Empty only for servers.")
    var server: String
    @Guide(description: "For schema, exact approved tool name to select. For readResource, a discovered URI. Empty for listings.")
    var name: String
    @Guide(description: "Optional tool-name/description filter or name glob. Nil to list all approved tools.")
    var query: String?
    var offset: Int?
    var cursor: String?
}

@MainActor
final class LocalMCPConfiguration: ObservableObject {
    static let shared = LocalMCPConfiguration()
    @Published private(set) var servers: [MCPServerConfiguration] = []
    @Published private(set) var error: String?
    private let file: URL

    init(file: URL = NotchLeeStorage.root.appendingPathComponent("mcp-servers.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 128_000 else { throw AtlasBridgeError.invalidFrame }
            let loaded = try JSONDecoder().decode([MCPServerConfiguration].self, from: Data(contentsOf: file))
            guard loaded.count <= 8, Set(loaded.map(\.id)).count == loaded.count else { throw AtlasBridgeError.invalidFrame }
            for server in loaded { try Self.validate(server) }
            servers = loaded
        } catch { self.error = "The MCP connections could not be loaded. No servers were enabled." }
    }

    var enabledServers: [MCPServerConfiguration] {
        #if APPSTORE
        []
        #else
        servers.filter(\.enabled)
        #endif
    }

    static func validate(_ server: MCPServerConfiguration) throws {
        guard !server.useOAuth || server.isRemote else {
            throw MCPConfigurationError.invalidAuthentication
        }
        guard server.oauthClientID.utf8.count <= 2048,
              !server.oauthClientID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MCPConfigurationError.invalidAuthentication
        }
        guard !server.id.isEmpty, server.id.utf8.count <= 64, !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              server.name.utf8.count <= 80,
              server.allowedTools.count <= 256, Set(server.allowedTools.map(\.name)).count == server.allowedTools.count,
              server.allowedTools.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 128 && $0.digest.count == 64 }) else {
            throw MCPConfigurationError.invalid
        }
        switch server.transport {
        case "stdio":
            guard server.command.hasPrefix("/"), !server.command.contains("\0"),
                  server.command.utf8.count <= 4096, server.arguments.count <= 32,
                  server.arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_000,
                  server.arguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) else {
                throw MCPConfigurationError.invalidProgram
            }
        case "http":
            guard MCPServerConfiguration.isValidRemoteEndpoint(server.url) else {
                throw MCPConfigurationError.invalidEndpoint
            }
        default:
            throw MCPConfigurationError.invalid
        }
    }

    func save(_ server: MCPServerConfiguration) throws {
        try Self.validate(server)
        var updated = servers.filter { $0.id != server.id }
        updated.append(server)
        guard updated.count <= 8 else { throw MCPConfigurationError.limit }
        try persist(updated)
    }

    func remove(_ id: String) throws { try persist(servers.filter { $0.id != id }) }

    private func persist(_ updated: [MCPServerConfiguration]) throws {
        try NotchLeeStorage.prepare(file.deletingLastPathComponent())
        let stored = updated.map { server in
            var server = server
            server.headers = [:]
            server.authorizationError = nil
            return server
        }
        let data = try JSONEncoder().encode(stored)
        guard data.count <= 128_000 else { throw MCPConfigurationError.limit }
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        servers = stored
        error = nil
        // Revoking a grant also cancels the active run's configuration snapshot.
        if VoiceAssistant.shared.phase == .thinking { VoiceAssistant.shared.cancel() }
    }
}

enum MCPConfigurationError: LocalizedError {
    case invalid, invalidProgram, invalidEndpoint, invalidAuthentication, limit
    var errorDescription: String? {
        switch self {
        case .invalid: "Enter a server name and a valid MCP connection."
        case .invalidProgram: "Enter an absolute executable path and arguments as a JSON array of strings."
        case .invalidEndpoint: "Enter an HTTPS endpoint without embedded credentials or a URL fragment."
        case .invalidAuthentication: "Browser sign-in is available for remote HTTPS connections."
        case .limit: "The MCP configuration limit was reached (8 servers, 256 tools per server)."
        }
    }
}

@Generable
struct MCPArguments {
    @Generable enum Operation { case servers, tools, schema, call, resources, readResource }
    var operation: Operation
    @Guide(description: "Required configured server id, such as s1. Use an empty string only when listing servers.")
    var server: String
    @Guide(description: "Required exact tool name for schema or call (for example read_archive), or discovered URI for readResource. Use an empty string for listings.")
    var name: String
    @Guide(description: "Required JSON object string for call, matching the tool schema. Use {} for a tool with no arguments or for other operations.")
    var argumentsJSON: String
    @Guide(description: "For tools, a name/description search or name glob such as *search*. Otherwise nil.")
    var query: String?
    var offset: Int?
    @Guide(description: "For resources, the nextCursor from the preceding page. Otherwise nil.")
    var cursor: String?
}

