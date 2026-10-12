import Foundation

struct MCPToolApproval: Codable, Equatable, Sendable {
    var name: String
    var digest: String
}

struct MCPServerConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = ""
    var transport = "stdio"
    var url = ""
    var useOAuth = false
    var oauthClientID = ""
    /// Runtime credentials are supplied by the bridge; never persist them with server settings.
    var headers: [String: String] = [:]
    var authorizationError: String?
    var command = ""
    var arguments: [String] = []
    var enabled = false
    var allowedTools: [MCPToolApproval] = []
    var allowResources = false

    var isRemote: Bool { transport == "http" }

    static func isValidRemoteEndpoint(_ url: String) -> Bool {
        guard url.utf8.count <= 4096, !url.contains(where: { $0.isWhitespace || $0.isNewline }),
              !url.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let endpoint = URLComponents(string: url), endpoint.scheme?.lowercased() == "https",
              let host = endpoint.host, !host.isEmpty, endpoint.url != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        return true
    }

    /// Display the destination without exposing query parameters or credentials.
    var destination: String {
        guard isRemote else { return URL(fileURLWithPath: command).lastPathComponent }
        guard let endpoint = URLComponents(string: url), let host = endpoint.host else { return "Remote HTTPS" }
        let port = endpoint.port.map { ":\($0)" } ?? ""
        return host + port + endpoint.path
    }
}

extension MCPServerConfiguration {
    private enum CodingKeys: String, CodingKey {
        case id, name, transport, url, useOAuth, oauthClientID, headers, authorizationError, command, arguments, enabled, allowedTools, allowResources
    }

    // Existing installations have local-program configurations with no transport or URL fields.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        transport = try values.decodeIfPresent(String.self, forKey: .transport) ?? "stdio"
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
        useOAuth = try values.decodeIfPresent(Bool.self, forKey: .useOAuth) ?? false
        oauthClientID = try values.decodeIfPresent(String.self, forKey: .oauthClientID) ?? ""
        headers = [:]
        authorizationError = nil
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        allowedTools = try values.decodeIfPresent([MCPToolApproval].self, forKey: .allowedTools) ?? []
        allowResources = try values.decodeIfPresent(Bool.self, forKey: .allowResources) ?? false
    }
}

struct MCPDiscoveredTool: Codable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let digest: String
    let supported: Bool
}

struct MCPCatalog: Codable, Sendable {
    let tools: [MCPDiscoveredTool]
    let hasResources: Bool
}

struct MCPSelectedTool: Codable, Sendable {
    let server: String
    let name: String
    let description: String
    let inputSchemaJSON: String
}

/// Live discovery is capability metadata, not an operation result. The helper
/// includes only supported definitions matching the user's saved approvals.
struct MCPConnectionDiscovery: Codable, Sendable {
    struct Tool: Codable, Sendable {
        let name: String
        let description: String
    }
    let server: String
    let name: String
    let error: String?
    let toolCount: Int
    let hasMore: Bool
    let tools: [Tool]
}
