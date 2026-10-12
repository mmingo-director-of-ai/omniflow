import Foundation

@MainActor
enum AtlasRetrievalChecks {
    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws {
        try sourceAssembly()
        try largerSourceAssembly()
        try operationCatalogAssembly()
        try sourceBoundaries()
        try readContinuations()
        try resolvedAnalysis()
        try followUpReferences()
        AtlasIntegrationTests.report("Retrieval checks passed: exact source coverage, source isolation, resolved analysis text and bounded follow-up references")
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw CheckFailure(description: message) }
    }

    private static func rejected(_ operation: () throws -> Void, _ message: String) throws {
        do { try operation() } catch { return }
        throw CheckFailure(description: message)
    }

    private static func evidence(_ text: String, bytes: Int, chunks: Int, chunk: Int,
                                 start: Int, end: Int? = nil, source: String = "mcp:s1:read_record",
                                 hash: String = String(repeating: "a", count: 64),
                                 excerpt: Bool = false, error: Bool = false) -> AtlasSourceEvidence {
        AtlasSourceEvidence(id: "p2", source: source, sha256: hash, bytes: bytes, chunks: chunks,
            chunk: chunk, startByte: start, endByte: end ?? start + text.utf8.count,
            text: text, isSearchExcerpt: excerpt, isError: error)
    }

    private static func sourceAssembly() throws {
        let parts = ["Start 紅", "🐼\n", "Final café."]
        let expected = parts.joined()
        let total = expected.utf8.count
        let starts = [0, parts[0].utf8.count, parts[0].utf8.count + parts[1].utf8.count]
        let records = parts.enumerated().map { index, text in
            evidence(text, bytes: total, chunks: 3, chunk: index, start: starts[index])
        }
        var document = try AtlasRetrievedDocument(records[2])
        try expect(document.completeText == nil && document.nextChunk == 0, "Out-of-order last chunk falsely completed the source")
        try document.add(records[0])
        try expect(document.completeText == nil && document.nextChunk == 1, "Collector skipped the missing middle chunk")
        try document.add(records[1])
        try expect(document.completeText == expected && document.nextChunk == nil, "Exact UTF-8 ranges were not assembled in source order")
        try document.add(records[1])
        try expect(document.completeText == expected, "Identical repeated delivery changed the source")

        var gap = try AtlasRetrievedDocument(evidence("ab", bytes: 7, chunks: 2, chunk: 0, start: 0))
        try gap.add(evidence("xy", bytes: 7, chunks: 2, chunk: 1, start: 5))
        try expect(gap.completeText == nil, "All chunk labels were mistaken for contiguous byte coverage")
        let truncated = try AtlasRetrievedDocument(evidence("prefix", bytes: 10, chunks: 1, chunk: 0, start: 0))
        try expect(truncated.completeText == nil, "An incomplete final byte range became complete text")
    }

    private static func sourceBoundaries() throws {
        let first = evidence("abc", bytes: 6, chunks: 2, chunk: 0, start: 0)
        let invalid = [
            evidence("def", bytes: 6, chunks: 2, chunk: 1, start: 3, source: "mcp:s2:read_record"),
            evidence("def", bytes: 6, chunks: 2, chunk: 1, start: 3, hash: String(repeating: "b", count: 64)),
            evidence("def", bytes: 7, chunks: 2, chunk: 1, start: 3),
            evidence("def", bytes: 6, chunks: 3, chunk: 1, start: 3),
            evidence("def", bytes: 6, chunks: 2, chunk: 2, start: 3),
            evidence("def", bytes: 6, chunks: 2, chunk: 1, start: 3, end: 5),
            evidence("def", bytes: 6, chunks: 2, chunk: 1, start: -1),
            evidence("def", bytes: 6, chunks: 2, chunk: 1, start: 4),
            evidence("def", bytes: 6, chunks: 2, chunk: 1, start: 3, excerpt: true),
            evidence("def", bytes: 6, chunks: 2, chunk: 1, start: 3, error: true),
            evidence("xyz", bytes: 6, chunks: 2, chunk: 0, start: 0),
        ]
        for record in invalid {
            try rejected({
                var document = try AtlasRetrievedDocument(first)
                try document.add(record)
            }, "Mismatched identity, coverage, or non-source data entered a collected record")
        }
        try rejected({ _ = try AtlasRetrievedDocument(evidence("a", bytes: 24_001, chunks: 1, chunk: 0, start: 0)) },
                     "Collector exceeded its direct-read byte budget")
        for kind in ["schema", "binary"] {
            let value: [String: Any] = ["payload": ["id": "p2", "source": "mcp:s1:read_record",
                "sha256": String(repeating: "a", count: 64), "bytes": 3, "chunks": 1, "kind": kind],
                "chunk": 0, "startByte": 0, "endByte": 3, "text": "abc", "completeText": true]
            let content = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            try expect(AtlasSourceEvidence.records(from: content).isEmpty, "Schema or binary data was accepted as source text")
        }
    }

    private static func largerSourceAssembly() throws {
        let parts = [String(repeating: "entry café\n", count: 400),
                     String(repeating: "zone 紅熊猫\n", count: 400),
                     String(repeating: "status pending\n", count: 200) + "Final result: five records.\n"]
        let expected = parts.joined()
        let total = expected.utf8.count
        try expect(total > 8_000 && total < 24_000, "The service-data fixture no longer exercises the larger assembly allowance")
        let starts = [0, parts[0].utf8.count, parts[0].utf8.count + parts[1].utf8.count]
        var document = try AtlasRetrievedDocument(evidence(parts[0], bytes: total, chunks: 3, chunk: 0, start: 0))
        try document.add(evidence(parts[2], bytes: total, chunks: 3, chunk: 2, start: starts[2]))
        try expect(document.completeText == nil && document.nextChunk == 1,
                   "A large source was marked complete while its middle chunk was missing")
        try document.add(evidence(parts[1], bytes: total, chunks: 3, chunk: 1, start: starts[1]))
        try expect(document.completeText == expected && document.completeText?.utf8.count == total && document.nextChunk == nil,
                   "A source beyond 8 KB lost complete byte coverage or its final result")

        // This is a host-side assembly allowance, not an inference token limit.
        let head = String(repeating: "a", count: 12_000)
        let tail = String(repeating: "🐼", count: 3_000)
        var boundary = try AtlasRetrievedDocument(evidence(head, bytes: 24_000, chunks: 2, chunk: 0, start: 0))
        try boundary.add(evidence(tail, bytes: 24_000, chunks: 2, chunk: 1, start: 12_000))
        try expect(boundary.completeText == head + tail && boundary.completeText?.utf8.count == 24_000,
                   "The exact direct-assembly byte limit rejected complete Unicode source text")
    }

    private static func operationCatalogAssembly() throws {
        let head = String(repeating: "x", count: 40_000)
        let tail = "{\"operations\":[\"records.read\"]}"
        let bytes = head.utf8.count + tail.utf8.count
        let first = evidence(head, bytes: bytes, chunks: 2, chunk: 0, start: 0)
        try rejected({ _ = try AtlasRetrievedDocument(first) }, "Metadata allowance silently expanded ordinary source collection")
        var catalog = try AtlasRetrievedDocument(first, maximumBytes: AtlasMCPOperationRouting.maximumCatalogBytes)
        try expect(catalog.completeText == nil && catalog.nextChunk == 1, "Partial operation catalog was treated as complete")
        try catalog.add(evidence(tail, bytes: bytes, chunks: 2, chunk: 1, start: 40_000))
        try expect(catalog.completeText == head + tail, "Bounded operation metadata lost the final dispatch definitions")
        try rejected({ _ = try AtlasRetrievedDocument(first, maximumBytes: AtlasMCPOperationRouting.maximumCatalogBytes + 1) },
                     "A caller exceeded the explicit catalog assembly bound")
    }

    private static func resolvedAnalysis() throws {
        let findings = "The full record says the release was postponed. Exact source: 紅熊猫."
        func response(id: String = "m17", text: String = findings) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: [
                "record": ["id": id, "text": text, "sources": [["id": "p2", "startByte": 0, "endByte": 4000]]],
            ]), as: UTF8.self)
        }
        let plain = try response()
        let wrapped = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        for content in [plain, wrapped] {
            let text = try AtlasRetrieval.analysisRecord(from: content, expectedID: "m17")
            try expect(text == findings && text != "m17", "Analysis supplied a memory identifier instead of the resolved findings")
        }
        try rejected({ _ = try AtlasRetrieval.analysisRecord(from: plain, expectedID: "m18") }, "Wrong memory record was accepted")
        try rejected({ _ = try AtlasRetrieval.analysisRecord(from: plain, expectedID: "p2") }, "Payload ID was accepted as an analysis record")
        try rejected({ _ = try AtlasRetrieval.analysisRecord(from: response(text: ""), expectedID: "m17") }, "Empty analysis findings were accepted")
        try rejected({ _ = try AtlasRetrieval.analysisRecord(from: response(text: String(repeating: "x", count: 8_001)), expectedID: "m17") },
                     "Analysis text exceeded its bounded result allowance")
        try rejected({ _ = try AtlasRetrieval.analysisRecord(from: #"{"text":"m17"}"#, expectedID: "m17") },
                     "An unresolved analysis ID was mistaken for a record")
    }

    private static func readContinuations() throws {
        func call(name: String = "documents", arguments: [String: Any], operation: String = "call",
                  hostTool: String = "mcp") throws -> AtlasToolCall {
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            let outer: [String: Any] = ["operation": operation, "server": "s1", "name": name, "argumentsJSON": encoded]
            return AtlasToolCall(name: hostTool, argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: outer), as: UTF8.self))
        }
        for action in ["get_page", "read", "search_records", "getPage", "list", "projects.list", "documents.get_page", "tools.catalog", "projects.help"] {
            let proposal = try call(arguments: ["action": action, "pageId": "record-42"])
            try expect(AtlasRetrieval.permitsReadContinuation(proposal), "An explicit read dispatch was rejected")
        }
        let direct = try call(name: "read_record", arguments: ["id": "record-42"])
        try expect(AtlasRetrieval.permitsReadContinuation(direct), "A direct named read operation was rejected")
        try expect(AtlasRetrieval.requestsRecordBody(direct), "A direct record read lost its planned body transition")
        for action in ["get_page", "getPage", "read", "fetch_record", "retrieve_document", "documents.get_page"] {
            let proposal = try call(arguments: ["action": action, "pageId": "record-42"])
            try expect(AtlasRetrieval.requestsRecordBody(proposal), "An approved record read lost its planned body transition")
        }
        let consistentDispatch = try call(arguments: ["action": "get_page", "operation": "read", "method": "GET"])
        try expect(AtlasRetrieval.requestsRecordBody(consistentDispatch), "Consistent record-read dispatch fields were rejected")
        let listings = try [
            call(arguments: ["action": "search_records"]),
            call(arguments: ["action": "list"]),
            call(arguments: ["action": "projects.list"]),
            call(arguments: ["action": "get_schema"]),
            call(arguments: ["action": "get_outline"]),
            call(arguments: ["action": "get_page", "view": "outline"]),
            call(arguments: ["action": "get_status"]),
            call(arguments: ["action": "get_page", "operation": "list"]),
            call(arguments: ["action": "get_page", "method": "search"]),
            call(arguments: ["operation": "read_record", "method": "get_schema"]),
            call(arguments: ["action": "list", "operation": "get_page"]),
            call(name: "list_records", arguments: [:]),
        ]
        for proposal in listings {
            try expect(!AtlasRetrieval.requestsRecordBody(proposal), "A listing, schema, or outline was classified as an opened record body")
        }
        let rejectedCalls = try [
            call(arguments: ["action": "deletePage"]),
            call(arguments: ["action": "get_and_delete"]),
            call(arguments: ["action": "delete.read"]),
            call(arguments: ["action": "documents.get_and_delete"]),
            call(arguments: ["action": "documents.unknown"]),
            call(arguments: ["action": ".read"]),
            call(arguments: ["action": "documents..read"]),
            call(name: "delete_document", arguments: ["action": "read"]),
            call(arguments: ["action": "read", "operation": "write"]),
            call(arguments: ["action": ["read"]]),
            call(arguments: ["action": "unknown"]),
            call(name: "documents", arguments: [:]),
            call(arguments: ["action": "read"], operation: "schema"),
            call(arguments: ["action": "read"], hostTool: "native"),
        ]
        for proposal in rejectedCalls {
            try expect(!AtlasRetrieval.permitsReadContinuation(proposal), "A mutation or unknown dispatch entered automatic read continuation")
            try expect(!AtlasRetrieval.requestsRecordBody(proposal), "A rejected operation established a record-read transition")
        }
        let failed = try call(arguments: ["action": "tools.learn"])
        let corrected = try call(arguments: ["action": "tools.catalog"])
        try expect(AtlasRetrieval.permitsReadRecovery(corrected, after: failed), "A same-capability catalog read could not recover unknown arguments")
        try expect(!AtlasRetrieval.permitsReadRecovery(failed, after: failed), "Recovery repeated the identical failed request")
        let ordered = try call(arguments: ["action": "projects.list", "limit": 5])
        let reordered = AtlasToolCall(name: "mcp", argumentsJSON: #"{"server":"s1","name":"documents","operation":"call","argumentsJSON":"{\"limit\":5,\"action\":\"projects.list\"}"}"#)
        try expect(!AtlasRetrieval.permitsReadRecovery(reordered, after: ordered), "JSON key order bypassed duplicate-recovery prevention")
        let otherTool = try call(name: "other_documents", arguments: ["action": "tools.catalog"])
        try expect(!AtlasRetrieval.permitsReadRecovery(otherTool, after: failed), "Recovery switched the approved capability")
        let mutation = try call(arguments: ["action": "projects.delete"])
        try expect(!AtlasRetrieval.permitsReadRecovery(mutation, after: failed), "Error recovery proposed a mutation")
        let listing = try call(arguments: ["action": "projects.list"])
        try expect(AtlasRetrieval.returnsRequestedListing(listing, request: .searchListing), "A requested namespace listing still depended on classifying an arbitrary source chunk")
        try expect(!AtlasRetrieval.returnsRequestedListing(listing, request: .recordContents), "A search/list response replaced a requested full record")
        let help = try call(arguments: ["action": "projects.help"])
        for metadata in [help, corrected, failed] {
            try expect(AtlasRetrieval.isMetadataRequest(metadata), "Help/catalog/operation definitions counted as business evidence")
            try expect(!AtlasRetrieval.returnsRequestedListing(metadata, request: .searchListing), "Metadata was treated as the requested business listing")
        }
        for args in [["action": "get_help"], ["action": "getCatalog"], ["method": "get_catalog"], ["operation": "tools.schema"]] {
            let metadata = try call(arguments: args)
            try expect(AtlasRetrieval.isMetadataRequest(metadata) && !AtlasRetrieval.requestsRecordBody(metadata),
                       "A metadata dispatch established an awaited document body")
        }
        let article = try call(arguments: ["action": "documents.get_help_article"])
        try expect(!AtlasRetrieval.isMetadataRequest(article), "A help article body was mistaken for a tool parameter catalog")
        let state = AtlasRetrievalState()
        state.requestedOutput = .other
        state.recordProposal(try call(arguments: [:], operation: "schema"))
        try expect(!state.mayDraftAnswer, "Selecting a schema was enough to answer remote-account facts")
        state.recordProposal(AtlasToolCall(name: "getMacContext", argumentsJSON: #"{"topic":"system"}"#))
        try expect(!state.mayDraftAnswer, "Local Mac data was enough to assert remote-account facts")
        state.recordProposal(help)
        try expect(!state.mayDraftAnswer, "Merely proposing service help established live evidence")
        state.needsRecordBody = true
        state.recordProposal(direct)
        try expect(state.awaitingRecordResponse, "An accepted planned record read lost its pending-body state")
        // The read fails; a metadata recovery must not inherit the old body flag.
        state.recordProposal(help)
        try expect(!state.awaitingRecordResponse, "Failed record-read state promoted recovery help into document evidence")
        state.hasRemoteEvidence = true
        try expect(state.mayDraftAnswer, "Verified remote evidence could not support a draft")
        state.document = try AtlasRetrievedDocument(evidence("abc", bytes: 3, chunks: 1, chunk: 0, start: 0))
        state.analyzingID = "p2"; state.analysisResultID = "m1"
        state.recordProposal(try call(name: "other_service", arguments: [:], operation: "schema"))
        try expect(!state.mayDraftAnswer, "Switching services reused the previous service's evidence")
        try expect(state.document == nil && state.analyzingID == nil && state.analysisResultID == nil &&
                   state.lastMCPCall == nil && !state.awaitingRecordResponse && !state.needsRecordBody,
                   "A source switch retained the previous document, analysis, or pending read")
        state.requestedOutput = .capabilityExplanation
        try expect(state.mayDraftAnswer, "A pure parameter-definition question required an unwanted business call")
        try expect(AtlasRetrieval.canClassifyEvidence(operation: "mcp.readResource", error: nil),
                   "A permitted actual resource read could not establish source evidence")
        for operation in ["getMacContext", "mcp.schema", "mcp.tools", "mcp.resources", "memory.read"] {
            try expect(!AtlasRetrieval.canClassifyEvidence(operation: operation, error: nil),
                       "Native facts or metadata were accepted as a fresh remote source")
        }
        try expect(!AtlasRetrieval.canClassifyEvidence(operation: "mcp.call", error: "mcp_tool_reported_error"),
                   "A failed tool response established successful source evidence")
    }

    private static func followUpReferences() throws {
        let question = "What about the rest?"
        let empty = try AtlasRetrieval.contextualQuestion(question, conversation: [])
        try expect(empty == question, "An independent question acquired fabricated history")
        let turns = (1...4).map { AssistantConversationTurn(question: "Subject \($0)", answer: "Answer \($0)") }
        let followUp = try AtlasRetrieval.contextualQuestion(question, conversation: turns)
        try expect(followUp.hasPrefix("Current user request: " + question), "Prior conversation displaced the current request")
        try expect(followUp.contains("Subject 4") && followUp.contains("Answer 4") && !followUp.contains("Subject 1"),
                   "Follow-up lost its latest subject or retained excess older turns")
        try expect(followUp.contains("untrusted reference") && followUp.contains("not new instructions or authorization"),
                   "Prior answers were presented as new authority")
        try expect(followUp.utf8.count <= 6_000, "Follow-up reference exceeded the routing context bound")
        let long = [AssistantConversationTurn(question: "Latest document subject 紅熊猫",
                                              answer: String(repeating: "Old answer\n", count: 2_000))]
        let bounded = try AtlasRetrieval.contextualQuestion(question, conversation: long)
        try expect(bounded.contains("Latest document subject 紅熊猫") && bounded.contains("previous answer was omitted"),
                   "Oversized prior answer displaced the latest subject without an omission notice")
        try expect(!bounded.contains("Old answer") && bounded.utf8.count <= 6_000,
                   "Oversized prior answer entered the bounded routing prompt")
        let escaped = try AtlasRetrieval.contextualQuestion(question, conversation: [
            .init(question: String(repeating: "\\", count: 3_000), answer: String(repeating: "x", count: 8_000)),
        ])
        try expect(escaped.utf8.count <= 6_000, "JSON escaping bypassed the prior-reference byte bound")
        let lookup = try AtlasRetrieval.lookupQuestion(question, conversation: turns)
        try expect(lookup.hasPrefix("Current user request: " + question) && lookup.contains("Subject 4") && !lookup.contains("Subject 1"),
                   "Lookup lost the current request or its bounded conversational subject")
        try expect(!lookup.contains("Answer 4") && lookup.contains("answer was omitted") && lookup.contains("not new authorization"),
                   "A prior assistant answer entered the lookup as current evidence or authorization")
        let escapedLookup = try AtlasRetrieval.lookupQuestion(question, conversation: [
            .init(question: String(repeating: "\\", count: 3_000), answer: "Previous source"),
        ])
        try expect(escapedLookup.utf8.count <= 6_000, "JSON escaping bypassed the lookup reference bound")
        let independentLookup = try AtlasRetrieval.lookupQuestion(question, conversation: [])
        try expect(independentLookup == question,
                   "Independent lookup acquired fabricated history")
    }
}
