// Ports of the local-process tests in mcp_test.go (and the process-lifetime
// half of the broker test) against tests/fixtures/mcp_server.py.
import Foundation
import Testing
@testable import OmniFlowApp

@Suite(.serialized) struct AtlasStdioTests {
    static let python = "/opt/homebrew/bin/python3"
    static let script = Fixtures.repository.appendingPathComponent("tests/fixtures/mcp_server.py").path

    final class Fixture {
        let store: AtlasPayloadStore
        let host: AtlasMCPHost
        let connection: AtlasMCPRunConnection
        init(store: AtlasPayloadStore, host: AtlasMCPHost, connection: AtlasMCPRunConnection) {
            self.store = store; self.host = host; self.connection = connection
        }
        var client: AtlasStdioClient { connection.connection.session.client as! AtlasStdioClient }
        func approve(_ name: String) { connection.approve(AtlasMCPApproval(name: name, digest: connection.tools[name]!.digest)) }
        func close() async { await host.close(); store.close() }
    }

    func fixture() async throws -> Fixture {
        let store = try AtlasPayloadStore(directory: nil)
        let host = try AtlasMCPHost(configs: [AtlasMCPServerConfig(id: "fixture", name: "Fixture", command: Self.python, arguments: [Self.script],
                                                                   enabled: true, allowResources: true)],
                                    store: store, pool: MCPConnectionPool(), launcher: AtlasStdioTransport.launcher)
        let connection = try await host.connect("fixture")
        return Fixture(store: store, host: host, connection: connection)
    }

