// Ports of memory_test.go and the schema/number checks in mcp_test.go.
import Foundation
import Testing
@testable import OmniFlowApp

struct AtlasMemoryTests {
    @Test func largeAnalysisChainsAndKeepsSourceLineage() async throws {
        let markers = ["First decision: staging only.", "Middle decision: 17 checks remain.", "Final decision: production is NOT approved."]
        let source = markers[0] + String(repeating: " alpha", count: 256000) + "\n" + markers[1] + String(repeating: " beta", count: 256000) + "\n" + markers[2]
        let ranges = Box<[(Int, Int)]>([])
        let session = try memoryFixture { request in
            var result = AtlasRuntimeAnalysisReply()
            if request.phase == "extract" {
                let offered = request.text ?? ""
                precondition(offered.utf8.count <= atlasAnalysisBytes)
                // Simulate a tokenizer admitting less than the offered source.
                let text = AtlasUTF8.prefix(offered, 11000)
                result.consumedBytes = text.utf8.count
                ranges.value.append((request.startByte, request.startByte + result.consumedBytes))
                for marker in markers where text.contains(marker) {
                    result.text += marker + " "
                    result.quotes.append(marker)
                }
            } else {
                let records = request.records ?? []
                result.consumedRecords = min(2, records.count) // exercise more than one reduction level
                result.text = records.prefix(result.consumedRecords).map(\.text).joined()
            }
            return reply(result)
        }
        defer { session.store.close() }
        let memory = session.memory!
        let entry = try session.store.put("large-source", Array(source.utf8), isText: true)
        var calls = 0
        while true {
            calls += 1
            #expect(calls <= 100, "analysis failed to converge")
            if calls > 100 { return }
            _ = try await memory.analyze(entry.id, goal: "Preserve every decision")
            if memory.jobs[entry.id]!.complete { break }
            // The host, rather than the model, must schedule the continuation.
            let next = try await session.generate([])
            #expect(next.toolCalls.count == 1 && next.toolCalls[0].name == "memory" && next.toolCalls[0].arguments["id"]?.stringValue == entry.id)
        }
        let job = memory.jobs[entry.id]!
        #expect(job.processedBytes == source.utf8.count && memory.passes > 24)
        var end = 0
        for span in ranges.value {
            #expect(span.0 <= end && span.1 > end, "a source region was skipped or failed to progress")
            end = span.1
        }
        let root = try #require(memory.record(job.result ?? ""))
        #expect((root.parents?.count ?? 0) >= 2)
        for marker in markers { #expect(root.text.contains(marker), "lost decision: \(marker)") }
        let bytes = Array(source.utf8)
        func verify(_ id: String) {
            guard let note = memory.record(id) else { Issue.record("broken note reference"); return }
            for reference in note.sources ?? [] {
                #expect(String(decoding: bytes[reference.startByte..<reference.endByte], as: UTF8.self) == reference.quote)
            }
            for parent in note.parents ?? [] { verify(parent) }
        }
        verify(root.id)
        let journal = try String(contentsOfFile: session.store.path("task-memory.jsonl"), encoding: .utf8)
        #expect(journal.contains(#""complete":true"#))
    }

    @Test func analysisRejectsInventedEvidenceWithoutAdvancing() async throws {
        let valid = Box(false)
        let session = try memoryFixture { request in
            reply(.init(text: "Deployment is NOT approved.", quotes: [valid.value ? "Deployment is NOT approved." : "invented evidence"],
                        consumedBytes: request.text?.utf8.count ?? 0))
        }
        defer { session.store.close() }
        let memory = session.memory!
        let entry = try session.store.put("fixture", Array("Deployment is NOT approved.".utf8), isText: true)
        await #expect(throws: AtlasRuntimeError("analysis_quote_not_in_source")) { try await memory.analyze(entry.id, goal: "approval") }
        #expect(memory.jobs[entry.id]!.processedBytes == 0 && memory.records.isEmpty)
        valid.value = true
        _ = try await memory.analyze(entry.id, goal: "")
        #expect(memory.jobs[entry.id]!.complete && memory.records.count == 1)
        await #expect(throws: AtlasRuntimeError("analysis_goal_already_pinned")) { try await memory.analyze(entry.id, goal: "different goal") }
    }

    @Test func analysisFailureAndCancellationKeepPriorProgress() async throws {
        let fail = Box(false)
        let session = try memoryFixture { request in
            if fail.value { var frame = AtlasRuntimeFrame(type: "reply"); frame.analysisError = "analysis_generation_failed"; return frame }
            fail.value = true
            return reply(.init(consumedBytes: request.text?.utf8.count ?? 0))
        }
        defer { session.store.close() }
        let memory = session.memory!
        let entry = try session.store.put("fixture", Array(String(repeating: "café 紅熊猫.\n", count: 10000).utf8), isText: true)
        await #expect(throws: AtlasRuntimeError.self) { try await memory.analyze(entry.id, goal: "find a decision") }
        let cursor = memory.jobs[entry.id]!.processedBytes
        #expect(cursor != 0 && cursor != entry.bytes)
        // A cancelled run context stops analysis before any pass.
        session.cancel(currentTask: false)
        await #expect(throws: CancellationError.self) { try await memory.analyze(entry.id, goal: "find a decision") }
        #expect(memory.jobs[entry.id]!.processedBytes == cursor)
    }

    @Test func rememberedFactsSurviveWindowSelection() async throws {
        let session = try memoryFixture { _ in Issue.record("remember should not invoke a model"); return reply(.init()) }
        defer { session.store.close() }
        let memory = session.memory!
        var source = ""
        for index in 0..<40 { source += "Fact \(index): retain exact identifier item-\(String(format: "%04d", index)).\n" }
        let entry = try session.store.put("fixture", Array(source.utf8), isText: true)
        for quote in source.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n") {
            _ = try await memory.execute(["operation": .string("remember"), "id": .string(entry.id), "quote": .string(String(quote))])
        }
        #expect(memory.view("unrelated").records.count < memory.records.count, "memory was not bounded")
        var seen: Set<String> = []
        var offset = 0
        while offset < memory.records.count {
            let page = memory.page("unrelated", offset: offset)
            #expect(!page.records.isEmpty, "pagination stopped before the end")
            if page.records.isEmpty { break }
            for note in page.records { seen.insert(note.id) }
            offset += page.records.count
        }
        #expect(seen.count == memory.records.count)
        let old = try await memory.execute(["operation": .string("read"), "id": .string("m1")])
        #expect(old.contains("item-0000"))
        await #expect(throws: AtlasRuntimeError.self) {
            try await memory.execute(["operation": .string("remember"), "id": .string(entry.id), "quote": .string("unverified")])
        }
        try memory.receipt("mcp", ["operation": .string("call"), "name": .string("create_item"), "server": .string("s1")], success: true)
        #expect(memory.records.count == seen.count && memory.view("").recentOperations?.count == 1 && memory.receipts[0].contains("create_item completed"))
    }

    @Test func mcpErrorResultIsNotRememberedAsSuccess() async throws {
        let session = try memoryFixture { _ in reply(.init()) }
        defer { session.store.close() }
        session.localToolOverride = { _, _ in #"{"isError":true,"evidence":{"text":"fixture failure"}}"# }
        _ = try await session.executeLocalTool("mcp", ["operation": .string("call")])
        #expect(session.previousError == "mcp_tool_reported_error", "server-reported error would be recorded as successful execution")
        // A failing local tool reports a fixed code, never server text.
        session.localToolOverride = nil
        let result = try await session.executeLocalTool("mcp", ["operation": .string("call"), "server": .string("absent")])
        #expect(session.previousError == "mcp_server_not_enabled" && result.contains(#""complete":false"#))
    }

    @Test func analysisFocusCannotReplaceOriginalUserGoal() async throws {
        let goal = "Summarize staging and production restrictions."
        let evidence = "Staging is permitted. Production is not approved."
        let session = try memoryFixture { request in
            #expect(request.goal == goal && request.focus == "staging", "a narrow model query replaced the original user goal")
            return reply(.init(text: evidence, quotes: [evidence], consumedBytes: request.text?.utf8.count ?? 0))
        }
        defer { session.store.close() }
        session.store.question = goal
        let entry = try session.store.put("fixture", Array(evidence.utf8), isText: true)
        _ = try await session.memory.analyze(entry.id, goal: "staging")
    }

    @Test func schemaFailsClosed() throws {
        #expect(!AtlasSchema.numbersRoundTrip(Array(#"{"id":9007199254740993}"#.utf8)))
        #expect(AtlasSchema.numbersRoundTrip(Array(#"{"id":42,"amount":0.1}"#.utf8)))
        for number in ["1e-999999999999", "1e999999999999", "1e-400", "9007199254740993"] {
            #expect(!AtlasSchema.numbersRoundTrip(Array(#"{"value":\#(number)}"#.utf8)), "unsafe numeric representation accepted: \(number)")
        }
        var schema = object(#"{"type":"object","properties":{"mode":{"type":"string","enum":["read"]},"count":{"type":"integer","minimum":1,"maximum":3}},"required":["mode"],"additionalProperties":false}"#)
        #expect(AtlasSchema.supported(schema, root: schema, depth: 0))
        #expect(AtlasSchema.validate(.object(["mode": .string("read"), "count": .number(2)]), schema, root: schema, depth: 0))
        for value in [#"{"mode":"write"}"#, #"{"count":1}"#, #"{"mode":"read","count":4}"#, #"{"mode":"read","extra":true}"#] {
            #expect(!AtlasSchema.validate(try AtlasJSON.parse(value), schema, root: schema, depth: 0), "invalid arguments accepted: \(value)")
        }
        schema["unevaluatedProperties"] = .bool(false)
        #expect(!AtlasSchema.supported(schema, root: schema, depth: 0))
    }

    @Test func schemaPatternsAreLimitedToRE2() {
        for pattern in ["^[a-z]+$", "(?P<name>x)", "a{2,3}?", "[[:alpha:]]+", #"\d+"#] {
            #expect(AtlasSchema.compile(pattern) != nil, "RE2 pattern rejected: \(pattern)")
        }
        for pattern in ["(?=x)", "(?!x)", "(?<=x)y", "(?<!x)y", "(?>x)", #"(a)\1"#, "a++", "a*+", "a?+", "a{2}+", #"\k<n>"#, #"x\Z"#] {
            #expect(AtlasSchema.compile(pattern) == nil, "non-RE2 pattern accepted: \(pattern)")
        }
        let schema = object(#"{"type":"object","properties":{"id":{"type":"string","pattern":"(?=secret)"}}}"#)
        #expect(!AtlasSchema.supported(schema, root: schema, depth: 0))
    }

    @Test func structuredContentIndentPreservesExactNumbers() throws {
        let indented = String(decoding: AtlasJSON.indent(Array(#"{"id":9007199254740993,"list":[1,{"a":[]}],"e":{}}"#.utf8))!, as: UTF8.self)
        #expect(indented == "{\n  \"id\": 9007199254740993,\n  \"list\": [\n    1,\n    {\n      \"a\": []\n    }\n  ],\n  \"e\": {}\n}")
    }

    @Test func goGlobMatching() {
        #expect(AtlasGlob.match("read_*", "read_archive"))
        #expect(AtlasGlob.match("r?ad_[a-c]*", "read_archive"))
        #expect(!AtlasGlob.match("read_*", "write_archive"))
        #expect(!AtlasGlob.match("[", "["))
        #expect(AtlasGlob.match("[^x]ead*", "read"))
    }
}
