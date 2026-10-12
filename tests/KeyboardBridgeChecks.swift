import Foundation
import Network

/// Loopback keyboard transport checks: pairing policy, request shape, rate limit, lockout, loopback-only binding.
@main enum KeyboardBridgeChecks {
    static func raw(_ port: UInt16, _ text: String, host: String = "127.0.0.1") async -> String {
        await withCheckedContinuation { c in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = NSLock(); nonisolated(unsafe) var done = false
            @Sendable func finish(_ s: String) { once.lock(); defer { once.unlock() }; if !done { done = true; conn.cancel(); c.resume(returning: s) } }
            conn.stateUpdateHandler = { st in
                if case .failed = st { finish("CONNECT-FAILED") }
                if case .waiting = st { finish("CONNECT-REFUSED") }
                if case .ready = st {
                    conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { d, _, _, _ in
                            finish(String(decoding: d ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? "")
                        }
                    })
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish("TIMEOUT") }
        }
    }
    @MainActor static func main() async throws {
        let server = KeyboardServer()
        var pairing = KeyboardBridge.Pairing.make()
        precondition(pairing.isValid)
        precondition(KeyboardBridge.Pairing(url: pairing.url) == pairing, "url round trip")
        precondition(KeyboardBridge.Pairing(url: URL(string: "omniflow://keyboard-session?token=abc&port=50000")!) == nil, "short token")
        precondition(KeyboardBridge.Pairing(url: URL(string: "omniflow://keyboard-session?token=\(pairing.token)&port=80")!) == nil, "low port")
        precondition(KeyboardBridge.decide(sourceApplication: KeyboardBridge.keyboardBundleID) == .start)
        precondition(KeyboardBridge.decide(sourceApplication: KeyboardBridge.appBundleID) == .start)
        precondition(KeyboardBridge.decide(sourceApplication: nil) == .confirm, "unknown source must confirm")
        precondition(KeyboardBridge.decide(sourceApplication: "com.evil.app") == .confirm, "foreign app must confirm")
        precondition(KeyboardBridge.decide(sourceApplication: "com.mengohlabs.NotchLee.ios.keyboardX") == .confirm)
        print("pairing source policy: ok")
        let hosted = KeyboardBridge.Pairing.make(host: "com.apple.MobileSMS")
        precondition(KeyboardBridge.Pairing(url: hosted.url) == hosted && hosted.hostBundleID == "com.apple.MobileSMS", "host round trip")
        precondition(KeyboardBridge.Pairing.make(host: "bad host!").hostBundleID == nil, "invalid host kept")
        precondition(KeyboardBridge.Pairing(url: URL(string: hosted.url.absoluteString + "&extra=1")!) == nil, "unknown query item accepted")
        print("host pairing: ok")
        var seen: [String] = []; var locked = false
        // A random port can be taken or slow to bind under load: retry on a fresh port
        // until the listener answers, rather than trusting a fixed delay.
        func listen() throws {
            try server.start(pairing, handler: { c, _ in seen.append(c.rawValue) }, onLockout: { locked = true })
        }
        try listen()
        let H = KeyboardBridge.tokenHeader
        func req(_ line: String, token: String? = nil, extra: String = "") -> String {
            "\(line)\r\n" + (token.map { "\(H): \($0)\r\n" } ?? "") + "\r\n" + extra
        }
        var first = ""
        attempts: for attempt in 0..<4 {
            for _ in 0..<30 {
                first = await raw(pairing.port, req("GET /state HTTP/1.1", token: pairing.token))
                if first.contains("200") { break attempts }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard attempt < 3 else { break }
            pairing = KeyboardBridge.Pairing.make()
            try listen()
        }
        let p = pairing.port, t = pairing.token
        print("ok state      ", first)
        print("start         ", await raw(p, req("POST /start HTTP/1.1", token: t)))
        print("consume ok    ", await raw(p, req("POST /consume?id=\(UUID().uuidString) HTTP/1.1", token: t)))
        print("consume bad id", await raw(p, req("POST /consume?id=nope HTTP/1.1", token: t)))
        print("query on start", await raw(p, req("POST /start?x=1 HTTP/1.1", token: t)))
        print("body          ", await raw(p, req("POST /start HTTP/1.1", token: t, extra: "hello")))
        print("http/1.0      ", await raw(p, req("GET /state HTTP/1.0", token: t)))
        print("PUT           ", await raw(p, req("PUT /state HTTP/1.1", token: t)))
        print("dup token hdr ", await raw(p, "GET /state HTTP/1.1\r\n\(H): \(t)\r\n\(H): \(t)\r\n\r\n"))
        print("oversized     ", await raw(p, req("GET /state HTTP/1.1", token: t) .replacingOccurrences(of: "\r\n\r\n", with: "\r\nX: " + String(repeating: "a", count: 2000) + "\r\n\r\n")))
        print("unknown       ", await raw(p, req("POST /nope HTTP/1.1", token: t)))
        print("wrong method  ", await raw(p, req("POST /state HTTP/1.1", token: t)))
        let lan = (try? String(contentsOfFile: "/tmp/lanip", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !lan.isEmpty { print("via LAN \(lan)", await raw(p, req("GET /state HTTP/1.1", token: t), host: lan)) }
        // Rate limit: burst 40 in under a second.
        var codes: [String] = []
        await withTaskGroup(of: String.self) { g in
            for _ in 0..<90 { g.addTask { await raw(p, req("GET /state HTTP/1.1", token: t)) } }
            for await r in g { codes.append(r) }
        }
        print("burst 90       429s:", codes.filter { $0.contains("429") }.count, "200s:", codes.filter { $0.contains("200") }.count)
        try await Task.sleep(for: .seconds(1.1))
        for i in 1...5 { print("bad token \(i)   ", await raw(p, req("GET /state HTTP/1.1", token: KeyboardBridge.makeToken()))) }
        print("locked out:", locked, "listening:", server.isListening)
        print("after lockout ", await raw(p, req("GET /state HTTP/1.1", token: t)))
        print("handled", seen)
    }
}
