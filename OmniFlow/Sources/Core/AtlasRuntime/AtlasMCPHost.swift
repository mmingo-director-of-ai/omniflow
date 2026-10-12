// Native Atlas runtime: the run-scoped MCP host (port of mcp.go and
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
// mcp_discovery.go). Grants are evaluated per run against the user's saved
// approvals; pooled sessions only supply the transport and cached catalog.
import Foundation

/// One server as seen by one run.
final class AtlasMCPRunConnection {
    private(set) var config: AtlasMCPServerConfig
    let connection: MCPPooledConnection
    let pooled: Bool
    /// Catalog snapshot pinned at attach (or refresh) time.
    var tools: [String: MCPCatalogTool]
    /// Resource URIs discovered in this run only.
    var resources: Set<String> = []

    init(config: AtlasMCPServerConfig, connection: MCPPooledConnection, pooled: Bool) {
        self.config = config; self.connection = connection; self.pooled = pooled
        tools = connection.tools
    }

    var hasResources: Bool { connection.hasResources }

    /// Adds a run-scoped approval (tests and catalog review only).
    func approve(_ approval: AtlasMCPApproval) { config.allowedTools.append(approval) }

    /// A catalog-change notification revokes every grant for the rest of the run.
    func allowed(_ tool: MCPCatalogTool?) -> Bool {
        guard let tool, !connection.session.catalogChanged else { return false }
        return tool.supported && config.allowedTools.contains { $0.name == tool.name && $0.digest == tool.digest }
    }

    func rememberResource(_ uri: String) throws {
        guard !uri.isEmpty, uri.utf8.count <= 2048, resources.count < 1024 else { throw AtlasRuntimeError("mcp_resource_limit") }
        resources.insert(uri)
    }
}

final class AtlasMCPHost {
    var selected: AtlasRuntimeSelectedTool?
    let configs: [AtlasMCPServerConfig]
    var connections: [String: AtlasMCPRunConnection] = [:]
    let store: AtlasPayloadStore
    let pool: MCPConnectionPool
    let launcher: AtlasStdioLauncher?

    init(configs: [AtlasMCPServerConfig], store: AtlasPayloadStore, pool: MCPConnectionPool, launcher: AtlasStdioLauncher?) throws {
        guard configs.count <= 8 else { throw AtlasRuntimeError("mcp_server_limit") }
        var ids: Set<String> = []
        for config in configs {
            guard (1...64).contains(config.id.utf8.count), !ids.contains(config.id), config.name.utf8.count <= 80,
                  config.arguments.count <= 32, config.allowedTools.count <= 256 else {
                throw AtlasRuntimeError("invalid_mcp_configuration")
            }
            ids.insert(config.id)
            if let error = config.authorizationError, error != "mcp_authentication_required" { throw AtlasRuntimeError("invalid_mcp_configuration") }
            switch config.transport {
            case "", "stdio":
                guard config.command.hasPrefix("/"), config.url.isEmpty, config.headers.isEmpty else {
                    throw AtlasRuntimeError("invalid_local_mcp_configuration")
                }
            case "http":
                guard config.command.isEmpty, config.arguments.isEmpty else { throw AtlasRuntimeError("invalid_remote_mcp_configuration") }
                _ = try MCPHTTPClient.validate(url: config.url, headers: config.headers)
            default:
                throw AtlasRuntimeError("unsupported_mcp_transport")
            }
            for argument in config.arguments where argument.utf8.count > 4096 || argument.contains("\u{0}") {
                throw AtlasRuntimeError("invalid_mcp_argument")
            }
            for approval in config.allowedTools where approval.name.utf8.count > 128 || approval.digest.utf8.count != 64 {
                throw AtlasRuntimeError("invalid_mcp_approval")
            }
        }
        self.configs = configs
        self.store = store
        self.pool = pool
        self.launcher = launcher
    }

    func selectedTool() -> AtlasRuntimeSelectedTool? {
        guard let selected, let connection = connections[selected.server], connection.allowed(connection.tools[selected.name]) else { return nil }
        return selected
    }

