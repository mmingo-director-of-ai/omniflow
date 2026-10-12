// Native Atlas runtime: the version 4 frame contract shared with the host.
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
// Field names and JSON keys are identical to the Go helper's `frame` and to the
// App's `AtlasFrame`, so frames transcode losslessly between the two.
import Foundation

public struct AtlasRuntimeToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
    public init(name: String, description: String = "", inputSchemaJSON: String) {
        self.name = name; self.description = description; self.inputSchemaJSON = inputSchemaJSON
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        inputSchemaJSON = try values.decodeIfPresent(String.self, forKey: .inputSchemaJSON) ?? ""
    }
}

public struct AtlasRuntimeToolCall: Codable, Sendable, Equatable {
    public var name: String
    public var argumentsJSON: String
    public var id: String? = nil
    public var modelName: String? = nil
    public var modelArgumentsJSON: String? = nil
    public init(name: String, argumentsJSON: String) { self.name = name; self.argumentsJSON = argumentsJSON }
}

public struct AtlasRuntimeMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String
    public var toolCallId: String?
    public var toolCalls: [AtlasRuntimeToolCall]? = nil
    public init(role: String, content: String, toolCallId: String? = nil, toolCalls: [AtlasRuntimeToolCall]? = nil) {
        self.toolCalls = toolCalls
        self.role = role; self.content = content; self.toolCallId = toolCallId?.isEmpty == true ? nil : toolCallId
    }
}

public struct AtlasRuntimeMemorySource: Codable, Sendable, Equatable {
    public var id: String
    public var startByte: Int
    public var endByte: Int
    public var quote: String?
}

public struct AtlasRuntimeMemoryRecord: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var sources: [AtlasRuntimeMemorySource]?
    public var parents: [String]?
}

public struct AtlasRuntimeAnalysisJob: Codable, Sendable, Equatable {
    public var id: String
    public var goal: String
    public var processedBytes: Int
    public var totalBytes: Int
    public var level: [String]?
    public var next: [String]?
    public var reduced: Int
    public var complete: Bool
    public var result: String?
}

public struct AtlasRuntimeMemoryView: Codable, Sendable, Equatable {
    public var records: [AtlasRuntimeMemoryRecord]
    public var recentOperations: [String]?
    public var totalRecords: Int
    public var analysisPasses: Int
    public var active: AtlasRuntimeAnalysisJob?
}

public struct AtlasRuntimeAnalysisRequest: Codable, Sendable, Equatable {
    public var phase: String
    public var goal: String
    public var focus: String?
    public var id: String
    public var startByte: Int
    public var totalBytes: Int
    public var text: String?
    public var records: [AtlasRuntimeMemoryRecord]?
}

public struct AtlasRuntimeAnalysisReply: Codable, Sendable, Equatable {
    public var text: String
    public var quotes: [String]
    public var consumedBytes: Int
    public var consumedRecords: Int
    public init(text: String = "", quotes: [String] = [], consumedBytes: Int = 0, consumedRecords: Int = 0) {
        self.text = text; self.quotes = quotes; self.consumedBytes = consumedBytes; self.consumedRecords = consumedRecords
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        quotes = try values.decodeIfPresent([String].self, forKey: .quotes) ?? []
        consumedBytes = try values.decodeIfPresent(Int.self, forKey: .consumedBytes) ?? 0
        consumedRecords = try values.decodeIfPresent(Int.self, forKey: .consumedRecords) ?? 0
    }
}

/// Only the selected, approved schema crosses into model context, never the
/// entire catalog.
public struct AtlasRuntimeSelectedTool: Codable, Sendable, Equatable {
    public var server: String
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
}

public struct AtlasRuntimeDiscoveryTool: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
}

/// Only approved, current capability metadata crosses this boundary.
/// Connection configuration, credentials, schemas and server bodies do not.
public struct AtlasRuntimeDiscovery: Codable, Sendable, Equatable {
    public var server: String
    public var name: String
    public var error: String?
    public var toolCount: Int
    public var hasMore: Bool
    public var tools: [AtlasRuntimeDiscoveryTool]
}

public struct AtlasMCPApproval: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var digest: String
    public init(name: String, digest: String) { self.name = name; self.digest = digest }
}

