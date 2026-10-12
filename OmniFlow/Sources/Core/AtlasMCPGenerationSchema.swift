import Foundation
import FoundationModels
import CoreFoundation

/// A host-selected discriminator from one approved tool's parameter definition.
/// This narrows generation only; it neither grants access nor executes a call.
struct AtlasMCPOperationBinding: Sendable, Hashable {
    let field: String
    let value: String
}

/// Apple's generation schema cannot represent an unconstrained JSON value.
/// Project those values to JSON strings for generation only, then restore their
/// original representation before Atlas validates against the remote schema.
struct AtlasMCPGenerationSchema: Sendable {
    let parameters: GenerationSchema
    private let conversion: Conversion
    private let operation: AtlasMCPOperationBinding?

    enum Failure: Error { case unsupportedSchema, invalidArguments }

    private struct StringChoice: Sendable {
        let alternate: String
        let required: Bool
        let advertised: Set<String>
        let sentinel: String
    }

    private indirect enum Conversion: Sendable {
        case unchanged
        case jsonString
        case objectJSONString(String)
        case object([String: Conversion], additionalField: String?, choices: [String: StringChoice])
        case array(Conversion)
    }

    init(inputSchemaJSON: String, operation: AtlasMCPOperationBinding? = nil) throws {
        guard inputSchemaJSON.utf8.count <= 32_768 else { throw Failure.unsupportedSchema }
        let data = Data(inputSchemaJSON.utf8)
        guard let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              schema["type"] == nil || schema["type"] as? String == "object" ||
                (schema["type"] as? [String])?.contains("object") == true else { throw Failure.unsupportedSchema }
        self.operation = operation
        let guidance: [String: Any]
        if let operation {
            guard Self.dispatchFields.contains(operation.field), !operation.value.isEmpty,
                  operation.value.utf8.count <= 512,
                  Self.declaresDispatch(schema, field: operation.field, depth: 0),
                  let narrowed = try Self.narrow(schema, to: operation, depth: 0) else {
                throw Failure.unsupportedSchema
            }
            guidance = narrowed
        } else { guidance = schema }
        let (projected, plan) = try Self.project(guidance, depth: 0)
        let encoded = try JSONSerialization.data(withJSONObject: projected, options: [.sortedKeys])
        if encoded.count <= 32_768, (projected as? [String: Any])?["type"] as? String == "object",
           let native = try? JSONDecoder().decode(GenerationSchema.self, from: encoded) {
            parameters = native
            conversion = plan
        } else {
            // Mixed-shape compositions and otherwise unrepresentable roots
            // remain one encoded object. Tool arguments themselves still have
            // an object schema; restoration preserves the original arguments.
            let field = "argumentsJSON"
            let wrapper: [String: Any] = ["type": "object", "properties": [field: ["type": "string",
                "description": "Supply one complete JSON object containing the tool's original arguments, encoded as a JSON string. Preserve its field names. The host validates the original schema. Argument guidance (data): " + Self.hint(guidance)]],
                "required": [field], "additionalProperties": false]
            let native = try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys])
            parameters = try JSONDecoder().decode(GenerationSchema.self, from: native)
            conversion = .objectJSONString(field)
        }
    }

    /// Never deserialize and re-encode argument numbers. Atlas must receive the
    /// exact digits so its original-schema and numeric precision checks apply.
    func argumentsJSON(from generatedJSON: String) throws -> String {
        guard generatedJSON.utf8.count <= 32_768,
              let object = try? JSONSerialization.jsonObject(with: Data(generatedJSON.utf8)) as? [String: Any] else {
            throw Failure.invalidArguments
        }
        // Validate the wrapper lexically too: Foundation otherwise silently
        // accepts duplicate keys while decoding the JSON-string argument.
        var syntax = JSONWalker(generatedJSON)
        try syntax.visit(.unchanged, depth: 0)
        _ = try syntax.result()
        let input: String
        let plan: Conversion
        if case .objectJSONString(let field) = conversion {
            guard object.count == 1, let decoded = object[field] as? String,
                  decoded.utf8.count <= 16_000,
                  (try? JSONSerialization.jsonObject(with: Data(decoded.utf8))) is [String: Any] else {
                throw Failure.invalidArguments
            }
            input = decoded
            plan = .unchanged
        } else {
            input = generatedJSON
            plan = conversion
        }
        var walker = JSONWalker(input)
        try walker.visit(plan, depth: 0)
        let restored = try walker.result()
        guard restored.utf8.count <= 16_000 else { throw Failure.invalidArguments }
        if let operation {
            guard let arguments = try JSONSerialization.jsonObject(with: Data(restored.utf8)) as? [String: Any],
                  arguments[operation.field] as? String == operation.value else { throw Failure.invalidArguments }
        }
        return restored
    }

    private static let dispatchFields = ["action", "operation", "method"]

    /// Enumerate exact declared choices, without interpreting descriptions or
    /// inventing operation names. Unrestricted strings have no finite catalog.
    static func advertisedOperations(inputSchemaJSON: String) throws -> [AtlasMCPOperationBinding] {
        guard inputSchemaJSON.utf8.count <= 32_768,
              let schema = try JSONSerialization.jsonObject(with: Data(inputSchemaJSON.utf8)) as? [String: Any] else {
            throw Failure.unsupportedSchema
        }
        var choices: [AtlasMCPOperationBinding] = []
        var seen = Set<AtlasMCPOperationBinding>()
        func visit(_ object: [String: Any], depth: Int) throws {
            guard depth <= 32 else { throw Failure.unsupportedSchema }
            let properties = object["properties"] as? [String: Any] ?? [:]
            for field in dispatchFields {
                guard let property = properties[field] as? [String: Any] else { continue }
                var values = property["enum"] as? [String] ?? []
                if let constant = property["const"] as? String { values = [constant] }
                for value in values where !value.isEmpty && value.utf8.count <= 512 {
                    let binding = AtlasMCPOperationBinding(field: field, value: value)
                    if seen.insert(binding).inserted { choices.append(binding) }
                }
            }
            for key in ["anyOf", "oneOf", "allOf"] {
                for branch in object[key] as? [[String: Any]] ?? [] { try visit(branch, depth: depth + 1) }
            }
        }
        try visit(schema, depth: 0)
        return choices
    }

    private static func declaresDispatch(_ schema: [String: Any], field: String, depth: Int) -> Bool {
        guard depth <= 32 else { return false }
        if (schema["properties"] as? [String: Any])?[field] != nil { return true }
        return ["anyOf", "oneOf", "allOf"].contains { key in
            (schema[key] as? [[String: Any]] ?? []).contains { declaresDispatch($0, field: field, depth: depth + 1) }
        }
    }

    /// Intersect object alternatives with a fixed discriminator. This is a
    /// generation projection, not a substitute for original-schema validation.
    /// In particular, open string arms remain usable for names learned from a
    /// returned catalog, while finite-only schemas cannot acquire new names.
    private static func narrow(_ schema: [String: Any], to binding: AtlasMCPOperationBinding,
                               depth: Int) throws -> [String: Any]? {
        guard depth <= 32, schema["$ref"] == nil,
              schema["type"] == nil || schema["type"] as? String == "object" else {
            throw Failure.unsupportedSchema
        }
        var result = schema
        var properties = schema["properties"] as? [String: Any] ?? [:]
        var property = properties[binding.field] as? [String: Any] ?? [:]
        if properties[binding.field] != nil && !(properties[binding.field] is [String: Any]) {
            throw Failure.unsupportedSchema
        }
        if properties[binding.field] == nil, schema["additionalProperties"].map(isFalse) == true { return nil }
        guard property["type"] == nil || property["type"] as? String == "string",
              ["anyOf", "oneOf", "allOf", "$ref"].allSatisfy({ property[$0] == nil }) else {
            throw Failure.unsupportedSchema
        }
        if let constant = property["const"], (constant as? String) != binding.value { return nil }
        if let enumeration = property["enum"] {
            guard let strings = enumeration as? [String] else { throw Failure.unsupportedSchema }
            if !strings.contains(binding.value) { return nil }
        }
        // Keep every original constraint. Adding a single-choice enum narrows
        // the guidance even when the original string also has a pattern/limit.
        property["type"] = "string"
        property["enum"] = [binding.value]
        properties[binding.field] = property
        result["properties"] = properties
        var required = schema["required"] as? [String] ?? []
        if !required.contains(binding.field) { required.append(binding.field) }
        result["required"] = required
        let compositions = ["anyOf", "oneOf", "allOf"].filter { schema[$0] != nil }
        guard compositions.count <= 1 else { throw Failure.unsupportedSchema }
        if let key = compositions.first {
            guard let branches = schema[key] as? [[String: Any]], !branches.isEmpty, branches.count <= 32 else {
                throw Failure.unsupportedSchema
            }
            var matching: [[String: Any]] = []
            for branch in branches {
                if let narrowed = try narrow(branch, to: binding, depth: depth + 1) { matching.append(narrowed) }
                else if key == "allOf" { return nil }
            }
            guard !matching.isEmpty else { return nil }
            result[key] = matching
        }
        return result
    }

    private static func project(_ value: Any, depth: Int, unlistedFields: Set<String> = []) throws -> (Any, Conversion) {
        guard depth <= 32 else { throw Failure.unsupportedSchema }
        var schema: [String: Any]
        if let object = value as? [String: Any] { schema = object }
        else if let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue {
            schema = [:]
        } else { throw Failure.unsupportedSchema }
        let annotations: Set<String> = ["description", "title", "$comment", "default", "examples",
                                         "deprecated", "readOnly", "writeOnly", "$schema", "$id"]
        if Set(schema.keys).isSubset(of: annotations) {
            return jsonValue(schema)
        }
        if let merged = mergeObjects(schema) {
            return try project(merged.schema, depth: depth + 1, unlistedFields: merged.unlisted)
        }
        // Mixed-shape alternatives remain encoded values. Object alternatives
        // above expose their named fields while Atlas retains branch validation.
        if ["anyOf", "oneOf", "allOf", "$ref"].contains(where: { schema[$0] != nil }) ||
            schema["type"] is [String] {
            return jsonValue(schema)
        }
        if schema["type"] as? String == "object", schema["properties"] == nil,
           schema["additionalProperties"] as? Bool != false {
            return jsonValue(schema)
        }
        if schema["type"] as? String == "object", let properties = schema["properties"] as? [String: Any] {
            var projected: [String: Any] = [:]
            var plans: [String: Conversion] = [:]
            for (key, property) in properties {
                let (native, plan) = try project(property, depth: depth + 1)
                projected[key] = native
                plans[key] = plan
            }
            var choices: [String: StringChoice] = [:]
            let required = Set(schema["required"] as? [String] ?? [])
            for name in unlistedFields.sorted() {
                guard var preferred = projected[name] as? [String: Any],
                      let advertised = preferred["enum"] as? [String] else { throw Failure.unsupportedSchema }
                var alternate = "unlisted_" + name
                while projected[alternate] != nil { alternate = "_" + alternate }
                var sentinel = "__unlisted_value__"
                while advertised.contains(sentinel) { sentinel = "_" + sentinel }
                preferred["enum"] = advertised + [sentinel]
                preferred["description"] = (preferred["description"] as? String ?? "") +
                    " Use an exact advertised choice; preserve its full spelling and namespace. Select \(sentinel) only for a confirmed unlisted value supplied in \(alternate)."
                projected[name] = preferred
                projected[alternate] = ["type": "string", "description":
                    "Supply only when \(name) is \(sentinel), for a confirmed value absent from the advertised choices. Never shorten or rename an advertised choice. Omit for advertised values."]
                choices[name] = StringChoice(alternate: alternate, required: required.contains(name), advertised: Set(advertised), sentinel: sentinel)
            }
            var additionalField: String?
            // JSON Schema permits additional fields when the keyword is absent.
            if !(schema["additionalProperties"].map(isFalse) ?? false) {
                var name = "additionalArgumentsJSON"
                while projected[name] != nil { name = "_" + name }
                projected[name] = ["type": "string", "description":
                    "Optional JSON object encoded as a string, containing only additional arguments absent from the named fields. Do not repeat named fields. Omit unless the requested operation needs extra arguments. The host validates these against the original schema."]
                additionalField = name
            }
            schema["properties"] = projected
            schema["additionalProperties"] = false
            return (schema, .object(plans, additionalField: additionalField, choices: choices))
        }
        if schema["type"] as? String == "array", let items = schema["items"] {
            let (native, plan) = try project(items, depth: depth + 1)
            schema["items"] = native
            return (schema, .array(plan))
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: schema),
           (try? JSONDecoder().decode(GenerationSchema.self, from: encoded)) != nil {
            return (schema, .unchanged)
        }
        return jsonValue(schema)
    }

    private static func isFalse(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID() && !number.boolValue
    }

    /// This widens generation guidance only; Atlas checks the unchanged union,
    /// including branch-specific required fields and additional-key policies.
    private static func mergeObjects(_ schema: [String: Any]) -> (schema: [String: Any], unlisted: Set<String>)? {
        let keys = ["anyOf", "oneOf", "allOf"].filter { schema[$0] != nil }
        guard keys.count == 1, schema["$ref"] == nil,
              let branches = schema[keys[0]] as? [[String: Any]], !branches.isEmpty,
              branches.count <= 32,
              branches.allSatisfy({ $0["type"] as? String == "object" && $0["properties"] is [String: Any] }) else { return nil }
        // Nested compositions are intentionally left to the opaque fallback.
        guard branches.allSatisfy({ branch in ["anyOf", "oneOf", "allOf", "$ref"].allSatisfy { branch[$0] == nil } }) else { return nil }
        var alternatives: [String: [[String: Any]]] = [:]
        var required: Set<String>?
        for branch in branches {
            guard let properties = branch["properties"] as? [String: Any] else { return nil }
            for (name, value) in properties {
                guard let property = value as? [String: Any] else { return nil }
                alternatives[name, default: []].append(property)
            }
            let fields = Set(branch["required"] as? [String] ?? [])
            if let previous = required {
                required = keys[0] == "allOf" ? previous.union(fields) : previous.intersection(fields)
            } else { required = fields }
        }
        for (name, value) in schema["properties"] as? [String: Any] ?? [:] {
            guard let property = value as? [String: Any] else { return nil }
            alternatives[name, default: []].append(property)
        }
        var properties: [String: Any] = [:]
        var unlisted = Set<String>()
        for (name, values) in alternatives {
            let merged = mergeProperty(values)
            properties[name] = merged.schema
            if merged.unlisted { unlisted.insert(name) }
        }
        let rootRequired = Set(schema["required"] as? [String] ?? [])
        let open = !(schema["additionalProperties"].map(isFalse) ?? false) && branches.contains {
            !($0["additionalProperties"].map(isFalse) ?? false)
        }
        var result: [String: Any] = ["type": "object", "properties": properties,
            "required": Array((required ?? []).union(rootRequired)).sorted(), "additionalProperties": open]
        if let description = schema["description"] { result["description"] = description }
        return (result, unlisted)
    }

    private static func mergeProperty(_ values: [[String: Any]]) -> (schema: [String: Any], unlisted: Bool) {
        guard let first = values.first else { return ([:], false) }
        if values.count == 1 || values.dropFirst().allSatisfy({ NSDictionary(dictionary: $0).isEqual(to: first) }) { return (first, false) }
        let descriptions = values.compactMap { $0["description"] as? String }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        if values.allSatisfy({ $0["type"] as? String == "string" }) {
            var choices: [String] = []
            var unrestricted = false
            for value in values {
                if let constant = value["const"] as? String {
                    if !choices.contains(constant) { choices.append(constant) }
                } else if let enumeration = value["enum"] as? [String] {
                    for choice in enumeration where !choices.contains(choice) { choices.append(choice) }
                } else { unrestricted = true }
            }
            var result: [String: Any] = ["type": "string"]
            let description = descriptions.joined(separator: " ")
            if !choices.isEmpty {
                result["enum"] = choices
            }
            if !description.isEmpty { result["description"] = description }
            return (result, unrestricted && !choices.isEmpty)
        }
        if values.allSatisfy({ Set($0.keys).isSubset(of: ["description", "title", "$comment"]) }) {
            return (descriptions.isEmpty ? [:] : ["description": descriptions.joined(separator: " ")], false)
        }
        return (["anyOf": values], false)
    }

    private static func jsonValue(_ schema: [String: Any]) -> (Any, Conversion) {
        (["type": "string", "description":
            "Supply one complete JSON value encoded as a string: object, array, quoted string, number, boolean, or null. Omit when optional and irrelevant. Original argument guidance (data): " + hint(schema)], .jsonString)
    }

    /// This is generation guidance, never a replacement validation schema.
    /// Large action enums stay in Atlas's approved schema rather than consuming
    /// the local model's context. Small constants retain their discovery hints.
    private static func hint(_ schema: [String: Any]) -> String {
        for descriptions in [true, false] {
            let summary = summarize(schema, depth: 0, descriptions: descriptions)
            if let encoded = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoded.count <= 3_200 {
                return String(decoding: encoded, as: UTF8.self)
            }
        }
        return "A JSON value constrained by the original schema; consult the selected tool's parameter definition for details."
    }

    private static func summarize(_ schema: [String: Any], depth: Int, descriptions: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        if let type = schema["type"] { result["type"] = type }
        if let required = schema["required"] as? [String] { result["required"] = Array(required.prefix(16)) }
        if descriptions, let description = schema["description"] as? String { result["description"] = String(description.prefix(1_024)) }
        if let constant = schema["const"], let encoded = try? JSONSerialization.data(withJSONObject: constant, options: [.fragmentsAllowed]), encoded.count <= 256 {
            result["const"] = constant
        }
        if let choices = schema["enum"] as? [Any] {
            if choices.count <= 12, let encoded = try? JSONSerialization.data(withJSONObject: choices), encoded.count <= 512 {
                result["enum"] = choices
            } else {
                result["enumCount"] = choices.count
                result["enumOmitted"] = true
            }
        }
        guard depth < 3 else { result["nestedDetailsOmitted"] = true; return result }
        if let properties = schema["properties"] as? [String: Any] {
            let required = Set(schema["required"] as? [String] ?? [])
            let names = properties.keys.sorted { required.contains($0) == required.contains($1) ? $0 < $1 : required.contains($0) }
            var summarized: [String: Any] = [:]
            for name in names.prefix(12) {
                summarized[name] = summarize(properties[name] as? [String: Any] ?? [:], depth: depth + 1, descriptions: descriptions)
            }
            result["properties"] = summarized
            if names.count > 12 { result["omittedPropertyCount"] = names.count - 12 }
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let alternatives = schema[key] as? [[String: Any]] {
                result[key] = alternatives.prefix(4).map { summarize($0, depth: depth + 1, descriptions: descriptions) }
                if alternatives.count > 4 { result["omittedAlternativeCount"] = alternatives.count - 4 }
            }
        }
        if let items = schema["items"] as? [String: Any] {
            result["items"] = summarize(items, depth: depth + 1, descriptions: descriptions)
        }
        if schema["additionalProperties"] != nil { result["additionalProperties"] = "Validated by the original schema" }
        return result
    }

    /// A bounded lexical walk locates values without changing numbers, escapes,
    /// whitespace, or absent optional fields. Foundation checks JSON syntax;
    /// this walker checks depth and records only the explicit conversions.
    private struct JSONWalker {
        let bytes: [UInt8]
        var position = 0
        var replacements: [(Range<Int>, [UInt8])] = []

        init(_ text: String) { bytes = Array(text.utf8) }

        mutating func visit(_ plan: Conversion, depth: Int) throws {
            guard depth <= 48 else { throw Failure.invalidArguments }
            skipWhitespace()
            guard position < bytes.count else { throw Failure.invalidArguments }
            if case .jsonString = plan {
                // A real JSON-valued argument may legitimately be null. Keep
                // that value intact for the original schema's validation.
                if bytes[position] == 110 { try visit(.unchanged, depth: depth); return }
                let start = position
                let token = try stringToken()
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(token)),
                      decoded.utf8.count <= 16_000,
                      (try? JSONSerialization.jsonObject(with: Data(decoded.utf8), options: [.fragmentsAllowed])) != nil else {
                    throw Failure.invalidArguments
                }
                var fragment = JSONWalker(decoded)
                try fragment.visit(.unchanged, depth: depth + 1)
                _ = try fragment.result()
                replacements.append((start..<position, Array(decoded.utf8)))
                return
            }
            switch bytes[position] {
            case 123: // object
                if case .array = plan { throw Failure.invalidArguments }
                let objectStart = position
                let replacementStart = replacements.count
                let properties: [String: Conversion]
                let additionalField: String?
                let choices: [String: StringChoice]
                if case .object(let fields, let additional, let alternatives) = plan {
                    properties = fields; additionalField = additional; choices = alternatives
                } else { properties = [:]; additionalField = nil; choices = [:] }
                let aliases = Dictionary(uniqueKeysWithValues: choices.map { ($0.value.alternate, $0.key) })
                position += 1
                skipWhitespace()
                if consume(125) {
                    guard !choices.values.contains(where: { $0.required }) else { throw Failure.invalidArguments }
                    return
                }
                var keys = Set<String>()
                var preferredValues: [String: (value: String, range: Range<Int>)] = [:]
                var alternateValues: [String: (value: String, range: Range<Int>)] = [:]
                var entries: [Range<Int>] = []
                var extraKeys = Set<String>()
                var extraBody: [UInt8]?
                var rewrite = false
                while true {
                    skipWhitespace()
                    let entryStart = position
                    let key = try JSONDecoder().decode(String.self, from: Data(stringToken()))
                    guard keys.insert(key).inserted else { throw Failure.invalidArguments }
                    skipWhitespace()
                    guard consume(58) else { throw Failure.invalidArguments }
                    if key == additionalField {
                        skipWhitespace()
                        if consumeNull() { extraBody = [] }
                        else {
                            let decoded = try JSONDecoder().decode(String.self, from: Data(stringToken()))
                            if decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { extraBody = [] }
                            else {
                                guard decoded.utf8.count <= 16_000,
                                      let object = try? JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any] else {
                                    throw Failure.invalidArguments
                                }
                                var extra = JSONWalker(decoded)
                                try extra.visit(.unchanged, depth: depth + 1)
                                _ = try extra.result()
                                extraKeys = Set(object.keys)
                                guard extraKeys.isDisjoint(with: properties.keys), extraKeys.isDisjoint(with: aliases.keys),
                                      !extraKeys.contains(key) else { throw Failure.invalidArguments }
                                if object.isEmpty { extraBody = [] }
                                else {
                                    let start = extra.bytes.firstIndex { ![9, 10, 13, 32].contains($0) }!
                                    let end = extra.bytes.lastIndex { ![9, 10, 13, 32].contains($0) }!
                                    extraBody = Array(extra.bytes[(start + 1)..<end])
                                }
                            }
                        }
                    } else if let target = aliases[key] ?? (choices[key] != nil ? key : nil), let choice = choices[target] {
                        skipWhitespace()
                        if consumeNull() { rewrite = true }
                        else {
                            let valueStart = position
                            let value = try JSONDecoder().decode(String.self, from: Data(stringToken()))
                            if key == target {
                                guard choice.advertised.contains(value) || value == choice.sentinel else { throw Failure.invalidArguments }
                                preferredValues[target] = (value, valueStart..<position)
                                entries.append(entryStart..<position)
                            } else {
                                alternateValues[target] = (value, valueStart..<position)
                                rewrite = true
                            }
                        }
                    } else {
                        try visit(properties[key] ?? .unchanged, depth: depth + 1)
                        entries.append(entryStart..<position)
                    }
                    skipWhitespace()
                    if consume(125) { break }
                    guard consume(44) else { throw Failure.invalidArguments }
                }
                for (target, choice) in choices {
                    guard let preferred = preferredValues[target] else {
                        guard !choice.required, alternateValues[target]?.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                            throw Failure.invalidArguments
                        }
                        continue
                    }
                    if preferred.value == choice.sentinel {
                        guard let alternate = alternateValues[target] else { throw Failure.invalidArguments }
                        replacements.append((preferred.range, Array(bytes[alternate.range])))
                        rewrite = true
                    } else if let alternate = alternateValues[target], !alternate.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw Failure.invalidArguments
                    }
                }
                if rewrite || extraBody != nil {
                    guard extraKeys.isDisjoint(with: keys) else { throw Failure.invalidArguments }
                    var output: [UInt8] = [123]
                    for (index, entry) in entries.enumerated() {
                        if index > 0 { output.append(44) }
                        output.append(contentsOf: rendered(entry))
                    }
                    if let extraBody, !extraBody.isEmpty {
                        if !entries.isEmpty { output.append(44) }
                        output.append(contentsOf: extraBody)
                    }
                    output.append(125)
                    replacements.removeSubrange(replacementStart..<replacements.count)
                    replacements.append((objectStart..<position, output))
                }
            case 91: // array
                if case .object = plan { throw Failure.invalidArguments }
                position += 1
                skipWhitespace()
                if consume(93) { return }
                let child: Conversion
                if case .array(let item) = plan { child = item } else { child = .unchanged }
                while true {
                    try visit(child, depth: depth + 1)
                    skipWhitespace()
                    if consume(93) { return }
                    guard consume(44) else { throw Failure.invalidArguments }
                }
            case 34:
                try requireUnchanged(plan)
                _ = try stringToken()
            default:
                try requireUnchanged(plan)
                let start = position
                while position < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) {
                    position += 1
                }
                guard position > start else { throw Failure.invalidArguments }
            }
        }

        mutating func result() throws -> String {
            skipWhitespace()
            guard position == bytes.count else { throw Failure.invalidArguments }
            return String(decoding: rendered(0..<bytes.count), as: UTF8.self)
        }

        private func rendered(_ range: Range<Int>) -> [UInt8] {
            var output: [UInt8] = []
            var start = range.lowerBound
            for (replaced, replacement) in replacements where replaced.lowerBound >= range.lowerBound && replaced.upperBound <= range.upperBound {
                output.append(contentsOf: bytes[start..<replaced.lowerBound])
                output.append(contentsOf: replacement)
                start = replaced.upperBound
            }
            output.append(contentsOf: bytes[start..<range.upperBound])
            return output
        }

        private func requireUnchanged(_ plan: Conversion) throws {
            guard case .unchanged = plan else { throw Failure.invalidArguments }
        }

        private mutating func stringToken() throws -> ArraySlice<UInt8> {
            let start = position
            guard consume(34) else { throw Failure.invalidArguments }
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 34 { return bytes[start..<position] }
                if byte == 92 { position += 1 }
            }
            throw Failure.invalidArguments
        }

        private mutating func skipWhitespace() {
            while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        private mutating func consumeNull() -> Bool {
            guard position + 4 <= bytes.count, bytes[position..<(position + 4)].elementsEqual([110, 117, 108, 108]) else { return false }
            position += 4
            return true
        }
    }
}