    func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await fixture()
        do { try await body(fixture) } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func localPaginationApprovalAndLargeResult() async throws {
        try await withFixture { fixture in
            let host = fixture.host
            #expect(fixture.connection.tools.count == 3, "catalog pagination lost tools")
            var args: [String: AtlasJSON] = ["operation": .string("call"), "server": .string("fixture"), "name": .string("read_archive"), "argumentsJSON": .string("{}")]
            await #expect(throws: AtlasRuntimeError.self, "unapproved tool ran") { try await host.execute(args) }
            fixture.approve("read_archive")
            let original = fixture.connection.tools["read_archive"]!
            fixture.connection.tools["read_archive"] = MCPCatalogTool(name: original.name, description: original.description,
                                                                      digest: String(repeating: "0", count: 64), supported: true, schema: original.schema)
            await #expect(throws: AtlasRuntimeError.self, "changed definition retained permission") { try await host.execute(args) }
            fixture.connection.tools["read_archive"] = original
            args["argumentsJSON"] = .string(#"{"extra":"not approved"}"#)
            await #expect(throws: AtlasRuntimeError.self, "unexpected argument accepted") { try await host.execute(args) }
            args["argumentsJSON"] = .string("{}")
            let result = try await host.execute(args)
            #expect(result.utf8.count <= 7000 && !result.contains("release-comet-73"), "large result bypassed preview limit")
            let entry = decoded(result)["evidence"]?["payload"]?.dictionary ?? [:]
            #expect((entry["bytes"]?.doubleValue ?? 0) >= 1_000_000 && (entry["chunks"]?.doubleValue ?? 0) >= 500 && entry["suspicious"] == .bool(true))
            let id = entry["id"]?.stringValue ?? ""
            let search = try fixture.store.execute(["operation": .string("search"), "id": .string(id), "query": .string("release-comet-73")])
            #expect(search.contains("release-comet-73") && search.contains(#""scannedEndByte""#), "tail evidence inaccessible")
            #expect(throws: AtlasRuntimeError.self) { try fixture.store.data("../../secret") }
            fixture.store.question = "Search the returned archive for the phrase release label and tell me that label."
            let preview = fixture.store.preview(fixture.store.entries[id]!)
            #expect(preview.contains("release-comet-73") && preview.contains(#""method":"local keyword relevance""#))
        }
    }

    @Test func processBoundariesAndHostRequests() async throws {
        try await withFixture { fixture in
            fixture.approve("probe_boundaries")
            let outsideDirectory = ScratchDirectory()
            let outside = outsideDirectory.file("forbidden.txt")
            let arguments = jsonText(.object(["outside": .string(outside)]))
            let result = try await fixture.host.execute(["operation": .string("call"), "server": .string("fixture"), "name": .string("probe_boundaries"),
                                                         "argumentsJSON": .string(arguments)])
            let text = decoded(result)["evidence"]?["text"]?.stringValue ?? ""
            let checks = decoded(text)
            #expect(checks["writeBlocked"] == .bool(true) && checks["networkBlocked"] == .bool(true) && checks["temporaryWriteAllowed"] == .bool(true), "sandbox failed: \(text)")
            for key in checks["environmentKeys"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                #expect(!key.contains("TOKEN") && !key.contains("KEY"), "secret environment inherited: \(key)")
            }
            #expect(!FileManager.default.fileExists(atPath: outside), "server wrote outside work folder")
            // The run's evidence store (the work directory's parent) is unreadable.
            #expect(AtlasStdioClient.profile(workdir: "/private/var/x/server-0").contains(#"(deny file-read* (subpath "/private/var/x"))"#))
            let response = try await fixture.connection.connection.session.rpc("fixture/host-request", .object([:]))
            #expect(String(decoding: response, as: UTF8.self).contains("true"), "server-initiated sampling was not refused")
        }
    }

    @Test func resourcesAndCancellation() async throws {
        try await withFixture { fixture in
            let host = fixture.host
            await #expect(throws: AtlasRuntimeError.self, "undiscovered resource accepted") {
                try await host.execute(["operation": .string("readResource"), "server": .string("fixture"), "name": .string("fixture://not-listed")])
            }
            _ = try await host.execute(["operation": .string("resources"), "server": .string("fixture")])
            let result = try await host.execute(["operation": .string("readResource"), "server": .string("fixture"), "name": .string("fixture://compressed")])
            let attachments = decoded(result)["attachments"]?.arrayValue ?? []
            #expect(attachments.count == 1, "decoded resource missing")
            let (data, entry) = try fixture.store.data(attachments.first?["id"]?.stringValue ?? "")
            #expect(entry.text && String(decoding: data, as: UTF8.self).contains("紅熊猫"), "base64/gzip decoding failed")
            fixture.approve("slow")
            let pid = fixture.client.processIdentifier
            // A 150 ms deadline cancels the in-flight call (Go: context.WithTimeout).
            let session = fixture.connection.connection.session
            await #expect(throws: AtlasRuntimeError.self) {
                try await atlasWithDeadline(0.15) { try await session.callTool("slow", arguments: .object([:])) }
            }
            for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(kill(pid, 0) != 0 && errno == ESRCH, "cancelled MCP process survived")
        }
    }

    @Test func structuredContentPreservesNumericIdentifiers() async throws {
        try await withFixture { fixture in
            let result = try fixture.host.ingest(fixture.connection, source: "fixture",
                                                 raw: Array(#"{"content":[],"structuredContent":{"id":9007199254740993}}"#.utf8), isResource: false)
            #expect(result.contains("9007199254740993"), "structured-content identifier was rounded")
        }
    }

    @Test func catalogChangeRevokesRunGrants() async throws {
        try await withFixture { fixture in
            fixture.approve("read_archive")
            _ = try await fixture.connection.connection.session.rpc("fixture/catalog-changed", .object([:]))
            await #expect(throws: AtlasRuntimeError("mcp_tool_not_approved_or_definition_changed")) {
                try await fixture.host.execute(["operation": .string("call"), "server": .string("fixture"), "name": .string("read_archive"), "argumentsJSON": .string("{}")])
            }
        }
    }

    @Test func closingKillsTheServerProcessGroup() async throws {
        let fixture = try await fixture()
        let raw = try await fixture.connection.connection.session.rpc("fixture/process", .object([:]))
        let pid = Int32(decoded(String(decoding: raw, as: UTF8.self))["pid"]?.doubleValue ?? 0)
        #expect(pid > 0, "server did not start")
        await fixture.close()
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) != 0 && errno == ESRCH, "MCP child survived transport close")
        #expect(!FileManager.default.fileExists(atPath: fixture.store.directory), "per-run scratch files survived")
    }

    @Test func localServerWithoutLauncherFailsTheRun() async throws {
        var start = startFrame(servers: [AtlasMCPServerConfig(id: "s1", name: "Local", command: Self.python, arguments: [Self.script], enabled: true)])
        start.requestID = "test-request"
        let client = FrameClient(start, launcher: nil)
        guard case let .failure(error) = await client.result else { Issue.record("run started without a launcher"); return }
        #expect((error as? AtlasRuntimeError)?.code == "mcp_launcher_unavailable")
    }
}
