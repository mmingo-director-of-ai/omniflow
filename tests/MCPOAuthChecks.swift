import Foundation

/// Protocol and transport checks use synthetic credentials and isolated request
/// fixtures. They never open a browser, register a real client, or use Keychain.
enum MCPOAuthChecks {
    static func run() async throws {
        try protocolChecks()
        try await discoveryChecks()
        try await registrationAndTokenChecks()
        try await transportChecks()
        try await loopbackChecks()
        try await browserLifecycleChecks()
        try await nativeCompletionQueueChecks()
        report("OAuth discovery, PKCE, callback binding, public registration, token validation, response limits and cancellation: passed")
    }

    private static func protocolChecks() throws {
        // RFC 7636 Appendix B, independently specified interoperability vector.
        precondition(MCPOAuthProtocol.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
                     "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = try MCPOAuthProtocol.randomURLToken()
        precondition(random.count == 43 && random.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        let secondRandom = try MCPOAuthProtocol.randomURLToken()
        precondition(random != secondRandom)
        let encoded = String(decoding: MCPOAuthProtocol.form(["a+b": "space + & = / 日本語"]), as: UTF8.self)
        precondition(encoded == "a%2Bb=space%20%2B%20%26%20%3D%20%2F%20%E6%97%A5%E6%9C%AC%E8%AA%9E")
        for value in ["http://issuer.example/token", "https://user:secret@issuer.example/token", "https://issuer.example/token#fragment", "https://issuer.example/token\r\nInjected", "file:///tmp/token"] {
            try fails(.invalidResource) { _ = try MCPOAuthProtocol.httpsURL(value) }
        }
        let tenant = URL(string: "https://issuer.example/tenant?ignored=true")!
        let wellKnown = try MCPOAuthProtocol.wellKnown(tenant, name: "oauth-authorization-server", includePath: true)
        precondition(wellKnown.absoluteString == "https://issuer.example/.well-known/oauth-authorization-server/tenant")
        try fails(.discovery) {
            _ = try MCPOAuthProtocol.add(parameters: ["state": "expected"], to: "https://issuer.example/authorize?state=forged")
        }
        let authorization = try MCPOAuthProtocol.add(parameters: ["client_id": "native+fixture", "resource": "https://tools.example/a+b"],
                                                     to: "https://issuer.example/authorize?tenant=one%2Btwo")
        let authorizationQuery = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.percentEncodedQuery!
        precondition(authorizationQuery.contains("tenant=one%2Btwo") && authorizationQuery.contains("client_id=native%2Bfixture") &&
                     authorizationQuery.contains("resource=https%3A%2F%2Ftools.example%2Fa%2Bb"),
                     "Authorization query must preserve literal pluses when the provider uses OAuth form decoding")
        let header = #"Bearer realm="OAuth", resource_metadata="https://tools.example/metadata", scope="read search""#
        precondition(MCPOAuthProtocol.challengeValue("resource_metadata", header: header) == "https://tools.example/metadata")
        precondition(MCPOAuthProtocol.challengeValue("scope", header: header) == "read search")

        let redirect = URL(string: "http://127.0.0.1:41923/oauth/callback")!
        let valid = URL(string: redirect.absoluteString + "?code=fixture%2Bcode&state=expected")!
        let code = try MCPOAuthProtocol.callbackCode(valid, redirect: redirect, state: "expected")
        precondition(code == "fixture+code")
        for suffix in ["?code=fixture&state=wrong", "?code=fixture&state=expected&state=expected", "?code=one&code=two&state=expected", "?state=expected", "?code=fixture&state=expected#fragment"] {
            try fails(.invalidCallback) {
                _ = try MCPOAuthProtocol.callbackCode(URL(string: redirect.absoluteString + suffix)!, redirect: redirect, state: "expected")
            }
        }
        for wrong in ["http://localhost:41923/oauth/callback", "http://127.0.0.1:41924/oauth/callback", "http://127.0.0.1:41923/other"] {
            try fails(.invalidCallback) {
                _ = try MCPOAuthProtocol.callbackCode(URL(string: wrong + "?code=fixture&state=expected")!, redirect: redirect, state: "expected")
            }
        }
        try fails(.denied) {
            _ = try MCPOAuthProtocol.callbackCode(URL(string: redirect.absoluteString + "?state=expected&error=access_denied")!, redirect: redirect, state: "expected")
        }
        let issuer = "https://issuer.example"
        let issuerCallback = URL(string: valid.absoluteString + "&iss=https%3A%2F%2Fissuer.example")!
        let issuerCode = try MCPOAuthProtocol.callbackCode(issuerCallback, redirect: redirect, state: "expected", expectedIssuer: issuer, requireIssuer: true)
        precondition(issuerCode == "fixture+code")
        try fails(.invalidCallback) {
            _ = try MCPOAuthProtocol.callbackCode(valid, redirect: redirect, state: "expected", expectedIssuer: issuer, requireIssuer: true)
        }
        for suffix in ["&iss=https%3A%2F%2Fother.example", "&iss=https%3A%2F%2Fissuer.example&iss=https%3A%2F%2Fissuer.example"] {
            try fails(.invalidCallback) {
                _ = try MCPOAuthProtocol.callbackCode(URL(string: valid.absoluteString + suffix)!, redirect: redirect, state: "expected", expectedIssuer: issuer)
            }
        }
    }

    private static let resource = "https://tools.example/mcp"
    private static let issuer = "https://issuer.example/tenant"
    private static let advertisedMetadata = "https://tools.example/advertised-resource"
    private static let issuerMetadata = "https://issuer.example/.well-known/oauth-authorization-server/tenant"

    private static func metadata(issuer: String = issuer, pkce: [String] = ["S256"], methods: [String] = ["none"]) -> [String: Any] {
        ["issuer": issuer, "authorization_endpoint": "https://issuer.example/authorize", "token_endpoint": "https://issuer.example/token",
         "registration_endpoint": "https://issuer.example/register", "code_challenge_methods_supported": pkce,
         "token_endpoint_auth_methods_supported": methods]
    }
    private static func resourceMetadata(resource: String = resource, scopes: [String]? = ["broad"]) -> [String: Any] {
        var value: [String: Any] = ["resource": resource, "authorization_servers": [issuer]]
        if let scopes { value["scopes_supported"] = scopes }
        return value
    }
    private static func reply(_ value: [String: Any], status: Int = 200, challenge: String? = nil) throws -> MCPOAuthNetwork.Reply {
        .init(status: status, data: try JSONSerialization.data(withJSONObject: value), challenge: challenge)
    }
    private static func discoveryChecks() async throws {
        let fixture = OAuthRequestFixture(responses: [
            resource: try reply([:], status: 401, challenge: #"Bearer resource_metadata="https://tools.example/advertised-resource", scope="read""#),
            advertisedMetadata: try reply(resourceMetadata()), issuerMetadata: try reply(metadata()),
        ])
        let discovery = try await MCPOAuthNetwork.discover(resource: resource, load: fixture.loader)
        precondition(discovery.scope == "read", "The challenged scope must take precedence over advertised scopes")
        precondition(discovery.authorization.issuer == issuer)
        let requests = await fixture.requests
        precondition(requests.map(\.url) == [resource, advertisedMetadata, issuerMetadata], "Advertised resource metadata must be used before fallback")
        precondition(requests.allSatisfy { $0.method == "GET" && $0.data == nil })

        let fallback = OAuthRequestFixture(responses: [
            resource: try reply([:], status: 405),
            "https://tools.example/.well-known/oauth-protected-resource/mcp": try reply([:], status: 404),
            "https://tools.example/.well-known/oauth-protected-resource": try reply(resourceMetadata(scopes: nil)),
            issuerMetadata: try reply([:], status: 404),
            "https://issuer.example/.well-known/openid-configuration/tenant": try reply(metadata()),
        ])
        let noScopes = try await MCPOAuthNetwork.discover(resource: resource, load: fallback.loader)
        precondition(noScopes.scope == nil, "Do not invent scopes when resource metadata omits them")

        let mismatchedResource = OAuthRequestFixture(responses: [
            resource: try reply([:], status: 401),
            "https://tools.example/.well-known/oauth-protected-resource/mcp": try reply(resourceMetadata(resource: "https://other.example/mcp")),
        ])
        try await fails(.discovery) { _ = try await MCPOAuthNetwork.discover(resource: resource, load: mismatchedResource.loader) }
        let mismatchRequests = await mismatchedResource.requests
        precondition(mismatchRequests.allSatisfy { !$0.url.hasPrefix("https://issuer.example/") })

        for (serverMetadata, error) in [
            (metadata(issuer: "https://other.example"), MCPOAuthError.discovery),
            (metadata(pkce: ["plain"]), .unsupportedPKCE),
            (metadata(methods: ["client_secret_basic"]), .invalidClient),
        ] {
            let invalid = OAuthRequestFixture(responses: [
                resource: try reply([:], status: 401),
                "https://tools.example/.well-known/oauth-protected-resource/mcp": try reply(resourceMetadata()),
                issuerMetadata: try reply(serverMetadata),
            ])
            try await fails(error) { _ = try await MCPOAuthNetwork.discover(resource: resource, load: invalid.loader) }
        }
    }

    private static func registrationAndTokenChecks() async throws {
        let metadata = try JSONDecoder().decode(MCPOAuthServerMetadata.self, from: JSONSerialization.data(withJSONObject: metadata()))
        let redirect = "http://127.0.0.1:41923/oauth/callback"
        let fixture = OAuthRequestFixture(responses: [
            "https://issuer.example/register": try reply(["client_id": "fixture-public-client", "token_endpoint_auth_method": "none", "redirect_uris": [redirect]], status: 201),
        ])
        let id = try await MCPOAuthNetwork.register(metadata: metadata, redirect: redirect, load: fixture.loader)
        precondition(id == "fixture-public-client")
        let sent = await fixture.requests[0]
        let registered = try JSONSerialization.jsonObject(with: sent.data!) as! [String: Any]
        precondition(sent.method == "POST" && !sent.form)
        precondition(registered["redirect_uris"] as? [String] == [redirect] && registered["token_endpoint_auth_method"] as? String == "none")
        precondition(registered["client_secret"] == nil, "Native OAuth must not register as a confidential client")
        for response: [String: Any] in [
            ["client_id": "fixture", "client_secret": "fixture-secret"],
            ["client_id": "fixture", "token_endpoint_auth_method": "client_secret_post"],
            ["client_id": "fixture", "redirect_uris": ["https://other.example/callback"]],
        ] {
            let invalid = OAuthRequestFixture(responses: ["https://issuer.example/register": try reply(response, status: 201)])
            try await fails(.registration) { _ = try await MCPOAuthNetwork.register(metadata: metadata, redirect: redirect, load: invalid.loader) }
        }

        let tokens = OAuthRequestFixture(responses: [
            "https://issuer.example/token": try reply(["access_token": "fixture-access", "token_type": "Bearer", "refresh_token": "fixture-rotated", "expires_in": 900, "resource": resource]),
        ])
        let parameters = ["grant_type": "refresh_token", "client_id": "fixture+client", "refresh_token": "fixture+refresh/=", "resource": resource]
        let token = try await MCPOAuthNetwork.token(endpoint: metadata.token_endpoint, parameters: parameters, resource: resource, load: tokens.loader)
        precondition(token.access_token == "fixture-access" && token.refresh_token == "fixture-rotated" && token.expiry != nil)
        let tokenRequest = await tokens.requests[0]
        precondition(tokenRequest.url == metadata.token_endpoint && tokenRequest.method == "POST" && tokenRequest.form)
        let posted = String(decoding: tokenRequest.data!, as: UTF8.self)
        precondition(posted.contains("client_id=fixture%2Bclient") && posted.contains("refresh_token=fixture%2Brefresh%2F%3D") && posted.contains("resource=https%3A%2F%2Ftools.example%2Fmcp"))
        var wrongResource = parameters
        wrongResource["resource"] = "https://other.example/mcp"
        let uncontacted = OAuthRequestFixture(responses: [:])
        try await fails(.invalidResource) {
            _ = try await MCPOAuthNetwork.token(endpoint: metadata.token_endpoint, parameters: wrongResource, resource: resource, load: uncontacted.loader)
        }
        let wrongResourceRequests = await uncontacted.requests
        precondition(wrongResourceRequests.isEmpty, "A mismatched token resource must fail before transmitting refresh credentials")
        for response: [String: Any] in [
            ["access_token": "fixture", "token_type": "Bearer", "resource": "https://other.example/mcp"],
            ["access_token": "fixture\r\nInjected: true", "token_type": "Bearer"],
            ["access_token": "fixture", "token_type": "Basic"],
            ["access_token": "fixture", "token_type": "Bearer", "expires_in": -1],
        ] {
            let invalid = OAuthRequestFixture(responses: [metadata.token_endpoint: try reply(response)])
            try await fails(.invalidToken) { _ = try await MCPOAuthNetwork.token(endpoint: metadata.token_endpoint, parameters: parameters, resource: resource, load: invalid.loader) }
        }
        let expired = OAuthRequestFixture(responses: [metadata.token_endpoint: try reply(["error": "invalid_grant", "error_description": "DO_NOT_EXPOSE_PROVIDER_BODY"], status: 400)])
        try await fails(.expired) { _ = try await MCPOAuthNetwork.token(endpoint: metadata.token_endpoint, parameters: parameters, resource: resource, load: expired.loader) }
    }

    private static func transportChecks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthProtocolFixture.self]
        let endpoint = URL(string: "https://fixture.invalid/oauth")!
        OAuthProtocolFixture.state.reset(.init(status: 302, headers: ["Location": "https://unexpected.invalid/token"], data: Data()))
        try await fails(.redirect) { _ = try await MCPOAuthNetwork.request(endpoint, configuration: configuration) }
        precondition(OAuthProtocolFixture.state.requestCount == 1, "OAuth must not follow redirects")
        OAuthProtocolFixture.state.reset(.init(status: 200, headers: ["Content-Length": "128001"], data: Data()))
        try await fails(.responseLimit) { _ = try await MCPOAuthNetwork.request(endpoint, configuration: configuration) }
        OAuthProtocolFixture.state.reset(.init(status: 200, headers: [:], data: Data(repeating: 120, count: 128_001)))
        try await fails(.responseLimit) { _ = try await MCPOAuthNetwork.request(endpoint, configuration: configuration) }
        OAuthProtocolFixture.state.reset(.init(status: 200, headers: ["Content-Type": "application/json"], data: Data("{}".utf8), delay: 2))
        let task = Task { try await MCPOAuthNetwork.request(endpoint, configuration: configuration) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = Date()
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled OAuth request completed") }
        catch is CancellationError { }
        precondition(Date().timeIntervalSince(cancelled) < 1, "OAuth cancellation waited for the remote response")
    }

    private static func loopbackChecks() async throws {
        let observed = OAuthCallbackObservation()
        let receiver = MCPOAuthLoopback(state: "fixture-expected-state") { observed.receive($0) }
        let redirect = try await receiver.start()
        defer { receiver.cancel() }
        precondition(redirect.host == "127.0.0.1" && redirect.scheme == "http" && redirect.port != nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let invalid = URL(string: redirect.absoluteString + "?state=wrong&code=fixture-code")!
        let (_, invalidResponse) = try await session.data(from: invalid)
        precondition((invalidResponse as? HTTPURLResponse)?.statusCode == 400 && observed.count == 0)
        let valid = URL(string: redirect.absoluteString + "?state=fixture-expected-state&code=fixture-code")!
        var forgedHost = URLRequest(url: valid)
        forgedHost.setValue("other.example", forHTTPHeaderField: "Host")
        _ = try? await session.data(for: forgedHost)
        precondition(observed.count == 0, "A callback with an unexpected Host header completed sign-in")
        let (_, validResponse) = try await session.data(from: valid)
        precondition((validResponse as? HTTPURLResponse)?.statusCode == 200)
        for _ in 0..<20 where observed.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        precondition(observed.count == 1 && observed.url == valid)
        receiver.cancel()
        try await Task.sleep(for: .milliseconds(100))
        do { _ = try await session.data(from: valid); preconditionFailure("Cancelled OAuth callback listener remained reachable") }
        catch is URLError { }
        precondition(observed.count == 1, "Callback completed again after cancellation")
    }

    @MainActor
    private static func browserLifecycleChecks() async throws {
        let authorization = URL(string: "https://issuer.example/authorize?state=fixture")!
        let callback = URL(string: "http://127.0.0.1:41923/oauth/callback?state=fixture&code=fixture")!
        let auth = MCPOAuth()
        var opened = false
        let cancelledID = UUID()
        let pending = Task { @MainActor in
            try await auth.authenticate(url: authorization, id: cancelledID, presentation: .defaultBrowser,
                timeout: .seconds(1), openURL: { url in opened = true; precondition(url == authorization); return true })
        }
        for _ in 0..<100 where !opened { await Task.yield() }
        precondition(opened, "Browser retry did not launch its supplied authorization URL")
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancelled browser sign-in completed") }
        catch MCPOAuthError.cancelled { }
        // A callback arriving after cancellation cannot complete a later retry.
        let retryID = UUID()
        var retryOpened = false
        var retryCompleted = false
        let retry = Task { @MainActor in
            let result = try await auth.authenticate(url: authorization, id: retryID, presentation: .defaultBrowser,
                timeout: .seconds(1), openURL: { _ in retryOpened = true; return true })
            retryCompleted = true
            return result
        }
        for _ in 0..<100 where !retryOpened { await Task.yield() }
        precondition(retryOpened)
        auth.finishBrowser(cancelledID, result: .success(callback))
        await Task.yield()
        precondition(!retryCompleted, "An old callback completed a new sign-in attempt")
        auth.finishBrowser(retryID, result: .success(callback))
        let accepted = try await retry.value
        precondition(accepted == callback && retryCompleted)
        // Completing a flow cancels its old timer; a timeout cleans up state and
        // permits another attempt rather than stranding the Settings spinner.
        let timedID = UUID()
        let started = Date()
        do {
            _ = try await auth.authenticate(url: authorization, id: timedID, presentation: .defaultBrowser,
                timeout: .milliseconds(20), openURL: { _ in true })
            preconditionFailure("Browser sign-in ignored its wait timeout")
        } catch MCPOAuthError.timedOut { }
        precondition(Date().timeIntervalSince(started) < 1)
        auth.finishBrowser(timedID, result: .success(callback))
        do {
            _ = try await auth.authenticate(url: authorization, id: UUID(), presentation: .defaultBrowser,
                timeout: .seconds(1), openURL: { _ in false })
            preconditionFailure("A failed browser launch left sign-in pending")
        } catch MCPOAuthError.unavailable { }
    }

    /// Safari's native completion arrives on an XPC queue, not MainActor.
    /// Exercise the production callback factory on a real background queue;
    /// inheriting MainActor isolation here reproduces the dispatch assertion.
    @MainActor
    private static func nativeCompletionQueueChecks() async throws {
        let authorization = URL(string: "https://issuer.example/authorize?state=fixture")!
        let auth = MCPOAuth()
        let cancelledID = UUID()
        var opened = false
        let cancelled = Task { @MainActor in
            try await auth.authenticate(url: authorization, id: cancelledID, presentation: .defaultBrowser,
                timeout: .seconds(2), openURL: { _ in opened = true; return true })
        }
        for _ in 0..<100 where !opened { await Task.yield() }
        precondition(opened)
        let staleCompletion = auth.authenticationSessionCompletion(for: cancelledID)
        await invokeOffMain(staleCompletion, error: NSError(domain: "OAuthCallbackFixture", code: 1))
        do { _ = try await cancelled.value; preconditionFailure("Native cancellation did not finish sign-in") }
        catch MCPOAuthError.cancelled { }

        let retryID = UUID()
        var retryOpened = false
        var retryFinished = false
        let retry = Task { @MainActor in
            defer { retryFinished = true }
            return try await auth.authenticate(url: authorization, id: retryID, presentation: .defaultBrowser,
                timeout: .seconds(2), openURL: { _ in retryOpened = true; return true })
        }
        for _ in 0..<100 where !retryOpened { await Task.yield() }
        precondition(retryOpened)
        // A delayed native callback from the old sheet must not cancel a new
        // browser attempt, even when both reach MainActor in adjacent turns.
        await invokeOffMain(staleCompletion, error: NSError(domain: "OAuthCallbackFixture", code: 1))
        await Task.yield()
        precondition(!retryFinished, "A stale native completion ended the new sign-in")
        await invokeOffMain(auth.authenticationSessionCompletion(for: retryID), error: nil)
        do { _ = try await retry.value; preconditionFailure("Empty native completion was accepted as a valid callback") }
        catch MCPOAuthError.invalidCallback { }
        precondition(retryFinished)
        report("Native authentication callbacks cross from a background queue to MainActor without crashing or completing stale flows: passed")
    }

    private static func invokeOffMain(_ callback: @escaping @Sendable (URL?, Error?) -> Void,
                                      error: Error?) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                precondition(!Thread.isMainThread, "Native callback regression must execute off the main thread")
                callback(nil, error)
                continuation.resume()
            }
        }
    }

