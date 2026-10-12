import Foundation

enum AtlasMCPOperationRoutingChecks {
    static func run() throws {
        let schema = #"{"type":"object","properties":{"action":{"type":"string","description":"Operation namespaces include records.read, metadata.get_object_metadata and tools.catalog."},"payload":{}},"required":["action"]}"#
        let selected = tool(schema)
        for binding in [AtlasMCPOperationBinding(field: "action", value: "metadata.get_object_metadata"),
                        .init(field: "method", value: "records.read"), .init(field: "operation", value: "tools.catalog")] {
            precondition(AtlasMCPOperationRouting.readBinding(binding, selected: selected),
                         "A documented read was rejected before metadata continuation")
        }
        for binding in [AtlasMCPOperationBinding(field: "action", value: "records.create"),
                        .init(field: "action", value: "nested.delete_then_read"),
                        .init(field: "action", value: "records..read"),
                        .init(field: "action", value: "records.unknown"),
                        .init(field: "server", value: "records.read")] {
            precondition(!AtlasMCPOperationRouting.readBinding(binding, selected: selected),
                         "An automatic metadata binding allowed a mutation, unknown dispatch or identity substitution")
        }
        let flat = try AtlasMCPOperationRouting.catalog(#"{"actions":[{"action":"records.list","description":"List records"},{"operation":"metadata.get_object_metadata","purpose":"Read object definitions"},{"name":"records.list","description":"duplicate"}]}"#, selected: selected)
        precondition(flat.map(\.binding) == [.init(field: "action", value: "records.list"),
                                             .init(field: "action", value: "metadata.get_object_metadata")],
                     "Flat catalogs changed exact names, dispatch field, order or duplicate suppression")
        let grouped = try AtlasMCPOperationRouting.catalog(#"{"catalog":{"METADATA":[{"name":"get_object_metadata","description":"Read object definitions"}],"RECORDS":[{"name":"list","description":"List records"}],"UNDOCUMENTED":[{"name":"read","description":"Unknown namespace"}]}}"#, selected: selected)
        precondition(Set(grouped.map(\.binding)) == [.init(field: "action", value: "metadata.get_object_metadata"),
                                                    .init(field: "action", value: "records.list")],
                     "Grouped catalog names were not restricted to documented dispatch namespaces")
        let help = try AtlasMCPOperationRouting.catalog(#"{"domain":"metadata","operations":{"get_object_metadata":{"purpose":"Read an object's fields"},"list_objects":{"description":"List types"}}}"#, selected: selected)
        precondition(help.map(\.binding.value) == ["metadata.get_object_metadata", "metadata.list_objects"],
                     "An operation-help map lost its documented namespace")
        let method = tool(#"{"type":"object","properties":{"method":{"type":"string","enum":["records.read","records.list"]}},"required":["method"]}"#)
        let known = try AtlasMCPOperationRouting.advertised(method)
        precondition(known.map(\.binding) == [.init(field: "method", value: "records.read"), .init(field: "method", value: "records.list")])
        let learnedFromNamespace = try AtlasMCPOperationRouting.catalog(#"{"RECORDS":[{"name":"read"}]}"#, selected: method)
        precondition(learnedFromNamespace.map(\.binding) == [.init(field: "method", value: "records.read")])
        let generated = try AtlasMCPGenerationSchema(inputSchemaJSON: schema, operation: flat[1].binding)
        let restored = try generated.argumentsJSON(from: #"{"action":"metadata.get_object_metadata","payload":"{\"limit\":9007199254740993}"}"#)
        precondition(restored == #"{"action":"metadata.get_object_metadata","payload":{"limit":9007199254740993}}"#)
        precondition(selected.inputSchemaJSON == schema && selected.server == "s2" && selected.name == "generic_records",
                     "Metadata selection changed the original schema or capability binding")
        try expectFailure { _ = try generated.argumentsJSON(from: #"{"action":"records.list"}"#) }

        let keys: Set<String> = ["o0", "o1", "continue_without_operation"]
        let chosen = try AtlasMCPOperationRouting.selection(#"{"choice":"o1"}"#, keys: keys)
        precondition(chosen == "o1" && flat[1].binding.value == "metadata.get_object_metadata")
        let declined = try AtlasMCPOperationRouting.selection(#"{"choice":"continue_without_operation"}"#, keys: keys)
        precondition(declined == "continue_without_operation")
        for invalid in [#"{"choice":"metadata.get_object_metadata"}"#, #"{"choice":"o2"}"#,
                        #"{"choice":"next_page"}"#, #"{"choice":"o1","server":"s3"}"#,
                        #"{"choice":1}"#, #"{"choice":null}"#, #"{}"#, #"[]"#,
                        String(repeating: "x", count: 2049)] {
            try expectFailure { _ = try AtlasMCPOperationRouting.selection(invalid, keys: keys) }
        }
        for malformed in ["{broken}", "null", "[]", "{}", #"{"actions":[null,1,true]}"#] {
            let choices = try AtlasMCPOperationRouting.catalog(malformed, selected: selected)
            precondition(choices.isEmpty, "Malformed metadata invented an operation")
        }
        let noDispatcher = tool(#"{"type":"object","properties":{"payload":{"type":"string"}}}"#)
        let absent = try AtlasMCPOperationRouting.catalog(#"{"actions":[{"name":"records.read"}]}"#, selected: noDispatcher)
        precondition(absent.isEmpty, "A catalog invented a dispatch parameter")
        let ambiguous = tool(#"{"type":"object","properties":{"action":{"type":"string"},"method":{"type":"string"}}}"#)
        let ambiguousChoices = try AtlasMCPOperationRouting.catalog(#"{"actions":[{"name":"records.read"}]}"#, selected: ambiguous)
        precondition(ambiguousChoices.isEmpty, "An ambiguous dispatch parameter was guessed")
        let oversized = String(repeating: "界", count: AtlasMCPOperationRouting.maximumCatalogBytes / 3 + 1)
        let oversizeChoices = try AtlasMCPOperationRouting.catalog(oversized, selected: selected)
        precondition(oversizeChoices.isEmpty, "Catalog byte bounds were enforced as character counts")
        let longName = String(repeating: "x", count: 161)
        let longCatalog = try json(["actions": [["name": longName], ["name": "records.read", "description": String(repeating: "x", count: 1000)]]])
        let short = try AtlasMCPOperationRouting.catalog(longCatalog, selected: selected)
        precondition(short.count == 1 && short[0].binding.value == "records.read" && short[0].description.count <= 240,
                     "Catalog names or description growth escaped the bound")

        let many = (0..<(AtlasMCPOperationRouting.maximumOperations + 20)).map { ["name": "records.read_\($0)"] }
        let bounded = try AtlasMCPOperationRouting.catalog(json(["actions": many]), selected: selected)
        precondition(bounded.count == AtlasMCPOperationRouting.maximumOperations,
                     "The local operation catalog exceeded its declared limit")
        precondition(AtlasMCPOperationRouting.pageSize * AtlasMCPOperationRouting.maximumPages <= AtlasMCPOperationRouting.maximumOperations)
        let candidates: [AtlasMCPOperationCandidate] = [
            .init(binding: .init(field: "action", value: "tools.catalog"), description: "List available operations"),
            .init(binding: .init(field: "action", value: "account.read_identity"), description: "Read current account identity"),
            .init(binding: .init(field: "action", value: "records.list"), description: "List records")
        ]
        let ranked = AtlasMCPOperationRouting.ranked(candidates, question: "What is my current account identity?")
        precondition(ranked.first?.binding == candidates[1].binding && Set(ranked.map(\.binding)) == Set(candidates.map(\.binding)),
                     "Ranking lost exact candidates or failed to prioritize matching record metadata")
        let repeated = AtlasMCPOperationRouting.ranked(candidates.reversed(), question: "unmatched")
        precondition(repeated.map(\.binding.value) == candidates.map(\.binding.value).sorted(),
                     "Equal-score operation order was nondeterministic")
        print("MCP operation routing preserves exact schema bindings, documented namespaces and bounded catalogs: passed")
    }

    private static func tool(_ schema: String) -> MCPSelectedTool {
        .init(server: "s2", name: "generic_records", description: "Read a generic connected service", inputSchemaJSON: schema)
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func expectFailure(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        preconditionFailure("Invalid operation metadata selection was accepted")
    }
}
