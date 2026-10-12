// Native Atlas runtime: Go-compatible JSON values.
//
// Ported from the NotchLee Atlas helper (OmniFlow/Helpers/Atlas) and the
// canonical Atlas Go SDK (MIT, Quandry Labs) at revision
// 49104b74160ee24cc350eee461df6378e51cccd3; see docs/omniflow/atlas-swift-port.md.
//
// Saved MCP approvals are SHA-256 digests of Go's `json.Marshal` output for a
// re-decoded tool definition. This encoder reproduces that byte stream exactly
// (sorted map keys, HTML-safe escaping, Go float formatting) so approvals made
// by the Go helper keep matching after cutover.
import Foundation

/// A decoded JSON value with Go `interface{}` semantics: every number is a
/// float64, objects decoded from JSON are maps whose keys sort on encoding, and
/// `fields` preserves declaration order like a Go struct.
public enum AtlasJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AtlasJSON])
    /// A Go map: keys are encoded in byte order.
    case object([String: AtlasJSON])
    /// A Go struct: fields are encoded in the given order.
    case fields([(String, AtlasJSON)])
    /// Pre-encoded JSON embedded verbatim (Go `json.RawMessage`).
    case raw([UInt8])

    public static func == (lhs: AtlasJSON, rhs: AtlasJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.raw(a), .raw(b)): a == b
        default:
            if let a = lhs.dictionary, let b = rhs.dictionary { a == b } else { false }
        }
    }

    public var dictionary: [String: AtlasJSON]? {
        switch self {
        case let .object(values): values
        case let .fields(values): Dictionary(values, uniquingKeysWith: { _, last in last })
        case let .raw(bytes): (try? AtlasJSON.parse(bytes))?.dictionary
        default: nil
        }
    }
    public var stringValue: String? { if case let .string(value) = self { value } else { nil } }
    public var doubleValue: Double? { if case let .number(value) = self { value } else { nil } }
    public var boolValue: Bool? { if case let .bool(value) = self { value } else { nil } }
    public var arrayValue: [AtlasJSON]? { if case let .array(value) = self { value } else { nil } }
    public subscript(key: String) -> AtlasJSON? { dictionary?[key] }

    public static func int(_ value: Int) -> AtlasJSON { .number(Double(value)) }
    public static func strings(_ values: [String]) -> AtlasJSON { .array(values.map(AtlasJSON.string)) }
}

// MARK: - Encoding (Go encoding/json, escapeHTML = true)

extension AtlasJSON {
    /// Go `json.Marshal` output. Non-finite numbers are not representable; like
    /// Go's `jsonText`, the caller receives an empty string in that case.
    public var goText: String { String(decoding: goBytes, as: UTF8.self) }

    public var goBytes: [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(64)
        guard Self.encode(self, into: &output) else { return [] }
        return output
    }

