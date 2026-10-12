import AppKit
import FoundationModels

@main
enum AtlasIntegrationTests {
    static func report(_ message: String) {
        try! FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }
    @MainActor static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let identity = try JSONDecoder().decode(AtlasBuildIdentity.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        UserDefaults.standard.setVolatileDomain(["localTelemetryEnabled": false, "ambientEnabled": false], forName: UserDefaults.argumentDomain)
        precondition(LocalMCPLauncher.shared.start(executable: executable))
        defer { LocalMCPLauncher.shared.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notchlee-atlas-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.txt")
        try Data("The release label is persimmon. There are three pending checks.".utf8).write(to: file)
        let mac = MacContextTool()
        let files = LocalFilesTool()
        let definitions = try [
            AtlasToolDefinition(name: mac.name, description: mac.description,
                inputSchemaJSON: String(decoding: JSONEncoder().encode(MacContextTool.Arguments.generationSchema), as: UTF8.self)),
            AtlasToolDefinition(name: files.name, description: files.description,
                inputSchemaJSON: String(decoding: JSONEncoder().encode(LocalFilesTool.Arguments.generationSchema), as: UTF8.self))
        ]
        let args = LocalFilesTool.Arguments(operation: .read, path: file.path, query: nil, offset: 0)
        var toolCalls = 0
        let bridge = AtlasBridge()
        report("Starting real Atlas/native tool integration")
        let result = try await bridge.run(prompt: "Read the local fixture.", tools: definitions, executable: executable, identity: identity,
            onModel: { frame in
                if frame.step == 1 {
                    return AtlasFrame(type: "reply", toolCalls: [.init(name: files.name, argumentsJSON: args.generatedContent.jsonString)])
                }
                precondition(frame.messages?.last?.content.contains("persimmon") == true, "Atlas lost the local tool result")
                return AtlasFrame(type: "reply", content: "The label is persimmon.")
            }, onTool: { frame in
                toolCalls += 1
                precondition(frame.tool == files.name)
                let arguments = try LocalFilesTool.Arguments(GeneratedContent(json: frame.argumentsJSON!))
                return AtlasFrame(type: "reply", content: try await files.call(arguments: arguments))
            })
        precondition(result.text.contains("persimmon") && result.steps == 2 && result.toolCount == 1 && toolCalls == 1)
        report("Real Atlas SDK → Swift file tool → Atlas continuation: passed")

        let plain = try await AtlasBridge().run(prompt: "Answer directly.", tools: definitions, executable: executable, identity: identity,
            onModel: { _ in AtlasFrame(type: "reply", content: "A direct local answer.") },
            onTool: { _ in preconditionFailure("Direct answer should not call a tool") })
        precondition(plain.steps == 1 && plain.toolCount == 0)
        report("Direct answers correctly complete with zero tool calls: passed")

        let cancellationBridge = AtlasBridge()
        let task = Task {
            try await cancellationBridge.run(prompt: "Cancel this run.", tools: definitions, executable: executable, identity: identity,
                onModel: { _ in
                    try await Task.sleep(for: .seconds(20))
                    return AtlasFrame(type: "reply", content: "Should not be delivered")
                }, onTool: { _ in preconditionFailure("No tool should execute") })
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled run returned an answer") }
        catch is CancellationError { }
        try await Task.sleep(for: .milliseconds(450))
        if let pid = cancellationBridge.processID { precondition(kill(pid, 0) == -1 && errno == ESRCH, "Cancelled helper survived") }
        report("Cancellation stops inference and removes the helper process: passed")

        do {
            _ = try await AtlasBridge().run(prompt: "Reject a stale helper.", tools: definitions, executable: executable,
                identity: AtlasBuildIdentity(version: "wrong", revision: "wrong"),
                onModel: { _ in preconditionFailure("Incompatible helper reached the model") },
                onTool: { _ in preconditionFailure("Incompatible helper reached a tool") })
            preconditionFailure("Incompatible Atlas helper accepted")
        } catch AtlasBridgeError.incompatible { }
        do {
            _ = try await AtlasBridge().run(prompt: "Fail closed.", tools: definitions, executable: nil, identity: identity,
                onModel: { _ in preconditionFailure("Missing helper reached the model") },
                onTool: { _ in preconditionFailure("Missing helper reached a tool") })
            preconditionFailure("Missing helper silently bypassed Atlas")
        } catch AtlasBridgeError.unavailable { }
        report("Missing and incompatible helpers fail without bypassing Atlas: passed")

        let timedBridge = AtlasBridge()
        do {
            _ = try await timedBridge.run(prompt: "Bound the wait.", tools: definitions, executable: executable, identity: identity, timeout: 0.1,
                onModel: { _ in
                    try await Task.sleep(for: .seconds(20))
                    return AtlasFrame(type: "reply", content: "Should not be delivered")
                }, onTool: { _ in preconditionFailure("Timed out run should not call a tool") })
            preconditionFailure("Deadline did not stop the run")
        } catch AtlasBridgeError.timedOut { }
        do {
            _ = try await AtlasBridge().run(prompt: "Handle a crashed helper.", tools: definitions,
                executable: URL(fileURLWithPath: "/usr/bin/false"), identity: identity,
                onModel: { _ in preconditionFailure("Crashed helper reached the model") },
                onTool: { _ in preconditionFailure("Crashed helper reached a tool") })
            preconditionFailure("Crashed helper was accepted")
        } catch AtlasBridgeError.failed { }
        report("Deadlines and helper crashes finish without hanging the assistant: passed")
        try await RemoteMCPIntegrationChecks.run(executable: executable, identity: identity, folder: folder)
        try await MCPOAuthChecks.run()
        try await AtlasAnswerContextChecks.run()
        try AssistantConversationChecks.run()
        try AtlasRetrievalChecks.run()
        try await AtlasMCPSelectionChecks.run()
        try AtlasMCPGenerationSchemaChecks.run()
        try AtlasMCPInitialRoutingChecks.run()
        try AtlasMCPOperationRoutingChecks.run()

        // A tool named read_archive must not be generated as a resource read.
        let wrongNamespace = try GeneratedContent(json: #"{"operation":"readResource","server":"s1","name":"read_archive"}"#)
        do {
            _ = try AtlasMCPToolDiscoveryArguments(wrongNamespace)
            preconditionFailure("Resource operations leaked into the tool-selection schema")
        } catch { }
        let resourceProposal = AtlasToolProposal()
        let resourceAdapter = AtlasMCPResourceTool(proposal: resourceProposal)
        do {
            _ = try await resourceAdapter.call(arguments: .init(operation: .read, server: "s1", uri: "resource://fixture/archive", cursor: nil))
            preconditionFailure("A model proposal must stop before execution")
        } catch { }
        let proposedResource = await resourceProposal.call
        let resourceFields = try JSONSerialization.jsonObject(with: Data(proposedResource!.argumentsJSON.utf8)) as! [String: String]
        precondition(proposedResource?.name == "mcp" && resourceFields["operation"] == "readResource" && resourceFields["name"] == "resource://fixture/archive")
        report("Model tool-selection and resource-URI schemas remain separate; proposals still execute through Atlas: passed")

        let fixtureScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tests/fixtures/mcp_server.py")
        var fixtureServer = MCPServerConfiguration(name: "Test archive", command: "/opt/homebrew/bin/python3",
            arguments: [fixtureScript.path], enabled: true)
        let catalog = try await AtlasBridge.catalog(server: fixtureServer, executable: executable, identity: identity)
        precondition(catalog.tools.count == 3 && catalog.hasResources, "MCP discovery lost a catalog page")
        let archiveTool = catalog.tools.first { $0.name == "read_archive" }!
        precondition(archiveTool.supported)
        fixtureServer.allowedTools = [.init(name: archiveTool.name, digest: archiveTool.digest)]
        if CommandLine.arguments.contains("--memory-assistant-only") {
            var small = fixtureServer; small.arguments.append("small-analysis")
            try await AtlasTaskMemoryChecks.runAssistant(executable: executable, identity: identity, server: small)
            return
        }
        let probeTool = catalog.tools.first { $0.name == "probe_boundaries" }!
        var probeServer = fixtureServer
        probeServer.allowedTools = [.init(name: probeTool.name, digest: probeTool.digest)]
        let outside = folder.appendingPathComponent("forbidden-server-write.txt")
        let probeJSON = String(decoding: try JSONEncoder().encode(["outside": outside.path]), as: UTF8.self)
        let probeArgs = MCPArguments(operation: .call, server: probeServer.id, name: probeTool.name, argumentsJSON: probeJSON, query: nil, offset: nil, cursor: nil)
        _ = try await AtlasBridge().run(prompt: "Verify the local MCP sandbox.", tools: definitions, servers: [probeServer],
            executable: executable, identity: identity, onModel: { frame in
                if frame.step == 1 { return AtlasFrame(type: "reply", toolCalls: [.init(name: "mcp", argumentsJSON: probeArgs.generatedContent.jsonString)]) }
                let envelope = try toolObject(frame.messages!.last!.content)
                let evidence = envelope["evidence"] as! [String: Any]
                let checks = try toolObject(evidence["text"] as! String)
                precondition(checks["writeBlocked"] as? Bool == true && checks["networkBlocked"] as? Bool == true)
                precondition(checks["temporaryWriteAllowed"] as? Bool == true)
                return AtlasFrame(type: "reply", content: "Sandbox restrictions verified.")
            }, onTool: { _ in preconditionFailure("Probe must execute inside the MCP sandbox") })
        precondition(!FileManager.default.fileExists(atPath: outside.path))
        report("Authenticated local launcher → MCP IP/write restrictions: passed")
        let call = MCPArguments(operation: .call, server: fixtureServer.id, name: "read_archive", argumentsJSON: "{}", query: nil, offset: nil, cursor: nil)
        var payloadID = ""
        let large = try await AtlasBridge().run(prompt: "Find the archive release label.", tools: definitions,
            servers: [fixtureServer], executable: executable, identity: identity, onModel: { frame in
                if frame.step == 1 {
                    return AtlasFrame(type: "reply", toolCalls: [.init(name: "mcp", argumentsJSON: call.generatedContent.jsonString)])
                }
                let content = frame.messages!.last!.content
                if frame.step == 2 {
                    let result = try toolObject(content)
                    let evidence = result["evidence"] as! [String: Any]
                    let payload = evidence["payload"] as! [String: Any]
                    precondition((payload["bytes"] as! Int) > 1_000_000)
                    precondition(payload["suspicious"] as? Bool == true)
                    precondition(!content.contains("release-comet-73"), "The result was not bounded to a preview")
                    payloadID = payload["id"] as! String
                    let search = PayloadArguments(operation: .search, id: payloadID, offset: 0, query: "release label")
                    return AtlasFrame(type: "reply", toolCalls: [.init(name: "payload", argumentsJSON: search.generatedContent.jsonString)])
                }
                precondition(content.contains("release-comet-73"), "Large payload tail was lost")
                return AtlasFrame(type: "reply", content: "The label is release-comet-73.")
            }, onTool: { _ in preconditionFailure("MCP data should stay in the helper payload store") })
        precondition(large.steps == 3 && large.toolCount == 2 && !payloadID.isEmpty)
        report("Local MCP catalog pagination → approved tool → multi-megabyte storage → tail search: passed")
        try await AssistantMemoryChecks.run(executable: executable, identity: identity, definitions: definitions,
            server: fixtureServer, live: CommandLine.arguments.contains("--live") || CommandLine.arguments.contains("--durable-live"))
        try await AtlasTaskMemoryChecks.run(executable: executable, identity: identity, definitions: definitions,
            server: fixtureServer, live: CommandLine.arguments.contains("--live") || CommandLine.arguments.contains("--memory-live"))

        let window = AtlasContextWindow()
        let pinned = AtlasMessage(role: "user", content: "PINNED_USER_REQUEST")
        var history = [pinned]
        for index in 1...12 {
            history.append(.init(role: "assistant", content: "Requested evidence."))
            let body: [String: Any] = ["trust": "untrusted_data", "payload": ["id": "p\(index)", "source": "fixture", "sha256": String(repeating: "a", count: 64), "bytes": 50000, "chunks": 20, "suspicious": true], "text": String(repeating: "source body ", count: 2000)]
            history.append(.init(role: "tool", content: String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)))
        }
        let fitted = try await window.prepare(messages: history, archived: 0, capacity: 8192, fixedTokens: 1000,
            responseTokens: 800, finalStep: false, count: { $0.utf8.count })
        precondition(fitted.prompt.contains("PINNED_USER_REQUEST") && fitted.prompt.contains("untrusted_data"))
        precondition(fitted.omittedMessages > 0 && fitted.inputTokens + 800 + 384 <= 8192)
        precondition(fitted.prompt.contains("sha256") || fitted.prompt.contains("payload list"))
        do {
            _ = try await AtlasContextWindow().prepare(messages: [.init(role: "user", content: String(repeating: "x", count: 20000))],
                archived: 0, capacity: 4096, fixedTokens: 800, responseTokens: 800, finalStep: false, count: { $0.utf8.count })
            preconditionFailure("Oversized pinned request was silently truncated")
        } catch AtlasContextError.requestTooLarge { }
        do {
            _ = try await AtlasContextWindow().prepare(messages: [pinned], archived: 0, capacity: 4096,
                fixedTokens: 4000, responseTokens: 800, finalStep: false, count: { $0.utf8.count })
            preconditionFailure("Oversized tool schema was blamed on the user request")
        } catch AtlasContextError.toolBudgetTooLarge { }
        report("Sliding context preserves the request, provenance and output reserve; oversized requests fail explicitly: passed")

        if CommandLine.arguments.contains("--live") {
            guard case .available = SystemLanguageModel.default.availability else {
                throw NSError(domain: "AtlasLiveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple on-device model unavailable; live integration not verified."])
            }
            if !CommandLine.arguments.contains("--mcp-only") {
            var partialCount = 0
            let answer = try await AtlasAssistant.answer("Read the local text file \(file.path). What is its release label?",
                context: VoiceSessionContext(sessions: [], focusedID: nil), cursorContext: nil,
                executable: executable, identity: identity, servers: [], onProgress: { report("Native live: " + $0) }, onPartial: { _ in partialCount += 1 })
            report("Native fixture answer: " + answer)
            precondition(answer.localizedCaseInsensitiveContains("persimmon"), "Live Atlas/model/file answer did not contain the fixture label")
            precondition(partialCount > 0, "No live response streaming")
            report("Apple model → Atlas → native file read → Apple streamed answer, entirely local: passed")
            let selection = try await AtlasAssistant.answer("What is the error code in this selected text, and what does it mean? Include the code.",
                context: VoiceSessionContext(sessions: [], focusedID: nil), cursorContext: "HTTP 404: the requested resource could not be found.",
                executable: executable, identity: identity, servers: [])
            report("Cursor fixture answer: " + selection)
            precondition(selection.contains("404"), "Cursor reference lost through Atlas")
            report("Cursor context survives the Atlas integration: passed")
            }
            let mcpAnswer = try await AtlasAssistant.answer("Use the local MCP server Test archive and its read_archive tool. Search the returned archive for the phrase release label, then tell me that label.",
                context: VoiceSessionContext(sessions: [], focusedID: nil), cursorContext: nil,
                executable: executable, identity: identity, servers: [fixtureServer], onProgress: { report("MCP live: " + $0) }, onTrace: { step, error in if let error { report("MCP step \(step) prior error: " + error) } }, onProposal: { report("MCP fixture proposal: " + $0.argumentsJSON) })
            report("Live MCP fixture answer: " + mcpAnswer)
            precondition(mcpAnswer.contains("release-comet-73"), "Live model could not retrieve the large MCP payload tail")
            report("Apple model → approved MCP call → large-payload search → grounded answer: passed")
            let model = SystemLanguageModel.default
            let fixed = try await AtlasContextWindow.fixedTokens(instructions: "Test instructions.", schema: MCPArguments.generationSchema, model: model)
            let measured = try await AtlasContextWindow().prepare(messages: history, archived: 0, capacity: model.contextSize,
                fixedTokens: fixed, responseTokens: 800, finalStep: false,
                count: { try await AtlasContextWindow.tokenCount($0, model: model) })
            precondition(measured.inputTokens + 1184 <= model.contextSize)
            report("Actual Apple tokenizer enforces the device's \(model.contextSize)-token window: passed")
        }
    }
    static func toolObject(_ content: String) throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(with: Data(content.utf8), options: [.fragmentsAllowed])
        if let encoded = value as? String { value = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) }
        return value as! [String: Any]
    }

}
