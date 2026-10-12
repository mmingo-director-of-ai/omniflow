import Foundation
import Darwin
import FoundationModels

enum RemoteMCPIntegrationChecks {
    @MainActor
    static func run(executable: URL, identity: AtlasBuildIdentity, folder: URL) async throws {
        try configurationChecks(folder: folder)
        let mac = MacContextTool()
        let files = LocalFilesTool()
        let definitions = try [
            AtlasToolDefinition(name: mac.name, description: mac.description,
                inputSchemaJSON: String(decoding: JSONEncoder().encode(MacContextTool.Arguments.generationSchema), as: UTF8.self)),
            AtlasToolDefinition(name: files.name, description: files.description,
                inputSchemaJSON: String(decoding: JSONEncoder().encode(LocalFilesTool.Arguments.generationSchema), as: UTF8.self)),
        ]

        // Remote-only connections must work without the stdio process broker.
        let restoreLauncher = LocalMCPLauncher.shared.endpoint != nil
        LocalMCPLauncher.shared.stop()
        defer {
            if restoreLauncher { precondition(LocalMCPLauncher.shared.start(executable: executable)) }
        }
        precondition(LocalMCPLauncher.shared.endpoint == nil)

        let fixture = Process()
        let output = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        fixture.arguments = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tests/fixtures/mcp_http_server.py").path]
        fixture.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
        fixture.currentDirectoryURL = folder
        fixture.standardInput = FileHandle.nullDevice
        fixture.standardOutput = output
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate() }
            fixture.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        try output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let endpoint = try await Task.detached { try readFixtureEndpoint(descriptor: descriptor) }.value
        var server = MCPServerConfiguration(name: "HTTP integration fixture", transport: "http", url: endpoint,
            headers: ["Authorization": "Bearer fixture-only"], enabled: true)
        let catalog = try await AtlasBridge.catalog(server: server, executable: executable, identity: identity)
        precondition(catalog.tools.count == 1 && catalog.hasResources)
        let tool = catalog.tools[0]
        precondition(tool.name == "read_release_label" && tool.supported)
        server.allowedTools = [.init(name: tool.name, digest: tool.digest)]
        let call = MCPArguments(operation: .call, server: server.id, name: tool.name,
            argumentsJSON: "{}", query: nil, offset: nil, cursor: nil)
        let result = try await AtlasBridge().run(prompt: "Read the fixture release label.", tools: definitions, servers: [server],
            executable: executable, identity: identity, onModel: { frame in
                let exposed = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
                precondition(!exposed.contains("fixture-only") && !exposed.contains("Authorization"), "Credentials entered the model frame")
                if frame.step == 1 {
                    return AtlasFrame(type: "reply", toolCalls: [.init(name: "mcp", argumentsJSON: call.generatedContent.jsonString)])
                }
                precondition(frame.messages?.last?.content.contains("aurora-42") == true, "HTTP tool evidence was lost")
                return AtlasFrame(type: "reply", content: "The label is aurora-42.")
            }, onTool: { _ in preconditionFailure("Remote MCP must execute through Atlas, not a native Swift tool") })
        precondition(result.text.contains("aurora-42") && result.steps == 2 && result.toolCount == 1)
        precondition(LocalMCPLauncher.shared.endpoint == nil, "Remote requests unexpectedly launched the stdio broker")

        var unauthorized = server
        unauthorized.headers = [:]
        do {
            _ = try await AtlasBridge.catalog(server: unauthorized, executable: executable, identity: identity)
            preconditionFailure("Unauthorized remote catalog was accepted")
        } catch AtlasBridgeError.mcpAuthentication { }
        report("Swift → Atlas → authenticated HTTP MCP without a stdio broker; credentials excluded from model frames; 401 mapping: passed")

        try await resourceChecks(server: server, definitions: definitions, executable: executable,
            identity: identity, folder: folder)

