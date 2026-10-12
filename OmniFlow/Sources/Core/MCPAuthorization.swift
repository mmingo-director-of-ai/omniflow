import Foundation

/// Authentication is bound to each registered endpoint. Tokens cross only the
/// helper's private pipe and never enter model context or saved MCP settings.
@MainActor
enum MCPAuthorization {
    static func configure(_ servers: [MCPServerConfiguration], requireAuthentication: Bool) async throws -> [MCPServerConfiguration] {
        var configured = servers
        for index in configured.indices where configured[index].isRemote && configured[index].useOAuth {
            try Task.checkCancellation()
            configured[index].authorizationError = nil
            do {
                configured[index].headers["Authorization"] = try await MCPOAuth.shared.authorizationHeader(for: configured[index])
            } catch {
                try Task.checkCancellation()
                if requireAuthentication { throw error }
                // An unavailable remote account must not block native Mac questions.
                // Selecting this server then fails locally, before any request is sent.
                configured[index].headers = [:]
                configured[index].authorizationError = "mcp_authentication_required"
            }
        }
        try Task.checkCancellation()
        return configured
    }
}