    private static func fails(_ expected: MCPOAuthError, _ operation: () throws -> Void) throws {
        do { try operation(); preconditionFailure("Expected OAuth failure: \(expected)") }
        catch let error as MCPOAuthError { precondition(String(describing: error) == String(describing: expected), "Unexpected OAuth failure: \(error)") }
    }
    private static func fails(_ expected: MCPOAuthError, _ operation: () async throws -> Void) async throws {
        do { try await operation(); preconditionFailure("Expected OAuth failure: \(expected)") }
        catch let error as MCPOAuthError { precondition(String(describing: error) == String(describing: expected), "Unexpected OAuth failure: \(error)") }
    }
    private static func report(_ message: String) { try! FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8)) }
}

private final class OAuthCallbackObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<URL, MCPOAuthError>] = []
    var count: Int { lock.withLock { results.count } }
    var url: URL? { lock.withLock { results.first.flatMap { try? $0.get() } } }
    func receive(_ value: Result<URL, MCPOAuthError>) { lock.withLock { results.append(value) } }
}

private actor OAuthRequestFixture {
    struct Request: Sendable { let url: String; let method: String; let data: Data?; let form: Bool }
    let responses: [String: MCPOAuthNetwork.Reply]
    private(set) var requests: [Request] = []
    init(responses: [String: MCPOAuthNetwork.Reply]) { self.responses = responses }
    nonisolated var loader: MCPOAuthNetwork.Loader {
        { url, method, data, form in try await self.load(url, method, data, form) }
    }
    func load(_ url: URL, _ method: String, _ data: Data?, _ form: Bool) throws -> MCPOAuthNetwork.Reply {
        requests.append(.init(url: url.absoluteString, method: method, data: data, form: form))
        guard let response = responses[url.absoluteString] else { throw MCPOAuthError.network }
        return response
    }
}

private final class OAuthProtocolFixture: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var headers: [String: String]; var data: Data; var delay: Double = 0 }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var reply = Reply(status: 500, headers: [:], data: Data())
        private var count = 0
        var requestCount: Int { lock.withLock { count } }
        func reset(_ value: Reply) { lock.withLock { reply = value; count = 0 } }
        func receive() -> Reply { lock.withLock { count += 1; return reply } }
    }
    static let state = State()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.receive()
        let deliver: @Sendable () -> Void = { [self] in
            guard !lock.withLock({ stopped }) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay == 0 { deliver() }
        else { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}
