// Ports of mcp_http_test.go against a real loopback HTTP server.
import Foundation
import Testing
import Synchronization
@testable import OmniFlowApp

@Suite(.serialized) struct MCPHTTPTests {
    func store() throws -> AtlasPayloadStore { try AtlasPayloadStore(directory: nil) }

    @Test func urlAndHeaderValidation() {
        for endpoint in ["http://example.com/mcp", "https://user:secret@example.com/mcp", "https://example.com/mcp#fragment", "https://example.com/\n", "file:///tmp/mcp", "https://"] {
            #expect(throws: AtlasRuntimeError.self, "accepted invalid endpoint \(endpoint)") { try MCPHTTPClient.validate(url: endpoint, headers: [:]) }
        }
        for endpoint in ["https://example.com/mcp", "http://127.0.0.1:8000/mcp", "http://[::1]/mcp", "http://localhost/mcp"] {
            #expect(throws: Never.self) { try MCPHTTPClient.validate(url: endpoint, headers: [:]) }
        }
        for headers: [String: String] in [["Authorization": "Bearer fixture\r\nInjected: true"], ["Host": "other.example"], ["Mcp-Session-Id": "fixture"],
                                          ["Accept": "*/*"], ["Proxy-Authorization": "secret"], ["Authorization": "", "authorization": "second"]] {
            #expect(throws: AtlasRuntimeError.self) { try MCPHTTPClient.validate(url: "https://example.com/mcp", headers: headers) }
        }
    }

