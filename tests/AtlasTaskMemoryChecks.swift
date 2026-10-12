import Foundation
import FoundationModels

@MainActor
enum AtlasTaskMemoryChecks {
    static func run(executable: URL, identity: AtlasBuildIdentity, definitions: [AtlasToolDefinition],
                    server: MCPServerConfiguration, live: Bool) async throws {
        let markers = ["First decision: staging only.", "Middle decision: 17 checks remain.", "Final decision: production is NOT approved."]
        let source = markers[0] + "\n" + String(repeating: " alpha", count: 256000)
            + "\n" + markers[1] + "\n" + String(repeating: " beta", count: 256000) + "\n" + markers[2] + "\n"
        let model = SystemLanguageModel.default
        let instructions = AtlasAssistant.instructions(AtlasFrame(type: "analysis"), allowMCP: true, allowMCPResources: false)
        precondition(instructions.contains("You are Omni") && instructions.contains("getMacContext")
            && instructions.contains("UNTRUSTED DATA"), "Analysis must retain the assistant identity, capabilities and source trust boundary")
        let fixed: Int
        if live {
            fixed = try await AtlasContextWindow.fixedTokens(instructions: instructions,
                schema: AtlasAnalysisEngine.extractionSchema(passageCount: 40), model: model)
        } else {
            fixed = AtlasContextWindow.estimatedTokens(instructions)
                + AtlasContextWindow.estimatedTokens(String(decoding: try JSONEncoder().encode(AtlasAnalysisEngine.extractionSchema(passageCount: 40)), as: UTF8.self))
        }
        if live {
            let total = try await AtlasContextWindow.tokenCount(source, model: model)
            precondition(total > 512000, "Large fixture must exceed a 512K context")
            AtlasIntegrationTests.report("Large-source fixture measured with Apple tokenizer: \(total) tokens")
        }
        var fixture = server
        fixture.arguments.append("large-analysis")
        let call = MCPArguments(operation: .call, server: fixture.id, name: "read_archive", argumentsJSON: "{}", query: nil, offset: nil, cursor: nil)
        var payloadID = ""
        var passes = 0
        var mcpCalls = 0
        var finalMemory: AtlasMemoryView?
        let result = try await AtlasBridge().run(prompt: "Read the archive and combine every decision.", tools: definitions,
            servers: [fixture], question: "Combine every decision", executable: executable, identity: identity,
            onModel: { frame in
                if let request = frame.analysis {
                    passes += 1
                    let capacity = live ? model.contextSize : 8192
                    let slice = try await AtlasAnalysisEngine.prepare(request, capacity: capacity, fixedTokens: fixed,
                        count: { if live { try await AtlasContextWindow.tokenCount($0, model: model) } else { AtlasContextWindow.estimatedTokens($0) } })
                    precondition(slice.inputTokens + 1184 <= capacity)
                    let text: String
                    let quotes: [String]
                    if request.phase == "extract" {
                        let admitted = String(decoding: Data(request.text!.utf8).prefix(slice.consumedBytes), as: UTF8.self)
                        quotes = markers.filter { admitted.contains($0) }
                        text = quotes.joined(separator: " ")
                    } else {
                        quotes = []
                        text = request.records!.prefix(slice.consumedRecords).map(\.text).joined(separator: " ")
                    }
                    return AtlasFrame(type: "reply", analysisResult: .init(text: text, quotes: quotes,
                        consumedBytes: slice.consumedBytes, consumedRecords: slice.consumedRecords))
                }
                if frame.step == 1 {
                    mcpCalls += 1
                    return AtlasFrame(type: "reply", toolCalls: [.init(name: "mcp", argumentsJSON: call.generatedContent.jsonString)])
                }
                if frame.step == 2 {
                    let value = try AtlasIntegrationTests.toolObject(frame.messages!.last!.content)
                    let evidence = value["evidence"] as! [String: Any]
                    let payload = evidence["payload"] as! [String: Any]
                    payloadID = payload["id"] as! String
                    let args = AtlasMemoryArguments(operation: .analyze, id: payloadID, quote: nil, query: nil)
                    return AtlasFrame(type: "reply", toolCalls: [.init(name: "memory", argumentsJSON: args.generatedContent.jsonString)])
                }
                finalMemory = frame.memory
                precondition(frame.memory?.active?.complete == true)
                let combined = frame.memory!.records.map(\.text).joined(separator: " ")
                precondition(markers.allSatisfy { combined.contains($0) }, "Early or late decisions disappeared during synthesis")
                return AtlasFrame(type: "reply", content: combined)
            }, onTool: { _ in preconditionFailure("Source processing must stay inside the helper") })
        precondition(passes > 24 && mcpCalls == 1 && result.toolCount > 1)
        precondition(finalMemory?.active?.processedBytes == finalMemory?.active?.totalBytes)
        AtlasIntegrationTests.report("Large MCP source → \(passes) token-bounded passes → cumulative synthesis; one original MCP call: passed")

        let memory = AtlasMemoryView(records: [.init(id: "m1", text: "EARLY_VERIFIED_FINDING", sources: nil, parents: nil)],
            totalRecords: 100, analysisPasses: passes, active: nil)
        var history = [AtlasMessage(role: "user", content: "PINNED_GOAL")]
        for _ in 0..<10 {
            history.append(.init(role: "assistant", content: "Requested source"))
            history.append(.init(role: "tool", content: String(repeating: "old source ", count: 500)))
        }
        let fitted = try await AtlasContextWindow().prepare(messages: history, archived: 0, capacity: 8192, fixedTokens: 1200,
            responseTokens: 800, finalStep: false, memory: memory, count: { $0.utf8.count })
        precondition(fitted.omittedMessages > 0 && fitted.prompt.contains("EARLY_VERIFIED_FINDING") && fitted.prompt.contains("PINNED_GOAL"))
        let unicode = AtlasAnalysisRequest(phase: "extract", goal: "Find dates", id: "p1", startByte: 0,
            totalBytes: 16000, text: String(repeating: "紅熊猫 café ", count: 700), records: nil)
        let unicodeSlice = try await AtlasAnalysisEngine.prepare(unicode, capacity: 4096, fixedTokens: 1000, count: { $0.utf8.count })
        precondition(unicodeSlice.inputTokens + 1184 <= 4096 && unicodeSlice.consumedBytes < unicode.text!.utf8.count)
        precondition(String(data: Data(unicode.text!.utf8).prefix(unicodeSlice.consumedBytes), encoding: .utf8) != nil)
        precondition(unicodeSlice.excerpts.joined() == String(decoding: Data(unicode.text!.utf8).prefix(unicodeSlice.consumedBytes), as: UTF8.self))
        precondition(unicodeSlice.excerpts.allSatisfy { $0.utf8.count <= 700 })
        AtlasIntegrationTests.report("Compaction keeps cumulative findings; smaller windows consume only a valid UTF-8 prefix: passed")

        if live {
            var small = server
            small.arguments.append("small-analysis")
            let smallCall = MCPArguments(operation: .call, server: small.id, name: "read_archive", argumentsJSON: "{}", query: nil, offset: nil, cursor: nil)
            var livePasses = 0
            _ = try await AtlasBridge().run(prompt: "Extract deployment decisions, preserving restrictions.", tools: definitions,
                servers: [small], question: "What deployment decisions and restrictions are stated?", executable: executable, identity: identity,
                onModel: { frame in
                    if let request = frame.analysis {
                        livePasses += 1
                        let reply = try await AtlasAnalysisEngine.respond(request, instructions: instructions)
                        return AtlasFrame(type: "reply", analysisResult: reply)
                    }
                    if frame.step == 1 { return AtlasFrame(type: "reply", toolCalls: [.init(name: "mcp", argumentsJSON: smallCall.generatedContent.jsonString)]) }
                    if frame.step == 2 {
                        let value = try AtlasIntegrationTests.toolObject(frame.messages!.last!.content)
                        let evidence = value["evidence"] as! [String: Any]
                        let payload = evidence["payload"] as! [String: Any]
                        let args = AtlasMemoryArguments(operation: .analyze, id: payload["id"] as! String, quote: nil, query: nil)
                        return AtlasFrame(type: "reply", toolCalls: [.init(name: "memory", argumentsJSON: args.generatedContent.jsonString)])
                    }
                    precondition(frame.previousError == nil, "Live analysis failed: \(frame.previousError ?? "")")
                    precondition(frame.memory?.active?.complete == true)
                    let rootID = frame.memory!.active!.result!
                    let findings = frame.memory!.records.first { $0.id == rootID }!.text.lowercased()
                    AtlasIntegrationTests.report("Live merged decision notes: " + findings)
                    let keepsRestriction = ["not approved", "not been approved", "not authorized", "not permitted", "unapproved", "no approval"].contains { findings.contains($0) }
                    precondition(findings.contains("staging") && findings.contains("production") && keepsRestriction, "Live synthesis lost a deployment restriction")
                    return AtlasFrame(type: "reply", content: findings)
                }, onTool: { _ in preconditionFailure("No native tool expected") })
            precondition(livePasses >= 3)
            AtlasIntegrationTests.report("Live Apple extraction and synthesis across \(livePasses) bounded passes preserves restrictions and exact source quotations: passed")
            try await runAssistant(executable: executable, identity: identity, server: small)
        }
    }

