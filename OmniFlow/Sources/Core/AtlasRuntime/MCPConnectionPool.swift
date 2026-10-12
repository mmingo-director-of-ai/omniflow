// Native Atlas runtime: MCP connections that outlive a single question.
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
//
// The Go helper spawned per question and connected to every server
// sequentially, re-running the initialize handshake and catalog listing each
// time. Here remote (HTTP) sessions are pooled by a fingerprint of their
// endpoint and credentials, catalogs are cached for a short TTL, and first-step
// discovery connects to all servers in parallel. Approvals, discovered
// resource URIs, the selected tool and catalog-change revocation stay per run
// (see AtlasMCPHost), so pooling never widens what a run may do.
import CryptoKit
import Foundation
import Synchronization

/// One advertised tool, pinned by the digest of its entire definition.
public struct MCPCatalogTool: Sendable {
    public let name: String
    public let description: String
    public let digest: String
    public let supported: Bool
    let schema: [String: AtlasJSON]?
}

/// An initialized MCP session plus its most recent tool catalog.
public final class MCPPooledConnection: Sendable {
    public let session: MCPSession
    public let isHTTP: Bool
    public let hasTools: Bool
    public let hasResources: Bool
    let key: String
    private let catalogState = Mutex<(tools: [String: MCPCatalogTool], fetched: ContinuousClock.Instant)>(([:], .now))

    init(session: MCPSession, isHTTP: Bool, initialized: MCPInitializeResult, key: String) {
        self.session = session; self.isHTTP = isHTTP; self.key = key
        hasTools = initialized.hasTools; hasResources = initialized.hasResources
    }

    public var tools: [String: MCPCatalogTool] { catalogState.withLock { $0.tools } }
    var catalogAge: Duration { catalogState.withLock { .now - $0.fetched } }

    /// Lists every catalog page (Go `connect`), pinning each full definition.
    func refreshCatalog() async throws {
        guard hasTools else { return }
        var cursor = ""
        var seen: Set<String> = []
        var tools: [String: MCPCatalogTool] = [:]
        for _ in 0..<32 {
            let raw = try await session.rpc("tools/list", cursor.isEmpty ? .object([:]) : .object(["cursor": .string(cursor)]),
                                            timeoutError: isHTTP ? AtlasRuntimeError("mcp_http_timeout") : AtlasRuntimeError("context_deadline_exceeded"))
            guard let members = AtlasJSON.rawMembers(raw) else { throw AtlasRuntimeError("invalid_mcp_catalog") }
            var definitions: [ArraySlice<UInt8>] = []
            if let list = members["tools"], MCPSession.trim(list) != Array("null".utf8) {
                guard let elements = AtlasJSON.rawElements(list) else { throw AtlasRuntimeError("invalid_mcp_catalog") }
                definitions = elements
            }
            var next = ""
            if let value = members["nextCursor"] {
                guard let parsed = try? AtlasJSON.parse(value) else { throw AtlasRuntimeError("invalid_mcp_catalog") }
                if parsed != .null {
                    guard let text = parsed.stringValue else { throw AtlasRuntimeError("invalid_mcp_catalog") }
                    next = text
                }
            }
            for encoded in definitions {
                guard encoded.count <= 32768, let definition = try? AtlasJSON.parse(encoded), let object = definition.dictionary else {
                    throw AtlasRuntimeError("mcp_tool_definition_limit_or_duplicate")
                }
                let name = object["name"].flatMap { $0 == .null ? "" : $0.stringValue }
                let description = object["description"].flatMap { $0 == .null ? "" : $0.stringValue }
                let schemaValue = object["inputSchema"] ?? .null
                guard let name, let description = description ?? (object["description"] == nil ? "" : nil),
                      schemaValue == .null || schemaValue.dictionary != nil,
                      (1...128).contains(name.utf8.count), description.utf8.count <= 8192, tools[name] == nil else {
                    throw AtlasRuntimeError("mcp_tool_definition_limit_or_duplicate")
                }
                let schema = schemaValue.dictionary
                // Pin the entire advertised definition, including descriptions and
                // annotations, so a changed catalog requires new user approval.
                let digest = SHA256.hash(data: definition.goBytes).map { String(format: "%02x", $0) }.joined()
                let supported = AtlasSchema.numbersRoundTrip(encoded) && AtlasSchema.supported(schema, root: schema, depth: 0)
                tools[name] = MCPCatalogTool(name: name, description: description, digest: digest, supported: supported, schema: schema)
                guard tools.count <= 256 else { throw AtlasRuntimeError("mcp_catalog_limit_256_tools") }
            }
            cursor = next
            if cursor.isEmpty {
                catalogState.withLock { $0 = (tools, .now) }
                return
            }
            guard !seen.contains(cursor), cursor.utf8.count <= 4096 else { throw AtlasRuntimeError("mcp_invalid_pagination") }
            seen.insert(cursor)
        }
        throw AtlasRuntimeError("mcp_catalog_page_limit")
    }

