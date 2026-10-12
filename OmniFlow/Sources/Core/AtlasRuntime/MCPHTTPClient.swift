// Native Atlas runtime: MCP Streamable HTTP transport (port of mcp_http.go).
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
// Credentials exist only in the private run configuration, never model context.
// Like the Go client: no cookies, caches, proxies, compression or redirects.
import Foundation
import Synchronization

public final class MCPHTTPClient: MCPClient {
    public let endpoint: URL
    let headers: [(String, String)]
    private let session: URLSession
    private let state = Mutex<(sessionID: String, protocolVersion: String, expired: Bool, closed: Bool)>(("", "", false, false))
    public var serializesExchanges: Bool { false }
    public var expired: Bool { state.withLock { $0.expired } }

    /// Validates the endpoint and headers (Go `validateMCPHTTP`).
    public init(url: String, headers configured: [String: String], configuration: URLSessionConfiguration? = nil) throws {
        let (endpoint, headers) = try Self.validate(url: url, headers: configured)
        self.endpoint = endpoint
        self.headers = headers
        let settings = configuration ?? .ephemeral
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.urlCache = nil
        settings.urlCredentialStorage = nil
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        if configuration == nil { settings.connectionProxyDictionary = [:] }
        settings.tlsMinimumSupportedProtocolVersion = .TLSv12
        settings.timeoutIntervalForRequest = 12
        settings.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: settings, delegate: MCPHTTPRedirectRefusal(), delegateQueue: nil)
    }

    static func validate(url: String, headers configured: [String: String]) throws -> (URL, [(String, String)]) {
        guard (1...4096).contains(url.utf8.count), safeHeaderValue(url), !url.contains(" "),
              let components = URLComponents(string: url), components.user == nil, components.password == nil,
              components.fragment == nil, let scheme = components.scheme?.lowercased(), let endpoint = components.url else {
            throw AtlasRuntimeError("invalid_mcp_http_url")
        }
        let host = (components.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, !components.path.isEmpty || components.host != nil, url.contains("//") else { throw AtlasRuntimeError("invalid_mcp_http_url") }
        // Cleartext only to a literal loopback address or localhost. URLSession has
        // no dial hook, so the Go client's post-dial remote-address check is not
        // replicated; a non-loopback name is refused before any connection.
        guard scheme == "https" || (scheme == "http" && isLoopbackHost(host)) else { throw AtlasRuntimeError("mcp_http_requires_https") }
        guard configured.count <= 16 else { throw AtlasRuntimeError("mcp_http_header_limit") }
        var seen: Set<String> = []
        var total = 0
        var headers: [(String, String)] = []
        for (name, value) in configured.sorted(by: { $0.key < $1.key }) {
            let lower = name.lowercased()
            guard headerToken(name), name.utf8.count <= 128, value.utf8.count <= 8192, safeHeaderValue(value), !seen.contains(lower) else {
                throw AtlasRuntimeError("invalid_mcp_http_header")
            }
            let reserved: Set<String> = ["host", "connection", "proxy-connection", "proxy-authorization", "proxy-authenticate", "keep-alive",
                                         "transfer-encoding", "te", "trailer", "upgrade", "content-length", "content-type", "accept",
                                         "accept-encoding", "mcp-session-id", "mcp-protocol-version", "last-event-id", "origin"]
            guard !reserved.contains(lower) else { throw AtlasRuntimeError("reserved_mcp_http_header") }
            total += name.utf8.count + value.utf8.count
            guard total <= 16384 else { throw AtlasRuntimeError("mcp_http_header_limit") }
            seen.insert(lower)
            headers.append((name, value))
        }
        return (endpoint, headers)
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }
            // IPv4-mapped loopback (::ffff:127.0.0.0/104).
            return bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127
        }
        return false
    }

    static func headerToken(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
        }
    }

    static func safeHeaderValue(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) } }

    public func connect() async throws {}

    private func request(method: String, body: [UInt8]?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("OmniFlow/" + AtlasRuntimeIdentity.version, forHTTPHeaderField: "User-Agent")
        let (sessionID, protocolVersion) = state.withLock { ($0.sessionID, $0.protocolVersion) }
        if !sessionID.isEmpty { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if !protocolVersion.isEmpty { request.setValue(protocolVersion, forHTTPHeaderField: "Mcp-Protocol-Version") }
        if let body { request.httpBody = Data(body) }
        return request
    }

    public func post(_ body: [UInt8], expectsResponse: Bool, initialize: Bool) async throws -> (any MCPResponseReader)? {
        guard !state.withLock({ $0.closed }) else { throw AtlasRuntimeError("mcp_http_closed") }
        guard body.count <= 32768 else { throw AtlasRuntimeError("mcp_request_limit") }
        let body = MCPHTTPBody(session: session, request: request(method: "POST", body: body))
        let response: URLResponse
        do {
            response = try await body.response()
        } catch {
            body.cancel()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            // URLSession errors can contain URLs, query strings and credentials.
            if (error as? URLError)?.code == .timedOut { throw AtlasRuntimeError("mcp_http_timeout") }
            throw AtlasRuntimeError("mcp_http_connection_failed")
        }
        var accepted = false
        defer { if !accepted { body.cancel() } }
        guard let http = response as? HTTPURLResponse else { throw AtlasRuntimeError("mcp_http_connection_failed") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw AtlasRuntimeError("mcp_authentication_required")
            case 403: throw AtlasRuntimeError("mcp_http_forbidden")
            case 404:
                state.withLock { if !$0.sessionID.isEmpty { $0.expired = true } }
                throw AtlasRuntimeError("mcp_http_endpoint_unavailable")
            case 429: throw AtlasRuntimeError("mcp_http_rate_limited")
            case 300..<400: throw AtlasRuntimeError("mcp_http_redirect_refused")
            default: throw AtlasRuntimeError("mcp_http_status_error")
            }
        }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            // Duplicate headers arrive comma-joined and fail the space check.
            guard !session.isEmpty, session.utf8.count <= 4096, Self.safeHeaderValue(session), !session.contains(" "), !session.contains(",") else {
                throw AtlasRuntimeError("invalid_mcp_http_session")
            }
            try state.withLock { state in
                if initialize { state.sessionID = session } else if session != state.sessionID { throw AtlasRuntimeError("mcp_http_session_changed") }
            }
        }
        if !expectsResponse {
            guard http.statusCode == 202 || http.statusCode == 204 else { throw AtlasRuntimeError("mcp_http_notification_not_accepted") }
            // Acknowledgements cannot carry arbitrary streams or unbounded bodies.
            guard let rest = try? await body.next(limit: 2), rest.isEmpty else { throw AtlasRuntimeError("mcp_http_invalid_acknowledgement") }
            return nil
        }
        guard http.statusCode == 200 else { throw AtlasRuntimeError("mcp_http_response_required") }
        let mediaType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard mediaType == "application/json" || mediaType == "text/event-stream" else {
            throw AtlasRuntimeError("mcp_http_unsupported_content_type")
        }
        guard http.expectedContentLength <= Int64(atlasMaxMCPFrameBytes) else { throw AtlasRuntimeError("mcp_http_response_limit") }
        accepted = true
        return MCPHTTPResponseReader(client: self, body: body, stream: mediaType == "text/event-stream", initialize: initialize)
    }

    fileprivate func finished(initialize: Bool, result: [UInt8], isError: Bool) throws {
        guard initialize, !isError else { return }
        guard let value = try? AtlasJSON.parse(result), let version = value["protocolVersion"]?.stringValue, atlasSupportedMCPProtocol(version) else {
            throw AtlasRuntimeError("unsupported_mcp_protocol")
        }
        state.withLock { $0.protocolVersion = version }
    }

    /// Terminates only the session allocated to this connection. Tool POSTs are
    /// never retried: cancellation can leave a remote operation's outcome unknown.
    public func close() async {
        let (shouldDelete, wasClosed) = state.withLock { state -> (Bool, Bool) in
            let previous = state.closed
            state.closed = true
            return (!state.sessionID.isEmpty && !state.expired, previous)
        }
        guard !wasClosed else { return }
        if shouldDelete {
            var deletion = request(method: "DELETE", body: nil)
            deletion.timeoutInterval = 1
            let request = deletion
            // Detached so a cancelled caller still releases the remote session.
            await Task.detached { [session] in
                _ = try? await atlasWithDeadline(1) { _ = try await session.data(for: request) }
            }.value
        }
        session.invalidateAndCancel()
    }

    func finishedForTest(initialize: Bool, result: [UInt8]) throws { try finished(initialize: initialize, result: result, isError: false) }

    /// Test hook: the active session identifier.
    var sessionID: String { state.withLock { $0.sessionID } }
}