    /// Release pooled sessions (evicting revoked or expired ones) and close
    /// per-run local processes.
    nonisolated(nonsending) func close() async {
        for connection in connections.values {
            if connection.pooled {
                if connection.connection.session.catalogChanged || connection.connection.session.expired {
                    await pool.evict(connection.connection)
                }
                await pool.release(connection.connection)
            } else {
                await connection.connection.close()
            }
        }
        connections.removeAll()
    }

    private func enabledConfig(_ id: String) -> AtlasMCPServerConfig? { configs.first { $0.id == id && $0.enabled } }

    /// Opens (or leases) a server's connection without touching run state, so
    /// several servers can connect concurrently.
    static func open(_ config: AtlasMCPServerConfig, index: Int, pool: MCPConnectionPool, launcher: AtlasStdioLauncher?,
                     storeDirectory: String, forceCatalogRefresh: Bool) async throws -> (MCPPooledConnection, Bool) {
        if let error = config.authorizationError { throw AtlasRuntimeError(error) }
        if config.isHTTP {
            let connection = try await atlasWithDeadline(12, timeout: AtlasRuntimeError("mcp_http_timeout")) {
                try await pool.lease(config, forceCatalogRefresh: forceCatalogRefresh)
            }
            return (connection, true)
        }
        guard let launcher else { throw AtlasRuntimeError("mcp_launcher_unavailable") }
        let workdir = (storeDirectory as NSString).appendingPathComponent("server-\(index)")
        let client = try launcher(config, workdir)
        let connection = try await atlasWithDeadline(12) {
            try await MCPPooledConnection.open(client: client, isHTTP: false, key: "")
        }
        return (connection, false)
    }

    nonisolated(nonsending) func connect(_ id: String, forceCatalogRefresh: Bool = false) async throws -> AtlasMCPRunConnection {
        if let existing = connections[id] {
            if !existing.connection.session.expired { return existing }
            // A session-expiry error ends that operation. A later explicit operation
            // gets a fresh handshake/catalog; never automatically replay a tool call.
            connections[id] = nil
            if existing.pooled {
                await pool.evict(existing.connection)
                await pool.release(existing.connection)
            } else {
                await existing.connection.close()
            }
        }
        guard let config = enabledConfig(id) else { throw AtlasRuntimeError("mcp_server_not_enabled") }
        let index = configs.firstIndex { $0.id == id } ?? 0
        let (connection, pooled) = try await Self.open(config, index: index, pool: pool, launcher: launcher,
                                                       storeDirectory: store.directory, forceCatalogRefresh: forceCatalogRefresh)
        let attached = AtlasMCPRunConnection(config: config, connection: connection, pooled: pooled)
        connections[id] = attached
        return attached
    }

    nonisolated(nonsending) func catalog(_ id: String) async throws -> String {
        let connection = try await connect(id, forceCatalogRefresh: true)
        let tools = connection.tools.values.sorted { $0.name < $1.name }.map { tool in
            AtlasJSON.fields([("name", .string(tool.name)), ("description", .string(AtlasUTF8.prefix(tool.description, 320))),
                              ("digest", .string(tool.digest)), ("supported", .bool(tool.supported))])
        }
        return jsonText(.object(["tools": .array(tools), "hasResources": .bool(connection.hasResources)]))
    }

    // MARK: Discovery (mcp_discovery.go)