    static func runAssistant(executable: URL, identity: AtlasBuildIdentity, server: MCPServerConfiguration) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notchlee-live-task-memory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = AssistantMemory(root: root, defaults: nil)
        var proposedAnalysis = false
        let answer = try await AtlasAssistant.answer(
            "Use the local MCP server Test archive and its read_archive tool. Analyze the ENTIRE returned text, then summarize the deployment decisions and restrictions, including staging and production.",
            context: VoiceSessionContext(sessions: [], focusedID: nil), cursorContext: nil,
            executable: executable, identity: identity, servers: [server], memory: memory,
            onProgress: { AtlasIntegrationTests.report("Cumulative assistant: " + $0) },
            onProposal: { call in
                AtlasIntegrationTests.report("Cumulative proposal: " + call.name + " " + call.argumentsJSON)
                if call.name == "memory", let args = try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any], args["operation"] as? String == "analyze" {
                    proposedAnalysis = true
                }
            })
        AtlasIntegrationTests.report("Cumulative assistant answer: " + answer)
        let lowered = answer.lowercased()
        let keepsRestriction = ["not approved", "not been approved", "not authorized", "not permitted", "unapproved", "no approval"].contains { lowered.contains($0) }
        precondition(proposedAnalysis && lowered.contains("staging") && lowered.contains("production") && keepsRestriction,
            "The assistant did not complete the cumulative tool workflow")
        precondition(memory.error == nil && memory.document.tasks.count == 1 && memory.document.tasks[0].progress?.complete == true
            && memory.document.tasks[0].status == .complete, "Live cumulative work was not retained in persistent memory")
        AtlasIntegrationTests.report("Live assistant selects MCP → cumulative analysis → final answer with persistent task memory: passed")
    }
}
