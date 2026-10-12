// Native Atlas runtime: durable task memory (port of memory.go and the
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
// restore half of persistence.go). The append-only `task-memory.jsonl`
// journal uses the Go helper's exact event shapes.
import Foundation

let atlasAnalysisBytes = 16000
let atlasAnalysisBatch = 8
let atlasMaxAnalysisPasses = 4096
let atlasMaxMemoryBytes = 16 * 1024 * 1024

/// Derived notes are untrusted evidence, never instructions or authorization.
/// Exact excerpts and parent IDs let a later window recover their provenance.
final class AtlasTaskJournal {
    unowned let session: AtlasRuntimeSession
    var records: [AtlasRuntimeMemoryRecord] = []
    var receipts: [String] = []
    var jobs: [String: AtlasRuntimeAnalysisJob] = [:]
    var active = ""
    var passes = 0
    var bytes = 0
    var broken = false

    init(session: AtlasRuntimeSession) { self.session = session }

    var store: AtlasPayloadStore { session.store }
    var journalPath: String { store.files.path(AtlasWorkspaceFiles.journalName) }

    // MARK: Journal encoding (Go struct field order)

    static func json(_ source: AtlasRuntimeMemorySource) -> AtlasJSON {
        var fields: [(String, AtlasJSON)] = [("id", .string(source.id)), ("startByte", .int(source.startByte)), ("endByte", .int(source.endByte))]
        if let quote = source.quote, !quote.isEmpty { fields.append(("quote", .string(quote))) }
        return .fields(fields)
    }

    static func json(_ record: AtlasRuntimeMemoryRecord) -> AtlasJSON {
        var fields: [(String, AtlasJSON)] = [("id", .string(record.id)), ("text", .string(record.text))]
        if let sources = record.sources, !sources.isEmpty { fields.append(("sources", .array(sources.map(json)))) }
        if let parents = record.parents, !parents.isEmpty { fields.append(("parents", .strings(parents))) }
        return .fields(fields)
    }

    static func json(_ job: AtlasRuntimeAnalysisJob) -> AtlasJSON {
        var fields: [(String, AtlasJSON)] = [
            ("id", .string(job.id)), ("goal", .string(job.goal)), ("processedBytes", .int(job.processedBytes)),
            ("totalBytes", .int(job.totalBytes)), ("level", job.level.map(AtlasJSON.strings) ?? .null),
            ("next", job.next.map(AtlasJSON.strings) ?? .null), ("reduced", .int(job.reduced)), ("complete", .bool(job.complete))
        ]
        if let result = job.result, !result.isEmpty { fields.append(("result", .string(result))) }
        return .fields(fields)
    }

    static func json(_ view: AtlasRuntimeMemoryView) -> AtlasJSON {
        var fields: [(String, AtlasJSON)] = [("records", .array(view.records.map(json)))]
        if let operations = view.recentOperations, !operations.isEmpty { fields.append(("recentOperations", .strings(operations))) }
        fields.append(("totalRecords", .int(view.totalRecords)))
        fields.append(("analysisPasses", .int(view.analysisPasses)))
        if let active = view.active { fields.append(("active", json(active))) }
        return .fields(fields)
    }

    // MARK: Commit

    /// One append commits the note and its cursor together. Model-window resets
    /// never replay a completed source slice or an external MCP operation.
    func commit(_ record: AtlasRuntimeMemoryRecord?, _ job: AtlasRuntimeAnalysisJob?) throws {
        if broken || (record != nil && records.count >= 8192) { throw AtlasRuntimeError("task_memory_limit") }
        var event: [(String, AtlasJSON)] = []
        if let record { event.append(("record", Self.json(record))) }
        if let job { event.append(("job", Self.json(job))) }
        try append(.fields(event))
        if let record { records.append(record) }
        if let job { jobs[job.id] = job }
    }

    func append(_ event: AtlasJSON) throws {
        if broken { throw AtlasRuntimeError("task_memory_limit") }
        let data = event.goBytes
        guard !data.isEmpty, bytes + data.count + 1 <= atlasMaxMemoryBytes else { throw AtlasRuntimeError("task_memory_limit") }
        do {
            try store.files.appendJournal(data, sync: store.persistent)
        } catch let error as AtlasRuntimeError where error.code == "task_memory_write_failed_broken" {
            broken = true
            throw AtlasRuntimeError("task_memory_write_failed")
        }
        bytes += data.count + 1
    }