    /// Initialize a transport and list its catalog, closing it on any failure.
    static func open(client: any MCPClient, isHTTP: Bool, key: String) async throws -> MCPPooledConnection {
        let session = MCPSession(client: client)
        let initialized: MCPInitializeResult
        do {
            initialized = try await session.initialize()
        } catch {
            await client.close()
            if error is CancellationError { throw error }
            if isHTTP {
                throw atlasSafeMCPHTTPError(error) ?? AtlasRuntimeError("mcp_initialize_failed_check_endpoint_and_credentials")
            }
            throw AtlasRuntimeError("mcp_initialize_failed_check_local_command")
        }
        guard atlasSupportedMCPProtocol(initialized.protocolVersion) else {
            await client.close()
            throw AtlasRuntimeError("unsupported_mcp_protocol")
        }
        let connection = MCPPooledConnection(session: session, isHTTP: isHTTP, initialized: initialized, key: key)
        do { try await connection.refreshCatalog() } catch { await client.close(); throw error }
        return connection
    }

    public func close() async { await session.client.close() }
}

/// Creates the macOS sandboxed stdio transport. Unavailable on iOS and in the
/// App Store build, where an enabled local server fails the run at start.
public typealias AtlasStdioLauncher = @Sendable (_ config: AtlasMCPServerConfig, _ workdir: String) throws -> any MCPClient