/// The run-scoped server configuration (Go `mcpServerConfig`). The App's
/// `MCPServerConfiguration` encodes to a superset of these keys.
public struct AtlasMCPServerConfig: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var transport: String
    public var url: String
    public var headers: [String: String]
    public var authorizationError: String?
    public var command: String
    public var arguments: [String]
    public var enabled: Bool
    public var allowedTools: [AtlasMCPApproval]
    public var allowResources: Bool

    public init(id: String, name: String = "", transport: String = "", url: String = "", headers: [String: String] = [:],
                authorizationError: String? = nil, command: String = "", arguments: [String] = [], enabled: Bool = false,
                allowedTools: [AtlasMCPApproval] = [], allowResources: Bool = false) {
        self.id = id; self.name = name; self.transport = transport; self.url = url; self.headers = headers
        self.authorizationError = authorizationError; self.command = command; self.arguments = arguments
        self.enabled = enabled; self.allowedTools = allowedTools; self.allowResources = allowResources
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        transport = try values.decodeIfPresent(String.self, forKey: .transport) ?? ""
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try values.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        authorizationError = try values.decodeIfPresent(String.self, forKey: .authorizationError)
        if authorizationError?.isEmpty == true { authorizationError = nil }
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        allowedTools = try values.decodeIfPresent([AtlasMCPApproval].self, forKey: .allowedTools) ?? []
        allowResources = try values.decodeIfPresent(Bool.self, forKey: .allowResources) ?? false
    }

    var isHTTP: Bool { transport == "http" }
}

public struct AtlasRuntimeFrame: Codable, Sendable {
    public var type: String
    public var version: Int?
    public var requestID: String?
    public var id: String?
    public var sdkVersion: String?
    public var revision: String?
    public var mode: String?
    public var servers: [AtlasMCPServerConfig]?
    public var storeDirectory: String?
    public var persistent: Bool?
    public var resume: Bool?
    public var archivedMessages: Int?
    public var memory: AtlasRuntimeMemoryView?
    public var analysis: AtlasRuntimeAnalysisRequest?
    public var analysisResult: AtlasRuntimeAnalysisReply?
    public var analysisError: String?
    public var payloadReady: Bool?
    public var previousOperation: String?
    public var previousError: String?
    public var mcpTool: AtlasRuntimeSelectedTool?
    public var mcpDiscovery: [AtlasRuntimeDiscovery]?
    public var prompt: String?
    public var question: String?
    public var discoveryQuery: String?
    public var content: String?
    public var error: String?
    public var tool: String?
    public var argumentsJSON: String?
    public var tools: [AtlasRuntimeToolDefinition]?
    public var toolCalls: [AtlasRuntimeToolCall]?
    public var messages: [AtlasRuntimeMessage]?
    public var finalStep: Bool?
    public var step: Int?
    public var steps: Int?
    public var toolCount: Int?
    public var stopReason: String?
    public var success: Bool?

    public init(type: String) { self.type = type }

    /// Go encodes empty strings, zero ints and false bools as absent
    /// (omitempty), except `payloadReady` and `toolCount`, which are always present.
    func normalized() -> AtlasRuntimeFrame {
        var frame = self
        func clear(_ value: inout String?) { if value?.isEmpty == true { value = nil } }
        clear(&frame.requestID); clear(&frame.id); clear(&frame.mode); clear(&frame.storeDirectory); clear(&frame.analysisError)
        clear(&frame.previousOperation); clear(&frame.previousError); clear(&frame.prompt); clear(&frame.question)
        clear(&frame.discoveryQuery); clear(&frame.content); clear(&frame.error); clear(&frame.tool); clear(&frame.argumentsJSON)
        clear(&frame.stopReason); clear(&frame.sdkVersion); clear(&frame.revision)
        if frame.persistent == false { frame.persistent = nil }
        if frame.resume == false { frame.resume = nil }
        if frame.finalStep == false { frame.finalStep = nil }
        if frame.success == false { frame.success = nil }
        if frame.archivedMessages == 0 { frame.archivedMessages = nil }
        if frame.step == 0 { frame.step = nil }
        if frame.steps == 0 { frame.steps = nil }
        if frame.mcpDiscovery?.isEmpty == true { frame.mcpDiscovery = nil }
        if frame.messages?.isEmpty == true { frame.messages = nil }
        if frame.tools?.isEmpty == true { frame.tools = nil }
        if frame.toolCalls?.isEmpty == true { frame.toolCalls = nil }
        if frame.servers?.isEmpty == true { frame.servers = nil }
        frame.payloadReady = frame.payloadReady ?? false
        frame.toolCount = frame.toolCount ?? 0
        return frame
    }
}
