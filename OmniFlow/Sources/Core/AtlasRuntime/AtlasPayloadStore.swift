// Native Atlas runtime: run-scoped evidence store (port of payload.go and the
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
// payload half of persistence.go). On-disk format is identical to the Go
// helper: `pN.gz` gzip files plus `payload-index.json` (version 1), all 0600
// inside a 0700 directory, so durable task workspaces survive the cutover.
import CryptoKit
import Foundation

let atlasMaxPayloadBytes = 16 * 1024 * 1024
let atlasMaxStoreBytes = 64 * 1024 * 1024
let atlasChunkBytes = 2400

/// Payloads never become instructions. Compression is a disk concern; the
/// model receives ordinary UTF-8 evidence and opaque, run-scoped references.
public final class AtlasPayloadEntry {
    public var kind: String
    public let id: String
    public let source: String
    public let sha256: String
    public let bytes: Int
    public internal(set) var chunks: Int
    public let suspicious: Bool
    public let text: Bool
    public internal(set) var viewed: Int
    var offsets: [Int]
    var seen: Set<Int>

    init(kind: String, id: String, source: String, sha256: String, bytes: Int, chunks: Int, suspicious: Bool, text: Bool,
         viewed: Int = 0, offsets: [Int] = [], seen: Set<Int> = []) {
        self.kind = kind; self.id = id; self.source = source; self.sha256 = sha256; self.bytes = bytes
        self.chunks = chunks; self.suspicious = suspicious; self.text = text; self.viewed = viewed
        self.offsets = offsets; self.seen = seen
    }

    var json: AtlasJSON {
        .fields([("kind", .string(kind)), ("id", .string(id)), ("source", .string(source)), ("sha256", .string(sha256)),
                 ("bytes", .int(bytes)), ("chunks", .int(chunks)), ("suspicious", .bool(suspicious)), ("text", .bool(text)),
                 ("fullyReadChunks", .int(viewed))])
    }

    /// Chunk boundaries prefer record/paragraph ends and never split a scalar.
    static func chunkOffsets(_ data: [UInt8]) -> [Int] {
        var offsets = [0]
        var start = 0
        while start < data.count {
            var end = min(start + atlasChunkBytes, data.count)
            if end < data.count {
                if let newline = data[start..<end].lastIndex(of: 0x0A), newline - start >= atlasChunkBytes / 2 {
                    end = newline + 1
                }
                while end > start && !AtlasUTF8.isRuneStart(data[end]) { end -= 1 }
            }
            offsets.append(end)
            start = end
        }
        return offsets
    }
}

public final class AtlasPayloadStore {
    var persistent = false
    var question = ""
    /// All workspace file IO (the encryption-at-rest seam).
    let files: AtlasWorkspaceFiles
    public var directory: String { files.directory }
    var entries: [String: AtlasPayloadEntry] = [:]
    var order: [String] = []
    var used = 0

    /// A missing directory creates a private temporary one, like the Go helper.
    public init(directory: String?) throws {
        files = try AtlasWorkspaceFiles(directory: directory)
    }

    func path(_ name: String) -> String { files.path(name) }

    public func close() {
        files.unlock()
        if !persistent { files.removeAll() }
    }

    @discardableResult
    func put(_ source: String, _ data: [UInt8], isText: Bool) throws -> AtlasPayloadEntry {
        guard data.count <= atlasMaxPayloadBytes, used + data.count <= atlasMaxStoreBytes, entries.count < 128 else {
            throw AtlasRuntimeError("payload_quota_exceeded")
        }
        if isText && !AtlasUTF8.isValid(data) { throw AtlasRuntimeError("invalid_utf8_payload") }
        let id = "p\(order.count + 1)"
        var suspicious = false
        var offsets: [Int] = []
        if isText {
            suspicious = AtlasPromptInjection.detect(String(decoding: data, as: UTF8.self))
            offsets = AtlasPayloadEntry.chunkOffsets(data)
        }
        let entry = AtlasPayloadEntry(kind: isText ? "text" : "binary", id: id, source: source, sha256: Self.digest(data),
                                      bytes: data.count, chunks: isText ? offsets.count - 1 : 0, suspicious: suspicious, text: isText,
                                      offsets: offsets)
        try files.writePayload(id, data)
        entries[id] = entry
        order.append(id)
        used += data.count
        try persistIndex()
        return entry
    }