    @Test func sessionPaginationAndToolApproval() async throws {
        let calls = Mutex(0)
        let problems = Mutex<[String]>([])
        let endpoint = MCPFixtureEndpoint(result: { method, params, request in
            if request.header("Authorization") != "Bearer fixture" { problems.withLock { $0.append("authorization not forwarded") } }
            if method != "initialize" && (request.header("Mcp-Session-Id") != "fixture-session" || request.header("Mcp-Protocol-Version") != "2025-11-25") {
                problems.withLock { $0.append("session/protocol headers not retained") }
            }
            switch method {
            case "initialize": return MCPFixtureEndpoint.initializeResult
            case "tools/list":
                let second = params["cursor"]?.stringValue == "second-page"
                let tool = #"{"name":"\#(second ? "second" : "first")","description":"A fixture read","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}"#
                return second ? #"{"tools":[\#(tool)]}"# : #"{"tools":[\#(tool)],"nextCursor":"second-page"}"#
            case "tools/call":
                calls.withLock { $0 += 1 }
                return #"{"content":[{"type":"text","text":"remote fixture evidence"}]}"#
            default: return nil
            }
        }, custom: { request, response in
            if !(request.header("Accept") ?? "").contains("application/json") || !(request.header("Accept") ?? "").contains("text/event-stream") {
                problems.withLock { $0.append("missing Accept types") }
            }
            return false
        })
        let store = try store()
        defer { store.close() }
        let pool = MCPConnectionPool()
        let host = try AtlasMCPHost(configs: [AtlasMCPServerConfig(id: "remote", name: "Fixture", transport: "http", url: endpoint.url,
                                                                   headers: ["Authorization": "Bearer fixture"], enabled: true)],
                                    store: store, pool: pool, launcher: nil)
        let connection = try await host.connect("remote")
        #expect(connection.tools.count == 2 && endpoint.count("notifications/initialized") == 1)
        let callArgs: [String: AtlasJSON] = ["operation": .string("call"), "server": .string("remote"), "name": .string("first"), "argumentsJSON": .string("{}")]
        await #expect(throws: AtlasRuntimeError.self) { try await host.execute(callArgs) }
        #expect(calls.withLock { $0 } == 0)
        let selection: [String: AtlasJSON] = ["operation": .string("schema"), "server": .string("remote"), "name": .string("first")]
        await #expect(throws: AtlasRuntimeError.self) { try await host.execute(selection) }
        #expect(host.selectedTool() == nil)
        connection.config.approve("first", connection.tools["first"]!.digest, host: host)
        let receiptText = try await host.execute(selection)
        #expect(calls.withLock { $0 } == 0)
        let receipt = decoded(receiptText)
        #expect(receipt["status"]?.stringValue == "ready_to_call" && receipt["server"]?.stringValue == "remote" && receipt["name"]?.stringValue == "first"
                && receipt["executed"] == .bool(false))
        let definitionID = receipt["parameterDefinitionID"]?.stringValue ?? ""
        let stored = try #require(store.entries[definitionID])
        #expect(stored.kind == "schema" && stored.source == "mcp:remote:first:schema" && stored.viewed == 0 && stored.sha256.utf8.count == 64)
        for omitted in ["additionalProperties", #""payload""#, #""sha256""#, #""chunks""#, #""coverage""#, #""evidence""#] {
            #expect(!receiptText.contains(omitted), "schema bookkeeping leaked: \(omitted)")
        }
        let selected = try #require(host.selectedTool())
        #expect(selected.server == "remote" && selected.name == "first"
                && selected.inputSchemaJSON == jsonText(.object(host.connections["remote"]!.tools["first"]!.schema!)))
        let inspection = decoded(try store.execute(["operation": .string("read"), "id": .string(definitionID), "offset": .number(0)]))
        #expect(inspection["text"]?.stringValue == selected.inputSchemaJSON && inspection["completeText"] == .bool(true)
                && inspection["payload"]?["kind"]?.stringValue == "schema" && (inspection["coverage"]?.stringValue ?? "").contains("Schema metadata only"))
        let result = try await host.execute(callArgs)
        #expect(result.contains("remote fixture evidence") && calls.withLock { $0 } == 1)
        let execution = decoded(result)
        let evidence = execution["evidence"]?.dictionary ?? [:]
        #expect(execution["isError"] == .bool(false) && evidence["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "remote fixture evidence"
                && evidence["completeText"] == .bool(true) && evidence["payload"]?["kind"]?.stringValue == "text"
                && evidence["payload"]?["source"]?.stringValue == "mcp:remote:first" && evidence["payload"]?["id"]?.stringValue != definitionID)
        // The pooled session survives the run; shutting the pool down ends it exactly once.
        await host.close()
        let pooled = await pool.count
        #expect(endpoint.count("DELETE") == 0 && pooled == 1)
        await pool.closeAll()
        await pool.closeAll()
        #expect(endpoint.count("DELETE") == 1, "owned remote session was not terminated exactly once")
        #expect(problems.withLock { $0 }.isEmpty, "\(problems.withLock { $0 })")
    }

    @Test func sseRefusesHostRequestsAndRevokesCatalog() async throws {
        let rejected = Mutex(0)
        let server = LoopbackHTTPServer { request, response in
            let fields = request.json
            if let error = fields["error"]?.dictionary {
                if error["code"]?.doubleValue == -32601 { rejected.withLock { $0 += 1 } }
                response.respond(202)
                return
            }
            response.stream(headers: [("Content-Type", "text/event-stream")])
            response.write(": keepalive\n\nid: prime\ndata:\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"sample\",\"method\":\"sampling/createMessage\"}\n\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n")
            response.write("data: {\"jsonrpc\":\"2.0\",\ndata: \"id\":\(request.rawID!),\"result\":{\"value\":9007199254740993}}\n\n")
        }
        let session = MCPSession(client: try MCPHTTPClient(url: server.url, headers: [:]))
        let raw = try await session.rpc("fixture/read", .object([:]))
        #expect(String(decoding: raw, as: UTF8.self).contains("9007199254740993") && session.catalogChanged && rejected.withLock { $0 } == 1)
        await session.client.close()
    }

    @Test(arguments: [(401, "mcp_authentication_required"), (403, "mcp_http_forbidden"), (404, "mcp_http_endpoint_unavailable"),
                      (429, "mcp_http_rate_limited"), (307, "mcp_http_redirect_refused"), (500, "mcp_http_status_error")])
    func errorsDoNotLeakOrFollowRedirects(status: Int, want: String) async throws {
        let destinationCalls = Mutex(0)
        let destination = LoopbackHTTPServer { _, response in destinationCalls.withLock { $0 += 1 }; response.respond(200) }
        let server = LoopbackHTTPServer { _, response in
            response.respond(status, headers: [("Location", destination.url)], body: Array("SECRET_RESPONSE_BODY".utf8))
        }
        let client = try MCPHTTPClient(url: server.url, headers: ["Authorization": "Bearer fixture"])
        await #expect(throws: AtlasRuntimeError(want)) {
            _ = try await client.post(Array(#"{"method":"initialize"}"#.utf8), expectsResponse: true, initialize: true)
        }
        await client.close()
        #expect(destinationCalls.withLock { $0 } == 0, "followed redirect with credentials")
    }

    @Test(arguments: [
        ("wrong-id", "application/json", #"{"jsonrpc":"2.0","id":"other","result":{}}"#, 0, "mcp_response_mismatch"),
        ("batch", "application/json", #"[{"jsonrpc":"2.0","id":1,"result":{}}]"#, 0, "mcp_invalid_frame"),
        ("html", "text/html", "<html>auth</html>", 0, "mcp_http_unsupported_content_type"),
        ("length", "application/json", "", atlasMaxMCPFrameBytes + 1, "mcp_http_response_limit"),
        ("stream-limit", "text/event-stream", "data: " + String(repeating: "x", count: atlasMaxMCPFrameBytes) + "\n\n", 0, "mcp_http_response_limit"),
        ("truncated-stream", "text/event-stream", "data: {}", 0, "mcp_http_stream_ended_before_response"),
        ("notifications", "text/event-stream", String(repeating: "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n", count: 65), 0, "mcp_notification_limit"),
    ])
    func boundsFramesAndChecksIDs(name: String, contentType: String, body: String, length: Int, want: String) async throws {
        let server = LoopbackHTTPServer { _, response in
            if length != 0 {
                response.stream(headers: [("Content-Type", contentType), ("Content-Length", String(length))])
            } else {
                response.stream(headers: [("Content-Type", contentType)])
                response.write(body)
            }
        }
        let session = MCPSession(client: try MCPHTTPClient(url: server.url, headers: [:]))
        await #expect(throws: AtlasRuntimeError(want), "\(name)") { _ = try await session.rpc("fixture/read", .object([:])) }
        await session.client.close()
    }

    @Test func cancellationAndProtocolValidation() async throws {
        let cancelled = Mutex(false)
        let server = LoopbackHTTPServer { _, response in
            response.stream(headers: [("Content-Type", "text/event-stream")])
            if response.waitForDisconnect(timeout: 5) { cancelled.withLock { $0 = true } }
        }
        let session = MCPSession(client: try MCPHTTPClient(url: server.url, headers: [:]))
        let started = ContinuousClock.now
        await #expect(throws: AtlasRuntimeError("mcp_http_timeout")) { _ = try await session.rpc("fixture/read", .object([:]), timeout: 0.05) }
        #expect(ContinuousClock.now - started < .seconds(1), "HTTP cancellation did not finish promptly")
        for _ in 0..<100 where !cancelled.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled.withLock { $0 }, "HTTP cancellation did not reach server")
        await session.client.close()
        let client = try MCPHTTPClient(url: "https://example.com/mcp", headers: [:])
        #expect(throws: AtlasRuntimeError("unsupported_mcp_protocol")) {
            try client.finishedForTest(initialize: true, result: Array(#"{"protocolVersion":"evil"}"#.utf8))
        }
    }

    @Test func expiredSessionReinitializesWithoutReplayingCall() async throws {
        let initialized = Mutex(0), calls = Mutex(0)
        let problems = Mutex<[String]>([])
        let server = LoopbackHTTPServer { request, response in
            if request.method == "DELETE" { response.respond(204); return }
            let fields = request.json
            let method = fields["method"]?.stringValue ?? ""
            if method == "notifications/initialized" { response.respond(202); return }
            if method != "initialize" { calls.withLock { $0 += 1 }; response.respond(404); return }
            let count = initialized.withLock { $0 += 1; return $0 }
            if request.header("Mcp-Session-Id") != nil { problems.withLock { $0.append("new initialize reused expired session") } }
            response.json(#"{"jsonrpc":"2.0","id":\#(request.rawID!),"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}"#,
                          headers: [("Mcp-Session-Id", "session-\(count)")])
        }
        let store = try store()
        defer { store.close() }
        let pool = MCPConnectionPool()
        let host = try AtlasMCPHost(configs: [AtlasMCPServerConfig(id: "remote", transport: "http", url: server.url, enabled: true)],
                                    store: store, pool: pool, launcher: nil)
        let first = try await host.connect("remote")
        await #expect(throws: AtlasRuntimeError("mcp_http_endpoint_unavailable")) {
            _ = try await first.connection.session.rpc("tools/call", .object(["name": .string("fixture")]))
        }
        let next = try await host.connect("remote")
        #expect(next !== first && next.connection !== first.connection && initialized.withLock { $0 } == 2 && calls.withLock { $0 } == 1,
                "session was not renewed cleanly, or failed call was replayed")
        await host.close()
        await pool.closeAll()
        #expect(problems.withLock { $0 }.isEmpty)
    }
}

extension AtlasMCPServerConfig {
    /// Approve a tool for this run (the Go tests append to config.AllowedTools).
    func approve(_ name: String, _ digest: String, host: AtlasMCPHost) {
        guard let connection = host.connections[id] else { return }
        connection.approve(AtlasMCPApproval(name: name, digest: digest))
    }
}