    func record(_ id: String) -> AtlasRuntimeMemoryRecord? { records.first { $0.id == id } }

    func receipt(_ name: String, _ args: [String: AtlasJSON], success: Bool) throws {
        var label = name
        for key in ["operation", "server"] {
            if let value = args[key]?.stringValue, !value.isEmpty { label += " " + AtlasUTF8.prefix(value, 80) }
        }
        let operation = args["operation"]?.stringValue
        if name == "mcp" && (operation == "call" || operation == "schema"), let value = args["name"]?.stringValue {
            label += " " + AtlasUTF8.prefix(value, 160)
        }
        let receipt = label + " " + (success ? "completed" : "reported an error; its remote outcome may be unknown")
        try append(.object(["operationReceipt": .string(receipt)]))
        receipts.append(receipt)
    }

    // MARK: Views

    func view(_ query: String) -> AtlasRuntimeMemoryView { page(query, offset: 0) }

    func page(_ query: String, offset: Int) -> AtlasRuntimeMemoryView {
        var view = AtlasRuntimeMemoryView(records: [], recentOperations: Array(receipts.suffix(8)), totalRecords: records.count, analysisPasses: passes)
        if view.recentOperations?.isEmpty == true { view.recentOperations = nil }
        if let job = jobs[active] {
            // The potentially large reduction queues stay outside the model window.
            view.active = AtlasRuntimeAnalysisJob(id: job.id, goal: "", processedBytes: job.processedBytes, totalBytes: job.totalBytes,
                                                  level: nil, next: nil, reduced: 0, complete: job.complete, result: job.result)
        }
        let terms = AtlasText.fields(AtlasText.goLower(query)).map { Array($0.utf8) }
        var ranked: [(index: Int, score: Int)] = []
        for (index, record) in records.enumerated() {
            let text = Array(AtlasText.goLower(record.text).utf8)
            var score = terms.filter { $0.count >= 3 && AtlasBytes.index(of: $0, in: text) != nil }.count
            if let active = view.active, record.id == active.result { score += 1000 }
            ranked.append((index, score))
        }
        // Stable: higher score first, then newer notes first.
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.index > $1.index }
        var remaining = 5000
        for candidate in ranked.dropFirst(offset) {
            if view.records.count == 6 || remaining < 400 { break }
            var record = records[candidate.index]
            record.text = AtlasUTF8.prefix(record.text, min(1600, remaining - 300))
            record.sources = nil // memory.read returns exact excerpts and parent links.
            record.parents = nil
            remaining -= record.text.utf8.count + 100
            view.records.append(record)
        }
        return view
    }

    // MARK: Tool

    nonisolated(nonsending) func execute(_ args: [String: AtlasJSON]) async throws -> String {
        try session.checkCancelled()
        let operation = args["operation"]?.stringValue ?? ""
        let id = args["id"]?.stringValue ?? ""
        var query = args["query"]?.stringValue ?? ""
        guard query.utf8.count <= 8000 else { throw AtlasRuntimeError("task_query_limit") }
        switch operation {
        case "search", "status":
            let offset = try integerArgument(args, "offset", 0, records.count)
            if query.isEmpty { query = store.question }
            let page = page(query, offset: offset)
            return jsonText(.object([
                "trust": .string("untrusted_data"), "memory": Self.json(page), "nextOffset": .int(offset + page.records.count),
                "hasMore": .bool(offset + page.records.count < records.count),
                "coverage": .string("Selected derived notes, not all evidence. Follow nextOffset for more notes; read note IDs to recover quotes and parent notes.")
            ]))
        case "read":
            guard let record = record(id) else { throw AtlasRuntimeError("unknown_memory_reference") }
            return jsonText(.object(["trust": .string("untrusted_data"), "record": Self.json(record)]))
        case "remember":
            let quote = args["quote"]?.stringValue ?? ""
            guard !quote.isEmpty, quote.utf8.count <= 2000 else { throw AtlasRuntimeError("memory_quote_required_max_2000_bytes") }
            let (data, entry) = try store.data(id)
            guard entry.text, entry.kind != "schema" else { throw AtlasRuntimeError("memory_requires_source_text") }
            let quoted = Array(quote.utf8)
            guard let position = AtlasBytes.index(of: quoted, in: data) else { throw AtlasRuntimeError("memory_quote_not_in_source") }
            if let existing = records.first(where: { $0.text == quote && $0.sources?.count == 1 && $0.sources?[0].id == id }) {
                return jsonText(.object(["trust": .string("untrusted_data"), "record": Self.json(existing)]))
            }
            let record = AtlasRuntimeMemoryRecord(id: "m\(records.count + 1)", text: quote,
                sources: [AtlasRuntimeMemorySource(id: id, startByte: position, endByte: position + quoted.count, quote: quote)])
            try commit(record, nil)
            return jsonText(.object(["trust": .string("untrusted_data"), "record": Self.json(record)]))
        case "analyze":
            return try await analyze(id, goal: query)
        default:
            throw AtlasRuntimeError("unknown_memory_operation")
        }
    }

    nonisolated(nonsending) func analyze(_ id: String, goal requestedGoal: String) async throws -> String {
        try session.checkCancelled()
        let (data, entry) = try store.data(id)
        guard entry.text, entry.kind != "schema" else { throw AtlasRuntimeError("memory_requires_source_text") }
        var job = jobs[id]
        var goal = requestedGoal
        if goal.isEmpty { goal = job?.goal ?? store.question }
        if let job, goal != job.goal { throw AtlasRuntimeError("analysis_goal_already_pinned") }
        if job == nil {
            let created = AtlasRuntimeAnalysisJob(id: id, goal: goal, processedBytes: 0, totalBytes: data.count, level: [], next: [],
                                                  reduced: 0, complete: false, result: nil)
            try commit(nil, created)
            job = created
        }
        guard var current = job else { throw AtlasRuntimeError("analysis_job_missing") }
        active = id
        var batch = 0
        while batch < atlasAnalysisBatch && !current.complete {
            batch += 1
            try session.checkCancelled()
            var next = current
            next.level = current.level ?? []
            next.next = current.next ?? []
            var request = AtlasRuntimeAnalysisRequest(phase: "", goal: goal, focus: nil, id: id, startByte: 0, totalBytes: data.count, text: nil, records: nil)
            if !store.question.isEmpty {
                request.goal = store.question
                if goal != request.goal { request.focus = goal }
            }
            var offered: [UInt8] = []
            if current.processedBytes < data.count {
                request.phase = "extract"
                var start = max(0, current.processedBytes - 320)
                while start < current.processedBytes && !AtlasUTF8.isRuneStart(data[start]) { start += 1 }
                request.startByte = start
                offered = Array(AtlasUTF8.prefix(String(decoding: data[start...], as: UTF8.self), atlasAnalysisBytes).utf8)
                request.text = String(decoding: offered, as: UTF8.self)
            } else {
                if next.reduced == next.level!.count {
                    next.level = next.next; next.next = []; next.reduced = 0
                }
                if next.level!.count <= 1 {
                    next.complete = true
                    if next.level!.count == 1 { next.result = next.level![0] }
                    try commit(nil, next)
                    current = next
                    break
                }
                request.phase = "merge"
                let level = next.level!
                request.records = level[next.reduced..<min(next.reduced + 4, level.count)].map { recordID in
                    var record = self.record(recordID)!
                    record.sources = nil; record.parents = nil
                    return record
                }
                // Carry a single remaining node to the next level without inference.
                if request.records!.count == 1 {
                    next.next!.append(request.records![0].id)
                    next.reduced += 1
                    try commit(nil, next)
                    current = next
                    continue
                }
            }
            guard passes < atlasMaxAnalysisPasses else { throw AtlasRuntimeError("analysis_pass_limit") }
            passes += 1
            var frame = AtlasRuntimeFrame(type: "analysis")
            frame.step = session.step
            frame.analysis = request
            let reply = try await session.exchange(frame)
            if let error = reply.analysisError, !error.isEmpty { throw AtlasRuntimeError("analysis_generation_failed_checkpoint_retained") }
            guard let result = reply.analysisResult, (reply.toolCalls ?? []).isEmpty, result.text.utf8.count <= 2400, result.quotes.count <= 4 else {
                throw AtlasRuntimeError("invalid_analysis_result")
            }
            var record: AtlasRuntimeMemoryRecord? = AtlasRuntimeMemoryRecord(id: "m\(records.count + 1)", text: result.text)
            if request.phase == "extract" {
                guard result.consumedBytes > current.processedBytes - request.startByte, result.consumedBytes <= offered.count,
                      result.consumedRecords == 0, AtlasUTF8.isValid(offered[..<result.consumedBytes]),
                      result.text.isEmpty || !result.quotes.isEmpty else {
                    throw AtlasRuntimeError("invalid_analysis_coverage")
                }
                let consumed = Array(offered[..<result.consumedBytes])
                for quote in result.quotes {
                    let quoted = Array(quote.utf8)
                    guard !quoted.isEmpty, quoted.count <= 800, let position = AtlasBytes.index(of: quoted, in: consumed) else {
                        throw AtlasRuntimeError("analysis_quote_not_in_source")
                    }
                    record!.sources = (record!.sources ?? []) + [AtlasRuntimeMemorySource(id: id, startByte: request.startByte + position,
                        endByte: request.startByte + position + quoted.count, quote: quote)]
                }
                next.processedBytes = request.startByte + result.consumedBytes
                if !result.text.isEmpty { next.level!.append(record!.id) } else { record = nil }
            } else {
                let offeredRecords = request.records ?? []
                guard result.consumedRecords >= 2, result.consumedRecords <= offeredRecords.count, result.consumedBytes == 0,
                      !result.text.isEmpty, result.quotes.isEmpty else {
                    throw AtlasRuntimeError("invalid_analysis_merge")
                }
                record!.parents = offeredRecords[..<result.consumedRecords].map(\.id)
                next.reduced += result.consumedRecords
                next.next!.append(record!.id)
            }
            try commit(record, next)
            current = next
        }
        return jsonText(.object([
            "trust": .string("untrusted_data"), "payloadID": .string(id), "processedBytes": .int(current.processedBytes),
            "totalBytes": .int(current.totalBytes), "complete": .bool(current.complete), "memory": Self.json(view(goal)),
            "coverage": .string("Processed bytes were presented to bounded extraction passes. Derived summaries can omit details; this is not proof of exhaustive understanding. Recover exact evidence with memory.read and payload.read/search.")
        ]))
    }

    // MARK: Restore (persistence.go)

    func restore() throws {
        let data = try store.files.readJournal(limit: atlasMaxMemoryBytes)
        // A process can die partway through the final append. Only complete lines
        // were committed; discard that tail before accepting any new checkpoint.
        let committed = (data.lastIndex(of: 0x0A) ?? -1) + 1
        var sources: [String: [UInt8]] = [:]
        // bufio.Scanner semantics: every committed line, including an empty one, must decode.
        for line in data[..<committed].split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            guard line.count <= 256 * 1024, let event = try? AtlasJSON.parse(line), event.dictionary != nil else {
                throw AtlasRuntimeError("invalid_checkpoint")
            }
            if let value = event["record"], value != .null {
                guard let record = Self.decodeRecord(value), records.count < 8192, record.id == "m\(records.count + 1)",
                      record.text.utf8.count <= 2400, (record.sources?.count ?? 0) <= 4, (record.parents?.count ?? 0) <= 4 else {
                    throw AtlasRuntimeError("invalid_checkpoint")
                }
                for source in record.sources ?? [] {
                    let quote = Array((source.quote ?? "").utf8)
                    guard let entry = store.entries[source.id], entry.text, entry.kind != "schema", source.startByte >= 0,
                          source.endByte > source.startByte, source.endByte <= entry.bytes, source.endByte - source.startByte == quote.count else {
                        throw AtlasRuntimeError("invalid_checkpoint")
                    }
                    if sources[source.id] == nil {
                        guard let (content, _) = try? store.data(source.id) else { throw AtlasRuntimeError("invalid_checkpoint") }
                        sources[source.id] = content
                    }
                    guard Array(sources[source.id]![source.startByte..<source.endByte]) == quote else { throw AtlasRuntimeError("invalid_checkpoint") }
                }
                for parent in record.parents ?? [] where self.record(parent) == nil { throw AtlasRuntimeError("invalid_checkpoint") }
                records.append(record)
            }
            if let receipt = event["operationReceipt"]?.stringValue, !receipt.isEmpty {
                guard receipt.utf8.count <= 1000, receipts.count <= 256 else { throw AtlasRuntimeError("invalid_checkpoint") }
                receipts.append(receipt)
            }
            if let value = event["job"], value != .null {
                guard let job = Self.decodeJob(value), let entry = store.entries[job.id], entry.text, entry.kind != "schema",
                      job.totalBytes == entry.bytes, job.processedBytes >= 0, job.processedBytes <= job.totalBytes,
                      job.reduced >= 0, job.reduced <= (job.level?.count ?? 0), job.goal.utf8.count <= 8000,
                      (job.level?.count ?? 0) + (job.next?.count ?? 0) <= 8192, !job.complete || job.processedBytes == job.totalBytes else {
                    throw AtlasRuntimeError("invalid_checkpoint")
                }
                for id in (job.level ?? []) + (job.next ?? []) where record(id) == nil { throw AtlasRuntimeError("invalid_checkpoint") }
                if let result = job.result, !result.isEmpty, record(result) == nil { throw AtlasRuntimeError("invalid_checkpoint") }
                jobs[job.id] = job
                active = job.id
            }
        }
        guard !active.isEmpty else { throw AtlasRuntimeError("no_analysis_checkpoint") }
        if committed != data.count {
            try store.files.truncateJournal(to: committed)
        }
        bytes = committed
        // Pass and orchestration budgets start afresh for the explicitly resumed
        // attempt; the retained journal/record quotas still span the whole task.
    }

    static func decodeRecord(_ value: AtlasJSON) -> AtlasRuntimeMemoryRecord? {
        guard let id = value["id"]?.stringValue, let text = value["text"]?.stringValue ?? (value["text"] == nil ? "" : nil) else { return nil }
        var record = AtlasRuntimeMemoryRecord(id: id, text: text)
        if let list = value["sources"]?.arrayValue {
            record.sources = []
            for source in list {
                guard let sourceID = source["id"]?.stringValue, let start = AtlasPayloadStore.int(source["startByte"] ?? .number(0)),
                      let end = AtlasPayloadStore.int(source["endByte"] ?? .number(0)) else { return nil }
                record.sources!.append(AtlasRuntimeMemorySource(id: sourceID, startByte: start, endByte: end, quote: source["quote"]?.stringValue ?? ""))
            }
        }
        if let list = value["parents"]?.arrayValue {
            let parents = list.compactMap(\.stringValue)
            guard parents.count == list.count else { return nil }
            record.parents = parents
        }
        return record
    }

    static func decodeJob(_ value: AtlasJSON) -> AtlasRuntimeAnalysisJob? {
        func strings(_ key: String) -> [String]?? {
            guard let list = value[key], list != .null else { return .some(nil) }
            guard let array = list.arrayValue else { return nil }
            let values = array.compactMap(\.stringValue)
            return values.count == array.count ? .some(values) : nil
        }
        guard let id = value["id"]?.stringValue, let processed = AtlasPayloadStore.int(value["processedBytes"] ?? .number(0)),
              let total = AtlasPayloadStore.int(value["totalBytes"] ?? .number(0)), let reduced = AtlasPayloadStore.int(value["reduced"] ?? .number(0)),
              let level = strings("level"), let next = strings("next") else { return nil }
        return AtlasRuntimeAnalysisJob(id: id, goal: value["goal"]?.stringValue ?? "", processedBytes: processed, totalBytes: total,
                                       level: level ?? [], next: next ?? [], reduced: reduced, complete: value["complete"]?.boolValue ?? false,
                                       result: value["result"]?.stringValue)
    }
}