    private static func encode(_ value: AtlasJSON, into output: inout [UInt8]) -> Bool {
        switch value {
        case .null: output.append(contentsOf: Array("null".utf8))
        case let .bool(flag): output.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case let .number(number):
            guard let text = goFloat(number) else { return false }
            output.append(contentsOf: Array(text.utf8))
        case let .string(text): encodeString(text, into: &output)
        case let .array(values):
            output.append(UInt8(ascii: "["))
            for (index, element) in values.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                guard encode(element, into: &output) else { return false }
            }
            output.append(UInt8(ascii: "]"))
        case let .object(values):
            let keys = values.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            return encodeMembers(keys.map { ($0, values[$0]!) }, into: &output)
        case let .fields(values):
            return encodeMembers(values, into: &output)
        case let .raw(bytes):
            output.append(contentsOf: bytes)
        }
        return true
    }

    private static func encodeMembers(_ members: [(String, AtlasJSON)], into output: inout [UInt8]) -> Bool {
        output.append(UInt8(ascii: "{"))
        for (index, member) in members.enumerated() {
            if index > 0 { output.append(UInt8(ascii: ",")) }
            encodeString(member.0, into: &output)
            output.append(UInt8(ascii: ":"))
            guard encode(member.1, into: &output) else { return false }
        }
        output.append(UInt8(ascii: "}"))
        return true
    }

    private static let hex = Array("0123456789abcdef".utf8)

    static func encodeString(_ text: String, into output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        var utf8 = text.utf8.makeIterator()
        var pending: [UInt8] = []
        while let byte = utf8.next() {
            if byte >= 0x80 {
                // Swift strings are valid UTF-8; only U+2028/U+2029 (E2 80 A8/A9) are escaped.
                if byte == 0xE2 {
                    pending = [byte]
                    if let second = utf8.next() { pending.append(second) }
                    if let third = utf8.next() { pending.append(third) }
                    if pending.count == 3 && pending[1] == 0x80 && (pending[2] == 0xA8 || pending[2] == 0xA9) {
                        output.append(contentsOf: Array((pending[2] == 0xA8 ? "\\u2028" : "\\u2029").utf8))
                    } else {
                        output.append(contentsOf: pending)
                    }
                } else {
                    output.append(byte)
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): output.append(contentsOf: [92, 34])
            case UInt8(ascii: "\\"): output.append(contentsOf: [92, 92])
            case 0x08: output.append(contentsOf: [92, UInt8(ascii: "b")])
            case 0x0C: output.append(contentsOf: [92, UInt8(ascii: "f")])
            case 0x0A: output.append(contentsOf: [92, UInt8(ascii: "n")])
            case 0x0D: output.append(contentsOf: [92, UInt8(ascii: "r")])
            case 0x09: output.append(contentsOf: [92, UInt8(ascii: "t")])
            case UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "&"), 0..<0x20:
                output.append(contentsOf: [92, UInt8(ascii: "u"), 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0xF)]])
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }

    /// Go `encoding/json` float64 formatting: shortest round-trip digits, `f`
    /// notation inside [1e-6, 1e21), otherwise `e` notation with the exponent's
    /// leading zero removed ("1e-07" -> "1e-7").
    static func goFloat(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value == 0 { return value.sign == .minus ? "-0" : "0" }
        let (negative, digits, exponent) = shortestDecimal(value)
        // value = 0.d1d2d3... x 10^exponent
        let magnitude = Swift.abs(value)
        var text = negative ? "-" : ""
        if magnitude < 1e-6 || magnitude >= 1e21 {
            text += String(digits.first!)
            if digits.count > 1 { text += "." + digits.dropFirst() }
            let power = exponent - 1
            // strconv pads the exponent to two digits; encoding/json then strips
            // the padding from negative exponents only.
            text += power < 0 ? "e-\(-power)" : "e+" + (power < 10 ? "0" : "") + "\(power)"
            return text
        }
        if exponent <= 0 {
            text += "0." + String(repeating: "0", count: -exponent) + digits
        } else if exponent >= digits.count {
            text += digits + String(repeating: "0", count: exponent - digits.count)
        } else {
            let split = digits.index(digits.startIndex, offsetBy: exponent)
            text += digits[..<split] + "." + digits[split...]
        }
        return text
    }

    /// Shortest round-trip decimal digits from Swift's description, which uses
    /// the same shortest-uniquely-identifying criterion as Go's strconv.
    private static func shortestDecimal(_ value: Double) -> (Bool, String, Int) {
        var description = Swift.abs(value).description
        let negative = value.sign == .minus
        var exponent = 0
        if let marker = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(description[description.index(after: marker)...])!
            description = String(description[..<marker])
        }
        var integer = description
        var fraction = ""
        if let dot = description.firstIndex(of: ".") {
            integer = String(description[..<dot])
            fraction = String(description[description.index(after: dot)...])
        }
        var digits = integer + fraction
        var point = integer.count + exponent
        while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); point -= 1 }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        return (negative, digits, point)
    }
}

// MARK: - Decoding (Go encoding/json into interface{})

