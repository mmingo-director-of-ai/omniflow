import Foundation

@MainActor
enum AtlasAnswerContextChecks {
    static func run() async throws {
        let tools = ["callSelectedMCPTool", "payload", "getMacContext", "inspectLocalFiles", "mcp", "selectMCPTool",
                     "mcpResources", "analyzeStoredSource", "memory", "recallSavedMemory"]
        let inventories = AtlasContextWindow.toolInventories(tools)
        precondition(inventories.first == tools && inventories.last == ["callSelectedMCPTool"])
        precondition(inventories.allSatisfy { $0.contains("callSelectedMCPTool") && Set($0).isSubset(of: Set(tools)) },
                     "Context reduction removed the bound capability or introduced an unapproved function")
        precondition(inventories.dropLast().allSatisfy { $0.contains("payload") },
                     "Parameter inspection was dropped before optional discovery and memory")
        precondition(AtlasContextWindow.toolInventories(["getMacContext", "inspectLocalFiles"]).count == 1,
                     "Ordinary native requests lost their context tools")
        let schema: [String: Any] = [
            "id": "p1", "source": "mcp:s1:portal_list_servers:schema", "kind": "schema",
            "sha256": String(repeating: "a", count: 64), "bytes": 56, "chunks": 1,
        ]
        let source: [String: Any] = [
            "id": "p3", "source": "mcp:s1:portal_list_servers", "kind": "text",
            "sha256": String(repeating: "b", count: 64), "bytes": 334, "chunks": 1,
        ]
        let receipt: [String: Any] = [
            "trust": "untrusted_data", "status": "ready_to_call", "server": "s1",
            "name": "portal_list_servers", "executed": false, "parameterDefinitionID": "p1",
        ]
        let services = "Authentik, AWS, Cloudflare, Infisical, Pergamon, and Twenty CRM"
        let result: [String: Any] = [
            "trust": "untrusted_data", "isError": false,
            "evidence": ["payload": source, "completeText": true, "text": services],
        ]
        // Exercise both result encodings accepted from the Atlas SDK.
        for wrapped in [false, true] {
            let window = AtlasContextWindow()
            let messages = [
                AtlasMessage(role: "user", content: "List connected services."),
                AtlasMessage(role: "assistant", content: "Select the approved tool."),
                AtlasMessage(role: "tool", content: try encode(receipt, wrapped: wrapped)),
                AtlasMessage(role: "tool", content: try encode(["payload": schema, "text": "Parameter definition"], wrapped: wrapped)),
                AtlasMessage(role: "assistant", content: "Run the selected tool."),
                AtlasMessage(role: "tool", content: try encode(result, wrapped: wrapped)),
            ]
            let slice = try await window.prepare(messages: messages, archived: 0, capacity: 20_000,
                fixedTokens: 500, responseTokens: 800, finalStep: false, question: "List connected services.", count: { $0.utf8.count })
            let envelope = try envelope(slice)
            let index = envelope["evidence"] as! [[String: String]]
            precondition(index.map { $0["id"]! } == ["p3"], "Tool definitions entered the source evidence index")
            precondition(index[0]["kind"] == "text", "The index lost the source's kind")
            precondition(slice.prompt.contains(services), "Actual returned facts were removed with parameter metadata")
            precondition(slice.prompt.contains("completeText"), "Result coverage was lost")
            precondition(slice.prompt.contains("ready_to_call"), "Selection history must remain available")
            precondition(slice.prompt.contains("User request:\nList connected services."), "The original request must remain outside source context")
        }

        // A document about schemas is still source evidence. Classification is
        // based on host payload kind, never keywords in the document or name.
        var schemaDocument = source
        schemaDocument["source"] = "mcp:s1:read_schema_design"
        let document: [String: Any] = ["payload": schemaDocument, "text": "The schema design is approved."]
        let error: [String: Any] = ["isError": true, "message": "Access denied"]
        let slice = try await AtlasContextWindow().prepare(messages: [
            .init(role: "user", content: "Read the schema design."),
            .init(role: "tool", content: try encode(document)),
            .init(role: "tool", content: try encode(error)),
        ], archived: 0, capacity: 20_000, fixedTokens: 500, responseTokens: 800,
            finalStep: false, count: { $0.utf8.count })
        let index = try envelope(slice)["evidence"] as! [[String: String]]
        precondition(index.count == 1 && index[0]["id"] == "p3")
        precondition(slice.prompt.contains("The schema design is approved.") && slice.prompt.contains("Access denied"))
        try await sourceProjectionChecks()
        AtlasIntegrationTests.report("Parameter receipts stay separate from source evidence; real facts, explicit schema documents, coverage and errors survive: passed")
    }

