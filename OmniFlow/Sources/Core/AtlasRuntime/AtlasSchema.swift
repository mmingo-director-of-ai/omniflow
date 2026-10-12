// Native Atlas runtime: bounded JSON Schema subset (port of schema.go).
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
// Fail closed for unsupported keywords; this is deliberately not a claim of
// full JSON Schema conformance.
import Foundation

enum AtlasSchema {
    /// Reject arguments whose numeric meaning would change when re-encoded as a
    /// float64, instead of calling a tool with a rounded identifier.
    static func numbersRoundTrip(_ data: some Collection<UInt8>) -> Bool {
        guard let root = try? AtlasJSON.parse(data, numberCheck: literalRoundTrips) else { return false }
        func depthOK(_ value: AtlasJSON, _ depth: Int) -> Bool {
            if depth > 32 { return false }
            switch value {
            case let .array(values): return values.allSatisfy { depthOK($0, depth + 1) }
            case let .object(values): return values.values.allSatisfy { depthOK($0, depth + 1) }
            case let .fields(values): return values.allSatisfy { depthOK($0.1, depth + 1) }
            default: return true
            }
        }
        return depthOK(root, 0)
    }

    private static func literalRoundTrips(_ literal: Substring) -> Bool {
        guard literal.utf8.count <= 128 else { return false }
        // Bound the exponent before computing an exact value.
        if let marker = literal.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let exponent = Int(literal[literal.index(after: marker)...]), (-512...512).contains(exponent) else { return false }
        }
        guard let value = Double(literal), value.isFinite, let formatted = AtlasJSON.goFloat(value) else { return false }
        return exactDecimal(literal) == exactDecimal(Substring(formatted))
    }

    /// An exact decimal (sign, significant digits, power of ten); equal values
    /// compare equal, mirroring Go's big.Rat comparison of two decimal strings.
    private static func exactDecimal(_ literal: Substring) -> (Bool, String, Int) {
        var text = literal
        var negative = false
        if text.first == "-" { negative = true; text = text.dropFirst() }
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: marker)...]) ?? 0
            text = text[..<marker]
        }
        var digits = String(text)
        if let dot = digits.firstIndex(of: ".") {
            exponent -= digits.distance(from: dot, to: digits.endIndex) - 1
            digits.remove(at: dot)
        }
        while digits.hasPrefix("0") { digits.removeFirst() }
        if digits.isEmpty { return (false, "", 0) }
        while digits.hasSuffix("0") { digits.removeLast(); exponent += 1 }
        return (negative, digits, exponent)
    }

    static func supported(_ schema: [String: AtlasJSON]?, root: [String: AtlasJSON]?, depth: Int) -> Bool {
        guard let schema, depth <= 16 else { return false }
        for (key, value) in schema {
            switch key {
            case "$schema", "$id", "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "const":
                continue
            case "type":
                let valid: (AtlasJSON) -> Bool = { ["object", "array", "string", "number", "integer", "boolean", "null"].contains($0.stringValue ?? "") }
                if let values = value.arrayValue { guard values.allSatisfy(valid) else { return false } } else if !valid(value) { return false }
            case "properties", "$defs", "definitions":
                guard case let .object(values) = value,
                      values.values.allSatisfy({ supported($0.dictionary, root: root, depth: depth + 1) && $0.dictionary != nil }) else { return false }
            case "$ref":
                guard let reference = value.stringValue, supported(resolve(reference, root: root), root: root, depth: depth + 1) else { return false }
            case "items":
                guard supported(value.dictionary, root: root, depth: depth + 1) else { return false }
            case "additionalProperties":
                if value.boolValue == nil, !supported(value.dictionary, root: root, depth: depth + 1) { return false }
            case "anyOf", "oneOf", "allOf":
                guard let children = value.arrayValue, (1...16).contains(children.count),
                      children.allSatisfy({ supported($0.dictionary, root: root, depth: depth + 1) }) else { return false }
            case "required":
                guard let values = value.arrayValue, values.allSatisfy({ $0.stringValue != nil }) else { return false }
            case "enum":
                guard let values = value.arrayValue, !values.isEmpty else { return false }
            case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties":
                guard value.doubleValue != nil else { return false }
            case "pattern":
                guard let pattern = value.stringValue, pattern.utf8.count <= 1024, compile(pattern) != nil else { return false }
            default:
                return false
            }
        }
        return true
    }

    static func resolve(_ reference: String, root: [String: AtlasJSON]?) -> [String: AtlasJSON]? {
        guard reference.hasPrefix("#/"), let root else { return nil }
        var value: AtlasJSON = .object(root)
        for part in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            guard let object = value.dictionary else { return nil }
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = object[key] else { return nil }
            value = next
        }
        return value.dictionary
    }

    static func validate(_ value: AtlasJSON, _ schema: [String: AtlasJSON]?, root: [String: AtlasJSON]?, depth: Int) -> Bool {
        guard let schema, depth <= 16 else { return false }
        if let reference = schema["$ref"]?.stringValue, !validate(value, resolve(reference, root: root), root: root, depth: depth + 1) { return false }
        if let choices = schema["enum"]?.arrayValue, !choices.contains(where: { jsonText($0) == jsonText(value) }) { return false }
        if let constant = schema["const"], jsonText(value) != jsonText(constant) { return false }
        for key in ["anyOf", "oneOf", "allOf"] {
            guard let children = schema[key]?.arrayValue else { continue }
            let matched = children.filter { validate(value, $0.dictionary, root: root, depth: depth + 1) }.count
            if (key == "anyOf" && matched == 0) || (key == "oneOf" && matched != 1) || (key == "allOf" && matched != children.count) { return false }
        }
        if let expected = schema["type"] {
            let kinds = expected.arrayValue ?? [expected]
            let match = kinds.contains { kind in
                switch (kind.stringValue, value) {
                case ("null", .null), ("string", .string), ("boolean", .bool), ("object", .object), ("object", .fields),
                     ("array", .array), ("number", .number): true
                case let ("integer", .number(number)): number.rounded(.towardZero) == number
                default: false
                }
            }
            if !match { return false }
        }
        func within(_ number: Double, _ minimum: String, _ maximum: String) -> Bool {
            if let lower = schema[minimum]?.doubleValue, number < lower { return false }
            if let upper = schema[maximum]?.doubleValue, number > upper { return false }
            return true
        }
        switch value {
        case .object, .fields:
            let object = value.dictionary!
            guard object.count <= 128, within(Double(object.count), "minProperties", "maxProperties") else { return false }
            if let required = schema["required"]?.arrayValue {
                for name in required where object[name.stringValue ?? ""] == nil { return false }
            }
            let properties = schema["properties"]?.dictionary
            for (key, child) in object {
                if let property = properties?[key]?.dictionary {
                    if !validate(child, property, root: root, depth: depth + 1) { return false }
                } else {
                    switch schema["additionalProperties"] {
                    case let .bool(allowed)?: if !allowed { return false }
                    case let additional? where additional.dictionary != nil:
                        if !validate(child, additional.dictionary, root: root, depth: depth + 1) { return false }
                    default:
                        // With explicit properties, refuse undocumented parameters unless
                        // the server explicitly permits them.
                        if schema["properties"]?.dictionary != nil { return false }
                    }
                }
            }
        case let .array(values):
            guard values.count <= 1024, within(Double(values.count), "minItems", "maxItems") else { return false }
            if let items = schema["items"]?.dictionary, !values.allSatisfy({ validate($0, items, root: root, depth: depth + 1) }) { return false }
        case let .string(text):
            guard text.utf8.count <= 16000, within(Double(text.unicodeScalars.count), "minLength", "maxLength") else { return false }
            if let pattern = schema["pattern"]?.stringValue {
                guard let expression = compile(pattern),
                      expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
            }
        case let .number(number):
            if !within(number, "minimum", "maximum") { return false }
            if let lower = schema["exclusiveMinimum"]?.doubleValue, number <= lower { return false }
            if let upper = schema["exclusiveMaximum"]?.doubleValue, number >= upper { return false }
        default: break
        }
        return true
    }

    /// Compile only RE2-expressible patterns. ICU accepts lookaround,
    /// backreferences, atomic groups and possessive quantifiers that Go's RE2
    /// rejects; without this guard such a tool would become approvable.
    static func compile(_ pattern: String) -> NSRegularExpression? {
        let scalars = Array(pattern.unicodeScalars)
        var index = 0
        var inClass = false
        var translated = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                guard index + 1 < scalars.count else { return nil }
                let next = scalars[index + 1]
                if !inClass && ("1"..."9" ~= next || next == "k" || next == "Z" || next == "G" || next == "X" || next == "R") { return nil }
                translated.append(scalar); translated.append(next)
                index += 2
                continue
            }
            if inClass {
                if scalar == "]" { inClass = false }
                if scalar == "[" && index + 1 < scalars.count && scalars[index + 1] != ":" { return nil } // ICU nested sets
                translated.append(scalar); index += 1
                continue
            }
            if scalar == "[" {
                inClass = true
                translated.append(scalar); index += 1
                // A leading ']' or '^]' is literal in both dialects.
                if index < scalars.count && scalars[index] == "^" { translated.append("^"); index += 1 }
                if index < scalars.count && scalars[index] == "]" { translated.append("]"); index += 1 }
                continue
            }
            if scalar == "(" && index + 1 < scalars.count && scalars[index + 1] == "?" {
                let rest = String(String.UnicodeScalarView(scalars[index...].prefix(4)))
                if rest.hasPrefix("(?=") || rest.hasPrefix("(?!") || rest.hasPrefix("(?<=") || rest.hasPrefix("(?<!") || rest.hasPrefix("(?>") || rest.hasPrefix("(?#") {
                    return nil
                }
                if rest.hasPrefix("(?P<") { // RE2 named group spelling
                    translated.append(contentsOf: "(?<".unicodeScalars); index += 4
                    continue
                }
            }
            if ["*", "+", "?", "}"].contains(scalar), index + 1 < scalars.count, scalars[index + 1] == "+" { return nil }
            translated.append(scalar); index += 1
        }
        return try? NSRegularExpression(pattern: String(translated))
    }
}
