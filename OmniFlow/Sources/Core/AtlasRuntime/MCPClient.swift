// Native Atlas runtime: MCP JSON-RPC session over a pluggable transport.
// Ports the request/response half of mcp_transport.go plus the Atlas SDK's
// `mcp.Bridge` Initialize/CallTool/ReadResource (MIT, Quandry Labs, revision
// 49104b74160ee24cc350eee461df6378e51cccd3).
import Foundation
import Synchronization

public let atlasMaxMCPFrameBytes = 24 * 1024 * 1024 // base64 framing headroom; expanded data has its own quota

/// A byte-level MCP transport: Streamable HTTP (`MCPHTTPClient`) or a
/// sandboxed local process (macOS `AtlasStdioTransport`).
public protocol MCPClient: AnyObject, Sendable {
    /// One pipe cannot interleave exchanges; HTTP requests are independent.
    var serializesExchanges: Bool { get }
    /// A remote session the server reported as gone (HTTP 404 on a session).
    var expired: Bool { get }
    func connect() async throws
    /// Sends one JSON-RPC message. Requests return a reader for that request's
    /// response frames; notifications and host-request refusals return nil.
    func post(_ body: [UInt8], expectsResponse: Bool, initialize: Bool) async throws -> (any MCPResponseReader)?
    func close() async
}

public protocol MCPResponseReader: Sendable {
    /// The next complete JSON-RPC frame (one line, or one SSE event).
    func nextFrame() async throws -> [UInt8]
    /// Releases the response and records protocol state after `initialize`.
    func finish(result: [UInt8], isError: Bool) async throws
}

public extension MCPResponseReader {
    func finish(result: [UInt8], isError: Bool) async throws {}
}

/// Protocol revisions this host accepts from `initialize`.
func atlasSupportedMCPProtocol(_ version: String) -> Bool {
    ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(version)
}

/// The SDK's advertised protocol version.
let atlasMCPVersion = "2025-11-25"

/// Fixed transport failure codes that may be shown to the host. Everything
/// else collapses to an operation-specific code; server text never escapes.
let atlasSafeMCPHTTPCodes: Set<String> = [
    "mcp_authentication_required", "mcp_http_forbidden", "mcp_http_endpoint_unavailable", "mcp_http_redirect_refused",
    "mcp_http_timeout", "mcp_http_rate_limited", "mcp_http_connection_failed"
]

func atlasSafeMCPHTTPError(_ error: any Error) -> AtlasRuntimeError? {
    if let error = error as? AtlasRuntimeError {
        if atlasSafeMCPHTTPCodes.contains(error.code) { return error }
        if error.code == "context_deadline_exceeded" { return AtlasRuntimeError("mcp_http_timeout") }
    }
    return nil
}

/// Runs `operation` with a deadline. Exceeding it cancels the operation and
/// throws `timeout`; cancellation by the caller still throws CancellationError.
func atlasWithDeadline<T: Sendable>(_ seconds: Double, timeout: AtlasRuntimeError = AtlasRuntimeError("context_deadline_exceeded"),
                                    _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            return nil
        }
        defer { group.cancelAll() }
        // Whichever child finishes first decides: the operation's own value or
        // error (including an internal cancellation), or the timer's nil.
        guard let first = try await group.next(), let value = first else { throw timeout }
        return value
    }
}

