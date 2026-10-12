// Ports of main_test.go, mcp_discovery_test.go and payload_ready_test.go,
// driven in-process (FrameClient) or over the v4 line protocol (AtlasFrameServer).
import Foundation
import Testing
import Synchronization
@testable import OmniFlowApp

@Suite(.serialized) struct AtlasServeTests {
    @Test func realAtlasToolLoop() async throws {
        let client = FrameClient(startFrame())
        var frame = try #require(await client.read())
        #expect(frame.type == "model" && frame.step == 1 && frame.messages?.count == 1, "initial model call missing")
        client.reply(to: frame, toolCalls: call("inspectLocalFiles", #"{"operation":"read","path":"/local-fixture"}"#))
        frame = try #require(await client.read())
        #expect(frame.type == "tool" && frame.tool == "inspectLocalFiles", "Atlas did not dispatch the tool")
        client.reply(to: frame, content: "private fixture label: persimmon")
        let event = try #require(await client.read())
        #expect(event.type == "event" && event.success == true && event.content == nil && event.argumentsJSON == nil, "content leaked into event")
        frame = try #require(await client.read())
        #expect(frame.type == "model" && frame.step == 2 && (frame.messages?.last?.content ?? "").contains("persimmon"))
        client.reply(to: frame, content: "The label is persimmon.")
        frame = try #require(await client.read())
        #expect(frame.type == "done" && frame.toolCount == 1 && frame.steps == 2 && frame.stopReason == "stop")
        let outcome = await client.result
        #expect(!outcome.isFailure)
    }

    @Test func invalidBatchTailCannotExecuteValidHead() async throws {
        let client = FrameClient(startFrame())
        let frame = try #require(await client.read())
        client.reply(to: frame, toolCalls: [
            AtlasRuntimeToolCall(name: "getMacContext", argumentsJSON: #"{"topic":"battery"}"#),
            AtlasRuntimeToolCall(name: "unregistered", argumentsJSON: "{}")])
        let result = try await atlasWithDeadline(1, timeout: AtlasRuntimeError("unexpected_tool_dispatch")) { await client.result }
        guard case let .failure(error) = result else {
            Issue.record("Invalid batch was admitted"); return
        }
        #expect(String(describing: error).contains("tool_denied"))
    }

    @Test(arguments: ["web_search", "run_shell_command", "write_file", "unknown"])
    func unknownToolsCannotReachHost(name: String) async throws {
        let client = FrameClient(startFrame())
        let frame = try #require(await client.read())
        client.reply(to: frame, toolCalls: call(name, "{}"))
        guard case let .failure(error) = await client.result else { Issue.record("unregistered tool was not denied"); return }
        #expect(String(describing: error).contains("tool_denied"))
    }

    @Test func stepLimitRequiresFinalAnswer() async throws {
        let client = FrameClient(startFrame())
        for step in 1...atlasMaxSteps {
            var frame = try #require(await client.read())
            #expect(frame.type == "model" && frame.step == step && (frame.finalStep ?? false) == (step == atlasMaxSteps), "step budget not enforced")
            if frame.finalStep == true {
                client.reply(to: frame, content: "Here is the bounded result.")
                break
            }
            client.reply(to: frame, toolCalls: call("getMacContext", #"{"topic":"system"}"#))
            frame = try #require(await client.read())
            client.reply(to: frame, content: "local evidence")
            _ = await client.read() // content-free tool event
        }
        let result = try #require(await client.read())
        #expect(result.steps == atlasMaxSteps && result.toolCount == atlasMaxSteps - 1, "Atlas exceeded its budget")
    }

    @Test(arguments: [false, true]) func cancelAndMismatchedReply(cancel: Bool) async throws {
        let client = FrameClient(startFrame())
        _ = await client.read()
        if cancel {
            client.task.cancel()
        } else {
            var reply = AtlasRuntimeFrame(type: "reply"); reply.content = "ignored"
            client.write(reply, id: "stale-callback")
        }
        let outcome = try await atlasWithDeadline(1, timeout: AtlasRuntimeError("hung")) { await client.result.isFailure }
        #expect(outcome, "invalid run succeeded")
    }

    @Test(arguments: ["not json\n", String(repeating: "x", count: AtlasFrameServer.maximumFrameBytes + 1)])
    func malformedAndOversizedInput(input: String) async throws {
        let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
        continuation.yield(Array(input.utf8))
        continuation.finish()
        let server = AtlasFrameServer(input: stream, output: { _ in }, pool: MCPConnectionPool(), launcher: nil)
        await #expect(throws: AtlasRuntimeError.self) { try await server.serve() }
    }

    @Test func frameServerSpeaksTheV4WireProtocol() async throws {
        let (input, feed) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
        let (lines, sink) = AsyncStream<AtlasRuntimeFrame>.makeStream()
        let server = AtlasFrameServer(input: input, output: { bytes in
            if let frame = try? JSONDecoder().decode(AtlasRuntimeFrame.self, from: Data(bytes.dropLast())) { sink.yield(frame) }
        }, pool: MCPConnectionPool(), launcher: nil)
        let task = Task { try await server.serve() }
        var iterator = lines.makeAsyncIterator()
        func send(_ frame: AtlasRuntimeFrame) { feed.yield(Array(try! JSONEncoder().encode(frame)) + [0x0A]) }
        let ready = try #require(await iterator.next())
        #expect(ready.type == "ready" && ready.version == 4 && ready.sdkVersion == AtlasRuntimeIdentity.version && ready.revision == AtlasRuntimeIdentity.revision)
        var start = startFrame(); start.version = 4; start.requestID = "wire"
        send(start)
        let model = try #require(await iterator.next())
        #expect(model.type == "model" && model.id == "1" && model.requestID == "wire" && model.payloadReady == false)
        var reply = AtlasRuntimeFrame(type: "reply"); reply.version = 4; reply.requestID = "wire"; reply.id = model.id; reply.content = "Answer."
        send(reply)
        let done = try #require(await iterator.next())
        #expect(done.type == "done" && done.content == "Answer." && done.steps == 1 && done.toolCount == 0)
        try await task.value
        #expect(AtlasFrameServer.errorFrame(AtlasRuntimeError("tool_denied")).error == "atlas_run_failed")
        #expect(AtlasFrameServer.errorFrame(AtlasRuntimeError("mcp_http_forbidden")).error == "mcp_http_forbidden")
    }

    // MARK: Discovery (mcp_discovery_test.go)

    static func definition(_ name: String, _ description: String, unsupported: Bool = false) -> String {
        let format = unsupported ? #","format":"unsupported""# : ""
        return #"{"name":"\#(name)","description":"\#(description)","inputSchema":{"type":"object","properties":{},"additionalProperties":false\#(format)}}"#
    }

    @Test func initialDiscoveryIsBoundedApprovedMetadata() async throws {
        var definitions: [String] = []
        var approvals: [AtlasMCPApproval] = []
        for index in 1...12 {
            let name = String(format: "read_%02d", index)
            let definition = Self.definition(name, String(repeating: "café 紅熊猫. ", count: 30), unsupported: index == 12)
            definitions.append(definition)
            if index == 10 { continue } // advertised but never approved
            approvals.append(AtlasMCPApproval(name: name, digest: index == 11 ? String(repeating: "0", count: 64) : approvalDigest(definition)))
        }
        let credential = "Bearer discovery-fixture-private-token"
        let problems = Mutex<[String]>([])
        let catalog = #"{"tools":[\#(definitions.joined(separator: ","))]}"#
        let endpoint = MCPFixtureEndpoint(result: { method, _, request in
            if request.header("Authorization") != credential { problems.withLock { $0.append("credential missing") } }
            switch method {
            case "initialize": return MCPFixtureEndpoint.initializeResult
            case "tools/list": return catalog
            case "tools/call": problems.withLock { $0.append("discovery executed a remote operation") }; return #"{"content":[]}"#
            default: return nil
            }
        }, custom: { request, response in
            if request.path == "/denied" {
                response.respond(401, body: Array("PRIVATE_REMOTE_ERROR_BODY".utf8))
                return true
            }
            return false
        })
        let base = endpoint.server.url
        let client = FrameClient(startFrame("Read a project note, or use native context if a connection fails.", servers: [
            AtlasMCPServerConfig(id: "denied", name: "Unavailable connection", transport: "http", url: base + "/denied", enabled: true),
            AtlasMCPServerConfig(id: "enabled", name: "Available connection", transport: "http", url: endpoint.url, headers: ["Authorization": credential],
                                 enabled: true, allowedTools: approvals),
            AtlasMCPServerConfig(id: "disabled", name: "Disabled connection", transport: "http", url: base + "/denied")
        ]))
        var frame = try #require(await client.read())
        #expect(frame.type == "model" && frame.step == 1 && frame.payloadReady == false && frame.mcpTool == nil && endpoint.count("tools/call") == 0)
        let discovery = frame.mcpDiscovery ?? []
        #expect(discovery.count == 2 && discovery.first?.error == "mcp_authentication_required" && discovery.last?.error == nil)
        let found = try #require(discovery.last)
        #expect(found.server == "enabled" && found.name == "Available connection" && found.toolCount == 9 && found.hasMore && found.tools.count == 8)
        for (index, tool) in found.tools.enumerated() {
            #expect(tool.name == String(format: "read_%02d", index + 1) && tool.description.utf8.count <= 200)
        }
        let encoded = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
        for secret in [credential, "PRIVATE_REMOTE_ERROR_BODY", #""headers""#, #""inputSchemaJSON""#] {
            #expect(!encoded.contains(secret), "leaked into discovery: \(secret)")
        }
        // A failed remote server does not block a normal native tool/answer path.
        client.reply(to: frame, toolCalls: call("getMacContext", "{}"))
        frame = try #require(await client.read())
        #expect(frame.type == "tool" && frame.tool == "getMacContext")
        client.reply(to: frame, content: "Native fixture evidence.")
        _ = await client.read()
        frame = try #require(await client.read())
        #expect(frame.type == "model" && frame.mcpDiscovery?.count == 2 && endpoint.count("initialize") == 1 && endpoint.count("tools/list") == 1)
        // Catalog filtering is metadata search, not a search of remote documents.
        client.reply(to: frame, toolCalls: call("mcp", #"{"operation":"tools","server":"enabled","query":"a document title not in tool metadata"}"#))
        _ = await client.read()
        frame = try #require(await client.read())
        var filtered = decoded(frame.messages?.last?.content ?? "")
        #expect(filtered["total"] == .number(0) && filtered["toolCount"] == .number(9) && filtered["searchScope"]?.stringValue == "tool_catalog"
                && !(filtered["filter"]?.stringValue ?? "").isEmpty && filtered["tools"]?.arrayValue?.isEmpty == true)
        client.reply(to: frame, toolCalls: call("mcp", #"{"operation":"tools","server":"enabled","offset":8}"#))
        _ = await client.read()
        frame = try #require(await client.read())
        filtered = decoded(frame.messages?.last?.content ?? "")
        #expect(filtered["total"] == .number(9) && filtered["tools"]?.arrayValue?.count == 1 && filtered["tools"]?.arrayValue?.first?["name"]?.stringValue == "read_09"
                && endpoint.count("tools/list") == 1 && endpoint.count("tools/call") == 0)
        client.reply(to: frame, content: "Native fixture evidence is available.")
        let done = try #require(await client.read())
        #expect(done.type == "done" && done.stopReason == "stop")
        #expect(problems.withLock { $0 }.isEmpty, "\(problems.withLock { $0 })")
    }

    @Test func discoveryCancellationAndSafeErrors() async throws {
        let requests = Mutex(0)
        let server = LoopbackHTTPServer { _, response in
            requests.withLock { $0 += 1 }
            _ = response.waitForDisconnect(timeout: 5)
        }
        let store = try AtlasPayloadStore(directory: nil)
        defer { store.close() }
        let pool = MCPConnectionPool()
        let host = try AtlasMCPHost(configs: [AtlasMCPServerConfig(id: "slow", name: "Slow fixture", transport: "http", url: server.url, enabled: true)],
                                    store: store, pool: pool, launcher: nil)
        let started = ContinuousClock.now
        var metadata = await host.discover("", timeout: 0.1)
        #expect(metadata.count == 1 && (metadata[0].error ?? "").hasSuffix("timeout") && ContinuousClock.now - started < .seconds(1) && requests.withLock { $0 } == 1)
        let cancelled = Task { () -> [AtlasRuntimeDiscovery] in
            withUnsafeCurrentTask { $0?.cancel() }
            let store = try! AtlasPayloadStore(directory: nil)
            defer { store.close() }
            let host = try! AtlasMCPHost(configs: [AtlasMCPServerConfig(id: "slow", name: "Slow fixture", transport: "http", url: server.url, enabled: true)],
                                         store: store, pool: pool, launcher: nil)
            return await host.discover("")
        }
        metadata = await cancelled.value
        #expect(metadata.count == 1 && metadata[0].error == "mcp_discovery_cancelled" && requests.withLock { $0 } == 1, "cancelled discovery initiated another connection")
        #expect(AtlasMCPHost.discoveryError(AtlasRuntimeError("private_token_from_remote_service")) == "mcp_discovery_failed")
        await host.close()
        await pool.closeAll()
    }

    /// The ranking fixture from mcp_discovery_test.go, attached to a fake connection.
    static func rankingConnection() -> AtlasMCPRunConnection {
        var tools: [String: MCPCatalogTool] = [:]
        var approvals: [AtlasMCPApproval] = []
        func add(_ name: String, _ description: String, approved: Bool, supported: Bool, digest: String = String(repeating: "a", count: 64)) {
            tools[name] = MCPCatalogTool(name: name, description: description, digest: digest, supported: supported, schema: [:])
            if approved { approvals.append(AtlasMCPApproval(name: name, digest: String(repeating: "a", count: 64))) }
        }
        for index in 1...9 { add(String(format: "read_%02d", index), "Read local service metadata", approved: true, supported: true) }
        add("zeta_relationships", "Search CRM contacts, customers and deals", approved: true, supported: true)
        add("private_unapproved", "CRM contacts customers deals", approved: false, supported: true)
        add("private_unsupported", "CRM contacts customers deals", approved: true, supported: false)
        add("private_stale", "CRM contacts", approved: true, supported: true, digest: String(repeating: "b", count: 64))
        let connection = MCPPooledConnection(session: MCPSession(client: try! MCPHTTPClient(url: "https://example.invalid/mcp", headers: [:])), isHTTP: true,
                                             initialized: MCPInitializeResult(protocolVersion: "2025-11-25", hasTools: true, hasResources: false), key: "")
        let run = AtlasMCPRunConnection(config: AtlasMCPServerConfig(id: "fixture", name: "Available fixture", transport: "http", url: "https://example.invalid/mcp",
                                                                     headers: ["Authorization": "PRIVATE_TRANSPORT_CREDENTIAL"], enabled: true, allowedTools: approvals),
                                        connection: connection, pooled: false)
        run.tools = tools
        return run
    }

    @Test func discoveryRanksOnlyCurrentApprovalsBeforeEightToolLimit() async throws {
        let connection = Self.rankingConnection()
        let store = try AtlasPayloadStore(directory: nil)
        defer { store.close() }
        let host = try AtlasMCPHost(configs: [connection.config], store: store, pool: MCPConnectionPool(), launcher: nil)
        host.connections["fixture"] = connection
        let metadata = await host.discover("Show my CRM contacts. PRIVATE_QUERY_MARKER")
        #expect(metadata.count == 1 && metadata[0].toolCount == 10 && metadata[0].hasMore && metadata[0].tools.count == 8 && metadata[0].tools[0].name == "zeta_relationships")
        #expect(!metadata[0].tools.contains { $0.name.hasPrefix("private_") })
        let encoded = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        for secret in ["PRIVATE_TRANSPORT_CREDENTIAL", "PRIVATE_QUERY_MARKER", "Authorization", "headers"] { #expect(!encoded.contains(secret)) }
        let baseline = AtlasMCPHost.rankedNames(connection, "CRM contacts")
        for _ in 0..<20 { #expect(AtlasMCPHost.rankedNames(connection, String(repeating: "CRM contacts ", count: 20)) == baseline) }
        #expect(AtlasMCPHost.rankedNames(connection, "Use `read_09` for the CRM contacts").first == "read_09")
        for query in ["", "please show me what the tools can do", String(repeating: " ", count: 8000) + "CRM contacts"] {
            let names = AtlasMCPHost.rankedNames(connection, query)
            #expect(names.count == 10 && names.first == "read_01" && names.last == "zeta_relationships")
        }
        // A catalog-change notification revokes every grant on the session.
        let changed = MCPSession(client: try MCPHTTPClient(url: "https://example.invalid/mcp", headers: [:]))
        changed.markCatalogChangedForTest()
        let revoked = AtlasMCPRunConnection(config: connection.config, connection: MCPPooledConnection(session: changed, isHTTP: true,
            initialized: MCPInitializeResult(protocolVersion: "2025-11-25", hasTools: true, hasResources: false), key: ""), pooled: false)
        revoked.tools = connection.tools
        #expect(AtlasMCPHost.rankedNames(revoked, "zeta_relationships CRM contacts").isEmpty)
    }

    @Test func discoveryNameBoundariesAndUnicodeTerms() {
        for query in ["read_090", "prefix-read_09", "read_09.extra", "read_09_suffix"] {
            #expect(!AtlasMCPHost.discoveryExactName(query, "read_09"))
        }
        #expect(AtlasMCPHost.discoveryExactName("Use `READ_09` now", "READ_09") && AtlasMCPHost.discoveryTerms("紅熊猫 café CRM CRM", 32).contains("紅熊猫"))
        #expect(AtlasMCPHost.discoveryTerms(String(repeating: "CRM ", count: 200), 32).count == 1)
    }

    @Test func discoveryQueryOverridesQuestionAndRemainsHostOnly() async throws {
        let ranking = Self.rankingConnection()
        var definitions: [String] = []
        var approvals: [AtlasMCPApproval] = []
        for (name, tool) in ranking.tools where !name.hasPrefix("private_") {
            let definition = Self.definition(name, tool.description)
            definitions.append(definition)
            approvals.append(AtlasMCPApproval(name: name, digest: approvalDigest(definition)))
        }
        let problems = Mutex<[String]>([])
        let catalog = #"{"tools":[\#(definitions.joined(separator: ","))]}"#
        let endpoint = MCPFixtureEndpoint(result: { method, _, request in
            if String(decoding: request.body, as: UTF8.self).contains("PRIVATE_QUERY_MARKER") { problems.withLock { $0.append("query sent to server") } }
            switch method {
            case "initialize": return MCPFixtureEndpoint.initializeResult
            case "tools/list": return catalog
            default: problems.withLock { $0.append("non-discovery operation \(method)") }; return nil
            }
        })
        for (query, question, first) in [("CRM contacts PRIVATE_QUERY_MARKER", "unrelated", "zeta_relationships"), ("", "CRM contacts", "zeta_relationships"),
                                         ("unrelated", "CRM contacts", "read_01")] {
            let client = FrameClient(startFrame("Rank only approved capability metadata.", servers: [
                AtlasMCPServerConfig(id: "fixture", name: "Fixture", transport: "http", url: endpoint.url, enabled: true, allowedTools: approvals)
            ], question: question, discoveryQuery: query))
            let frame = try #require(await client.read())
            #expect(frame.type == "model" && frame.mcpDiscovery?.count == 1 && frame.mcpDiscovery?[0].tools.count == 8
                    && frame.mcpDiscovery?[0].tools.first?.name == first && frame.mcpTool == nil)
            let encoded = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
            #expect(frame.discoveryQuery == nil && !encoded.contains("PRIVATE_QUERY_MARKER"))
            client.reply(to: frame, content: "Metadata review complete.")
            let done = try #require(await client.read())
            #expect(done.type == "done" && done.toolCount == 0)
        }
        let before = endpoint.count("initialize")
        var oversized = startFrame("Reject oversized ranking input.", servers: [
            AtlasMCPServerConfig(id: "fixture", name: "Fixture", transport: "http", url: endpoint.url, enabled: true, allowedTools: approvals)
        ])
        oversized.discoveryQuery = String(repeating: "紅", count: 2667)
        let client = FrameClient(oversized)
        guard case let .failure(error) = await client.result else { Issue.record("oversized discovery query accepted"); return }
        #expect((error as? AtlasRuntimeError)?.code == "invalid_start" && endpoint.count("initialize") == before)
        #expect(problems.withLock { $0 }.isEmpty, "\(problems.withLock { $0 })")
    }

    /// New with the native runtime: first-step discovery connects to every
    /// server concurrently instead of one after another.
    @Test func discoveryConnectsToServersInParallel() async throws {
        let endpoints = (0..<3).map { _ in
            MCPFixtureEndpoint(result: { method, _, _ in
                switch method {
                case "initialize":
                    Thread.sleep(forTimeInterval: 0.3)
                    return MCPFixtureEndpoint.initializeResult
                case "tools/list": return #"{"tools":[]}"#
                default: return nil
                }
            })
        }
        let store = try AtlasPayloadStore(directory: nil)
        defer { store.close() }
        let pool = MCPConnectionPool()
        let host = try AtlasMCPHost(configs: endpoints.enumerated().map {
            AtlasMCPServerConfig(id: "s\($0.offset + 1)", name: "Slow \($0.offset)", transport: "http", url: $0.element.url, enabled: true)
        }, store: store, pool: pool, launcher: nil)
        let started = ContinuousClock.now
        let metadata = await host.discover("anything")
        let elapsed = ContinuousClock.now - started
        #expect(metadata.map(\.server) == ["s1", "s2", "s3"] && metadata.allSatisfy { $0.error == nil })
        #expect(elapsed < .milliseconds(600), "discovery took \(elapsed); three 300 ms handshakes ran sequentially")
        await host.close()
        // A second run reuses the pooled sessions: no new handshakes.
        let again = try AtlasMCPHost(configs: host.configs, store: store, pool: pool, launcher: nil)
        let warmStart = ContinuousClock.now
        _ = await again.discover("anything")
        #expect(ContinuousClock.now - warmStart < .milliseconds(250) && endpoints.allSatisfy { $0.count("initialize") == 1 })
        await again.close()
        await pool.closeAll()
    }

    @Test func payloadReadyRequiresExecutionEvidence() async throws {
        let schema = #"{"type":"object","description":"\#(String(repeating: "Schema metadata only. ", count: atlasChunkBytes / 8))","properties":{},"additionalProperties":false}"#
        let definition = #"{"name":"read_fixture","description":"Read fixture evidence","inputSchema":\#(schema)}"#
        let executions = Mutex(0)
        let endpoint = MCPFixtureEndpoint(result: { method, _, _ in
            switch method {
            case "initialize": return MCPFixtureEndpoint.initializeResult
            case "tools/list": return #"{"tools":[\#(definition)]}"#
            case "tools/call":
                executions.withLock { $0 += 1 }
                return #"{"content":[{"type":"text","text":"The fixture label is persimmon."}]}"#
            default: return nil
            }
        })
        let client = FrameClient(startFrame("Read the fixture label.", servers: [
            AtlasMCPServerConfig(id: "fixture", name: "Fixture", transport: "http", url: endpoint.url, enabled: true,
                                 allowedTools: [AtlasMCPApproval(name: "read_fixture", digest: approvalDigest(definition))])
        ]))
        var frame = try #require(await client.read())
        #expect(frame.type == "model" && frame.payloadReady == false)
        client.reply(to: frame, toolCalls: call("mcp", #"{"operation":"schema","server":"fixture","name":"read_fixture"}"#))
        var event = try #require(await client.read())
        #expect(event.type == "event" && event.success == true)
        frame = try #require(await client.read())
        #expect(frame.type == "model" && frame.payloadReady == false && frame.mcpTool != nil && executions.withLock { $0 } == 0)
        let receipt = decoded(frame.messages?.last?.content ?? "")
        let definitionID = receipt["parameterDefinitionID"]?.stringValue ?? ""
        #expect(!definitionID.isEmpty && (frame.mcpTool?.inputSchemaJSON.utf8.count ?? 0) > atlasChunkBytes)
        // Explicitly reading schema text must still leave source analysis unavailable.
        client.reply(to: frame, toolCalls: call("payload", #"{"operation":"read","id":"\#(definitionID)","offset":1}"#))
        event = try #require(await client.read())
        #expect(event.type == "event" && event.success == true)
        frame = try #require(await client.read())
        #expect(frame.type == "model" && frame.payloadReady == false && executions.withLock { $0 } == 0)
        let inspection = decoded(frame.messages?.last?.content ?? "")
        #expect(inspection["payload"]?["id"]?.stringValue == definitionID && inspection["payload"]?["kind"]?.stringValue == "schema"
                && (inspection["payload"]?["chunks"]?.doubleValue ?? 0) >= 2 && inspection["chunk"] == .number(1) && !(inspection["text"]?.stringValue ?? "").isEmpty)
        client.reply(to: frame, toolCalls: call("mcp", #"{"operation":"call","server":"fixture","name":"read_fixture","argumentsJSON":"{}"}"#))
        event = try #require(await client.read())
        #expect(event.type == "event" && event.success == true)
        frame = try #require(await client.read())
        #expect(frame.type == "model" && frame.payloadReady == true && executions.withLock { $0 } == 1)
        #expect((frame.messages?.last?.content ?? "").contains("persimmon"))
        client.reply(to: frame, content: "The label is persimmon.")
        let done = try #require(await client.read())
        #expect(done.type == "done" && done.stopReason == "stop")
    }
}

extension Result {
    var isFailure: Bool { if case .failure = self { true } else { false } }
}