    static func digest(_ data: [UInt8]) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func data(_ id: String) throws -> ([UInt8], AtlasPayloadEntry) {
        guard Self.validStoredID(id), let entry = entries[id] else { throw AtlasRuntimeError("unknown_payload_reference") }
        guard let data = try? files.readPayload(entry.id, limit: atlasMaxPayloadBytes),
              data.count == entry.bytes, Self.digest(data) == entry.sha256 else {
            throw AtlasRuntimeError("payload_integrity_failed")
        }
        return (data, entry)
    }

    static func validStoredID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.first == UInt8(ascii: "p"), (2...4).contains(bytes.count) else { return false }
        return bytes.dropFirst().allSatisfy { (0x30...0x39).contains($0) }
    }

    /// Coverage concerns bytes delivered, not upstream completeness or model
    /// comprehension. In particular, reading the last chunk is not reading them all.
    static func coverage(_ result: inout [(String, AtlasJSON)], _ entry: AtlasPayloadEntry, available: Bool, start: Int, end: Int) {
        let complete = available && entry.text && start == 0 && end == entry.bytes
        let allRead = available && entry.text && entry.viewed == entry.chunks
        result.append(("completeText", .bool(complete)))
        result.append(("allChunksRead", .bool(allRead)))
        var coverage = "Payload text is unavailable in this response."
        if !entry.text {
            coverage = "Binary payload metadata only. No decoded text is included."
        } else if complete {
            coverage = "Complete returned payload text is included in this response; there are no omitted chunks for this payload."
        } else if allRead {
            coverage = "All chunks of this payload have been delivered across this run. This response contains only the indicated byte range."
        } else if available {
            coverage = "Partial payload text. Only the indicated byte range is included; read remaining chunks when complete payload coverage is needed."
        }
        if entry.kind == "schema" {
            coverage = "Schema metadata only; this describes a tool, not a tool execution result. " + coverage
        }
        result.append(("coverage", .string(coverage)))
    }

    func preview(_ entry: AtlasPayloadEntry) -> String {
        // Go builds a map, so keys are emitted sorted; `.object` reproduces that.
        var result: [(String, AtlasJSON)] = []
        var available = false, start = 0, end = 0
        if entry.text, let (data, _) = try? self.data(entry.id) {
            available = true
            if entry.chunks > 0 {
                var chunk = 0
                if entry.kind != "schema" && entry.chunks > 1 && !question.isEmpty {
                    let (best, matched) = Self.rankChunk(data, entry.offsets, question)
                    chunk = best
                    result.append(("retrieval", .object([
                        "method": .string("local keyword relevance"), "scannedBytes": .int(entry.bytes), "scannedChunks": .int(entry.chunks),
                        "matchingChunks": .int(matched), "returnedChunks": .int(1),
                        "coverage": .string("All chunks were searched for question keywords. Only the best matching chunk is shown. This does not prove absent facts or full-document understanding.")
                    ])))
                }
                result.append(("chunk", .int(chunk)))
                start = entry.offsets[chunk]; end = entry.offsets[chunk + 1]
                entry.seen.insert(chunk)
                entry.viewed = entry.seen.count
            }
            result.append(("startByte", .int(start)))
            result.append(("endByte", .int(end)))
            result.append(("text", .string(String(decoding: data[start..<end], as: UTF8.self))))
        }
        result.append(("trust", .string("untrusted_data")))
        result.append(("payload", entry.json))
        Self.coverage(&result, entry, available: available, start: start, end: end)
        return jsonText(.object(Dictionary(result, uniquingKeysWith: { _, last in last })))
    }

    /// Host-side keyword relevance (BM25-style IDF over chunk hits). Rare
    /// matching terms outweigh boilerplate repeated throughout a large result.
    static func rankChunk(_ data: [UInt8], _ offsets: [Int], _ question: String) -> (Int, Int) {
        var terms: [[UInt8]] = []
        var seen: Set<String> = []
        for term in AtlasText.words(AtlasText.goLower(question)) {
            if term.unicodeScalars.count < 3 || term.utf8.count > 80 || AtlasText.stopWords.contains(term) || seen.contains(term) { continue }
            seen.insert(term)
            terms.append(Array(term.utf8))
            if terms.count == 32 { break }
        }
        let count = offsets.count - 1
        var hits = [[Bool]](repeating: [], count: count)
        var documents = [Int](repeating: 0, count: terms.count)
        var matched = 0
        for chunk in 0..<count {
            let text = AtlasText.goLowerBytes(data[offsets[chunk]..<offsets[chunk + 1]])
            hits[chunk] = [Bool](repeating: false, count: terms.count)
            var any = false
            for (index, word) in terms.enumerated() where AtlasBytes.index(of: word, in: text) != nil {
                hits[chunk][index] = true
                documents[index] += 1
                any = true
            }
            if any { matched += 1 }
        }
        var best = 0, highest = 0.0
        for (chunk, matches) in hits.enumerated() {
            var score = 0.0
            for (index, hit) in matches.enumerated() where hit {
                score += log(1 + (Double(count - documents[index]) + 0.5) / (Double(documents[index]) + 0.5))
            }
            if score > highest { best = chunk; highest = score }
        }
        return (best, matched)
    }

    func execute(_ args: [String: AtlasJSON]) throws -> String {
        let operation = args["operation"]?.stringValue ?? ""
        if operation == "list" {
            let start = try integerArgument(args, "offset", 0, order.count)
            let end = min(start + 8, order.count)
            let listed = order[start..<end].map { entries[$0]!.json }
            return jsonText(.object(["trust": .string("untrusted_data"), "payloads": .array(listed), "nextOffset": .int(end), "total": .int(order.count)]))
        }
        let (data, entry) = try self.data(args["id"]?.stringValue ?? "")
        guard entry.text else { throw AtlasRuntimeError("binary_payload_has_no_text_chunks") }
        if operation == "read" {
            guard let chunk = try? integerArgument(args, "offset", 0, max(0, entry.chunks - 1)), entry.chunks > 0 else {
                throw AtlasRuntimeError("invalid_chunk")
            }
            entry.seen.insert(chunk)
            entry.viewed = entry.seen.count
            let start = entry.offsets[chunk], end = entry.offsets[chunk + 1]
            var result: [(String, AtlasJSON)] = [
                ("trust", .string("untrusted_data")), ("payload", entry.json), ("chunk", .int(chunk)), ("startByte", .int(start)),
                ("endByte", .int(end)), ("text", .string(String(decoding: data[start..<end], as: UTF8.self))),
                ("nextChunk", .int(chunk + 1)), ("hasMore", .bool(chunk + 1 < entry.chunks))
            ]
            Self.coverage(&result, entry, available: true, start: start, end: end)
            return jsonText(.object(Dictionary(result, uniquingKeysWith: { _, last in last })))
        }
        guard operation == "search" else { throw AtlasRuntimeError("unknown_payload_operation") }
        let query = Array((args["query"]?.stringValue ?? "").utf8)
        guard !query.isEmpty, query.count <= 256 else { throw AtlasRuntimeError("search_query_required_max_256_bytes") }
        let start = try integerArgument(args, "offset", 0, entry.bytes)
        // Literal byte search spans chunk boundaries and scans the full remaining
        // source. It does not interpret a query as a regexp, command, or glob path.
        var matches: [AtlasJSON] = []
        var total = 0, next = entry.bytes, position = start
        while position <= data.count - query.count {
            try Task.checkCancellation()
            guard let found = AtlasBytes.index(of: query, in: data, from: position) else { break }
            position = found
            total += 1
            if matches.count < 5 {
                var chunk = 0
                while chunk + 1 < entry.offsets.count - 1 && entry.offsets[chunk + 1] <= position { chunk += 1 }
                var left = max(0, position - 160), right = min(data.count, position + query.count + 320)
                while left < position && !AtlasUTF8.isRuneStart(data[left]) { left += 1 }
                while right < data.count && !AtlasUTF8.isRuneStart(data[right]) { right += 1 }
                matches.append(.object(["chunk": .int(chunk), "startByte": .int(position), "excerptStartByte": .int(left),
                                        "excerptEndByte": .int(right), "text": .string(String(decoding: data[left..<right], as: UTF8.self))]))
                next = position + query.count
            }
            position += query.count
        }
        return jsonText(.object([
            "trust": .string("untrusted_data"), "payload": entry.json, "matches": .array(matches), "totalMatchesFromOffset": .int(total),
            "scannedStartByte": .int(start), "scannedEndByte": .int(entry.bytes), "nextOffset": .int(next), "hasMore": .bool(total > matches.count),
            "coverage": .string("Every byte from scannedStartByte through scannedEndByte was searched. fullyReadChunks counts full chunks shown to the model, NOT chunks searched. Matching excerpts are not full-document comprehension.")
        ]))
    }

    // MARK: Persistence (persistence.go)

    /// Connection credentials and MCP grants are never serialized here. Durable
    /// workspaces contain source evidence; resuming restores local analysis only.
    func persistIndex() throws {
        guard persistent else { return }
        let index = AtlasJSON.fields([("version", .int(1)), ("question", .string(question)),
                                      ("entries", .array(order.map { entries[$0]!.json }))])
        try files.writeIndex(index.goBytes)
    }

    func enablePersistence(resume: Bool) throws {
        // Even a failed lock/restore must never delete somebody else's workspace.
        persistent = true
        try files.lock()
        if !resume {
            if files.indexExists { throw AtlasRuntimeError("checkpoint_already_exists") }
            return try persistIndex()
        }
        let indexData = try files.readIndex(limit: 256 * 1024)
        guard let index = try? AtlasJSON.parse(indexData), index["version"]?.doubleValue == 1, index["question"]?.stringValue == question,
              let list = index["entries"]?.arrayValue, list.count <= 128 else {
            throw AtlasRuntimeError("invalid_checkpoint")
        }
        for (position, value) in list.enumerated() {
            guard let id = value["id"]?.stringValue, id == "p\(position + 1)", let kind = value["kind"]?.stringValue,
                  let bytes = Self.int(value["bytes"]), bytes >= 0, bytes <= atlasMaxPayloadBytes,
                  ["schema", "text", "binary"].contains(kind), let isText = value["text"]?.boolValue, isText == (kind != "binary"),
                  let sha = value["sha256"]?.stringValue, sha.utf8.count == 64, used + bytes <= atlasMaxStoreBytes else {
                throw AtlasRuntimeError("invalid_checkpoint")
            }
            let entry = AtlasPayloadEntry(kind: kind, id: id, source: value["source"]?.stringValue ?? "", sha256: sha, bytes: bytes,
                                          chunks: 0, suspicious: value["suspicious"]?.boolValue ?? false, text: isText)
            entries[id] = entry
            // data() verifies the gzip size and SHA-256 before rebuilding offsets.
            guard let (content, _) = try? self.data(id), content.count == bytes, !isText || AtlasUTF8.isValid(content) else {
                throw AtlasRuntimeError("invalid_checkpoint")
            }
            entry.viewed = 0 // Do not claim that a previous process read all text.
            entry.offsets = isText ? AtlasPayloadEntry.chunkOffsets(content) : [0]
            entry.chunks = entry.offsets.count - 1
            order.append(id)
            used += bytes
        }
    }

    static func int(_ value: AtlasJSON?) -> Int? {
        guard let number = value?.doubleValue, number == number.rounded(), Swift.abs(number) < 9.0e15 else { return nil }
        return Int(number)
    }
}

