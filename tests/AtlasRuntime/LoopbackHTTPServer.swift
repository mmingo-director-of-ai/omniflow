// A minimal HTTP/1.1 loopback server for tests (Go's httptest equivalent).
// One request per connection; each connection runs on its own thread so a
// handler may block, stream, or wait for the client to disconnect.
import Darwin
import Foundation
import Synchronization
@testable import OmniFlowApp

final class LoopbackHTTPServer: Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String] // lowercased names
        let body: [UInt8]
        func header(_ name: String) -> String? { headers[name.lowercased()] }
        var json: [String: AtlasJSON] { (try? AtlasJSON.parse(body))?.dictionary ?? [:] }
        /// The request id's exact JSON text, for echoing.
        var rawID: String? { AtlasJSON.rawMembers(body)?["id"].map { String(decoding: $0, as: UTF8.self) } }
    }

    final class Response: @unchecked Sendable {
        private let socket: Int32
        private var started = false
        init(socket: Int32) { self.socket = socket }

        private func send(_ bytes: [UInt8]) {
            bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.send(socket, buffer.baseAddress! + offset, buffer.count - offset, 0)
                    if count <= 0 { return }
                    offset += count
                }
            }
        }

        private func head(_ status: Int, _ headers: [(String, String)]) {
            started = true
            var text = "HTTP/1.1 \(status) Status\r\n"
            for (name, value) in headers { text += "\(name): \(value)\r\n" }
            text += "Connection: close\r\n\r\n"
            send(Array(text.utf8))
        }

        /// A complete response with Content-Length (none for 204/304).
        func respond(_ status: Int, headers: [(String, String)] = [], body: [UInt8] = []) {
            var all = headers
            if status != 204 && status != 304 && !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
                all.append(("Content-Length", String(body.count)))
            }
            head(status, all)
            send(body)
        }

        func json(_ value: String, headers: [(String, String)] = []) {
            respond(200, headers: [("Content-Type", "application/json")] + headers, body: Array(value.utf8))
        }

        /// Starts a body delimited by connection close (for SSE streams).
        func stream(_ status: Int = 200, headers: [(String, String)]) { head(status, headers) }
        func write(_ text: String) { send(Array(text.utf8)) }
        func writeRaw(_ bytes: [UInt8]) { send(bytes) }

        /// Blocks until the client closes or resets the connection.
        func waitForDisconnect(timeout: Double = 10) -> Bool {
            var pollDescriptor = pollfd(fd: socket, events: Int16(POLLIN | POLLHUP), revents: 0)
            let deadline = Date().addingTimeInterval(timeout)
            var byte: UInt8 = 0
            while Date() < deadline {
                if poll(&pollDescriptor, 1, 50) > 0 {
                    if recv(socket, &byte, 1, MSG_PEEK) <= 0 { return true }
                    var sink = [UInt8](repeating: 0, count: 4096)
                    _ = recv(socket, &sink, sink.count, 0)
                }
            }
            return false
        }
    }

    typealias Handler = @Sendable (Request, Response) -> Void
    private let listener: Int32
    let port: UInt16
    final class Shared: Sendable {
        let handler: Handler
        let stopped = Mutex(false)
        init(_ handler: @escaping Handler) { self.handler = handler }
    }
    private let shared: Shared

    init(_ handler: @escaping Handler) {
        let shared = Shared(handler)
        self.shared = shared
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listener, 64)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        port = UInt16(bigEndian: bound.sin_port)
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { if shared.stopped.withLock({ $0 }) { return } else { continue } }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { LoopbackHTTPServer.serve(client, shared.handler) }
            }
        }
    }

    var url: String { "http://127.0.0.1:\(port)" }

    func stop() {
        shared.stopped.withLock { $0 = true }
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    deinit { stop() }

    private static func serve(_ client: Int32, _ handler: Handler) {
        defer { close(client) }
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        var headerEnd: Int?
        while headerEnd == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { return }
            data += buffer[..<count]
            if let range = Data(data).range(of: Data("\r\n\r\n".utf8)) { headerEnd = range.upperBound }
        }
        let head = String(decoding: data[..<(headerEnd! - 4)], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = head[0].split(separator: " ")
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        var body = Array(data[headerEnd!...])
        while body.count < length {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            body += buffer[..<count]
        }
        let request = Request(method: String(requestLine[0]), path: String(requestLine.count > 1 ? requestLine[1] : "/"), headers: headers, body: body)
        handler(request, Response(socket: client))
    }
}

/// An MCP JSON-RPC fixture endpoint built on the loopback server.
final class MCPFixtureEndpoint: @unchecked Sendable {
    final class Counts: Sendable { let values = Mutex<[String: Int]>([:]) }
    let server: LoopbackHTTPServer
    let counts = Counts()

    /// `result` maps a JSON-RPC method and params to a result JSON text; nil
    /// lets `custom` produce the whole response.
    init(sessionID: String? = "fixture-session",
         result: @escaping @Sendable (_ method: String, _ params: [String: AtlasJSON], _ request: LoopbackHTTPServer.Request) -> String?,
         custom: (@Sendable (LoopbackHTTPServer.Request, LoopbackHTTPServer.Response) -> Bool)? = nil) {
        let counts = counts
        server = LoopbackHTTPServer { request, response in
            if let custom, custom(request, response) { return }
            counts.values.withLock { $0[request.method, default: 0] += 1 }
            if request.method == "DELETE" { response.respond(204); return }
            let fields = request.json
            let method = fields["method"]?.stringValue ?? ""
            counts.values.withLock { $0[method, default: 0] += 1 }
            if fields["id"] == nil { response.respond(202); return }
            guard let value = result(method, fields["params"]?.dictionary ?? [:], request) else { response.respond(500); return }
            let headers = method == "initialize" ? sessionID.map { [("Mcp-Session-Id", $0)] } ?? [] : []
            response.json(#"{"jsonrpc":"2.0","id":\#(request.rawID!),"result":\#(value)}"#, headers: headers)
        }
    }

    var url: String { server.url + "/mcp" }
    func count(_ key: String) -> Int { counts.values.withLock { $0[key] ?? 0 } }

    static let initializeResult = #"{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}"#
}