public actor MCPConnectionPool {
    public static let shared = MCPConnectionPool()

    /// How long a catalog listing is reused before it is fetched again.
    public var catalogTTL: Duration
    /// Idle sessions are terminated (HTTP DELETE) after this long.
    public var idleTTL: Duration
    let sessionConfiguration: (@Sendable () -> URLSessionConfiguration)?

    private struct Entry {
        let connection: MCPPooledConnection
        let endpoint: String
        var leases: Int
        var lastUsed: ContinuousClock.Instant
    }
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<MCPPooledConnection, Error>] = [:]
    /// Evicted connections still leased by a run; closed on their last release.
    private var retired: [ObjectIdentifier: (MCPPooledConnection, Int)] = [:]
    private var sweeper: Task<Void, Never>?

    public init(catalogTTL: Duration = .seconds(30), idleTTL: Duration = .seconds(300),
                sessionConfiguration: (@Sendable () -> URLSessionConfiguration)? = nil) {
        self.catalogTTL = catalogTTL
        self.idleTTL = idleTTL
        self.sessionConfiguration = sessionConfiguration
    }

    public func configure(catalogTTL: Duration? = nil, idleTTL: Duration? = nil) {
        if let catalogTTL { self.catalogTTL = catalogTTL }
        if let idleTTL { self.idleTTL = idleTTL }
    }

    /// Pool identity: transport, endpoint and the exact credential headers.
    /// Run-scoped ids and display names are deliberately excluded.
    static func key(_ config: AtlasMCPServerConfig) -> String {
        var text = "http\u{0}" + config.url
        for (name, value) in config.headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            text += "\u{0}" + name.lowercased() + "\u{0}" + value
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Lease an initialized session with a fresh-enough catalog.
    public func lease(_ config: AtlasMCPServerConfig, forceCatalogRefresh: Bool = false) async throws -> MCPPooledConnection {
        let key = Self.key(config)
        if var entry = entries[key] {
            if entry.connection.session.expired || entry.connection.session.catalogChanged {
                evictEntry(key)
            } else {
                entry.leases += 1
                entry.lastUsed = .now
                entries[key] = entry
                if forceCatalogRefresh || entry.connection.catalogAge > catalogTTL {
                    do {
                        try await entry.connection.refreshCatalog()
                    } catch {
                        release(entry.connection)
                        evict(entry.connection)
                        if error is CancellationError { throw error }
                        return try await lease(config, forceCatalogRefresh: false)
                    }
                }
                return entry.connection
            }
        }
        // A changed credential for the same endpoint ends the old session.
        for (other, entry) in entries where entry.endpoint == config.url && other != key { evictEntry(other) }
        let task: Task<MCPPooledConnection, Error>
        if let existing = pending[key] {
            task = existing
        } else {
            let configuration = sessionConfiguration
            task = Task {
                let client = try MCPHTTPClient(url: config.url, headers: config.headers, configuration: configuration?())
                return try await MCPPooledConnection.open(client: client, isHTTP: true, key: key)
            }
            pending[key] = task
        }
        let connection: MCPPooledConnection
        do {
            connection = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if pending[key] == task { pending[key] = nil }
            throw error
        }
        if pending[key] == task { pending[key] = nil }
        if var entry = entries[key], entry.connection === connection {
            entry.leases += 1
            entries[key] = entry
        } else {
            entries[key] = Entry(connection: connection, endpoint: config.url, leases: 1, lastUsed: .now)
        }
        scheduleSweep()
        return connection
    }

    /// Return a lease. Retired connections close when their last lease ends.
    public func release(_ connection: MCPPooledConnection) {
        if var entry = entries[connection.key], entry.connection === connection {
            entry.leases = max(0, entry.leases - 1)
            entry.lastUsed = .now
            entries[connection.key] = entry
            return
        }
        let id = ObjectIdentifier(connection)
        guard let (retiredConnection, leases) = retired[id] else { return }
        if leases <= 1 {
            retired[id] = nil
            Task { await retiredConnection.close() }
        } else {
            retired[id] = (retiredConnection, leases - 1)
        }
    }

    /// Remove a connection whose catalog changed or whose session expired.
    public func evict(_ connection: MCPPooledConnection) {
        guard let entry = entries[connection.key], entry.connection === connection else { return }
        evictEntry(connection.key)
    }

    private func evictEntry(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if entry.leases == 0 {
            Task { await entry.connection.close() }
        } else {
            retired[ObjectIdentifier(entry.connection)] = (entry.connection, entry.leases)
        }
    }

    /// Warm sessions and catalogs before a question arrives (e.g. on wake).
    public func prewarm(_ configs: [AtlasMCPServerConfig]) async {
        await withTaskGroup(of: Void.self) { group in
            for config in configs where config.enabled && config.isHTTP && config.authorizationError == nil {
                group.addTask {
                    if let connection = try? await atlasWithDeadline(12, { try await self.lease(config) }) {
                        await self.release(connection)
                    }
                }
            }
        }
    }

    /// Close every session (app termination, sign-out, or tests).
    public func closeAll() async {
        sweeper?.cancel(); sweeper = nil
        let all = entries.values.map(\.connection) + retired.values.map(\.0)
        entries.removeAll(); retired.removeAll()
        for task in pending.values { task.cancel() }
        pending.removeAll()
        for connection in all { await connection.close() }
    }

    var count: Int { entries.count }

    private func scheduleSweep() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, await self.sweep() else { return }
            }
        }
    }

    /// Returns whether sweeping should continue.
    private func sweep() async -> Bool {
        for (key, entry) in entries where entry.leases == 0 && .now - entry.lastUsed > idleTTL { evictEntry(key) }
        if entries.isEmpty { sweeper = nil; return false }
        return true
    }
}