extension AtlasJSON {
    /// Decodes like Go `json.Unmarshal(data, &interface{})`: strict grammar,
    /// invalid UTF-8 bytes replaced one by one with U+FFFD, last duplicate key
    /// wins, and out-of-range numbers rejected.
    public static func parse(_ data: some Collection<UInt8>, numberCheck: ((Substring) -> Bool)? = nil) throws -> AtlasJSON {
        var parser = Parser(bytes: Array(data), numberCheck: numberCheck)
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw AtlasRuntimeError("invalid_json") }
        return value
    }

    public static func parse(_ text: String) throws -> AtlasJSON { try parse(Array(text.utf8)) }

    /// Validates JSON syntax only (Go `json.Valid`).
    public static func isValid(_ data: some Collection<UInt8>) -> Bool {
        (try? parse(data)) != nil
    }

    struct Parser {
        let bytes: [UInt8]
        let numberCheck: ((Substring) -> Bool)?
        var index = 0

        init(bytes: [UInt8], numberCheck: ((Substring) -> Bool)?) {
            self.bytes = bytes
            self.numberCheck = numberCheck
        }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> AtlasJSON {
            guard depth < 10000, index < bytes.count else { throw AtlasRuntimeError("invalid_json") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var values: [String: AtlasJSON] = [:]
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(values) }
                while true {
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw AtlasRuntimeError("invalid_json") }
                    let key = try string()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw AtlasRuntimeError("invalid_json") }
                    index += 1
                    skipSpace()
                    values[key] = try value(depth: depth + 1)
                    skipSpace()
                    guard index < bytes.count else { throw AtlasRuntimeError("invalid_json") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "}") else { throw AtlasRuntimeError("invalid_json") }
                    index += 1
                    return .object(values)
                }
            case UInt8(ascii: "["):
                index += 1
                var values: [AtlasJSON] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
                while true {
                    skipSpace()
                    values.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw AtlasRuntimeError("invalid_json") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "]") else { throw AtlasRuntimeError("invalid_json") }
                    index += 1
                    return .array(values)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw AtlasRuntimeError("invalid_json")
            }
            index += expected.count
        }

        mutating func number() throws -> AtlasJSON {
            let start = index
            func digit(_ i: Int) -> Bool { i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digit(index) else { throw AtlasRuntimeError("invalid_json") }
            if bytes[index] == 0x30 { index += 1 } else { while digit(index) { index += 1 } }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digit(index) else { throw AtlasRuntimeError("invalid_json") }
                while digit(index) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digit(index) else { throw AtlasRuntimeError("invalid_json") }
                while digit(index) { index += 1 }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if let numberCheck, !numberCheck(Substring(text)) { throw AtlasRuntimeError("number_round_trip") }
            guard let value = Double(text), value.isFinite else { throw AtlasRuntimeError("number_range") }
            return .number(value)
        }

        mutating func string() throws -> String {
            index += 1 // opening quote
            // Accumulate UTF-8 bytes; runs of valid UTF-8 are copied in bulk.
            var output: [UInt8] = []
            func appendScalar(_ scalar: Unicode.Scalar) { output.append(contentsOf: Array(String(scalar).utf8)) }
            while true {
                let runStart = index
                while index < bytes.count {
                    let byte = bytes[index]
                    if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") || byte < 0x20 || byte >= 0x80 { break }
                    index += 1
                }
                if index > runStart { output.append(contentsOf: bytes[runStart..<index]) }
                guard index < bytes.count else { throw AtlasRuntimeError("invalid_json") }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { index += 1; return String(decoding: output, as: UTF8.self) }
                if byte < 0x20 { throw AtlasRuntimeError("invalid_json") }
                if byte >= 0x80 {
                    let (scalar, size) = AtlasUTF8.decodeRune(bytes, at: index)
                    if scalar != nil { output.append(contentsOf: bytes[index..<(index + size)]) } else { output.append(contentsOf: [0xEF, 0xBF, 0xBD]) }
                    index += size
                    continue
                }
                // Escape sequence.
                index += 1
                guard index < bytes.count else { throw AtlasRuntimeError("invalid_json") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): output.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): output.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): output.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): output.append(0x08)
                case UInt8(ascii: "f"): output.append(0x0C)
                case UInt8(ascii: "n"): output.append(0x0A)
                case UInt8(ascii: "r"): output.append(0x0D)
                case UInt8(ascii: "t"): output.append(0x09)
                case UInt8(ascii: "u"):
                    let first = try hex4()
                    if (0xD800..<0xE000).contains(first) {
                        // Go combines a valid surrogate pair; otherwise it writes
                        // U+FFFD and leaves the following escape to be decoded.
                        if first < 0xDC00, index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            let saved = index
                            index += 2
                            let second = try hex4()
                            if (0xDC00..<0xE000).contains(second) {
                                appendScalar(Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))!)
                                continue
                            }
                            index = saved
                        }
                        appendScalar("\u{FFFD}")
                    } else {
                        appendScalar(Unicode.Scalar(first)!)
                    }
                default: throw AtlasRuntimeError("invalid_json")
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw AtlasRuntimeError("invalid_json") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte - 0x30)
                case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
                case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
                default: throw AtlasRuntimeError("invalid_json")
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }
    }
}