    /// Connects to every enabled server concurrently and returns approved,
    /// ranked capability metadata in configuration order. Individual
    /// handshakes keep their 12-second limit inside an overall `timeout`.
    nonisolated(nonsending) func discover(_ query: String, timeout: Double = 20) async -> [AtlasRuntimeDiscovery] {
        let enabled = configs.enumerated().filter { $0.element.enabled }
        var outcomes: [Int: Result<(MCPPooledConnection, Bool), any Error>] = [:]
        if Task.isCancelled {
            for (index, _) in enabled { outcomes[index] = .failure(CancellationError()) }
        } else {
            let pool = pool, launcher = launcher, directory = store.directory
            let pending = enabled.filter { connections[$0.element.id] == nil || connections[$0.element.id]!.connection.session.expired }
            let opened = await withTaskGroup(of: (Int, Result<(MCPPooledConnection, Bool), any Error>).self) { group in
                for (index, config) in pending {
                    group.addTask {
                        do {
                            let value = try await atlasWithDeadline(timeout, timeout: AtlasRuntimeError("context_deadline_exceeded")) {
                                try await Self.open(config, index: index, pool: pool, launcher: launcher, storeDirectory: directory, forceCatalogRefresh: false)
                            }
                            return (index, .success(value))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var results: [(Int, Result<(MCPPooledConnection, Bool), any Error>)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (index, result) in opened { outcomes[index] = result }
        }
        var discovered: [AtlasRuntimeDiscovery] = []
        for (index, config) in enabled {
            var item = AtlasRuntimeDiscovery(server: config.id, name: config.name, error: nil, toolCount: 0, hasMore: false, tools: [])
            var connection = connections[config.id]
            switch outcomes[index] {
            case let .success((opened, pooled))?:
                let attached = AtlasMCPRunConnection(config: config, connection: opened, pooled: pooled)
                connections[config.id] = attached
                connection = attached
            case let .failure(error)?:
                item.error = Self.discoveryError(error)
                connection = nil
            case nil: break
            }
            if let connection {
                let names = Self.rankedNames(connection, query)
                item.toolCount = names.count
                item.hasMore = names.count > 8
                item.tools = names.prefix(8).map { AtlasRuntimeDiscoveryTool(name: $0, description: AtlasUTF8.prefix(connection.tools[$0]!.description, 200)) }
            }
            discovered.append(item)
        }
        return discovered
    }

    /// Ranking changes which approved metadata fits the initial model window. It
    /// never selects a schema, calls a tool, or expands an approval. The query
    /// stays in the host; it is not sent to the MCP server.
    static func rankedNames(_ connection: AtlasMCPRunConnection, _ rawQuery: String) -> [String] {
        let query = AtlasText.goLower(AtlasUTF8.prefix(rawQuery, 8000))
        let terms = discoveryTerms(query, 32)
        var candidates: [(name: String, nameTerms: Set<String>, allTerms: Set<String>, score: Int)] = []
        var frequency: [String: Int] = [:]
        for (name, tool) in connection.tools where connection.allowed(tool) {
            let nameTerms = discoveryTerms(name, 128)
            let allTerms = discoveryTerms(name + " " + tool.description, 4096)
            for term in terms where allTerms.contains(term) { frequency[term, default: 0] += 1 }
            candidates.append((name, nameTerms, allTerms, 0))
        }
        for index in candidates.indices {
            if discoveryExactName(query, AtlasText.goLower(candidates[index].name)) { candidates[index].score += 1 << 20 }
            for term in terms where candidates[index].allTerms.contains(term) {
                let weight = 1 + candidates.count / frequency[term]!
                candidates[index].score += (candidates[index].nameTerms.contains(term) ? 8 : 2) * weight
            }
        }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
        return candidates.map(\.name)
    }

    static let discoveryStopWords: Set<String> = Set(AtlasText.fields("the and for from with this that what which where when how please tell find read search use using show give get list me my our your can could would about does not into then its of on as current user request previous conversation answer tools tool server connection"))

    static func discoveryTerms(_ text: String, _ maximum: Int) -> Set<String> {
        var terms: Set<String> = []
        for term in AtlasText.words(AtlasText.goLower(text)) {
            if term.unicodeScalars.count < 3 || term.utf8.count > 80 || discoveryStopWords.contains(term) { continue }
            terms.insert(term)
            if terms.count == maximum { break }
        }
        return terms
    }

    static func discoveryExactName(_ query: String, _ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let haystack = Array(query.utf8), needle = Array(name.utf8)
        func nameScalar(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return AtlasText.isLetterOrNumber(scalar) || "_.-".unicodeScalars.contains(scalar)
        }
        var offset = 0
        while offset < haystack.count {
            guard let start = AtlasBytes.index(of: needle, in: haystack, from: offset) else { return false }
            let end = start + needle.count
            var beforeStart = start - 1
            while beforeStart > 0 && !AtlasUTF8.isRuneStart(haystack[beforeStart]) { beforeStart -= 1 }
            let before = start == 0 ? nil : AtlasUTF8.decodeRune(haystack, at: beforeStart).0
            let after = end == haystack.count ? nil : AtlasUTF8.decodeRune(haystack, at: end).0
            if (start == 0 || !nameScalar(before)) && (end == haystack.count || !nameScalar(after)) { return true }
            offset = end
        }
        return false
    }

    /// Never forward arbitrary process, protocol or remote error text. It may
    /// contain a URL, a response body, or credentials echoed by a service.
    static func discoveryError(_ error: any Error) -> String {
        if error is CancellationError { return "mcp_discovery_cancelled" }
        if let error = error as? AtlasRuntimeError, error.code == "context_deadline_exceeded" { return "mcp_discovery_timeout" }
        if let safe = atlasSafeMCPHTTPError(error) { return safe.code }
        let code = (error as? AtlasRuntimeError)?.code ?? ""
        switch code {
        case "mcp_server_not_enabled", "mcp_initialize_failed_check_endpoint_and_credentials", "mcp_initialize_failed_check_local_command",
             "unsupported_mcp_protocol", "invalid_mcp_catalog", "mcp_tool_definition_limit_or_duplicate", "mcp_catalog_limit_256_tools",
             "mcp_invalid_pagination", "mcp_catalog_page_limit", "mcp_http_status_error":
            return code
        default:
            return "mcp_discovery_failed"
        }
    }

    // MARK: Tool (mcp.go execute)

    nonisolated(nonsending) func execute(_ args: [String: AtlasJSON]) async throws -> String {
        let operation = args["operation"]?.stringValue ?? ""
        if operation == "servers" {
            let list = configs.filter(\.enabled).map { config in
                AtlasJSON.object(["id": .string(config.id), "name": .string(config.name), "approvedTools": .int(config.allowedTools.count),
                                  "resourcesAllowed": .bool(config.allowResources)])
            }
            return jsonText(.object(["trust": .string("untrusted_data"), "servers": .array(list)]))
        }
        let id = args["server"]?.stringValue ?? ""
        let connection = try await connect(id)
        let name = args["name"]?.stringValue ?? ""
        switch operation {
        case "tools":
            let query = args["query"]?.stringValue ?? ""
            guard query.utf8.count <= 128 else { throw AtlasRuntimeError("mcp_query_limit") }
            var list: [AtlasJSON] = []
            var toolCount = 0
            let lowered = AtlasText.goLower(query)
            for toolName in connection.tools.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                let tool = connection.tools[toolName]!
                guard connection.allowed(tool) else { continue }
                toolCount += 1
                if query.isEmpty || AtlasGlob.match(query, toolName) || AtlasText.goLower(toolName + " " + tool.description).contains(lowered) {
                    list.append(.object(["name": .string(toolName), "description": .string(AtlasUTF8.prefix(tool.description, 200))]))
                }
            }
            let offset = try integerArgument(args, "offset", 0, list.count)
            let end = min(offset + 8, list.count)
            return jsonText(.object([
                "trust": .string("untrusted_data"), "server": .string(id), "tools": .array(Array(list[offset..<end])), "nextOffset": .int(end),
                "total": .int(list.count), "hasMore": .bool(end < list.count), "toolCount": .int(toolCount), "filter": .string(query),
                "searchScope": .string("tool_catalog")
            ]))
        case "schema", "call":
            guard let tool = connection.tools[name] else { throw AtlasRuntimeError("mcp_unknown_tool_name_use_tools_to_discover") }
            guard connection.allowed(tool) else { throw AtlasRuntimeError("mcp_tool_not_approved_or_definition_changed") }
            let schemaJSON = jsonText(tool.schema.map(AtlasJSON.object) ?? .null)
            selected = AtlasRuntimeSelectedTool(server: id, name: name, description: AtlasUTF8.prefix(tool.description, 320), inputSchemaJSON: schemaJSON)
            if operation == "schema" {
                let entry = try store.put("mcp:\(id):\(name):schema", Array(schemaJSON.utf8), isText: true)
                entry.kind = "schema"
                // The schema already defines the model's selected native function.
                // Keep it available for explicit inspection without presenting its
                // properties a second time as if they were fetched source evidence.
                return jsonText(.object([
                    "trust": .string("untrusted_data"), "status": .string("ready_to_call"), "server": .string(id), "name": .string(name),
                    "executed": .bool(false), "parameterDefinitionID": .string(entry.id)
                ]))
            }
            let encoded = Array((args["argumentsJSON"]?.stringValue ?? "").utf8)
            guard encoded.count <= 16000, AtlasSchema.numbersRoundTrip(encoded), let arguments = try? AtlasJSON.parse(encoded),
                  arguments.dictionary != nil, AtlasSchema.validate(arguments, tool.schema, root: tool.schema, depth: 0) else {
                throw AtlasRuntimeError("mcp_arguments_do_not_match_approved_schema")
            }
            let session = connection.connection.session
            let isHTTP = connection.connection.isHTTP
            let raw: [UInt8]
            do {
                raw = try await atlasWithDeadline(15, timeout: AtlasRuntimeError(isHTTP ? "mcp_http_timeout" : "context_deadline_exceeded")) {
                    try await session.callTool(name, arguments: arguments)
                }
            } catch {
                if error is CancellationError { throw error }
                if isHTTP, let safe = atlasSafeMCPHTTPError(error) { throw safe }
                throw AtlasRuntimeError("mcp_tool_failed_or_unsupported_result")
            }
            return try ingest(connection, source: "mcp:\(id):\(name)", raw: raw, isResource: false)
        case "resources":
            guard connection.config.allowResources, connection.hasResources else { throw AtlasRuntimeError("mcp_resources_not_enabled") }
            let cursor = args["cursor"]?.stringValue ?? ""
            guard cursor.utf8.count <= 4096 else { throw AtlasRuntimeError("mcp_cursor_limit") }
            let raw = try await connection.connection.session.rpc("resources/list", cursor.isEmpty ? .object([:]) : .object(["cursor": .string(cursor)]),
                timeoutError: AtlasRuntimeError(connection.connection.isHTTP ? "mcp_http_timeout" : "context_deadline_exceeded"))
            guard let page = try? AtlasJSON.parse(raw), let object = page.dictionary else { throw AtlasRuntimeError("mcp_resource_page_limit") }
            let rawResources = object["resources"] ?? .null, rawNext = object["nextCursor"] ?? .null
            let resources = rawResources == .null ? [] : rawResources.arrayValue
            let next = rawNext == .null ? "" : rawNext.stringValue
            func typed(_ resource: AtlasJSON) -> Bool {
                guard let fields = resource.dictionary else { return false }
                return ["uri", "name", "description", "mimeType"].allSatisfy { key in fields[key].map { $0 == .null || $0.stringValue != nil } ?? true }
            }
            guard let resources, let next, resources.count <= 256, next.utf8.count <= 4096, resources.allSatisfy(typed) else {
                throw AtlasRuntimeError("mcp_resource_page_limit")
            }
            for resource in resources { try connection.rememberResource(resource["uri"]?.stringValue ?? "") }
            let entry = try store.put("mcp:\(id):resources", raw, isText: true)
            return jsonText(.object(["trust": .string("untrusted_data"), "nextCursor": .string(next), "page": .raw(Array(store.preview(entry).utf8))]))
        case "readResource":
            guard connection.config.allowResources, connection.resources.contains(name) else {
                throw AtlasRuntimeError("mcp_resource_not_approved_or_not_discovered")
            }
            let session = connection.connection.session
            let isHTTP = connection.connection.isHTTP
            let raw: [UInt8]
            do {
                raw = try await atlasWithDeadline(15, timeout: AtlasRuntimeError(isHTTP ? "mcp_http_timeout" : "context_deadline_exceeded")) {
                    try await session.readResource(name)
                }
            } catch {
                if error is CancellationError { throw error }
                if isHTTP, let safe = atlasSafeMCPHTTPError(error) { throw safe }
                throw AtlasRuntimeError("mcp_resource_read_failed")
            }
            return try ingest(connection, source: "mcp:\(id):resource:" + AtlasUTF8.prefix(name, 256), raw: raw, isResource: true)
        default:
            throw AtlasRuntimeError("unknown_mcp_operation")
        }
    }

    /// Preserve the exact response, including structured content, before
    /// projecting text. Raw binary/base64 is never injected into a prompt.
    func ingest(_ connection: AtlasMCPRunConnection, source: String, raw: [UInt8], isResource: Bool) throws -> String {
        let original = try store.put(source + ":raw", raw, isText: false)
        guard let members = AtlasJSON.rawMembers(raw) else { throw AtlasRuntimeError("invalid_mcp_result") }
        func parsed(_ key: String) throws -> AtlasJSON? {
            guard let bytes = members[key] else { return nil }
            guard let value = try? AtlasJSON.parse(bytes) else { throw AtlasRuntimeError("invalid_mcp_result") }
            return value
        }
        let isError = try parsed("isError")
        guard isError == nil || isError == .null || isError?.boolValue != nil else { throw AtlasRuntimeError("invalid_mcp_result") }
        let blockList = try parsed(isResource ? "contents" : "content")
        guard blockList == nil || blockList == .null || blockList?.arrayValue != nil else { throw AtlasRuntimeError("invalid_mcp_result") }
        _ = try parsed(isResource ? "content" : "contents")
        let blocks = blockList?.arrayValue ?? []
        guard blocks.count <= 64 else { throw AtlasRuntimeError("mcp_content_block_limit") }
        var text: [UInt8] = []
        var attachments: [AtlasPayloadEntry] = []
        let keys = ["type", "text", "blob", "data", "mimeType", "uri", "name"]
        for rawBlock in blocks {
            guard var block = rawBlock.dictionary,
                  keys.allSatisfy({ key in block[key].map { $0 == .null || $0.stringValue != nil } ?? true }) else {
                throw AtlasRuntimeError("invalid_mcp_content_block")
            }
            if block["type"]?.stringValue == "resource", let nested = block["resource"], nested != .null {
                guard let inner = nested.dictionary, keys.allSatisfy({ key in inner[key].map { $0 == .null || $0.stringValue != nil } ?? true }) else {
                    throw AtlasRuntimeError("invalid_embedded_resource")
                }
                for (key, value) in inner where value != .null { block[key] = value }
            }
            func field(_ key: String) -> String { block[key]?.stringValue ?? "" }
            if field("type") == "resource_link" {
                try connection.rememberResource(field("uri"))
                text += Array(("Resource reference: " + jsonText(.object(["uri": .string(field("uri")), "name": .string(AtlasUTF8.prefix(field("name"), 200))])) + "\n").utf8)
            }
            if !field("text").isEmpty { text += Array(field("text").utf8) + [0x0A] }
            let blob = field("blob").isEmpty ? field("data") : field("blob")
            if !blob.isEmpty {
                let (decoded, isText) = try Self.decodeResourceBlob(blob, mime: field("mimeType"))
                attachments.append(try store.put(source + ":attachment", decoded, isText: isText))
                guard attachments.count <= 8 else { throw AtlasRuntimeError("mcp_attachment_limit") }
            }
            guard text.count <= atlasMaxPayloadBytes else { throw AtlasRuntimeError("expanded_payload_limit") }
        }
        if let structured = members["structuredContent"], MCPSession.trim(structured) != Array("null".utf8) {
            guard let formatted = AtlasJSON.indent(Array(structured)) else { throw AtlasRuntimeError("invalid_structured_content") }
            text += Array("\nStructured content:\n".utf8) + formatted
        }
        let entry = try store.put(source, text, isText: true)
        return jsonText(.object([
            "trust": .string("untrusted_data"), "isError": .bool(isError?.boolValue ?? false), "raw": .string(original.id),
            "evidence": .raw(Array(store.preview(entry).utf8)), "attachments": .array(attachments.map(\.json))
        ]))
    }

    /// Explicit MIME types select decoding. Never guess that arbitrary text is
    /// base64, and never let a decompression bomb exceed the expanded budget.
    static func decodeResourceBlob(_ blob: String, mime: String) throws -> ([UInt8], Bool) {
        guard blob.utf8.count <= atlasMaxPayloadBytes * 4 / 3 + 4 else { throw AtlasRuntimeError("encoded_payload_limit") }
        guard let decoded = Data(base64Encoded: blob) else { throw AtlasRuntimeError("invalid_base64") }
        let data = [UInt8](decoded)
        if mime == "application/gzip" || mime == "application/x-gzip" {
            do { _ = try AtlasGzip.headerEnd(data, from: 0) } catch { throw AtlasRuntimeError("invalid_gzip") }
            guard let expanded = try? AtlasGzip.decompress(data, limit: atlasMaxPayloadBytes), expanded.count <= atlasMaxPayloadBytes else {
                throw AtlasRuntimeError("expanded_payload_limit")
            }
            return (expanded, AtlasUTF8.isValid(expanded))
        }
        let text = mime.hasPrefix("text/") || mime == "application/json" || mime == "application/xml"
        guard data.count <= atlasMaxPayloadBytes, !text || AtlasUTF8.isValid(data) else { throw AtlasRuntimeError("decoded_payload_invalid") }
        return (data, text)
    }
}

/// Go `path/filepath.Match` (Unix separator), used for catalog name globs.
/// A malformed pattern matches nothing.
enum AtlasGlob {
    static func match(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.unicodeScalars), s = Array(name.unicodeScalars)
        return (try? matchFrom(p, 0, s, 0)) ?? false
    }

    private struct Malformed: Error {}

    private static func matchFrom(_ p: [Unicode.Scalar], _ pi: Int, _ s: [Unicode.Scalar], _ si: Int) throws -> Bool {
        var pi = pi, si = si
        while pi < p.count {
            switch p[pi] {
            case "*":
                pi += 1
                if pi == p.count { return !s[si...].contains("/") }
                var k = si
                while true {
                    if try matchFrom(p, pi, s, k) { return true }
                    if k == s.count || s[k] == "/" { break }
                    k += 1
                }
                try validate(p, pi)
                return false
            case "?":
                guard si < s.count, s[si] != "/" else { try validate(p, pi + 1); return false }
                pi += 1; si += 1
            case "[":
                pi += 1
                var negated = false
                if pi < p.count, p[pi] == "^" { negated = true; pi += 1 }
                var matched = false, count = 0
                let character = si < s.count ? s[si] : nil
                while true {
                    if pi < p.count, p[pi] == "]", count > 0 { pi += 1; break }
                    var low = try escaped(p, &pi)
                    var high = low
                    if pi < p.count, p[pi] == "-" { pi += 1; high = try escaped(p, &pi) }
                    if let character, low.value <= character.value && character.value <= high.value { matched = true }
                    low = high
                    count += 1
                }
                guard let character, character != "/", matched != negated else { return false }
                si += 1
            case "\\":
                pi += 1
                guard pi < p.count else { throw Malformed() }
                guard si < s.count, s[si] == p[pi] else { return false }
                pi += 1; si += 1
            default:
                guard si < s.count, s[si] == p[pi] else { try validate(p, pi + 1); return false }
                pi += 1; si += 1
            }
        }
        return si == s.count
    }

    private static func escaped(_ p: [Unicode.Scalar], _ pi: inout Int) throws -> Unicode.Scalar {
        guard pi < p.count, p[pi] != "-", p[pi] != "]" else { throw Malformed() }
        if p[pi] == "\\" { pi += 1; guard pi < p.count else { throw Malformed() } }
        defer { pi += 1 }
        return p[pi]
    }

    /// Go reports ErrBadPattern for the remainder even after a mismatch.
    private static func validate(_ p: [Unicode.Scalar], _ start: Int) throws {
        var pi = start
        while pi < p.count {
            if p[pi] == "\\" { pi += 2; if pi > p.count { throw Malformed() }; continue }
            if p[pi] == "[" {
                pi += 1
                if pi < p.count, p[pi] == "^" { pi += 1 }
                var count = 0
                while true {
                    if pi < p.count, p[pi] == "]", count > 0 { pi += 1; break }
                    _ = try escaped(p, &pi)
                    if pi < p.count, p[pi] == "-" { pi += 1; _ = try escaped(p, &pi) }
                    count += 1
                }
                continue
            }
            pi += 1
        }
    }
}