        fixture.terminate()
        fixture.waitUntilExit()
        var unavailable = server
        unavailable.headers = [:]
        unavailable.authorizationError = "mcp_authentication_required"
        let nativeAnswer = try await AtlasBridge().run(prompt: "Answer directly without remote tools.", tools: definitions, servers: [unavailable],
            executable: executable, identity: identity, onModel: { _ in AtlasFrame(type: "reply", content: "Native answers remain available.") },
            onTool: { _ in preconditionFailure("A direct answer must not call tools") })
        precondition(nativeAnswer.toolCount == 0 && nativeAnswer.text == "Native answers remain available.")
        let denied = try await AtlasBridge().run(prompt: "Try the unavailable remote tool.", tools: definitions, servers: [unavailable],
            executable: executable, identity: identity, onModel: { frame in
                if frame.step == 1 {
                    return AtlasFrame(type: "reply", toolCalls: [.init(name: "mcp", argumentsJSON: call.generatedContent.jsonString)])
                }
                // The fixture is stopped, so a network attempt would return a connection error instead.
                precondition(frame.previousError == "mcp_authentication_required")
                precondition(frame.messages?.last?.content.contains("mcp_authentication_required") == true)
                return AtlasFrame(type: "reply", content: "Reconnect the remote account.")
            }, onTool: { _ in preconditionFailure("Unavailable MCP authentication must fail in the helper") })
        precondition(denied.toolCount == 1 && denied.steps == 2)
        report("An unavailable remote sign-in preserves native answers and rejects remote calls locally before network access: passed")
    }

    @MainActor
    private static func resourceChecks(server: MCPServerConfiguration, definitions: [AtlasToolDefinition],
        executable: URL, identity: AtlasBuildIdentity, folder: URL) async throws {
        var allowed = server
        allowed.allowResources = true
        let firstURI = "fixture://http/first"
        let secondURI = "fixture://http/second"
        var cursor: String?
        let run = try await AtlasBridge().run(prompt: "Read both pages of the remote resource fixture.",
            tools: definitions, servers: [allowed], executable: executable, identity: identity, onModel: { frame in
                let exposed = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
                precondition(!exposed.contains("fixture-only") && !exposed.contains("Authorization"),
                    "Resource discovery exposed credentials to the model")
                switch frame.step {
                case 1:
                    return resourceCall(.readResource, server: server.id, uri: firstURI)
                case 2:
                    precondition(frame.previousError == "mcp_resource_not_approved_or_not_discovered",
                        "A valid but undiscovered remote URI was accepted")
                    return resourceCall(.resources, server: server.id)
                case 3:
                    precondition(frame.previousError == nil)
                    let page = try resourcePage(frame)
                    precondition(page.uris == [firstURI], "The first remote resource page was lost")
                    cursor = page.cursor
                    precondition(cursor == "resource-page-2", "Remote resource pagination lost its opaque cursor")
                    return resourceCall(.readResource, server: server.id, uri: secondURI)
                case 4:
                    precondition(frame.previousError == "mcp_resource_not_approved_or_not_discovered",
                        "A URI from an unread resource page was accepted")
                    return resourceCall(.resources, server: server.id, cursor: cursor)
                case 5:
                    precondition(frame.previousError == nil)
                    let page = try resourcePage(frame)
                    precondition(page.uris == [secondURI] && page.cursor.isEmpty,
                        "The final resource page was lost or pagination did not terminate")
                    return resourceCall(.readResource, server: server.id, uri: secondURI)
                case 6:
                    try verifyResource(frame, server: server.id, uri: secondURI,
                        text: "Second remote resource: the final release is comet-73.")
                    return resourceCall(.readResource, server: server.id, uri: firstURI)
                case 7:
                    try verifyResource(frame, server: server.id, uri: firstURI,
                        text: "First remote resource: café 紅熊猫.")
                    return AtlasFrame(type: "reply", content: "Both remote resources were read.")
                default:
                    preconditionFailure("Unexpected remote resource continuation")
                }
            }, onTool: { _ in preconditionFailure("HTTP resources must execute inside Atlas") })
        precondition(run.steps == 7 && run.toolCount == 6)

        // Discovery belongs to one helper run; another run must discover the
        // same URI again. The persisted resource grant does not preapprove URIs.
        for operation in [MCPArguments.Operation.readResource, .resources] {
            let enabled = operation == .readResource
            let denied = try await AtlasBridge().run(prompt: "Check remote resource boundaries.", tools: definitions,
                servers: [enabled ? allowed : server], executable: executable, identity: identity, onModel: { frame in
                    if frame.step == 1 { return resourceCall(operation, server: server.id, uri: firstURI) }
                    let expected = enabled ? "mcp_resource_not_approved_or_not_discovered" : "mcp_resources_not_enabled"
                    precondition(frame.previousError == expected,
                        enabled ? "Remote resource discovery leaked across helper runs" : "Disabled resources reached the server")
                    return AtlasFrame(type: "reply", content: "Resource access was correctly rejected.")
                }, onTool: { _ in preconditionFailure("Remote resource denial must remain in Atlas") })
            precondition(denied.steps == 2 && denied.toolCount == 1)
        }

        let audit = try String(contentsOf: folder.appendingPathComponent("http-resource-requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try object(String($0)) }
        precondition(audit.count == 4, "A denied resource request reached the HTTP endpoint")
        precondition(audit.map { $0["method"] as! String } == ["resources/list", "resources/list", "resources/read", "resources/read"])
        precondition((audit[0]["params"] as! [String: Any])["cursor"] == nil)
        precondition((audit[1]["params"] as! [String: Any])["cursor"] as? String == "resource-page-2")
        precondition((audit[2]["params"] as! [String: Any])["uri"] as? String == secondURI)
        precondition((audit[3]["params"] as! [String: Any])["uri"] as? String == firstURI)
        precondition(LocalMCPLauncher.shared.endpoint == nil, "HTTP resources started the stdio broker")
        report("HTTP resources: cursor pagination, full Unicode text/provenance, same-run URI discovery, fresh-run isolation, and disabled-resource rejection before resource requests: passed")
    }

    private static func resourceCall(_ operation: MCPArguments.Operation, server: String, uri: String = "", cursor: String? = nil) -> AtlasFrame {
        let arguments = MCPArguments(operation: operation, server: server, name: uri,
            argumentsJSON: "{}", query: nil, offset: nil, cursor: cursor)
        return AtlasFrame(type: "reply", toolCalls: [.init(name: "mcp", argumentsJSON: arguments.generatedContent.jsonString)])
    }

    private static func resourcePage(_ frame: AtlasFrame) throws -> (uris: [String], cursor: String) {
        let envelope = try object(frame.messages!.last!.content)
        precondition(envelope["trust"] as? String == "untrusted_data")
        let page = envelope["page"] as! [String: Any]
        precondition(page["completeText"] as? Bool == true, "A small resource page was truncated")
        let content = try object(page["text"] as! String)
        let resources = content["resources"] as! [[String: Any]]
        return (resources.map { $0["uri"] as! String }, envelope["nextCursor"] as! String)
    }

    private static func verifyResource(_ frame: AtlasFrame, server: String, uri: String, text: String) throws {
        precondition(frame.previousError == nil, "A discovered resource could not be read")
        let envelope = try object(frame.messages!.last!.content)
        let evidence = envelope["evidence"] as! [String: Any]
        let payload = evidence["payload"] as! [String: Any]
        precondition(envelope["trust"] as? String == "untrusted_data" && envelope["isError"] as? Bool == false)
        precondition(evidence["text"] as? String == text + "\n" && evidence["completeText"] as? Bool == true,
            "The remote resource lost text or incorrectly reported partial coverage")
        precondition(payload["source"] as? String == "mcp:\(server):resource:\(uri)")
        precondition(payload["bytes"] as? Int == (text + "\n").utf8.count && (payload["sha256"] as? String)?.count == 64)
    }

    private static func object(_ content: String) throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(with: Data(content.utf8), options: [.fragmentsAllowed])
        if let encoded = value as? String { value = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) }
        return value as! [String: Any]
    }

    @MainActor
    private static func configurationChecks(folder: URL) throws {
        let legacyJSON = Data(#"{"id":"legacy-stdio","name":"Legacy","command":"/usr/bin/true","arguments":[],"enabled":false,"allowedTools":[],"allowResources":false}"#.utf8)
        let legacy = try JSONDecoder().decode(MCPServerConfiguration.self, from: legacyJSON)
        precondition(legacy.transport == "stdio" && legacy.url.isEmpty && !legacy.useOAuth)
        try LocalMCPConfiguration.validate(legacy)

        var remote = MCPServerConfiguration(name: "Remote config fixture", transport: "http",
            url: "https://tools.example.com/mcp", useOAuth: true,
            headers: ["Authorization": "Bearer configuration-fixture-only"])
        remote.authorizationError = "fixture-transient-error"
        let file = folder.appendingPathComponent("remote-config-fixture.json")
        let configuration = LocalMCPConfiguration(file: file)
        try configuration.save(remote)
        let saved = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        precondition(!saved.contains("configuration-fixture-only") && !saved.contains("fixture-transient-error"))
        let reload = LocalMCPConfiguration(file: file)
        precondition(reload.error == nil && reload.servers.count == 1)
        precondition(reload.servers[0].headers.isEmpty && reload.servers[0].authorizationError == nil)
        precondition(reload.servers[0].useOAuth)
        let decodedRuntime = try JSONDecoder().decode(MCPServerConfiguration.self, from: JSONEncoder().encode(remote))
        precondition(decodedRuntime.headers.isEmpty && decodedRuntime.authorizationError == nil)
        for endpoint in ["http://tools.example.com/mcp", "https://user:password@tools.example.com/mcp", "https://tools.example.com/mcp#fragment"] {
            remote.url = endpoint
            do { try LocalMCPConfiguration.validate(remote); preconditionFailure("Unsafe remote endpoint accepted") }
            catch MCPConfigurationError.invalidEndpoint { }
        }
        report("Legacy MCP configuration and transient credential persistence: passed")
    }

    private static func readFixtureEndpoint(descriptor: Int32) throws -> String {
        let deadline = Date().addingTimeInterval(5)
        var bytes = Data()
        while Date() < deadline && bytes.count < 256 {
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let count = poll(&ready, 1, 100)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw FixtureFailure.startup }
            if count == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 256)
            let readCount = Darwin.read(descriptor, &buffer, buffer.count)
            guard readCount > 0 else { throw FixtureFailure.startup }
            bytes.append(contentsOf: buffer.prefix(readCount))
            if let newline = bytes.firstIndex(of: 10) {
                let endpoint = String(decoding: bytes[..<newline], as: UTF8.self)
                guard let parsed = URLComponents(string: endpoint), parsed.scheme == "http", parsed.host == "127.0.0.1",
                      parsed.path == "/mcp", parsed.port != nil else { throw FixtureFailure.startup }
                return endpoint
            }
        }
        throw FixtureFailure.startup
    }

    private enum FixtureFailure: Error { case startup }
    private static func report(_ message: String) {
        try! FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }
}
