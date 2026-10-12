import Foundation
import FoundationModels

enum AtlasMCPInitialRoutingChecks {
    static let fixtureChoices = [
        AtlasMCPSelectionChoice(server: "s1", name: "knowledge_pages",
            detail: "Company knowledge base (wiki). Action-routed: search_pages, get_page, list_spaces, list_pages, create_page, update_page, edit_page, get_outline, get_section."),
        AtlasMCPSelectionChoice(server: "s1", name: "cloud_infrastructure",
            detail: "Manage cloud computing instances, networking and deployed infrastructure."),
        AtlasMCPSelectionChoice(server: "s2", name: "knowledge_pages",
            detail: "Read public software API reference documentation."),
    ]

    static func run() throws {
        let routing = try AtlasMCPInitialRouting(choices: fixtureChoices)
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(routing.schema)) as! [String: Any]
        let property = ((schema["properties"] as! [String: Any])["route"] as! [String: Any])
        precondition(property["enum"] as? [String] == ["continue_without_mcp", "s1/knowledge_pages", "s1/cloud_infrastructure", "s2/knowledge_pages"])
        let general = try routing.proposal(responseJSON: #"{"requestKind":"general","route":"continue_without_mcp"}"#)
        precondition(general == nil, "The ordinary assistant route proposed an MCP operation")
        for server in ["s1", "s2"] {
            let call = try routing.proposal(responseJSON: "{\"requestKind\":\"connected_records\",\"route\":\"\(server)/knowledge_pages\"}")
            precondition(call?.name == "mcp")
            let arguments = try JSONDecoder().decode([String: String].self, from: Data(call!.argumentsJSON.utf8))
            precondition(arguments == ["operation": "schema", "server": server, "name": "knowledge_pages"],
                         "Initial routing changed the host binding or executed a business tool")
        }
        let contradictory = try routing.proposal(responseJSON: #"{"requestKind":"local_files","route":"s1/knowledge_pages"}"#)
        precondition(contradictory == nil, "A contradictory model route sent a local-file request to MCP")
        let unselected = try routing.proposal(responseJSON: #"{"requestKind":"connected_records","route":"continue_without_mcp"}"#)
        precondition(unselected == nil, "Classifying a connected-record request forced a selection")
        for invalid in [#"{"requestKind":"connected_records","route":"Hermes"}"#,
                        #"{"requestKind":"connected_records","route":"s3/knowledge_pages"}"#,
                        #"{"requestKind":"local_files","route":"s1/not_approved"}"#,
                        #"{"requestKind":"connected_records","route":"knowledge_pages"}"#,
                        #"{"requestKind":"connected_records","route":"s1/knowledge_pages","operation":"call"}"#,
                        #"{"requestKind":"invented","route":"continue_without_mcp"}"#,
                        #"{"route":null}"#, #"{"operation":"call"}"#] {
            try expectFailure { _ = try routing.proposal(responseJSON: invalid) }
        }
        try expectFailure { _ = try AtlasMCPInitialRouting(choices: []) }
        try expectFailure { _ = try AtlasMCPInitialRouting(choices: [fixtureChoices[0], fixtureChoices[0]]) }
        try expectFailure {
            _ = try AtlasMCPInitialRouting(choices: (0..<9).map { .init(server: "s1", name: "tool\($0)") })
        }
        let longDetail = try AtlasMCPInitialRouting(choices: [.init(server: "s1", name: "read_notes", detail: String(repeating: "界", count: 500))])
        let catalog = try JSONDecoder().decode([[String: String]].self, from: Data(longDetail.catalogJSON.utf8))
        precondition(catalog[0]["capability"]!.utf8.count <= 200)
        let prompt = try routing.prompt(question: "what is the kyube daily note for today")
        precondition(prompt.hasSuffix("User request:\nwhat is the kyube daily note for today"))
        let labelledPrompt = try routing.prompt(question: "Read my Team Notes", connectionLabels: #"[{"id":"s1","name":"Team Notes"}]"#)
        precondition(labelledPrompt.contains(#"{"id":"s1","name":"Team Notes"}"#))
        try expectFailure { _ = try routing.prompt(question: "Read my notes", connectionLabels: #"[{"name":"Team Notes"}]"#) }
        try expectFailure { _ = try routing.prompt(question: String(repeating: "x", count: 8_001)) }
        precondition(AtlasMCPInitialRouting.fits(capacity: 4096, fixedTokens: 800, promptTokens: 3040))
        precondition(!AtlasMCPInitialRouting.fits(capacity: 4096, fixedTokens: 800, promptTokens: 3041))
        precondition(!AtlasMCPInitialRouting.fits(capacity: 128, fixedTokens: 0, promptTokens: 0))
        precondition(!AtlasMCPInitialRouting.fits(capacity: 4096, fixedTokens: Int.max, promptTokens: Int.max))
        precondition(!AtlasMCPInitialRouting.fits(capacity: 4096, fixedTokens: -1, promptTokens: 0))
        let named = [
            AtlasMCPSelectionChoice(server: "s1", name: "vendor_router", detail: "Nimbus cloud accounts, zones and certificates."),
            AtlasMCPSelectionChoice(server: "s1", name: "portal_list_servers", detail: "Lists all available upstream servers, including Nimbus."),
            AtlasMCPSelectionChoice(server: "s1", name: "archive", detail: "Archive document and note search."),
        ]
        let narrowed = AtlasMCPInitialRouting.candidateChoices(question: "List five zones in my Nimbus account.", choices: named)
        precondition(narrowed.map(\.name) == ["vendor_router"], "An explicit service competed with a generic portal reference")
        precondition(AtlasMCPInitialRouting.candidateChoices(question: "List connected services.", choices: named) == named)
        precondition(AtlasMCPInitialRouting.candidateChoices(question: "Compare Nimbus with Archive.", choices: named) == named,
                     "A request naming multiple capabilities was narrowed to only one")
        let duplicate = named + [AtlasMCPSelectionChoice(server: "s2", name: "vendor_router", detail: "Nimbus staging account")]
        precondition(AtlasMCPInitialRouting.candidateChoices(question: "List Nimbus zones", choices: duplicate) == duplicate,
                     "Ambiguous capability names erased a second approved server")
        let narrowedRouting = try AtlasMCPInitialRouting(choices: narrowed)
        try expectFailure { _ = try narrowedRouting.proposal(responseJSON: #"{"requestKind":"connected_records","route":"s1/portal_list_servers"}"#) }
        let narrowedGeneral = try narrowedRouting.proposal(responseJSON: #"{"requestKind":"general","route":"continue_without_mcp"}"#)
        precondition(narrowedGeneral == nil,
                     "An explicit metadata name forced a business operation")
        print("MCP initial routing preserves host bindings, schema-only proposals and bounded context: passed")
    }

    /// Explicitly opt-in: these are on-device classifications over fixture
    /// metadata. No MCP connection or business operation is executed.
    @MainActor
    static func runLive() async throws {
        let original = try await AtlasMCPInitialRouting.route(question: "what is the kyube daily note for today", choices: fixtureChoices)
        guard let original else { throw CheckFailure.wrongRoute }
        let arguments = try JSONDecoder().decode([String: String].self, from: Data(original.argumentsJSON.utf8))
        guard original.name == "mcp", arguments == ["operation": "schema", "server": "s1", "name": "knowledge_pages"] else {
            throw CheckFailure.wrongRoute
        }
        for question in ["hello", "What is 2 + 2?", "Read /tmp/notes.md", "How much RAM is my Mac using right now?"] {
            let general = try await AtlasMCPInitialRouting.route(question: question, choices: fixtureChoices)
            guard general == nil else { throw CheckFailure.wrongRoute }
        }
        let noCatalog = try await AtlasMCPInitialRouting.route(question: "Read my daily note", choices: [])
        guard noCatalog == nil else { throw CheckFailure.wrongRoute }
        print("Live on-device routing: daily note selects metadata; greeting, arithmetic, local files, system status and absent catalog continue normally: passed")
    }

    private enum CheckFailure: Error { case wrongRoute }
    private static func expectFailure(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        preconditionFailure("Invalid MCP route was accepted")
    }
}
