import Foundation
import CoreFoundation

/// Text returned by the host payload store, not a claim about the completeness
/// of an upstream document. Search excerpts retain that distinction explicitly.
struct AtlasSourceEvidence: Sendable, Equatable {
    let id: String
    let source: String
    let sha256: String
    let bytes: Int
    let chunks: Int
    let chunk: Int?
    let startByte: Int?
    let endByte: Int?
    let text: String
    let isSearchExcerpt: Bool
    let isError: Bool

    var completeText: Bool {
        !isSearchExcerpt && startByte == 0 && endByte == bytes && text.utf8.count == bytes
    }

    /// Accept only the host's known result envelopes. JSON found inside source
    /// text is never parsed as host metadata, instructions, or another source.
    static func records(from content: String) -> [Self] {
        guard let object = object(from: content) else { return [] }
        var result: [Self] = []
        var remaining = 64 * 1024
        collect(object, inheritedError: false, depth: 0, remaining: &remaining, result: &result)
        return result
    }

    /// Compact whole evidence first; only then shorten its actual text. Numeric
    /// byte ranges describe precisely what remains, never a JSON-prefix length.
    static func compact(_ content: String, maximumTextBytes: Int) -> String {
        let limit = max(0, min(64 * 1024, maximumTextBytes))
        let records = records(from: content)
        var value: [String: Any] = ["trust": "untrusted_data", "contextProjection": true]
        if let original = object(from: content) {
            if let error = original["isError"] as? Bool { value["isError"] = error }
            // Preserve an actual error without retaining a large response or
            // turning an error into an empty successful result.
            for key in ["error", "message"] {
                if let text = original[key] as? String { value[key] = utf8Prefix(text, limit: 400) }
            }
        }
        if !records.isEmpty {
            let completeFits = records.reduce(0) { $0 + $1.text.utf8.count } <= limit
            let share = limit / records.count
            value["evidence"] = records.map { $0.projection(maximumTextBytes: completeFits ? $0.text.utf8.count : share) }
            value["coverage"] = "The included source text and byte ranges are authoritative for this working window. Omitted text remains in the payload store. Complete payload text does not establish that an upstream document was retrieved in full."
        } else {
            value["bodyOmitted"] = true
            value["completeText"] = false
            value["coverage"] = "Tool response omitted to fit this working window. This is not an empty result or a completed source read. Use retained payload references or repeat the relevant permitted lookup."
            if let original = object(from: content), let payload = original["payload"] as? [String: Any] {
                value["payload"] = payloadMetadata(payload)
                if payload["kind"] as? String == "schema", let text = original["text"] as? String {
                    value["schemaExcerpt"] = utf8Prefix(text, limit: limit)
                    value["coverage"] = "Parameter-definition excerpt only; not tool execution evidence."
                }
                if original["matches"] is [Any] {
                    for key in ["scannedStartByte", "scannedEndByte", "totalMatchesFromOffset", "nextOffset"] {
                        if let number = integer(original[key], maximum: 16 * 1024 * 1024) { value[key] = number }
                    }
                    if let more = original["hasMore"] as? Bool { value["hasMore"] = more }
                    value["matches"] = [] as [String]
                    value["coverage"] = "Search summary only; no source text is included. Scanning is not a full source read."
                }
            }
        }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"trust":"untrusted_data","bodyOmitted":true,"completeText":false}"#
    }

    private func projection(maximumTextBytes: Int) -> [String: Any] {
        let included = Self.utf8Prefix(text, limit: maximumTextBytes)
        let includedEnd = startByte.map { $0 + included.utf8.count }
        let whole = !isSearchExcerpt && startByte == 0 && includedEnd == bytes && included.utf8.count == bytes
        var value: [String: Any] = [
            "payload": ["id": id, "source": Self.utf8Prefix(source, limit: 240), "sha256": sha256, "kind": "text", "bytes": bytes, "chunks": chunks],
            "text": included, "completeText": whole, "isSearchExcerpt": isSearchExcerpt, "isError": isError,
            "coverage": isSearchExcerpt ? "Search excerpt only; not a full source read." :
                (whole ? "Complete returned payload text is included in this working window." : "Only the included source-text range is in this working window. Remaining text is stored locally."),
        ]
        if let chunk { value["chunk"] = chunk }
        if let startByte, let includedEnd {
            value["startByte"] = startByte
            value["endByte"] = includedEnd
            if isSearchExcerpt {
                value["excerptStartByte"] = startByte
                value["excerptEndByte"] = includedEnd
            }
        }
        // Cumulative helper delivery counts are deliberately not copied: Swift
        // may be omitting bytes before they reach this model context.
        return value
    }

    private static func collect(_ object: [String: Any], inheritedError: Bool, depth: Int,
                                remaining: inout Int, result: inout [Self]) {
        guard depth <= 4, result.count < 8 else { return }
        let isError = inheritedError || object["isError"] as? Bool == true
        if let payload = object["payload"] as? [String: Any],
           payload["kind"] as? String != "schema", payload["kind"] as? String != "binary",
           payload["text"] as? Bool != false,
           let id = payload["id"] as? String, id.range(of: #"^p[0-9]{1,3}$"#, options: .regularExpression) != nil,
           let source = payload["source"] as? String, source.utf8.count <= 8_192,
           let hash = payload["sha256"] as? String, hash.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
           let bytes = integer(payload["bytes"], maximum: 16 * 1024 * 1024),
           let chunks = integer(payload["chunks"], maximum: 16 * 1024) {
            func record(_ values: [String: Any], excerpt: Bool) -> Self? {
                guard let text = values["text"] as? String else { return nil }
                let originalLength = text.utf8.count
                var start = integer(values[excerpt ? "excerptStartByte" : "startByte"], maximum: bytes)
                var end = integer(values[excerpt ? "excerptEndByte" : "endByte"], maximum: bytes)
                if start == nil, end == nil, !excerpt, values["completeText"] as? Bool == true, originalLength == bytes {
                    start = 0; end = bytes
                }
                if start == nil || end == nil || end! < start! || end! - start! != originalLength {
                    start = nil; end = nil
                }
                let included = utf8Prefix(text, limit: remaining)
                if let first = start { end = first + included.utf8.count }
                let index = integer(values["chunk"], maximum: max(0, chunks - 1))
                return Self(id: id, source: source, sha256: hash, bytes: bytes, chunks: chunks, chunk: index,
                            startByte: start, endByte: end, text: included, isSearchExcerpt: excerpt, isError: isError)
            }
            if let text = record(object, excerpt: object["isSearchExcerpt"] as? Bool == true) {
                remaining -= text.text.utf8.count
                result.append(text)
            } else if let matches = object["matches"] as? [[String: Any]] {
                for match in matches.prefix(5) where result.count < 8 {
                    if let text = record(match, excerpt: true) {
                        remaining -= text.text.utf8.count
                        result.append(text)
                    }
                }
            }
            return
        }
        for key in ["evidence", "page"] {
            if let child = object[key] as? [String: Any] {
                collect(child, inheritedError: isError, depth: depth + 1, remaining: &remaining, result: &result)
            } else if let children = object[key] as? [[String: Any]] {
                for child in children.prefix(8) {
                    collect(child, inheritedError: isError, depth: depth + 1, remaining: &remaining, result: &result)
                }
            }
        }
    }

    private static func object(from content: String) -> [String: Any]? {
        guard content.utf8.count <= 256 * 1024,
              var value = try? JSONSerialization.jsonObject(with: Data(content.utf8), options: [.fragmentsAllowed]) else { return nil }
        if let text = value as? String,
           let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { value = decoded }
        return value as? [String: Any]
    }

    private static func integer(_ value: Any?, maximum: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue <= Double(maximum),
              number.doubleValue == number.doubleValue.rounded(.towardZero) else { return nil }
        return number.intValue
    }

    private static func payloadMetadata(_ payload: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["id", "source", "sha256", "kind"] {
            if let value = payload[key] as? String { result[key] = utf8Prefix(value, limit: 240) }
        }
        for key in ["bytes", "chunks"] {
            if let value = integer(payload[key], maximum: 16 * 1024 * 1024) { result[key] = value }
        }
        return result
    }

    private static func utf8Prefix(_ value: String, limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var bytes = Array(value.utf8.prefix(max(0, limit)))
        while let last = bytes.last {
            if let result = String(bytes: bytes, encoding: .utf8) { return result }
            bytes.removeLast()
            if last < 128 { break }
        }
        return ""
    }
}
