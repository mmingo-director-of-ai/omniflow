import Foundation
import FoundationModels

enum AtlasMCPGenerationSchemaChecks {
    static func run() throws {
        let schema = #"{"type":"object","properties":{"action":{"type":"string","enum":["read","write"]},"recordId":{"type":"string"},"content":{"description":"JSON document or text"}},"required":["action"]}"#
        let projected = try AtlasMCPGenerationSchema(inputSchemaJSON: schema)
        let native = try JSONSerialization.jsonObject(with: JSONEncoder().encode(projected.parameters)) as! [String: Any]
        let properties = native["properties"] as! [String: Any]
        precondition((properties["content"] as! [String: Any])["type"] as? String == "string")
        precondition((properties["action"] as! [String: Any])["enum"] as? [String] == ["read", "write"])
        precondition(native["required"] as? [String] == ["action"], "Projection changed required fields")

        let read = #"{ "action": "read", "recordId": "record-42" }"#
        let restoredRead = try projected.argumentsJSON(from: read)
        precondition(restoredRead == read,
                     "Read arguments changed or an omitted optional content field appeared")

        for fragment in [#"{"items":[1,true,null,"text"],"exact":9007199254740993}"#,
                         #"[false,{"x":"escaped \" value"}]"#, #""a string""#,
                         "9007199254740993", "1e-20", "true", "null"] {
            let input = String(decoding: try JSONEncoder().encode(["action": "write", "content": fragment]), as: UTF8.self)
            let restored = try projected.argumentsJSON(from: input)
            // The exact lexical fragment is forwarded, never a rounded NSNumber.
            precondition(restored.contains(":" + fragment) || restored.contains(": " + fragment),
                         "An arbitrary JSON fragment was altered")
            let result = try JSONSerialization.jsonObject(with: Data(restored.utf8)) as! [String: Any]
            precondition(result["action"] as? String == "write")
        }

        let nested = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"key":{"type":"string"},"value":{}},"required":["key","value"]}},"values":{"type":"array","items":{}},"unchanged":{"type":"number"}},"required":["items"]}"#)
        let nestedInput = #"{"items":[{"key":"a","value":"{\"exact\":9007199254740993}"},{"key":"b","value":"null"}],"values":["true","[1,2]","\"text\""],"unchanged":9007199254740993}"#
        let nestedExpected = #"{"items":[{"key":"a","value":{"exact":9007199254740993}},{"key":"b","value":null}],"values":[true,[1,2],"text"],"unchanged":9007199254740993}"#
        let restoredNested = try nested.argumentsJSON(from: nestedInput)
        precondition(restoredNested == nestedExpected,
                     "Nested projection changed paths, null, or exact number digits")

        let typed = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"count":{"type":"number"}},"required":["count"]}"#)
        let typedInput = #"{"count":9007199254740993}"#
        let restoredTyped = try typed.argumentsJSON(from: typedInput)
        precondition(restoredTyped == typedInput,
                     "A compatible native schema changed arguments before Go validation")

        let booleanSchema = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"value":true},"required":["value"]}"#)
        let restoredBoolean = try booleanSchema.argumentsJSON(from: #"{"value":"false"}"#)
        precondition(restoredBoolean == #"{"value":false}"#)

        let manyProperties = Dictionary(uniqueKeysWithValues: (0..<150).map { ("value\($0)", [:] as [String: String]) })
        let largeProjection = try JSONSerialization.data(withJSONObject: ["type": "object", "properties": manyProperties])
        let compactProjection = try AtlasMCPGenerationSchema(inputSchemaJSON: String(decoding: largeProjection, as: UTF8.self))
        let compactBytes = try JSONEncoder().encode(compactProjection.parameters).count
        precondition(compactBytes < 4_000,
                     "An oversized native projection was copied into the model context")
        try compositionAndMapChecks()
        try operationBindingChecks()

        for invalid in [#"{"action":"write","content":"{broken}"}"#,
                        #"{"action":"write","content":"1 2"}"#,
                        #"{"action":"write","content":{"unexpected":"unencoded"}}"#,
                        #"{"action":"write","content":""}"#,
                        #"["not an object"]"#] {
            try expectFailure { _ = try projected.argumentsJSON(from: invalid) }
        }
        let deepFragment = String(repeating: "[", count: 50) + "0" + String(repeating: "]", count: 50)
        let deepInput = String(decoding: try JSONEncoder().encode(["content": deepFragment]), as: UTF8.self)
        try expectFailure { _ = try projected.argumentsJSON(from: deepInput) }
        let oversized = String(decoding: try JSONEncoder().encode(["recordId": String(repeating: "x", count: 16_001)]), as: UTF8.self)
        try expectFailure { _ = try projected.argumentsJSON(from: oversized) }

        // Extremely large numbers may be rejected by Foundation's syntax check,
        // but must never be silently rounded on their way to Atlas validation.
        let huge = String(repeating: "9", count: 300)
        let hugeInput = String(decoding: try JSONEncoder().encode(["content": huge]), as: UTF8.self)
        if let result = try? projected.argumentsJSON(from: hugeInput) {
            precondition(result.contains(huge), "A large numeric fragment was silently rounded")
        }
        print("MCP native generation-schema projection checks passed")
    }

    private static func compositionAndMapChecks() throws {
        let choices = (0..<250).map { "operation_\($0)" }
        let schema: [String: Any] = ["type": "object", "anyOf": [
            ["type": "object", "properties": ["operation": ["type": "string", "const": "catalog.operations",
                "description": "Read the available operation catalog."]], "required": ["operation"], "additionalProperties": [:]],
            ["type": "object", "properties": ["operation": ["type": "string", "enum": choices],
                "body": ["description": "The operation's arguments."]], "required": ["operation"], "additionalProperties": [:]],
        ]]
        let union = try AtlasMCPGenerationSchema(inputSchemaJSON: String(decoding: JSONSerialization.data(withJSONObject: schema), as: UTF8.self))
        let encoded = try JSONEncoder().encode(union.parameters)
        let native = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(native["type"] as? String == "object" && native["required"] as? [String] == ["operation"])
        let nativeFields = native["properties"] as! [String: Any]
        let operation = nativeFields["operation"] as! [String: Any]
        precondition(operation["enum"] as? [String] == ["catalog.operations"] + choices,
                     "Merging finite alternatives lost advertised choices")
        let text = String(decoding: encoded, as: UTF8.self)
        precondition(text.contains("catalog.operations") && text.contains("Read the available operation catalog."),
                     "A merged union lost its discriminator and discovery guidance")
        let original = #"{"operation":"operation_249","body":{"count":9007199254740993,"small":1e-20},"extra":[true,null]}"#
        let unionRestored = try union.argumentsJSON(from: #"{"operation":"operation_249","body":"{\"count\":9007199254740993,\"small\":1e-20}","additionalArgumentsJSON":"{\"extra\":[true,null]}"}"#)
        precondition(unionRestored == original,
                     "Named union arguments lost fields or exact numeric digits")

        var unrestrictedSchema = schema
        var alternatives = schema["anyOf"] as! [[String: Any]]
        alternatives.append(["type": "object", "properties": ["operation": ["type": "string"]], "required": ["operation"]])
        unrestrictedSchema["anyOf"] = alternatives
        let unrestricted = try AtlasMCPGenerationSchema(inputSchemaJSON: String(decoding: JSONSerialization.data(withJSONObject: unrestrictedSchema), as: UTF8.self))
        let unrestrictedNative = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unrestricted.parameters)) as! [String: Any]
        let unrestrictedFields = unrestrictedNative["properties"] as! [String: Any]
        let unrestrictedOperation = unrestrictedFields["operation"] as! [String: Any]
        precondition(unrestrictedOperation["enum"] as? [String] == ["catalog.operations"] + choices + ["__unlisted_value__"] && unrestrictedFields["unlisted_operation"] != nil,
                     "A union lost its native choices or separate arbitrary-string branch")
        precondition(unrestrictedNative["required"] as? [String] == ["operation"], "Projection made an original-required discriminator optional")
        let advertisedRestored = try unrestricted.argumentsJSON(from: #"{"operation":"operation_249","unlisted_operation":null,"additionalArgumentsJSON":null}"#)
        precondition(advertisedRestored == #"{"operation":"operation_249"}"#)
        let blankPlaceholderRestored = try unrestricted.argumentsJSON(from: #"{"unlisted_operation":"","operation":"operation_249","additionalArgumentsJSON":" "}"#)
        precondition(blankPlaceholderRestored == #"{"operation":"operation_249"}"#,
                     "Blank synthetic placeholders conflicted with an advertised value")
        let unlistedRestored = try unrestricted.argumentsJSON(from: #"{"operation":"__unlisted_value__","unlisted_operation":"confirmed.external_operation","body":null,"additionalArgumentsJSON":null}"#)
        precondition(unlistedRestored == #"{"operation":"confirmed.external_operation","body":null}"#,
                     "An unlisted operation or real null argument was lost during restoration")
        let emptyUnlisted = try unrestricted.argumentsJSON(from: #"{"operation":"__unlisted_value__","unlisted_operation":""}"#)
        precondition(emptyUnlisted == #"{"operation":""}"#, "An explicit unlisted empty string was removed")
        for invalid in [#"{}"#, #"{"operation":null,"unlisted_operation":null}"#,
                        #"{"operation":"operation_249","unlisted_operation":"confirmed.external_operation"}"#,
                        #"{"operation":"invented_short_name"}"#,
                        #"{"unlisted_operation":"operation_249"}"#,
                        #"{"operation":"__unlisted_value__","unlisted_operation":null}"#,
                        #"{"operation":"__unlisted_value__"}"#] {
            try expectFailure { _ = try unrestricted.argumentsJSON(from: invalid) }
        }
        var aliasCollisionSchema = unrestrictedSchema
        aliasCollisionSchema["properties"] = ["unlisted_operation": ["type": "string"]]
        let aliasCollision = try AtlasMCPGenerationSchema(inputSchemaJSON: String(decoding: JSONSerialization.data(withJSONObject: aliasCollisionSchema), as: UTF8.self))
        let collisionRestored = try aliasCollision.argumentsJSON(from: #"{"_unlisted_operation":"confirmed.external_operation","operation":"__unlisted_value__","unlisted_operation":"original field"}"#)
        precondition(collisionRestored == #"{"operation":"confirmed.external_operation","unlisted_operation":"original field"}"#,
                     "An unlisted-choice alias shadowed an original field")

        for keyword in ["oneOf", "allOf"] {
            let composite = try AtlasMCPGenerationSchema(inputSchemaJSON:
                "{\"type\":\"object\",\"\(keyword)\":[{\"type\":\"object\",\"properties\":{\"count\":{\"type\":\"number\"}}}]}")
            let restored = try composite.argumentsJSON(from: #"{"count":9007199254740993}"#)
            precondition(restored == #"{"count":9007199254740993}"#)
        }
        let conditional = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","oneOf":[{"type":"object","properties":{"a":{"type":"string"},"common":{"type":"string"}},"required":["a","common"]},{"type":"object","properties":{"b":{"type":"number"},"common":{"type":"string"}},"required":["b","common"]}]}"#)
        let conditionalNative = try JSONSerialization.jsonObject(with: JSONEncoder().encode(conditional.parameters)) as! [String: Any]
        precondition(conditionalNative["required"] as? [String] == ["common"], "Union projection required fields from incompatible branches")
        let map = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"values":{"type":"object","additionalProperties":{"type":"number"}},"choice":{"oneOf":[{"type":"null"},{"type":"object","properties":{"id":{"type":"string"}}}]}},"required":["values"]}"#)
        let restored = try map.argumentsJSON(from: #"{"values":"{\"arbitrary/key\":9007199254740993,\"fraction\":1e-20}","choice":"{\"id\":\"abc\"}"}"#)
        precondition(restored == #"{"values":{"arbitrary/key":9007199254740993,"fraction":1e-20},"choice":{"id":"abc"}}"#,
                     "Nested map or union arguments were not restored exactly")
        let openRoot = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"operation":{"type":"string"}},"required":["operation"],"additionalProperties":{}}"#)
        let openBody = #"{"operation":"read","unknown":{"nested":9007199254740993}}"#
        let openRestored = try openRoot.argumentsJSON(from: #"{"operation":"read","additionalArgumentsJSON":"{\"unknown\":{\"nested\":9007199254740993}}"}"#)
        precondition(openRestored == openBody,
                     "An explicitly open object lost additional argument names")
        let defaultOpen = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"operation":{"type":"string"}},"required":["operation"]}"#)
        let defaultOpenRestored = try defaultOpen.argumentsJSON(from: #"{"additionalArgumentsJSON":"{\"unknown\":{\"nested\":9007199254740993}}","operation":"read"}"#)
        precondition(defaultOpenRestored == openBody,
                     "Omitting additionalProperties silently removed extra-argument support")
        let empty = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{},"required":[]}"#)
        let emptyRestored = try empty.argumentsJSON(from: #"{"additionalArgumentsJSON":null}"#)
        precondition(emptyRestored == "{}", "A null optional synthetic extra argument broke an empty call")
        let observedPortalRestored = try empty.argumentsJSON(from: #"{"additionalArgumentsJSON":""}"#)
        precondition(observedPortalRestored == "{}", "The observed native empty-string placeholder broke the portal call")
        let realString = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"value":{"type":"string"}},"additionalProperties":false}"#)
        let blankOriginal = try realString.argumentsJSON(from: #"{"value":""}"#)
        precondition(blankOriginal == #"{"value":""}"#, "A blank original string was removed as a synthetic placeholder")
        let nullOriginal = try projectedNullArguments()
        precondition(nullOriginal == #"{"value":null}"#, "A real optional null argument was silently removed")
        let closed = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"operation":{"type":"string"}},"additionalProperties":false}"#)
        let closedNative = try JSONSerialization.jsonObject(with: JSONEncoder().encode(closed.parameters)) as! [String: Any]
        precondition((closedNative["properties"] as! [String: Any])["additionalArgumentsJSON"] == nil,
                     "A closed object was given an extra-argument projection")
        let unstructured = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"body":{"type":"object"}},"required":["body"]}"#)
        let unstructuredRestored = try unstructured.argumentsJSON(from: #"{"body":"{\"arbitrary\":9007199254740993}"}"#)
        precondition(unstructuredRestored == #"{"body":{"arbitrary":9007199254740993}}"#,
                     "An object without declared properties lost arbitrary keys")

        let nestedExtras = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"body":{"type":"object","properties":{"value":{}},"additionalProperties":true},"additionalArgumentsJSON":{"type":"string"}},"additionalProperties":true}"#)
        let nestedExtrasRestored = try nestedExtras.argumentsJSON(from: #"{"_additionalArgumentsJSON":"{\"rootCount\":9007199254740993}","body":{"additionalArgumentsJSON":"{\"childCount\":9007199254740993}","value":"{\"fraction\":1e-20}"},"additionalArgumentsJSON":"real original field"}"#)
        precondition(nestedExtrasRestored == #"{"body":{"value":{"fraction":1e-20},"childCount":9007199254740993},"additionalArgumentsJSON":"real original field","rootCount":9007199254740993}"#,
                     "Nested extras overlapped lexical replacements or shadowed an original parameter")

        for invalid in [#"{"operation":"read","additionalArgumentsJSON":"{\"operation\":\"write\"}"}"#,
                        #"{"operation":"read","additionalArgumentsJSON":"{\"x\":1,\"x\":2}"}"#,
                        #"{"operation":"read","additionalArgumentsJSON":"{\"x\":1}","x":2}"#,
                        #"{"operation":"read","additionalArgumentsJSON":"[]"}"#,
                        #"{"operation":"read","additionalArgumentsJSON":{"x":1}}"#] {
            try expectFailure { _ = try openRoot.argumentsJSON(from: invalid) }
        }

        let opaque = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","anyOf":[{"type":"object","properties":{"operation":{"type":"string"}}},{"type":"array","items":{"type":"string"}}]}"#)
        for invalid in [#"{"operation":"read"}"#, #"{"argumentsJSON":"[]"}"#,
                        #"{"argumentsJSON":"null"}"#, #"{"argumentsJSON":"{broken}"}"#,
                        #"{"argumentsJSON":"{}","extra":true}"#,
                        #"{"argumentsJSON":"{}","argumentsJSON":"{}"}"#,
                        try wrap(#"{"operation":"read","\u006fperation":"write"}"#)] {
            try expectFailure { _ = try opaque.argumentsJSON(from: invalid) }
        }
        try expectFailure { _ = try map.argumentsJSON(from: #"{"values":"{\"a\":1,\"a\":2}"}"#) }
        try expectFailure { _ = try map.argumentsJSON(from: #"{"values":{"a":1}}"#) }
        try expectFailure { _ = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"array","items":{"type":"string"}}"#) }
    }

    private static func projectedNullArguments() throws -> String {
        let schema = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{"value":{}},"additionalProperties":false}"#)
        return try schema.argumentsJSON(from: #"{"value":null}"#)
    }

    private static func operationBindingChecks() throws {
        let choices = (0..<450).map { "records.read_\($0)" }
        let original: [String: Any] = ["type": "object", "anyOf": [
            ["type": "object", "properties": ["action": ["type": "string", "const": "tools.catalog"],
                "catalogFilter": ["type": "string"]], "required": ["action", "catalogFilter"], "additionalProperties": false],
            ["type": "object", "properties": ["action": ["type": "string", "enum": choices],
                "payload": [:]], "required": ["action", "payload"], "additionalProperties": false]
        ]]
        let schemaJSON = String(decoding: try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]), as: UTF8.self)
        let advertised = try AtlasMCPGenerationSchema.advertisedOperations(inputSchemaJSON: schemaJSON)
        precondition(advertised == (["tools.catalog"] + choices).map { AtlasMCPOperationBinding(field: "action", value: $0) },
                     "Operation extraction omitted, duplicated, reordered, or invented advertised names")
        let selected = AtlasMCPOperationBinding(field: "action", value: "records.read_449")
        let narrowed = try AtlasMCPGenerationSchema(inputSchemaJSON: schemaJSON, operation: selected)
        let nativeData = try JSONEncoder().encode(narrowed.parameters)
        let native = try JSONSerialization.jsonObject(with: nativeData) as! [String: Any]
        let fields = native["properties"] as! [String: Any]
        precondition((fields["action"] as! [String: Any])["enum"] as? [String] == [selected.value])
        precondition(fields["catalogFilter"] == nil && fields["unlisted_action"] == nil,
                     "A selected operation retained incompatible branches or an unlisted escape")
        precondition(Set(native["required"] as! [String]) == ["action", "payload"],
                     "Selecting one union arm lost its branch-specific required arguments")
        precondition(nativeData.count < 1_500, "A selected operation retained the large action catalog")
        let encoded = #"{"action":"records.read_449","payload":"{\"count\":9007199254740993,\"small\":1e-20}"}"#
        let restored = try narrowed.argumentsJSON(from: encoded)
        precondition(restored == #"{"action":"records.read_449","payload":{"count":9007199254740993,"small":1e-20}}"#,
                     "Constrained generation altered numeric digits or payload arguments")
        for invalid in [#"{"action":"records.read_448"}"#, #"{}"#, #"{"action":null}"#,
                        #"{"action":"records.read_449","\u0061ction":"tools.catalog"}"#] {
            try expectFailure { _ = try narrowed.argumentsJSON(from: invalid) }
        }
        try expectFailure { _ = try AtlasMCPGenerationSchema(inputSchemaJSON: schemaJSON,
            operation: .init(field: "action", value: "unadvertised.read")) }
        try expectFailure { _ = try AtlasMCPGenerationSchema(inputSchemaJSON: schemaJSON,
            operation: .init(field: "payload", value: "records.read_449")) }

        var withOpenBranch = original
        var branches = original["anyOf"] as! [[String: Any]]
        branches.append(["type": "object", "properties": ["action": ["type": "string"], "payload": [:]],
                         "required": ["action"], "additionalProperties": true])
        withOpenBranch["anyOf"] = branches
        let openJSON = String(decoding: try JSONSerialization.data(withJSONObject: withOpenBranch), as: UTF8.self)
        let learned = try AtlasMCPGenerationSchema(inputSchemaJSON: openJSON,
            operation: .init(field: "action", value: "confirmed.learned_read"))
        let learnedResult = try learned.argumentsJSON(from: #"{"action":"confirmed.learned_read","payload":"{\"count\":9007199254740993}","additionalArgumentsJSON":null}"#)
        precondition(learnedResult == #"{"action":"confirmed.learned_read","payload":{"count":9007199254740993}}"#,
                     "An original open string arm could not bind a learned operation")
        try expectFailure { _ = try learned.argumentsJSON(from: #"{"action":"confirmed.other_read"}"#) }

        let methodSchema = #"{"type":"object","properties":{"method":{"type":"string","enum":["records.read","records.read"]},"payload":{"type":"object","properties":{"action":{"type":"string","enum":["nested.ignored"]}}}},"required":["method"]}"#
        let methods = try AtlasMCPGenerationSchema.advertisedOperations(inputSchemaJSON: methodSchema)
        precondition(methods == [.init(field: "method", value: "records.read")],
                     "Catalog extraction included a nested payload dispatch or duplicate")
        let method = try AtlasMCPGenerationSchema(inputSchemaJSON: methodSchema,
            operation: .init(field: "method", value: "records.read"))
        let methodResult = try method.argumentsJSON(from: #"{"method":"records.read"}"#)
        precondition(methodResult == #"{"method":"records.read"}"#)
        let free = #"{"type":"object","properties":{"action":{"type":"string"}},"required":["action"]}"#
        let freeChoices = try AtlasMCPGenerationSchema.advertisedOperations(inputSchemaJSON: free)
        precondition(freeChoices.isEmpty)
        try expectFailure { _ = try AtlasMCPGenerationSchema(inputSchemaJSON: #"{"type":"object","properties":{}}"#,
            operation: .init(field: "action", value: "invented.read")) }
        let intersection = #"{"type":"object","allOf":[{"type":"object","properties":{"action":{"type":"string","enum":["read"]}}},{"type":"object","properties":{"action":{"type":"string","enum":["write"]}}}]}"#
        try expectFailure { _ = try AtlasMCPGenerationSchema(inputSchemaJSON: intersection,
            operation: .init(field: "action", value: "read")) }
    }

    private static func wrap(_ object: String) throws -> String {
        String(decoding: try JSONEncoder().encode(["argumentsJSON": object]), as: UTF8.self)
    }

    private static func expectFailure(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        preconditionFailure("Invalid projected arguments were accepted")
    }
}