// MARK: - UTF-8 helpers with Go semantics

enum AtlasUTF8 {
    /// Go `utf8.DecodeRune`: returns nil with size 1 for any invalid byte.
    static func decodeRune(_ bytes: [UInt8], at index: Int) -> (Unicode.Scalar?, Int) {
        let first = bytes[index]
        if first < 0x80 { return (Unicode.Scalar(first), 1) }
        func continuation(_ offset: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> UInt32? {
            guard index + offset < bytes.count, range.contains(bytes[index + offset]) else { return nil }
            return UInt32(bytes[index + offset] & 0x3F)
        }
        switch first {
        case 0xC2...0xDF:
            guard let a = continuation(1) else { return (nil, 1) }
            return (Unicode.Scalar(UInt32(first & 0x1F) << 6 | a), 2)
        case 0xE0...0xEF:
            let range: ClosedRange<UInt8> = first == 0xE0 ? 0xA0...0xBF : first == 0xED ? 0x80...0x9F : 0x80...0xBF
            guard let a = continuation(1, range), let b = continuation(2) else { return (nil, 1) }
            return (Unicode.Scalar(UInt32(first & 0x0F) << 12 | a << 6 | b), 3)
        case 0xF0...0xF4:
            let range: ClosedRange<UInt8> = first == 0xF0 ? 0x90...0xBF : first == 0xF4 ? 0x80...0x8F : 0x80...0xBF
            guard let a = continuation(1, range), let b = continuation(2), let c = continuation(3) else { return (nil, 1) }
            return (Unicode.Scalar(UInt32(first & 0x07) << 18 | a << 12 | b << 6 | c), 4)
        default: return (nil, 1)
        }
    }

    static func isValid(_ bytes: some Collection<UInt8>) -> Bool {
        let array = Array(bytes)
        var index = 0
        while index < array.count {
            let (scalar, size) = decodeRune(array, at: index)
            if scalar == nil { return false }
            index += size
        }
        return true
    }

    /// Go `utf8.RuneStart`.
    @inline(__always) static func isRuneStart(_ byte: UInt8) -> Bool { byte & 0xC0 != 0x80 }

    /// Go `utf8Prefix`: at most `limit` bytes, never splitting a scalar.
    static func prefix(_ value: String, _ limit: Int) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > limit else { return value }
        var end = max(0, limit)
        while end > 0 && bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

/// Go's `jsonText` helper: encode a value, or return "" when unrepresentable.
@inline(__always) func jsonText(_ value: AtlasJSON) -> String { value.goText }

extension AtlasJSON {
    /// Byte spans of a top-level object's members (last duplicate wins, as when
    /// Go decodes into a struct with `json.RawMessage` fields). Values keep their
    /// exact bytes, so large integers in results are never rounded.
    static func rawMembers(_ data: [UInt8]) -> [String: ArraySlice<UInt8>]? {
        var parser = Parser(bytes: data, numberCheck: nil)
        parser.skipSpace()
        guard parser.index < data.count, data[parser.index] == UInt8(ascii: "{") else { return nil }
        parser.index += 1
        var members: [String: ArraySlice<UInt8>] = [:]
        parser.skipSpace()
        if parser.index < data.count, data[parser.index] == UInt8(ascii: "}") {
            parser.index += 1
        } else {
            while true {
                parser.skipSpace()
                guard parser.index < data.count, data[parser.index] == UInt8(ascii: "\""), let key = try? parser.string() else { return nil }
                parser.skipSpace()
                guard parser.index < data.count, data[parser.index] == UInt8(ascii: ":") else { return nil }
                parser.index += 1
                parser.skipSpace()
                let start = parser.index
                guard (try? parser.value(depth: 1)) != nil else { return nil }
                members[key] = data[start..<parser.index]
                parser.skipSpace()
                guard parser.index < data.count else { return nil }
                if data[parser.index] == UInt8(ascii: ",") { parser.index += 1; continue }
                guard data[parser.index] == UInt8(ascii: "}") else { return nil }
                parser.index += 1
                break
            }
        }
        parser.skipSpace()
        return parser.index == data.count ? members : nil
    }
}

extension AtlasJSON {
    /// Byte spans of a top-level array's elements.
    static func rawElements(_ data: some Collection<UInt8>) -> [ArraySlice<UInt8>]? {
        let bytes = Array(data)
        var parser = Parser(bytes: bytes, numberCheck: nil)
        parser.skipSpace()
        guard parser.index < bytes.count, bytes[parser.index] == UInt8(ascii: "[") else { return nil }
        parser.index += 1
        var elements: [ArraySlice<UInt8>] = []
        parser.skipSpace()
        if parser.index < bytes.count, bytes[parser.index] == UInt8(ascii: "]") {
            parser.index += 1
        } else {
            while true {
                parser.skipSpace()
                let start = parser.index
                guard (try? parser.value(depth: 1)) != nil else { return nil }
                elements.append(bytes[start..<parser.index])
                parser.skipSpace()
                guard parser.index < bytes.count else { return nil }
                if bytes[parser.index] == UInt8(ascii: ",") { parser.index += 1; continue }
                guard bytes[parser.index] == UInt8(ascii: "]") else { return nil }
                parser.index += 1
                break
            }
        }
        parser.skipSpace()
        return parser.index == bytes.count ? elements : nil
    }

    /// Go `json.Indent(dst, src, "", indent)` over valid JSON: literal bytes
    /// (including exact numbers) are preserved; only whitespace changes.
    static func indent(_ source: [UInt8], indent unit: String = "  ") -> [UInt8]? {
        guard AtlasJSON.isValid(source) else { return nil }
        let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        var output: [UInt8] = []
        var depth = 0
        var inString = false, escaped = false
        var needIndent = false
        let unitBytes = Array(unit.utf8)
        func newline() {
            output.append(0x0A)
            for _ in 0..<depth { output.append(contentsOf: unitBytes) }
        }
        var index = 0
        // Leading whitespace is dropped; trailing whitespace is preserved.
        while index < source.count && space.contains(source[index]) { index += 1 }
        var end = source.count
        while end > index && space.contains(source[end - 1]) { end -= 1 }
        while index < end {
            let byte = source[index]
            index += 1
            if inString {
                output.append(byte)
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            if space.contains(byte) { continue }
            if needIndent && byte != UInt8(ascii: "]") && byte != UInt8(ascii: "}") {
                needIndent = false
                depth += 1
                newline()
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
                output.append(byte)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                needIndent = true
                output.append(byte)
            case UInt8(ascii: ","):
                output.append(byte)
                newline()
            case UInt8(ascii: ":"):
                output.append(byte)
                output.append(0x20)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if needIndent {
                    needIndent = false // empty container stays compact
                } else {
                    depth -= 1
                    newline()
                }
                output.append(byte)
            default:
                output.append(byte)
            }
        }
        output.append(contentsOf: source[end...])
        return output
    }
}