/// A FIFO async lock for transports that carry one exchange at a time.
final class AtlasAsyncGate: Sendable {
    private let state = Mutex<(locked: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func lock() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if !state.locked { state.locked = true; return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func unlock() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty { state.locked = false; return nil }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}

/// The server's `initialize` result fields the host relies on.
public struct MCPInitializeResult: Sendable {
    public let protocolVersion: String
    public let hasTools: Bool
    public let hasResources: Bool
}

/// JSON-RPC session over one transport. Server-initiated sampling, elicitation
/// and roots requests are refused: they cannot invoke host tools, collect
/// secrets, or expand the user's approved permissions.
public final class MCPSession: Sendable {
    public let client: any MCPClient
    private let gate = AtlasAsyncGate()
    private let state = Mutex<(sequence: Int, catalogChanged: Bool)>((0, false))

    public init(client: any MCPClient) { self.client = client }

    /// Set by `notifications/tools/list_changed`; revokes every grant on this session.
    public var catalogChanged: Bool { state.withLock { $0.catalogChanged } }
    public var expired: Bool { client.expired }

    func markCatalogChangedForTest() { state.withLock { $0.catalogChanged = true } }

    struct Response: Sendable {
        let result: [UInt8]
        let error: Bool
    }

    /// Send one request and wait for its matching response (Go Send+Receive).
    func exchange(id: [UInt8], method: String, params: AtlasJSON?, initialize: Bool = false) async throws -> Response {
        var body = Array("{\"jsonrpc\":\"2.0\",\"id\":".utf8) + id
        body += Array(",\"method\":".utf8)
        AtlasJSON.encodeString(method, into: &body)
        if let params {
            let encoded = params.goBytes
            guard !encoded.isEmpty else { throw AtlasRuntimeError("mcp_request_limit") }
            body += Array(",\"params\":".utf8) + encoded
        }
        body.append(UInt8(ascii: "}"))
        guard body.count <= 32768 else { throw AtlasRuntimeError("mcp_request_limit") }
        if client.serializesExchanges { await gate.lock() }
        defer { if client.serializesExchanges { gate.unlock() } }
        guard let reader = try await client.post(body, expectsResponse: true, initialize: initialize) else {
            throw AtlasRuntimeError("mcp_response_required")
        }
        for _ in 0..<64 {
            let frame = try await reader.nextFrame()
            guard let wire = AtlasJSON.rawMembers(frame), wire["jsonrpc"].map(Self.isJSONRPC2) == true else {
                throw AtlasRuntimeError("mcp_invalid_frame")
            }
            if let methodBytes = wire["method"], let notification = try? AtlasJSON.parse(methodBytes).stringValue, !notification.isEmpty {
                if notification == "notifications/tools/list_changed" { state.withLock { $0.catalogChanged = true } }
                if let requestID = wire["id"] {
                    let refusal = Array("{\"jsonrpc\":\"2.0\",\"id\":".utf8) + Self.trim(requestID)
                        + Array(",\"error\":{\"code\":-32601,\"message\":\"Host requests are disabled\"}}".utf8)
                    _ = try await client.post(refusal, expectsResponse: false, initialize: false)
                }
                continue
            }
            let result = wire["result"].map(Self.trim)
            let error = wire["error"].map(Self.trim).flatMap { $0 == Array("null".utf8) ? nil : $0 }
            if let error, (try? AtlasJSON.parse(error))?.dictionary == nil { throw AtlasRuntimeError("mcp_invalid_frame") }
            guard Self.trim(wire["id"] ?? []) == id, (result != nil) != (error != nil) else {
                throw AtlasRuntimeError("mcp_response_mismatch")
            }
            try await reader.finish(result: result ?? [], isError: error != nil)
            return Response(result: result ?? [], error: error != nil)
        }
        throw AtlasRuntimeError("mcp_notification_limit")
    }

    static func trim(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        Array(bytes.drop(while: { [0x20, 0x09, 0x0A, 0x0D].contains($0) }).reversed().drop(while: { [0x20, 0x09, 0x0A, 0x0D].contains($0) }).reversed())
    }

    private static func isJSONRPC2(_ bytes: ArraySlice<UInt8>) -> Bool {
        (try? AtlasJSON.parse(bytes))?.stringValue == "2.0"
    }

    func notify(_ method: String) async throws {
        var body = Array("{\"jsonrpc\":\"2.0\",\"method\":".utf8)
        AtlasJSON.encodeString(method, into: &body)
        body.append(UInt8(ascii: "}"))
        _ = try await client.post(body, expectsResponse: false, initialize: false)
    }

    /// SDK `Bridge.Initialize`: connect, initialize, then `notifications/initialized`.
    public func initialize(clientVersion: String = AtlasRuntimeIdentity.version) async throws -> MCPInitializeResult {
        try await client.connect()
        let params = AtlasJSON.fields([
            ("protocolVersion", .string(atlasMCPVersion)), ("capabilities", .fields([])),
            ("clientInfo", .fields([("name", .string("OmniFlow")), ("version", .string(clientVersion))]))
        ])
        let response = try await exchange(id: Array("\"init\"".utf8), method: "initialize", params: params, initialize: true)
        guard !response.error else { throw AtlasRuntimeError("mcp_initialize_error") }
        guard let result = try? AtlasJSON.parse(response.result), let object = result.dictionary else {
            throw AtlasRuntimeError("mcp_initialize_invalid_result")
        }
        let capabilities = object["capabilities"]?.dictionary ?? [:]
        func present(_ key: String) -> Bool { capabilities[key].map { $0 != .null } ?? false }
        try await notify("notifications/initialized")
        return MCPInitializeResult(protocolVersion: object["protocolVersion"]?.stringValue ?? "",
                                   hasTools: present("tools"), hasResources: present("resources"))
    }

    /// A host-numbered request with a 12-second limit (Go `transport.rpc`).
    public func rpc(_ method: String, _ params: AtlasJSON, timeout: Double = 12, timeoutError: AtlasRuntimeError? = nil) async throws -> [UInt8] {
        // HTTP reports its own deadline code; a local process reports the context error.
        let timeoutError = timeoutError ?? AtlasRuntimeError(client is MCPHTTPClient ? "mcp_http_timeout" : "context_deadline_exceeded")
        let sequence = state.withLock { state -> Int in state.sequence += 1; return state.sequence }
        let response = try await atlasWithDeadline(timeout, timeout: timeoutError) {
            try await self.exchange(id: Array(String(sequence).utf8), method: method, params: params)
        }
        guard !response.error else { throw AtlasRuntimeError("mcp_server_returned_error") }
        return response.result
    }

    /// SDK `Bridge.CallTool`. Returns the raw result after the SDK's typed
    /// decoding checks, so unsupported content blocks fail like they did in Go.
    public func callTool(_ name: String, arguments: AtlasJSON) async throws -> [UInt8] {
        let response = try await exchange(id: Array("\"tools-call\"".utf8), method: "tools/call",
                                          params: .object(["name": .string(name), "arguments": arguments]))
        guard !response.error else { throw AtlasRuntimeError("mcp_tool_call_error") }
        guard Self.decodesAsToolResult(response.result) else { throw AtlasRuntimeError("mcp_tool_result_invalid") }
        return response.result
    }

    /// SDK `Bridge.ReadResource`.
    public func readResource(_ uri: String) async throws -> [UInt8] {
        let response = try await exchange(id: Array("\"resources-read\"".utf8), method: "resources/read", params: .object(["uri": .string(uri)]))
        guard !response.error else { throw AtlasRuntimeError("mcp_resource_read_error") }
        guard let result = try? AtlasJSON.parse(response.result), let object = result.dictionary else {
            throw AtlasRuntimeError("mcp_resource_result_invalid")
        }
        if let contents = object["contents"], contents != .null {
            guard let list = contents.arrayValue, list.allSatisfy(Self.decodesAsResourceContent) else { throw AtlasRuntimeError("mcp_resource_result_invalid") }
        }
        return response.result
    }

    private static func stringsOrAbsent(_ object: [String: AtlasJSON], _ keys: [String]) -> Bool {
        keys.allSatisfy { key in object[key].map { $0 == .null || $0.stringValue != nil } ?? true }
    }

    private static func decodesAsResourceContent(_ value: AtlasJSON) -> Bool {
        guard let object = value.dictionary, stringsOrAbsent(object, ["type", "uri", "mimeType", "text", "blob"]) else { return false }
        if let nested = object["resource"], nested != .null {
            guard let inner = nested.dictionary, stringsOrAbsent(inner, ["type", "uri", "mimeType", "text", "blob"]) else { return false }
        }
        return true
    }

    private static func decodesAsToolResult(_ data: [UInt8]) -> Bool {
        guard let result = try? AtlasJSON.parse(data), let object = result.dictionary else { return false }
        if let flag = object["isError"], flag != .null, flag.boolValue == nil { return false }
        if let structured = object["structuredContent"], structured != .null, structured.dictionary == nil { return false }
        guard let content = object["content"], content != .null else { return true }
        guard let blocks = content.arrayValue else { return false }
        return blocks.allSatisfy { block in
            guard let fields = block.dictionary, let type = fields["type"]?.stringValue else { return false }
            switch type {
            case "text": return stringsOrAbsent(fields, ["type", "text"])
            case "image", "audio": return stringsOrAbsent(fields, ["type", "data", "mimeType"])
            case "resource_link":
                if let size = fields["size"], size != .null, size.doubleValue.map({ $0 == $0.rounded() }) != true { return false }
                return stringsOrAbsent(fields, ["type", "uri", "name", "description", "mimeType"])
            case "resource": return decodesAsResourceContent(block)
            default: return false
            }
        }
    }
}
