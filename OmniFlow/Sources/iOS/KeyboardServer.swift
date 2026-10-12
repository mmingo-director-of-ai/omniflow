import Foundation
import Network

/// Loopback-only HTTP endpoint the OmniFlow keyboard talks to during one
/// keyboard session (see KeyboardBridge for the threat model). One request per
/// connection, no bodies:
///   GET /state, POST /start, POST /stop, POST /cancel, POST /consume?id=<uuid>
/// Anything else is rejected: malformed or oversized requests 400, unknown
/// paths 404, wrong methods 405, missing or wrong token 403, too many requests
/// 429. Repeated bad tokens close the listener and end the session.
@MainActor
final class KeyboardServer {
    typealias Handler = @MainActor (KeyboardBridge.Command, URLComponents) -> Void

    nonisolated static let maximumRequestBytes = 1024
    /// The keyboard polls ~20 times a second while listening, for the voice ring.
    static let requestsPerSecond = 60
    static let maximumBadTokens = 5

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "omniflow.keyboard-server")
    private var pairing: KeyboardBridge.Pairing?
    private var handler: Handler?
    private var onLockout: (@MainActor () -> Void)?
    private var windowStart = Date.distantPast
    private var windowCount = 0
    private var badTokens = 0
    /// Read by `GET /state`; the session controller keeps it current.
    var state = KeyboardBridge.State()

    var isListening: Bool { listener != nil }

    /// Binds 127.0.0.1:`pairing.port` only. Replaces any previous pairing and listener.
    func start(_ pairing: KeyboardBridge.Pairing, handler: @escaping Handler, onLockout: @escaping @MainActor () -> Void) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(KeyboardBridge.host),
                                                      port: NWEndpoint.Port(rawValue: pairing.port)!)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.stop() } }
        }
        listener.start(queue: queue)
        self.listener = listener
        self.pairing = pairing
        self.handler = handler
        self.onLockout = onLockout
        badTokens = 0; windowCount = 0
    }

    /// Closes the listener and forgets the pairing; the token is dead from here.
    func stop() {
        listener?.cancel(); listener = nil
        pairing = nil; handler = nil; onLockout = nil
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else { connection.cancel(); return }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        // A client that never finishes its request is dropped.
        queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
    }

    private nonisolated func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }
            if buffer.count > KeyboardServer.maximumRequestBytes {
                Task { @MainActor in self?.reply(400, on: connection) }
            } else if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                // Requests have no body: nothing may follow the header block.
                let request = buffer, hasBody = end.upperBound != buffer.endIndex
                Task { @MainActor in self?.respond(to: request, hasBody: hasBody, on: connection) }
            } else if complete {
                connection.cancel()
            } else {
                self?.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: Data, hasBody: Bool, on connection: NWConnection) {
        guard let pairing, let handler else { return reply(403, on: connection) }
        guard withinRate() else { return reply(429, on: connection) }
        guard !hasBody, let parsed = Self.parse(request) else { return reply(400, on: connection) }
        guard let command = KeyboardBridge.Command(rawValue: String(parsed.components.path.dropFirst())) else {
            return reply(404, on: connection)
        }
        guard (command == .state ? "GET" : "POST") == parsed.method else { return reply(405, on: connection) }
        guard let presented = parsed.token, Self.constantTimeEqual(presented, pairing.token) else {
            badTokens += 1
            reply(403, on: connection)
            if badTokens >= Self.maximumBadTokens { let lockout = onLockout; stop(); lockout?() }
            return
        }
        if command == .consume {
            guard let items = parsed.components.queryItems, items.count == 1, items[0].name == "id",
                  items[0].value.flatMap(UUID.init(uuidString:)) != nil else { return reply(400, on: connection) }
        } else if parsed.components.query != nil {
            return reply(400, on: connection)
        }
        if command != .state { handler(command, parsed.components) }
        reply(200, body: (try? JSONEncoder().encode(state)) ?? Data(), on: connection)
    }

    private func withinRate(now: Date = .now) -> Bool {
        if now.timeIntervalSince(windowStart) >= 1 { windowStart = now; windowCount = 0 }
        windowCount += 1
        return windowCount <= Self.requestsPerSecond
    }

    struct Parsed { let method: String; let components: URLComponents; let token: String? }

    /// Accepts exactly `METHOD /path[?query] HTTP/1.1` followed by headers; nothing else.
    nonisolated static func parse(_ request: Data) -> Parsed? {
        guard let text = String(data: request, encoding: .utf8), text.allSatisfy({ $0.isASCII }) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET" || parts[0] == "POST", parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/"), let components = URLComponents(string: String(parts[1])) else { return nil }
        var token: String?
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            if line[..<colon].caseInsensitiveCompare(KeyboardBridge.tokenHeader) == .orderedSame {
                guard token == nil else { return nil }
                token = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return Parsed(method: String(parts[0]), components: components, token: token)
    }

    private func reply(_ status: Int, body: Data = Data(), on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 429: "Too Many Requests"][status] ?? "Error"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
