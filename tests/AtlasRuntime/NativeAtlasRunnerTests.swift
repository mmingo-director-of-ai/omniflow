// The in-process runner that replaces AtlasBridge: transcoding to an App-shaped
// frame, callback/telemetry semantics, error mapping, catalog mode, identity.
import Foundation
import Testing
import Synchronization
@testable import OmniFlowApp

/// A stand-in for the App's `AtlasFrame` (same JSON keys, App-side optionals).
struct HostFrame: Codable, Sendable {
    var type: String
    var version = 4
    var requestID: String?
    var id: String?
    var step: Int?
    var content: String?
    var tool: String?
    var argumentsJSON: String?
    var toolCalls: [AtlasRuntimeToolCall]?
    var messages: [AtlasRuntimeMessage]?
    var payloadReady: Bool?
    var finalStep: Bool?
    var mcpDiscovery: [AtlasRuntimeDiscovery]?
}

/// A stand-in for the App's `MCPServerConfiguration` (a superset of keys).
struct HostServer: Codable, Sendable {
    var id: String
    var name = ""
    var transport = "http"
    var url = ""
    var useOAuth = true
    var oauthClientID = "client"
    var headers: [String: String] = [:]
    var authorizationError: String?
    var command = ""
    var arguments: [String] = []
    var enabled = true
    var allowedTools: [AtlasMCPApproval] = []
    var allowResources = false
}

enum HostError: Error, Equatable { case code(String), timedOut, own }

