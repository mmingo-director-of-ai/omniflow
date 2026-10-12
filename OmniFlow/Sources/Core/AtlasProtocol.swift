import Foundation

struct AtlasBuildIdentity: Codable, Sendable {
    let version: String
    let revision: String
}

struct AtlasToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let inputSchemaJSON: String
}

struct AtlasToolCall: Codable, Sendable {
    let name: String
    let argumentsJSON: String
    var id: String? = nil
    var modelName: String? = nil
    var modelArgumentsJSON: String? = nil
}

struct AtlasMessage: Codable, Sendable {
    let role: String
    var content: String
    var toolCallId: String?
    var toolCalls: [AtlasToolCall]? = nil
}

enum AtlasBridgeError: LocalizedError {
    case unavailable, incompatible, invalidFrame, failed, timedOut
    case mcpAuthentication, mcpForbidden, mcpEndpoint, mcpRedirect, mcpRateLimited, mcpConnection
    case checkpointUnavailable, checkpointInUse

    var errorDescription: String? {
        switch self {
        case .unavailable: "The local Atlas helper is missing. Rebuild or reinstall OmniFlow."
        case .incompatible: "The bundled Atlas helper doesn't match this OmniFlow build. Reinstall OmniFlow."
        case .invalidFrame, .failed: "The local Atlas run couldn't finish. Please try again or narrow the question."
        case .timedOut: "The local Atlas run took too long. Please try a shorter question."
        case .mcpAuthentication: "This MCP server requires a valid sign-in. Sign in from its connection settings, then discover tools again."
        case .mcpForbidden: "The MCP server denied access to this account or connection."
        case .mcpEndpoint: "The MCP endpoint or session is unavailable. Check the endpoint and discover tools again."
        case .mcpRedirect: "The MCP endpoint redirected the request. Enter its final HTTPS address; credentials were not forwarded."
        case .mcpRateLimited: "The MCP server is rate limiting requests. Try again later."
        case .mcpConnection: "The remote MCP connection failed. Check the endpoint and network connection."
        case .checkpointUnavailable: "This saved task could not be restored. Its files have been left intact. Open Memory to review or forget the task."
        case .checkpointInUse: "This saved task is still running. Stop it before continuing from its checkpoint."
        }
    }

    static func remoteCode(_ code: String?) -> Self {
        switch code {
        case "mcp_authentication_required": .mcpAuthentication
        case "mcp_http_forbidden": .mcpForbidden
        case "mcp_http_endpoint_unavailable": .mcpEndpoint
        case "mcp_http_redirect_refused": .mcpRedirect
        case "mcp_http_rate_limited": .mcpRateLimited
        case "mcp_http_timeout": .timedOut
        case "mcp_http_connection_failed": .mcpConnection
        case "checkpoint_in_use": .checkpointInUse
        case "invalid_checkpoint", "checkpoint_unavailable", "checkpoint_already_exists", "no_analysis_checkpoint", "checkpoint_write_failed": .checkpointUnavailable
        default: .failed
        }
    }
}

struct AtlasRunResult: Sendable {
    let text: String
    let steps: Int
    let toolCount: Int
}

/// Bounds shared by the helper bridge and the code that validates its frames.
enum AtlasLimits {
    static let maximumFrameBytes = 256 * 1024
    static let maximumSteps = 128
}