    private static func sourceProjectionChecks() async throws {
        func payload(_ text: String, bytes: Int? = nil, kind: String = "text") -> [String: Any] {
            ["id": "p7", "source": "mcp:s1:read_record", "sha256": String(repeating: "c", count: 64),
             "kind": kind, "bytes": bytes ?? text.utf8.count, "chunks": 4, "fullyReadChunks": 4, "text": true]
        }
        let fact = "CURRENT_SOURCE_FACT — " + String(repeating: "紅熊猫 café. ", count: 60)
        let full: [String: Any] = ["trust": "untrusted_data", "isError": false,
            "transportMetadata": String(repeating: "irrelevant metadata ", count: 1500),
            "evidence": ["payload": payload(fact), "startByte": 0, "endByte": fact.utf8.count,
                         "text": fact, "completeText": true, "allChunksRead": true, "chunk": 0]]
        for wrapped in [false, true] {
            let content = try encode(full, wrapped: wrapped)
            let parsed = AtlasSourceEvidence.records(from: content)
            precondition(parsed.count == 1 && parsed[0].text == fact && parsed[0].completeText)
            let slice = try await AtlasContextWindow().prepare(messages: [
                .init(role: "user", content: "PINNED_CURRENT_REQUEST"), .init(role: "tool", content: content)],
                archived: 0, capacity: 6000, fixedTokens: 400, responseTokens: 400,
                finalStep: false, question: "PINNED_CURRENT_REQUEST", count: { $0.utf8.count })
            let message = (try envelope(slice)["messages"] as! [[String: Any]]).last!["content"] as! String
            let retained = AtlasSourceEvidence.records(from: message)
            precondition(retained.count == 1 && retained[0].text == fact && retained[0].completeText,
                         "Wrapper metadata displaced source text that fits the context")
            precondition(!message.contains("transportMetadata") && !message.contains("fullyReadChunks"))
        }

        let large = String(repeating: "紅熊猫 evidence ", count: 600)
        let unequal = try encode(["evidence": [
            ["payload": payload(fact), "text": fact, "startByte": 0, "endByte": fact.utf8.count],
            ["payload": payload("Tiny"), "text": "Tiny", "startByte": 0, "endByte": 4],
        ]])
        let unequalProjection = AtlasSourceEvidence.records(from: AtlasSourceEvidence.compact(unequal,
            maximumTextBytes: fact.utf8.count + 4))
        precondition(unequalProjection.map(\.text) == [fact, "Tiny"] && unequalProjection.allSatisfy(\.completeText),
                     "Even allocation truncated unequal source bodies despite enough total space")
        let largeBody = try encode(["evidence": ["payload": payload(large), "text": large,
            "startByte": 0, "endByte": large.utf8.count, "chunk": 0, "completeText": true, "allChunksRead": true]])
        let small = try await AtlasContextWindow().prepare(messages: [.init(role: "user", content: "Current question"),
            .init(role: "tool", content: largeBody)], archived: 0, capacity: 3300, fixedTokens: 200,
            responseTokens: 300, finalStep: false, question: "Current question", count: { $0.utf8.count })
        let smallContent = (try envelope(small)["messages"] as! [[String: Any]]).last!["content"] as! String
        let shortened = AtlasSourceEvidence.records(from: smallContent)
        precondition(shortened.count == 1 && !shortened[0].text.isEmpty && shortened[0].text.utf8.count < large.utf8.count)
        precondition(!shortened[0].completeText && shortened[0].startByte == 0 && shortened[0].endByte == shortened[0].text.utf8.count)
        precondition(shortened[0].id == "p7" && shortened[0].sha256 == String(repeating: "c", count: 64))
        precondition(!smallContent.contains("allChunksRead") && !smallContent.contains("fullyReadChunks") && !smallContent.contains("partialPreview"),
                     "Raw envelope coverage survived truncation of the source text")

        let later = try encode(["payload": payload(fact, bytes: 20_000), "text": fact,
            "startByte": 2400, "endByte": 2400 + fact.utf8.count, "chunk": 1, "completeText": true])
        let laterProjection = AtlasSourceEvidence.records(from: AtlasSourceEvidence.compact(later, maximumTextBytes: 43))
        precondition(laterProjection[0].chunk == 1 && laterProjection[0].startByte == 2400)
        precondition(laterProjection[0].endByte == 2400 + laterProjection[0].text.utf8.count && !laterProjection[0].completeText)

        let search = try encode(["isError": true, "payload": payload(fact), "scannedStartByte": 0,
            "scannedEndByte": fact.utf8.count, "matches": [["chunk": 0, "startByte": 20,
                "excerptStartByte": 0, "excerptEndByte": fact.utf8.count, "text": fact]]])
        let matches = AtlasSourceEvidence.records(from: AtlasSourceEvidence.compact(search, maximumTextBytes: 90))
        precondition(matches.count == 1 && matches[0].isSearchExcerpt && matches[0].isError && !matches[0].completeText)
        precondition(matches[0].startByte == 0 && matches[0].endByte == matches[0].text.utf8.count,
                     "A search excerpt lost its own byte range or became a complete source read")
        for kind in ["schema", "binary"] {
            let metadata = try encode(["payload": payload(fact, kind: kind), "text": fact])
            precondition(AtlasSourceEvidence.records(from: metadata).isEmpty)
        }
        let malformed = AtlasSourceEvidence.records(from: try encode(["payload": payload(fact), "text": fact,
            "startByte": 0, "endByte": 1, "completeText": true]))
        precondition(malformed.count == 1 && malformed[0].startByte == nil && malformed[0].endByte == nil && !malformed[0].completeText)

        let prior = [AssistantConversationTurn(question: "Earlier question", answer: "Earlier answer")]
        let dialogue = try await AtlasContextWindow().prepare(messages: [.init(role: "user", content: "NEW_REQUEST")],
            archived: 0, capacity: 5000, fixedTokens: 100, responseTokens: 100, finalStep: false,
            question: "NEW_REQUEST", conversation: prior, count: { $0.utf8.count })
        let dialogueEnvelope = try envelope(dialogue)
        let turns = dialogueEnvelope["priorConversation"] as! [[String: String]]
        precondition(turns.first?["answer"] == "Earlier answer" && dialogueEnvelope["omittedConversationTurns"] as? Int == 0)
        precondition((dialogueEnvelope["messages"] as! [[String: String]])[0]["content"] == "NEW_REQUEST",
                     "Prior conversation was inserted into the pinned current request")
        let conversationHeavy = try await AtlasContextWindow().prepare(messages: [
            .init(role: "user", content: "NEW_REQUEST"), .init(role: "tool", content: try encode(full))],
            archived: 0, capacity: 6000, fixedTokens: 400, responseTokens: 400, finalStep: false,
            question: "NEW_REQUEST", conversation: [.init(question: "Old", answer: String(repeating: "old answer ", count: 850))],
            count: { $0.utf8.count })
        let dropped = try envelope(conversationHeavy)
        precondition((dropped["priorConversation"] as! [[String: String]]).isEmpty && dropped["omittedConversationTurns"] as? Int == 1)
        let preservedBody = (dropped["messages"] as! [[String: String]]).last!["content"]!
        precondition(AtlasSourceEvidence.records(from: preservedBody).first?.text == fact,
                     "Old conversation displaced complete current evidence")
        AtlasIntegrationTests.report("Structured source projection preserves UTF-8 ranges, distinguishes search excerpts and drops prior dialogue before current evidence: passed")
    }

    private static func encode(_ value: [String: Any], wrapped: Bool = false) throws -> String {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        return wrapped ? String(decoding: try JSONEncoder().encode(text), as: UTF8.self) : text
    }

    private static func envelope(_ slice: AtlasContextSlice) throws -> [String: Any] {
        let json = slice.prompt.split(separator: "\n").first { $0.hasPrefix("{") }!
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }
}
