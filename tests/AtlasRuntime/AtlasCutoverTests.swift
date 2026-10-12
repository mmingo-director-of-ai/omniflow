// Compiles and runs the documented AtlasAssistant cutover against the App's
// real types (AtlasFrame, AtlasToolDefinition, MCPServerConfiguration,
// AtlasBridgeError, MCPAuthorization, MCPCatalog) instead of stand-ins.
import Foundation
import Testing
@testable import OmniFlowApp

@MainActor
struct AtlasCutoverTests {
    @Test func documentedRunCallDrivesRealAppFrames() async throws {
        let definitions = [
            AtlasToolDefinition(name: "getMacContext", description: "Mac", inputSchemaJSON: #"{"type":"object"}"#),
            AtlasToolDefinition(name: "inspectLocalFiles", description: "Files", inputSchemaJSON: #"{"type":"object"}"#)
        ]
        let activeServers: [MCPServerConfiguration] = []
        var tools: [String] = []
        // The cutover expression from docs/omniflow/atlas-swift-port.md, step 2.
        let result = try await NativeAtlasRunner<AtlasFrame>(pool: MCPConnectionPool(), launcher: nil,
            mapError: AtlasBridgeError.remoteCode, timedOut: AtlasBridgeError.timedOut,
            onEvent: { tool, success in Task { await LocalTelemetry.shared.event("atlas.tool.\(tool)", success: success) } })
            .run(prompt: "What is the label?", tools: definitions, servers: activeServers, question: "What is the label?",
                 discoveryQuery: "label", workspace: nil, resume: false, authorize: MCPAuthorization.configure,
                 onModel: { frame in
                     #expect(frame.version == 4 && frame.memory != nil && (1...AtlasBridge.maximumSteps).contains(frame.step ?? 0))
                     if frame.step == 1 { return AtlasFrame(type: "reply", toolCalls: [AtlasToolCall(name: "inspectLocalFiles", argumentsJSON: #"{"path":"/x"}"#)]) }
                     #expect((frame.messages?.last?.content ?? "").contains("persimmon"))
                     return AtlasFrame(type: "reply", content: "The label is persimmon.")
                 }, onTool: { frame in
                     tools.append(frame.tool ?? "")
                     return AtlasFrame(type: "reply", content: "label: persimmon")
                 })
        #expect(result.text == "The label is persimmon." && result.steps == 2 && result.toolCount == 1 && tools == ["inspectLocalFiles"])
    }

    @Test func analysisFramesRoundTripThroughAppTypes() async throws {
        let workspace = ScratchDirectory()
        let directory = URL(fileURLWithPath: workspace.file("task"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let definitions = [AtlasToolDefinition(name: "getMacContext", description: "", inputSchemaJSON: #"{"type":"object"}"#),
                           AtlasToolDefinition(name: "inspectLocalFiles", description: "", inputSchemaJSON: #"{"type":"object"}"#)]
        var analysed = false
        let source = String(repeating: "café 紅熊猫 line\n", count: 400) + "Final: production NOT approved.\n"
        let result = try await NativeAtlasRunner<AtlasFrame>(pool: MCPConnectionPool(), launcher: nil, mapError: AtlasBridgeError.remoteCode,
                                                             timedOut: AtlasBridgeError.timedOut)
            .run(prompt: "Analyse", tools: definitions, servers: [MCPServerConfiguration](), question: "Is production approved?", workspace: directory,
                 onModel: { frame in
                     if let analysis = frame.analysis {
                         analysed = true
                         let text = analysis.text ?? ""
                         return AtlasFrame(type: "reply", analysisResult: AtlasAnalysisReply(text: "note", quotes: ["café"],
                                                                                             consumedBytes: text.utf8.count, consumedRecords: 0))
                     }
                     switch frame.step {
                     case 1: return AtlasFrame(type: "reply", toolCalls: [AtlasToolCall(name: "getMacContext", argumentsJSON: "{}")])
                     case 2:
                         // The native tool's output is stored as payload p1.
                         return AtlasFrame(type: "reply", toolCalls: [AtlasToolCall(name: "memory", argumentsJSON: #"{"operation":"analyze","id":"p1"}"#)])
                     default:
                         if frame.memory?.active?.complete == false { return AtlasFrame(type: "reply", toolCalls: [AtlasToolCall(name: "memory", argumentsJSON: #"{"operation":"analyze","id":"p1"}"#)]) }
                         return AtlasFrame(type: "reply", content: "Production is not approved.")
                     }
                 }, onTool: { _ in AtlasFrame(type: "reply", content: source) })
        #expect(analysed && result.text == "Production is not approved.")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("task-memory.jsonl").path))
    }

    @Test func catalogDecodesAsAppCatalog() async throws {
        let definition = #"{"name":"read_label","description":"Read the label.","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}"#
        let endpoint = MCPFixtureEndpoint(result: { method, _, _ in
            method == "initialize" ? MCPFixtureEndpoint.initializeResult : method == "tools/list" ? #"{"tools":[\#(definition)]}"# : nil
        })
        let pool = MCPConnectionPool()
        var server = MCPServerConfiguration()
        server.name = "Fixture"; server.transport = "http"; server.url = endpoint.url; server.enabled = true
        // The cutover expression from step 3.
        let catalog = try await NativeAtlasRunner<AtlasFrame>.catalog(server: server, as: MCPCatalog.self, pool: pool, launcher: nil,
            authorize: MCPAuthorization.configure, mapError: AtlasBridgeError.remoteCode, timedOut: AtlasBridgeError.timedOut)
        #expect(catalog.tools.map(\.name) == ["read_label"] && catalog.tools[0].digest == approvalDigest(definition) && catalog.tools[0].supported)
        await pool.closeAll()
        // A remote failure maps to the App's own error.
        let denied = LoopbackHTTPServer { _, response in response.respond(401) }
        server.url = denied.url + "/mcp"
        await #expect(throws: AtlasBridgeError.self) {
            _ = try await NativeAtlasRunner<AtlasFrame>.catalog(server: server, as: MCPCatalog.self, pool: MCPConnectionPool(), launcher: nil,
                mapError: AtlasBridgeError.remoteCode, timedOut: AtlasBridgeError.timedOut)
        }
    }
}
