// Host-declared tools through the real runtime: iOS declares none (or its own
// read tools), the Mac declares getMacContext/inspectLocalFiles. Only names
// declared at start can be dispatched.
import Foundation
import Synchronization
import Testing
@testable import OmniFlowApp

struct AtlasHostToolTests {
    static func definition(_ name: String) -> AtlasRuntimeToolDefinition {
        AtlasRuntimeToolDefinition(name: name, description: "Fixture tool \(name).", inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#)
    }

    static func start(_ tools: [AtlasRuntimeToolDefinition]) -> AtlasRuntimeFrame {
        var frame = startFrame("What did I dictate yesterday?")
        frame.tools = tools
        return frame
    }

    @Test func zeroHostToolsAnswer() async throws {
        let client = FrameClient(Self.start([]))
        let frame = try #require(await client.read())
        #expect(frame.type == "model" && frame.step == 1)
        client.reply(to: frame, content: "You have no tools, but here is the answer.")
        let done = try #require(await client.read())
        #expect(done.type == "done" && done.steps == 1 && done.toolCount == 0)
    }

    @Test func nonMacHostToolDispatches() async throws {
        let client = FrameClient(Self.start([Self.definition("searchMyDictations")]))
        var frame = try #require(await client.read())
        client.reply(to: frame, toolCalls: call("searchMyDictations", #"{"query":"yesterday"}"#))
        frame = try #require(await client.read())
        #expect(frame.type == "tool" && frame.tool == "searchMyDictations" && frame.argumentsJSON == #"{"query":"yesterday"}"#)
        client.reply(to: frame, content: "Dictation: buy persimmons.")
        let event = try #require(await client.read())
        #expect(event.type == "event" && event.tool == "searchMyDictations" && event.success == true)
        frame = try #require(await client.read())
        #expect(frame.type == "model" && (frame.messages?.last?.content ?? "").contains("persimmons"))
        client.reply(to: frame, content: "You dictated: buy persimmons.")
        let done = try #require(await client.read())
        #expect(done.type == "done" && done.toolCount == 1)
    }

    @Test(arguments: ["getMacContext", "inspectLocalFiles", "web_search", "searchMyDictation"])
    func undeclaredNameIsDenied(name: String) async throws {
        let client = FrameClient(Self.start([Self.definition("searchMyDictations")]))
        let frame = try #require(await client.read())
        client.reply(to: frame, toolCalls: call(name, "{}"))
        guard case let .failure(error) = await client.result else { Issue.record("undeclared tool ran"); return }
        #expect(String(describing: error).contains("tool_denied"))
    }

    @Test(arguments: ["mcp", "payload", "memory", "selectMCPTool", "callSelectedMCPTool", "mcpResources", "analyzeStoredSource",
                      "9tools", "bad-name", "_hidden", "", String(repeating: "a", count: 65)])
    func reservedOrInvalidNamesAreRefusedAtStart(name: String) async throws {
        let client = FrameClient(Self.start([Self.definition(name)]))
        guard case let .failure(error) = await client.result else { Issue.record("accepted host tool \(name)"); return }
        #expect((error as? AtlasRuntimeError)?.code == "tool_denied")
    }

    @Test func duplicatesAndTooManyToolsAreRefused() async throws {
        let duplicate = FrameClient(Self.start([Self.definition("searchMyDictations"), Self.definition("searchMyDictations")]))
        guard case let .failure(first) = await duplicate.result else { Issue.record("duplicate accepted"); return }
        #expect((first as? AtlasRuntimeError)?.code == "duplicate_tool")
        let many = FrameClient(Self.start((0..<9).map { Self.definition("tool\($0)") }))
        guard case let .failure(second) = await many.result else { Issue.record("nine tools accepted"); return }
        #expect((second as? AtlasRuntimeError)?.code == "invalid_start")
    }

    @MainActor @Test func nativeRunnerWithNoToolsAndACustomTool() async throws {
        let events = Mutex<[String]>([])
        let runner = NativeAtlasRunner<HostFrame>(pool: MCPConnectionPool(), launcher: nil, mapError: { HostError.code($0) },
                                                  timedOut: HostError.timedOut, onEvent: { tool, success in events.withLock { $0.append("\(tool):\(success)") } })
        let plain = try await runner.run(prompt: "Hello", tools: [AtlasRuntimeToolDefinition](), servers: [HostServer](),
            onModel: { _ in HostFrame(type: "reply", content: "Hi.") }, onTool: { _ in throw HostError.own })
        #expect(plain.text == "Hi." && plain.toolCount == 0)
        var models = 0
        let custom = try await NativeAtlasRunner<HostFrame>(pool: MCPConnectionPool(), launcher: nil, mapError: { HostError.code($0) },
                                                            timedOut: HostError.timedOut, onEvent: { tool, success in events.withLock { $0.append("\(tool):\(success)") } })
            .run(prompt: "What did I dictate?", tools: [Self.definition("searchMyDictations")], servers: [HostServer](), onModel: { _ in
                models += 1
                return models == 1 ? HostFrame(type: "reply", toolCalls: [AtlasRuntimeToolCall(name: "searchMyDictations", argumentsJSON: "{}")])
                    : HostFrame(type: "reply", content: "Buy persimmons.")
            }, onTool: { frame in HostFrame(type: "reply", content: frame.tool == "searchMyDictations" ? "persimmons" : "wrong") })
        #expect(custom.text == "Buy persimmons." && custom.toolCount == 1)
        for _ in 0..<50 where events.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(events.withLock { $0 } == ["searchMyDictations:true"])
    }
}