@MainActor
struct NativeAtlasRunnerTests {
    let tools = [AtlasRuntimeToolDefinition(name: "getMacContext", description: "Mac", inputSchemaJSON: #"{"type":"object"}"#),
                 AtlasRuntimeToolDefinition(name: "inspectLocalFiles", description: "Files", inputSchemaJSON: #"{"type":"object"}"#)]

    @Test func runsToolLoopThroughHostShapedFrames() async throws {
        let events = Mutex<[String]>([])
        let runner = NativeAtlasRunner<HostFrame>(pool: MCPConnectionPool(), launcher: nil, mapError: { HostError.code($0) },
                                                  timedOut: HostError.timedOut, onEvent: { tool, success in events.withLock { $0.append("\(tool):\(success)") } })
        var models = 0
        let result = try await runner.run(prompt: "What is the label?", tools: tools, servers: [HostServer](), question: "What is the label?",
            onModel: { frame in
                models += 1
                #expect(frame.type == "model" && frame.payloadReady != nil)
                if models == 1 { return HostFrame(type: "reply", toolCalls: [AtlasRuntimeToolCall(name: "inspectLocalFiles", argumentsJSON: #"{"path":"/fixture"}"#)]) }
                #expect((frame.messages?.last?.content ?? "").contains("persimmon"))
                return HostFrame(type: "reply", content: "The label is persimmon.")
            }, onTool: { frame in
                #expect(frame.tool == "inspectLocalFiles" && frame.argumentsJSON == #"{"path":"/fixture"}"#)
                return HostFrame(type: "reply", content: "fixture label: persimmon")
            })
        #expect(result.text == "The label is persimmon." && result.steps == 2 && result.toolCount == 1)
        for _ in 0..<50 where events.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(events.withLock { $0 } == ["inspectLocalFiles:true"])
    }

    @Test func hostCallbackErrorsEndTheRunUnchanged() async throws {
        let runner = NativeAtlasRunner<HostFrame>(pool: MCPConnectionPool(), launcher: nil, mapError: { HostError.code($0) }, timedOut: HostError.timedOut)
        await #expect(throws: HostError.own) {
            _ = try await runner.run(prompt: "p", tools: tools, servers: [HostServer](), onModel: { _ in
                HostFrame(type: "reply", toolCalls: [AtlasRuntimeToolCall(name: "getMacContext", argumentsJSON: "{}")])
            }, onTool: { _ in throw HostError.own })
        }
        // Runtime failures map to fixed codes; internal detail never escapes.
        await #expect(throws: HostError.code("atlas_run_failed")) {
            _ = try await NativeAtlasRunner<HostFrame>(pool: MCPConnectionPool(), launcher: nil, mapError: { HostError.code($0) }, timedOut: HostError.timedOut)
                .run(prompt: "p", tools: tools, servers: [HostServer](), onModel: { _ in
                    HostFrame(type: "reply", toolCalls: [AtlasRuntimeToolCall(name: "run_shell_command", argumentsJSON: "{}")])
                }, onTool: { _ in HostFrame(type: "reply") })
        }
    }

    @Test func runTimeoutUsesHostTimeoutError() async throws {
        let runner = NativeAtlasRunner<HostFrame>(pool: MCPConnectionPool(), launcher: nil, mapError: { HostError.code($0) }, timedOut: HostError.timedOut)
        await #expect(throws: HostError.timedOut) {
            _ = try await runner.run(prompt: "p", tools: tools, servers: [HostServer](), timeout: 0.1, onModel: { _ in
                try await Task.sleep(for: .seconds(5)); return HostFrame(type: "reply", content: "late")
            }, onTool: { _ in HostFrame(type: "reply") })
        }
    }

    @Test func authorizationHookAndExposedRemoteCodes() async throws {
        let server = LoopbackHTTPServer { _, response in response.respond(403) }
        let authorized = Mutex(false)
        let catalogError: (any Error)?
        do {
            _ = try await NativeAtlasRunner<HostFrame>.catalog(server: HostServer(id: "s1", url: server.url + "/mcp"), as: AtlasJSONCatalog.self,
                pool: MCPConnectionPool(), launcher: nil, authorize: { servers, required in
                    #expect(required)
                    authorized.withLock { $0 = true }
                    return servers.map { var server = $0; server.headers["Authorization"] = "Bearer injected"; return server }
                }, mapError: { HostError.code($0) }, timedOut: HostError.timedOut)
            catalogError = nil
        } catch { catalogError = error }
        #expect(authorized.withLock { $0 } && (catalogError as? HostError) == .code("mcp_http_forbidden"))
    }

    @Test func catalogModeReturnsReviewMetadata() async throws {
        let definition = #"{"name":"read_label","description":"Read the label.","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}"#
        let endpoint = MCPFixtureEndpoint(result: { method, _, request in
            #expect(request.header("Authorization") == "Bearer injected")
            switch method {
            case "initialize": return MCPFixtureEndpoint.initializeResult
            case "tools/list": return #"{"tools":[\#(definition)]}"#
            default: return nil
            }
        })
        let pool = MCPConnectionPool()
        let catalog = try await NativeAtlasRunner<HostFrame>.catalog(server: HostServer(id: "s1", url: endpoint.url, headers: ["Authorization": "Bearer injected"]),
                                                                    as: AtlasJSONCatalog.self, pool: pool, launcher: nil)
        #expect(catalog.tools.map(\.name) == ["read_label"] && catalog.tools[0].digest == approvalDigest(definition) && catalog.tools[0].supported && !catalog.hasResources)
        await pool.closeAll()
    }

    @Test func identityMatchesTheSDKLock() throws {
        let lock = try AtlasJSON.parse(Array(Data(contentsOf: Fixtures.repository.appendingPathComponent("OmniFlow/Helpers/Atlas/atlas-sdk.lock.json"))))
        #expect(lock["version"]?.stringValue == AtlasRuntimeIdentity.version && lock["revision"]?.stringValue == AtlasRuntimeIdentity.revision)
    }
}

/// The App's `MCPCatalog` shape.
struct AtlasJSONCatalog: Decodable {
    struct Tool: Decodable { let name: String; let description: String; let digest: String; let supported: Bool }
    let tools: [Tool]
    let hasResources: Bool
}
