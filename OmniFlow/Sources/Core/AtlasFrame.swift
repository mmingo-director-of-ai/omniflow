import Foundation

/// The Atlas v4 frame shape exchanged with the model/tool host. The native
/// runtime passes these in process; the Go helper rollback path sends them
/// over private pipes. The optional MCP launcher address is local bootstrap
/// data for that helper, never a remote endpoint.
struct AtlasFrame: Codable, Sendable {
    var type: String
    var version = 4
    var requestID: String?
    var id: String?
    var sdkVersion: String?
    var revision: String?
    var broker: MCPBrokerEndpoint?
    var mode: String?
    var servers: [MCPServerConfiguration]?
    var storeDirectory: String?
    var persistent: Bool?
    var resume: Bool?
    var archivedMessages: Int?
    var memory: AtlasMemoryView?
    var analysis: AtlasAnalysisRequest?
    var analysisResult: AtlasAnalysisReply?
    var analysisError: String?
    var payloadReady: Bool?
    var previousOperation: String?
    var previousError: String?
    var mcpTool: MCPSelectedTool?
    var mcpDiscovery: [MCPConnectionDiscovery]?
    var prompt: String?
    var question: String?
    var discoveryQuery: String?
    var content: String?
    var error: String?
    var tool: String?
    var argumentsJSON: String?
    var tools: [AtlasToolDefinition]?
    var toolCalls: [AtlasToolCall]?
    var messages: [AtlasMessage]?
    var finalStep: Bool?
    var step: Int?
    var steps: Int?
    var toolCount: Int?
    var stopReason: String?
    var success: Bool?
}


/// The Go helper's local stdio launcher address (rollback path only).
struct MCPBrokerEndpoint: Codable, Sendable {
    let socket: String
    let token: String
}