/// Refuses every redirect so credentials never follow a Location header.
private final class MCPHTTPRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// One request's response, delivered as data chunks by a task delegate.
/// AsyncBytes delivers one byte per await, which is far too slow for
/// multi-megabyte tool results.
final class MCPHTTPBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Guarded by `lock`; delegate callbacks arrive on URLSession's queue.
    private let lock = NSLock()
    private var responseWaiter: CheckedContinuation<URLResponse, any Error>?
    private var receivedResponse: Result<URLResponse, any Error>?
    private var chunks: [Data] = []
    private var finished: (any Error)??
    private var chunkWaiter: CheckedContinuation<Void, Never>?
    private var task: URLSessionDataTask?

    init(session: URLSession, request: URLRequest) {
        super.init()
        let task = session.dataTask(with: request)
        task.delegate = self
        self.task = task
        task.resume()
    }

    func response() async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<URLResponse, any Error>? in
                    if let receivedResponse { return receivedResponse }
                    responseWaiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { lock.withLock { task }?.cancel() }

    private enum Next { case chunk([UInt8]), failure(any Error), wait }

    private func take(_ limit: Int) -> Next {
        lock.withLock {
            if !chunks.isEmpty {
                var chunk = chunks.removeFirst()
                if chunk.count > limit {
                    chunks.insert(chunk.subdata(in: limit..<chunk.count), at: 0)
                    chunk = chunk.subdata(in: 0..<limit)
                }
                return .chunk([UInt8](chunk))
            }
            if let finished { return finished.map { .failure($0) } ?? .chunk([]) }
            return .wait
        }
    }

    /// The next chunk of at most `limit` bytes; empty at the end of the body.
    func next(limit: Int = .max) async throws -> [UInt8] {
        while true {
            switch take(limit) {
            case let .chunk(bytes): return bytes
            case let .failure(error): throw error
            case .wait: break
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = lock.withLock { () -> Bool in
                        if !chunks.isEmpty || finished != nil { return true }
                        chunkWaiter = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            } onCancel: { self.cancel() }
            if Task.isCancelled { throw CancellationError() }
        }
    }

    private func wake() {
        let waiter = chunkWaiter
        chunkWaiter = nil
        waiter?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let waiter = lock.withLock { () -> CheckedContinuation<URLResponse, any Error>? in
            receivedResponse = .success(response)
            defer { responseWaiter = nil }
            return responseWaiter
        }
        waiter?.resume(returning: response)
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        chunks.append(data)
        wake()
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        finished = .some(error)
        if receivedResponse == nil { receivedResponse = .failure(error ?? URLError(.badServerResponse)) }
        let waiter = responseWaiter
        responseWaiter = nil
        wake()
        self.task = nil
        lock.unlock()
        waiter?.resume(throwing: error ?? URLError(.badServerResponse))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Reads one response body: a single JSON document or Server-Sent Events.
private final class MCPHTTPResponseReader: MCPResponseReader, @unchecked Sendable {
    // The reader is consumed by one exchange at a time, under its session.
    private let client: MCPHTTPClient
    private let body: MCPHTTPBody
    private let stream: Bool
    private let initialize: Bool
    private var buffer: [UInt8] = []
    private var position = 0
    private var ended = false
    private var remaining = atlasMaxMCPFrameBytes + 1

    init(client: MCPHTTPClient, body: MCPHTTPBody, stream: Bool, initialize: Bool) {
        self.client = client; self.body = body; self.stream = stream; self.initialize = initialize
    }

    /// Refills the buffer; returns false at the end of the body.
    private func fill() async throws -> Bool {
        guard !ended else { return false }
        let chunk: [UInt8]
        do { chunk = try await body.next() } catch {
            if Task.isCancelled || error is CancellationError { body.cancel(); throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { throw AtlasRuntimeError("mcp_http_timeout") }
            throw AtlasRuntimeError(stream ? "mcp_http_stream_ended_before_response" : "mcp_http_response_failed")
        }
        if chunk.isEmpty { ended = true; return false }
        if position > 0 { buffer.removeFirst(position); position = 0 }
        buffer += chunk
        return true
    }

    func nextFrame() async throws -> [UInt8] {
        if !stream {
            while try await fill() {
                if buffer.count > atlasMaxMCPFrameBytes { throw AtlasRuntimeError("mcp_http_response_limit") }
            }
            let data = Array(buffer[position...])
            position = buffer.count
            guard AtlasUTF8.isValid(data) else { throw AtlasRuntimeError("mcp_invalid_frame") }
            return data
        }
        var event: [UInt8] = []
        while true {
            // One line, bounded by the remaining response budget.
            var line: [UInt8] = []
            var terminated = false
            while !terminated {
                if position == buffer.count, !(try await fill()) { break }
                let available = buffer[position...]
                let allowed = remaining - line.count
                if let newline = available.prefix(allowed).firstIndex(of: 0x0A) {
                    line += buffer[position...newline]
                    position = newline + 1
                    terminated = true
                } else {
                    let take = min(available.count, allowed)
                    line += buffer[position..<(position + take)]
                    position += take
                    if line.count >= remaining { break }
                }
            }
            remaining -= line.count
            if remaining <= 0 { throw AtlasRuntimeError("mcp_http_response_limit") }
            guard terminated else { throw AtlasRuntimeError("mcp_http_stream_ended_before_response") }
            line.removeLast()
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty {
                if !event.isEmpty {
                    event.removeLast() // trailing newline
                    guard AtlasUTF8.isValid(event) else { throw AtlasRuntimeError("mcp_invalid_frame") }
                    return event
                }
                continue
            }
            if line.starts(with: Array("data:".utf8)) {
                var data = line[5...]
                if data.first == 0x20 { data = data.dropFirst() }
                // Empty priming events are allowed by Streamable HTTP.
                if !data.isEmpty || !event.isEmpty {
                    event += data
                    event.append(0x0A)
                }
            }
        }
    }

    func finish(result: [UInt8], isError: Bool) async throws {
        body.cancel()
        try client.finished(initialize: initialize, result: result, isError: isError)
    }
}