/// Go `integerArgument`: an absent value is the minimum; otherwise an
/// integral float64 within the inclusive bounds.
func integerArgument(_ args: [String: AtlasJSON], _ key: String, _ minimum: Int, _ maximum: Int) throws -> Int {
    guard let value = args[key], value != .null else { return minimum }
    guard let number = value.doubleValue, number >= Double(minimum), number <= Double(maximum), number == number.rounded(.towardZero) else {
        throw AtlasRuntimeError("invalid_offset")
    }
    return Int(number)
}

/// Port of the Atlas SDK's `security.DetectPromptInjection` patterns. RE2's
/// `\s` is ASCII-only, so it is spelled out explicitly here.
enum AtlasPromptInjection {
    private static let space = "[\\t\\n\\f\\r ]"
    private static let patterns: [NSRegularExpression] = [
        "ignore\(space)+(all\(space)+)?(previous|above)\(space)+(instructions|prompts|rules)",
        "disregard\(space)+(all\(space)+)?(previous|above)",
        "forget\(space)+(all\(space)+)?(previous|above)",
        "you\(space)+are\(space)+now\(space)+",
        "pretend\(space)+(you\(space)+are|to\(space)+be)",
        "act\(space)+as\(space)+(if\(space)+you\(space)+are|a)",
        "jailbreak",
        "DAN\(space)*:",
        "override\(space)+(your\(space)+)?(programming|instructions)"
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func detect(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}
