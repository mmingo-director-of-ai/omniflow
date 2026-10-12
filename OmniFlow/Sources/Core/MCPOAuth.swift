import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import Network
import Security

enum MCPOAuthPresentation: Sendable {
    case authenticationSession
    case defaultBrowser
}

/// The platform's part of the browser step. The redirect is always the native
/// loopback callback (`MCPOAuthLoopback`, http://127.0.0.1:<port>/oauth/callback,
/// RFC 8252 section 7.3), on macOS and iOS alike: it is the redirect form MCP
/// authorization servers already accept from OmniFlow through dynamic client
/// registration, and it needs no app-specific URL scheme or associated domain.
/// The authentication session only presents the page; it is cancelled as soon
/// as the loopback callback validates.
@MainActor
protocol MCPOAuthPresenter: AnyObject {
    /// The window or scene to present the authentication session over, or nil
    /// when none is available (sign-in then reports `unavailable`).
    func presentationAnchor() -> ASPresentationAnchor?
    /// Opens the authorization URL in the default browser (macOS only).
    func openInBrowser(_ url: URL) -> Bool
}

/// OAuth credentials belong to OmniFlow and to one exact configured MCP resource.
/// Neither a model nor another application's credential store participates.
@MainActor
final class MCPOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MCPOAuth()
    /// Supplied by the app at launch (`MacOAuthPresenter` on macOS, a
    /// scene-anchored presenter on iOS).
    var presenter: (any MCPOAuthPresenter)?
    let store: any MCPOAuthTokenStore
    let load: MCPOAuthNetwork.Loader
    private var browser: ASWebAuthenticationSession?
    private var browserID: UUID?
    private var browserContinuation: CheckedContinuation<URL, Error>?
    private var browserTimeout: Task<Void, Never>?
    private var anchor: ASPresentationAnchor?
    private var authorizing = false
    private var activeResource: String?
    private var generations: [String: Int] = [:]
    private var refreshes: [String: Task<MCPOAuthCredential, Error>] = [:]

    init(store: any MCPOAuthTokenStore = MCPOAuthKeychain(), load: @escaping MCPOAuthNetwork.Loader = MCPOAuthNetwork.live) {
        self.store = store
        self.load = load
    }

    func hasCredential(for server: MCPServerConfiguration) -> Bool {
        guard server.isRemote, let credential = try? store.load(resource: server.url) else { return false }
        return credential.resource == server.url && credential.configuredClientID == server.oauthClientID
    }

    func disconnect(server: MCPServerConfiguration) throws {
        generations[server.url, default: 0] += 1
        refreshes.removeValue(forKey: server.url)?.cancel()
        if activeResource == server.url, let id = browserID { finishBrowser(id, result: .failure(MCPOAuthError.cancelled)) }
        try store.delete(resource: server.url)
    }

    func authorize(server: MCPServerConfiguration, presentation: MCPOAuthPresentation = .authenticationSession) async throws {
        guard server.isRemote, !authorizing else { throw MCPOAuthError.unavailable }
        _ = try MCPOAuthProtocol.httpsURL(server.url)
        authorizing = true
        activeResource = server.url
        refreshes.removeValue(forKey: server.url)?.cancel()
        generations[server.url, default: 0] += 1
        let generation = generations[server.url, default: 0]
        defer { authorizing = false; activeResource = nil }
        let verifier = try MCPOAuthProtocol.randomURLToken()
        let state = try MCPOAuthProtocol.randomURLToken()
        let flow = UUID()
        let callback = MCPOAuthLoopback(state: state) { [weak self] result in
            Task { @MainActor in self?.finishBrowser(flow, result: result.mapError { $0 as Error }) }
        }
        defer { callback.cancel() }
        let redirect = try await callback.start()
        let discovery = try await MCPOAuthNetwork.discover(resource: server.url, load: load)
        try Task.checkCancellation()
        let clientID: String
        if !server.oauthClientID.isEmpty {
            guard MCPOAuthProtocol.safeValue(server.oauthClientID, limit: 4096) else { throw MCPOAuthError.invalidClient }
            clientID = server.oauthClientID
        } else {
            clientID = try await MCPOAuthNetwork.register(metadata: discovery.authorization, redirect: redirect.absoluteString, load: load)
        }
        var parameters = [
            "response_type": "code", "client_id": clientID, "redirect_uri": redirect.absoluteString,
            "resource": server.url, "state": state,
            "code_challenge": MCPOAuthProtocol.challenge(verifier), "code_challenge_method": "S256",
        ]
        if let scope = discovery.scope, !scope.isEmpty { parameters["scope"] = scope }
        let authorizationURL = try MCPOAuthProtocol.add(parameters: parameters, to: discovery.authorization.authorization_endpoint)
        let result = try await authenticate(url: authorizationURL, id: flow, presentation: presentation)
        let code = try MCPOAuthProtocol.callbackCode(result, redirect: redirect, state: state, expectedIssuer: discovery.authorization.issuer, requireIssuer: discovery.authorization.authorization_response_iss_parameter_supported == true)
        let token = try await MCPOAuthNetwork.token(endpoint: discovery.authorization.token_endpoint, parameters: [
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "redirect_uri": redirect.absoluteString, "code_verifier": verifier, "resource": server.url,
        ], resource: server.url, load: load)
        try Task.checkCancellation()
        guard generations[server.url, default: 0] == generation else { throw MCPOAuthError.cancelled }
        let credential = MCPOAuthCredential(resource: server.url, configuredClientID: server.oauthClientID,
            issuer: discovery.authorization.issuer, tokenEndpoint: discovery.authorization.token_endpoint,
            clientID: clientID, accessToken: token.access_token, refreshToken: token.refresh_token,
            expiresAt: token.expiry, scope: token.scope ?? discovery.scope)
        try store.save(credential)
    }

    func authorizationHeader(for server: MCPServerConfiguration) async throws -> String {
        guard server.isRemote else { throw MCPOAuthError.invalidResource }
        guard activeResource != server.url else { throw MCPOAuthError.missing }
        _ = try MCPOAuthProtocol.httpsURL(server.url)
        let store = store
        var credential = try await Task.detached(priority: .userInitiated) {
            try store.load(resource: server.url)
        }.value
        try Task.checkCancellation()
        guard credential.resource == server.url, credential.configuredClientID == server.oauthClientID else { throw MCPOAuthError.missing }
        if let expiry = credential.expiresAt, expiry <= Date().addingTimeInterval(60) {
            if let pending = refreshes[server.url] {
                credential = try await pending.value
            } else {
                guard let refresh = credential.refreshToken else { throw MCPOAuthError.expired }
                let previous = credential
                let generation = generations[server.url, default: 0]
                let load = load
                let task = Task { @MainActor in
                    let token = try await MCPOAuthNetwork.token(endpoint: previous.tokenEndpoint, parameters: [
                        "grant_type": "refresh_token", "client_id": previous.clientID,
                        "refresh_token": refresh, "resource": previous.resource,
                    ], resource: previous.resource, load: load)
                    try Task.checkCancellation()
                    guard self.generations[server.url, default: 0] == generation else { throw MCPOAuthError.cancelled }
                    var updated = previous
                    updated.accessToken = token.access_token
                    updated.refreshToken = token.refresh_token ?? previous.refreshToken
                    updated.expiresAt = token.expiry
                    updated.scope = token.scope ?? previous.scope
                    try self.store.save(updated)
                    return updated
                }
                refreshes[server.url] = task
                defer { if generations[server.url, default: 0] == generation { refreshes[server.url] = nil } }
                credential = try await task.value
            }
        }
        try Task.checkCancellation()
        guard MCPOAuthProtocol.safeValue(credential.accessToken, limit: 8_185), !credential.accessToken.contains(" ") else { throw MCPOAuthError.invalidToken }
        return "Bearer " + credential.accessToken
    }

    // The injected opener/timeout let tests exercise completion, cancellation
    // and stale callbacks without opening a browser or touching credentials.
    func authenticate(url: URL, id: UUID, presentation: MCPOAuthPresentation,
                      timeout: Duration = .seconds(300),
                      openURL: (@MainActor (URL) -> Bool)? = nil) async throws -> URL {
        try Task.checkCancellation()
        _ = try MCPOAuthProtocol.httpsURL(url.absoluteString)
        guard browserID == nil else { throw MCPOAuthError.unavailable }
        if presentation == .authenticationSession {
            guard let window = presenter?.presentationAnchor() else { throw MCPOAuthError.unavailable }
            anchor = window
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                browserID = id
                browserContinuation = continuation
                browserTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finishBrowser(id, result: .failure(MCPOAuthError.timedOut))
                }
                if Task.isCancelled {
                    finishBrowser(id, result: .failure(MCPOAuthError.cancelled))
                    return
                }
                if presentation == .defaultBrowser {
                    // Only the discovered authorization URL is opened. It has
                    // a PKCE challenge, never the verifier or access token.
                    // Every retry enters authorize() and creates a fresh flow.
                    let opened = openURL?(url) ?? presenter?.openInBrowser(url) ?? false
                    if !opened { finishBrowser(id, result: .failure(MCPOAuthError.unavailable)) }
                    return
                }
                // Both presentations finish through the same validated native
                // loopback callback; no browser cookies are read by OmniFlow.
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil,
                    completionHandler: authenticationSessionCompletion(for: id))
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                browser = session
                if !session.start() { finishBrowser(id, result: .failure(MCPOAuthError.unavailable)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishBrowser(id, result: .failure(MCPOAuthError.cancelled)) }
        }
    }

    // AuthenticationServices can invoke its Objective-C completion on Safari's
    // XPC queue. Creating that unannotated closure inside authenticate would
    // inherit MainActor isolation and trap before its Task could hop actors.
    nonisolated func authenticationSessionCompletion(for id: UUID) -> @Sendable (URL?, Error?) -> Void {
        { [weak self] _, error in
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.finishBrowser(id, result: .failure(failed ? MCPOAuthError.cancelled : MCPOAuthError.invalidCallback))
            }
        }
    }

    func finishBrowser(_ id: UUID, result: Result<URL, Error>) {
        guard browserID == id else { return }
        browserID = nil
        browserTimeout?.cancel()
        browserTimeout = nil
        let continuation = browserContinuation
        browserContinuation = nil
        let session = browser
        browser = nil
        anchor = nil
        session?.cancel()
        continuation?.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? presenter?.presentationAnchor() ?? ASPresentationAnchor()
    }
}

enum MCPOAuthError: LocalizedError, Sendable {
    case unavailable, cancelled, timedOut, missing, expired, keychain, invalidResource, discovery, unsupportedPKCE
    case registration, invalidClient, invalidCallback, invalidToken, network, responseLimit, denied, redirect
    #if os(macOS)
    private static let keychainName = "macOS Keychain"
    #else
    private static let keychainName = "Keychain"
    #endif
    var errorDescription: String? {
        switch self {
        case .unavailable: "Sign-in could not open. Try again from OmniFlow Settings."
        case .cancelled: "Sign-in was cancelled."
        case .timedOut: "Sign-in timed out after five minutes. Close the old sign-in page and start a fresh attempt in OmniFlow Settings."
        case .missing: "Sign in to this MCP server in OmniFlow Settings."
        case .expired: "This MCP sign-in expired. Sign in again in OmniFlow Settings."
        case .keychain: "OmniFlow could not access its saved MCP sign-in in the \(Self.keychainName)."
        case .invalidResource: "OAuth requires a valid HTTPS MCP endpoint without embedded credentials."
        case .discovery: "This server did not provide valid OAuth discovery metadata for its MCP endpoint."
        case .unsupportedPKCE: "This authorization server does not advertise PKCE S256 support for native sign-in."
        case .registration: "Automatic client registration is unavailable. Enter a registered public OAuth client ID that permits native loopback callbacks."
        case .invalidClient: "The server rejected this public OAuth client. Check its registration and loopback redirect settings."
        case .invalidCallback: "The sign-in callback did not match this authorization request. Try signing in again."
        case .invalidToken: "The authorization server returned an invalid or mismatched token."
        case .network: "The OAuth server could not be reached or rejected the request. Try again."
        case .responseLimit: "The OAuth server response exceeded OmniFlow's size limit."
        case .denied: "The authorization server did not grant access."
        case .redirect: "The OAuth server redirected a metadata or token request. Configure its final HTTPS endpoint."
        }
    }
}

struct MCPOAuthCredential: Codable, Sendable {
    var resource: String
    var configuredClientID: String
    var issuer: String
    var tokenEndpoint: String
    var clientID: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scope: String?
}

/// Pure protocol helpers are intentionally accessible to the integration tests.
enum MCPOAuthProtocol {
    static func safeValue(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
    }
    static func httpsURL(_ value: String) throws -> URL {
        guard safeValue(value, limit: 4096), !value.contains(" "),
              let parsed = URLComponents(string: value), parsed.scheme?.lowercased() == "https",
              let host = parsed.host, !host.isEmpty, parsed.user == nil, parsed.password == nil,
              parsed.fragment == nil, parsed.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parsed.url else { throw MCPOAuthError.invalidResource }
        return url
    }
    static func randomURLToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPOAuthError.unavailable }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func form(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(parameters.sorted(by: { $0.key < $1.key }).map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
    static func add(parameters: [String: String], to endpoint: String) throws -> URL {
        let url = try httpsURL(endpoint)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw MCPOAuthError.discovery }
        let items = components.queryItems ?? []
        guard !items.contains(where: { parameters[$0.name] != nil }) else { throw MCPOAuthError.discovery }
        let encoded = String(decoding: form(parameters), as: UTF8.self)
        components.percentEncodedQuery = [components.percentEncodedQuery, encoded]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
        guard let result = components.url else { throw MCPOAuthError.discovery }
        return result
    }
    static func challengeValue(_ name: String, header: String?) -> String? {
        guard let header, header.utf8.count <= 8192,
              let regex = try? NSRegularExpression(pattern: "(?:^|[,\\s])" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(?:\"([^\"]*)\"|([^,\\s]+))", options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        let index = match.range(at: 1).location == NSNotFound ? 2 : 1
        guard let range = Range(match.range(at: index), in: header) else { return nil }
        return String(header[range])
    }
    static func wellKnown(_ base: URL, name: String, includePath: Bool) throws -> URL {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw MCPOAuthError.discovery }
        parts.path = "/.well-known/" + name + (includePath && parts.path != "/" ? parts.path : "")
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { throw MCPOAuthError.discovery }
        return url
    }
    static func callbackCode(_ url: URL, redirect: URL, state: String, expectedIssuer: String? = nil, requireIssuer: Bool = false) throws -> String {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              value.scheme == expected.scheme, value.host == expected.host, value.port == expected.port,
              value.path == expected.path, value.user == nil, value.password == nil, value.fragment == nil else { throw MCPOAuthError.invalidCallback }
        let items = value.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { throw MCPOAuthError.invalidCallback }
        let issuers = items.filter { $0.name == "iss" }
        guard issuers.count <= 1, !requireIssuer || issuers.count == 1 else { throw MCPOAuthError.invalidCallback }
        if let expectedIssuer, let issuer = issuers.first, issuer.value != expectedIssuer { throw MCPOAuthError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw MCPOAuthError.denied }
        guard items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value,
              safeValue(code, limit: 8192) else { throw MCPOAuthError.invalidCallback }
        return code
    }
}

struct MCPOAuthResourceMetadata: Decodable, Sendable {
    let resource: String
    let authorization_servers: [String]
    let scopes_supported: [String]?
}
struct MCPOAuthServerMetadata: Decodable, Sendable {
    let issuer: String
    let authorization_endpoint: String
    let token_endpoint: String
    let registration_endpoint: String?
    let code_challenge_methods_supported: [String]?
    let token_endpoint_auth_methods_supported: [String]?
    let authorization_response_iss_parameter_supported: Bool?
}
struct MCPOAuthToken: Decodable, Sendable {
    let access_token: String
    let token_type: String
    let refresh_token: String?
    let expires_in: Double?
    let scope: String?
    let resource: String?
    var expiry: Date? { expires_in.map { Date().addingTimeInterval($0) } }
}
struct MCPOAuthDiscovery: Sendable {
    let authorization: MCPOAuthServerMetadata
    let scope: String?
}

private final class MCPOAuthNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum MCPOAuthNetwork {
    typealias Loader = @Sendable (URL, String, Data?, Bool) async throws -> Reply
    static func live(_ url: URL, _ method: String, _ data: Data?, _ form: Bool) async throws -> Reply {
        try await request(url, method: method, data: data, form: form)
    }
    struct Reply: Sendable { let status: Int; let data: Data; let challenge: String? }
    static func request(_ url: URL, method: String = "GET", data: Data? = nil, form: Bool = false, configuration suppliedConfiguration: URLSessionConfiguration? = nil) async throws -> Reply {
        _ = try MCPOAuthProtocol.httpsURL(url.absoluteString)
        try Task.checkCancellation()
        let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: MCPOAuthNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        request.setValue("NotchLee/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if data != nil { request.setValue(form ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw MCPOAuthError.network }
            guard !(300...399).contains(response.statusCode) else { throw MCPOAuthError.redirect }
            guard response.expectedContentLength <= 128_000 else { throw MCPOAuthError.responseLimit }
            var body = Data()
            for try await byte in bytes {
                guard body.count < 128_000 else { throw MCPOAuthError.responseLimit }
                body.append(byte)
            }
            try Task.checkCancellation()
            let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate").flatMap { $0.utf8.count <= 8192 ? $0 : nil }
            return Reply(status: response.statusCode, data: body, challenge: challenge)
        } catch let error as MCPOAuthError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw MCPOAuthError.network }
    }

    static func discover(resource: String, load: Loader = live) async throws -> MCPOAuthDiscovery {
        let endpoint = try MCPOAuthProtocol.httpsURL(resource)
        // The challenge is authoritative; its body (and all Set-Cookie values)
        // are discarded. This makes no authenticated tool call.
        let probe = try? await load(endpoint, "GET", nil, false)
        var candidates: [URL] = []
        if let advertised = MCPOAuthProtocol.challengeValue("resource_metadata", header: probe?.challenge) {
            candidates.append(try MCPOAuthProtocol.httpsURL(advertised))
        }
        candidates += [try MCPOAuthProtocol.wellKnown(endpoint, name: "oauth-protected-resource", includePath: true),
                       try MCPOAuthProtocol.wellKnown(endpoint, name: "oauth-protected-resource", includePath: false)]
        var metadata: MCPOAuthResourceMetadata?
        for candidate in candidates {
            try Task.checkCancellation()
            guard let reply = try? await load(candidate, "GET", nil, false), reply.status == 200,
                  let decoded = try? JSONDecoder().decode(MCPOAuthResourceMetadata.self, from: reply.data),
                  decoded.resource == resource, !decoded.authorization_servers.isEmpty, decoded.authorization_servers.count <= 8 else { continue }
            metadata = decoded; break
        }
        guard let metadata else { throw MCPOAuthError.discovery }
        let scope = MCPOAuthProtocol.challengeValue("scope", header: probe?.challenge) ?? metadata.scopes_supported?.joined(separator: " ")
        if let scope, !scope.isEmpty && !MCPOAuthProtocol.safeValue(scope, limit: 4096) { throw MCPOAuthError.discovery }
        for issuerString in metadata.authorization_servers {
            guard let issuer = try? MCPOAuthProtocol.httpsURL(issuerString), issuer.query == nil else { continue }
            var urls = [try MCPOAuthProtocol.wellKnown(issuer, name: "oauth-authorization-server", includePath: true),
                        try MCPOAuthProtocol.wellKnown(issuer, name: "openid-configuration", includePath: true)]
            if !issuer.path.isEmpty && issuer.path != "/" { urls.append(issuer.appendingPathComponent(".well-known/openid-configuration")) }
            // Some gateways publish their advertised issuer metadata on the MCP
            // resource origin. Equality with that advertised issuer is mandatory.
            urls.append(try MCPOAuthProtocol.wellKnown(endpoint, name: "oauth-authorization-server", includePath: false))
            for url in urls {
                try Task.checkCancellation()
                guard let reply = try? await load(url, "GET", nil, false), reply.status == 200,
                      let value = try? JSONDecoder().decode(MCPOAuthServerMetadata.self, from: reply.data), value.issuer == issuerString else { continue }
                _ = try MCPOAuthProtocol.httpsURL(value.authorization_endpoint)
                _ = try MCPOAuthProtocol.httpsURL(value.token_endpoint)
                guard value.code_challenge_methods_supported?.contains("S256") == true else { throw MCPOAuthError.unsupportedPKCE }
                if let methods = value.token_endpoint_auth_methods_supported, !methods.contains("none") { throw MCPOAuthError.invalidClient }
                return MCPOAuthDiscovery(authorization: value, scope: scope)
            }
        }
        throw MCPOAuthError.discovery
    }

    static func register(metadata: MCPOAuthServerMetadata, redirect: String, load: Loader = live) async throws -> String {
        guard let registration = metadata.registration_endpoint else { throw MCPOAuthError.registration }
        let endpoint = try MCPOAuthProtocol.httpsURL(registration)
        let data = try JSONSerialization.data(withJSONObject: [
            "client_name": "OmniFlow", "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"], "token_endpoint_auth_method": "none", "application_type": "native",
        ])
        let reply = try await load(endpoint, "POST", data, false)
        struct Registration: Decodable { let client_id: String; let token_endpoint_auth_method: String?; let redirect_uris: [String]?; let client_secret: String? }
        guard (200...201).contains(reply.status), let value = try? JSONDecoder().decode(Registration.self, from: reply.data),
              MCPOAuthProtocol.safeValue(value.client_id, limit: 4096), value.client_secret == nil,
              value.token_endpoint_auth_method == nil || value.token_endpoint_auth_method == "none",
              value.redirect_uris == nil || value.redirect_uris?.contains(redirect) == true else { throw MCPOAuthError.registration }
        return value.client_id
    }

    static func token(endpoint: String, parameters: [String: String], resource: String, load: Loader = live) async throws -> MCPOAuthToken {
        _ = try MCPOAuthProtocol.httpsURL(resource)
        guard parameters["resource"] == resource else { throw MCPOAuthError.invalidResource }
        let reply = try await load(MCPOAuthProtocol.httpsURL(endpoint), "POST", MCPOAuthProtocol.form(parameters), true)
        if reply.status != 200 {
            struct OAuthFailure: Decodable { let error: String }
            if let failure = try? JSONDecoder().decode(OAuthFailure.self, from: reply.data), failure.error == "invalid_grant" { throw MCPOAuthError.expired }
            throw MCPOAuthError.invalidClient
        }
        guard let value = try? JSONDecoder().decode(MCPOAuthToken.self, from: reply.data),
              value.token_type.lowercased() == "bearer", MCPOAuthProtocol.safeValue(value.access_token, limit: 8_185), !value.access_token.contains(" "),
              value.refresh_token.map({ MCPOAuthProtocol.safeValue($0, limit: 16_384) }) ?? true,
              value.expires_in.map({ $0.isFinite && $0 >= 0 && $0 <= 315_360_000 }) ?? true,
              value.resource == nil || value.resource == resource else { throw MCPOAuthError.invalidToken }
        return value
    }
}

/// Where OAuth credentials live. One credential per exact MCP resource URL.
protocol MCPOAuthTokenStore: Sendable {
    func load(resource: String) throws -> MCPOAuthCredential
    func save(_ credential: MCPOAuthCredential) throws
    func delete(resource: String) throws
}

/// The Keychain store. Item attributes are unchanged from the original Mac
/// implementation so existing sign-ins keep working: generic password, service
/// "NotchLee MCP OAuth", account = SHA-256 hex of the resource URL, not
/// synchronized, WhenUnlockedThisDeviceOnly, no access-control flags, and a
/// non-interactive authentication context.
struct MCPOAuthKeychain: MCPOAuthTokenStore {
    static let service = "NotchLee MCP OAuth"
    static func query(resource: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: SHA256.hash(data: Data(resource.utf8)).map { String(format: "%02x", $0) }.joined(),
                kSecUseAuthenticationContext as String: context, kSecAttrSynchronizable as String: false]
    }
    func load(resource: String) throws -> MCPOAuthCredential {
        var query = Self.query(resource: resource)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw MCPOAuthError.missing }
        guard status == errSecSuccess else { throw MCPOAuthError.keychain }
        guard let data = result as? Data, data.count <= 64_000,
              let value = try? JSONDecoder().decode(MCPOAuthCredential.self, from: data), value.resource == resource else { throw MCPOAuthError.invalidToken }
        return value
    }
    func save(_ credential: MCPOAuthCredential) throws {
        let data = try JSONEncoder().encode(credential)
        guard data.count <= 64_000 else { throw MCPOAuthError.invalidToken }
        let query = Self.query(resource: credential.resource)
        let updates: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "NotchLee MCP sign-in"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MCPOAuthError.keychain }
        } else if status != errSecSuccess { throw MCPOAuthError.keychain }
    }
    func delete(resource: String) throws {
        let status = SecItemDelete(Self.query(resource: resource) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MCPOAuthError.keychain }
    }
}

/// The only cleartext OAuth traffic is the native callback on explicitly bound
/// IPv4 loopback. State, Host and path validation occur before completing sign-in.
final class MCPOAuthLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.notchlee.mcp-oauth-callback")
    private let state: String
    private let completion: @Sendable (Result<URL, MCPOAuthError>) -> Void
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var redirect: URL?
    private var ready: CheckedContinuation<URL, Error>?
    private var cancelled = false
    init(state: String, completion: @escaping @Sendable (Result<URL, MCPOAuthError>) -> Void) { self.state = state; self.completion = completion }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if self.cancelled { continuation.resume(throwing: MCPOAuthError.cancelled); return }
                    self.ready = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { status in
                            switch status {
                            case .ready:
                                guard let port = listener.port, let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") else { self.fail(); return }
                                self.redirect = redirect
                                let continuation = self.ready; self.ready = nil; continuation?.resume(returning: redirect)
                            case .failed: self.fail()
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { connection in
                            guard !self.cancelled, self.connections.count < 8 else { connection.cancel(); return }
                            self.connections.append(connection)
                            connection.stateUpdateHandler = { [weak connection] status in
                                switch status {
                                case .cancelled, .failed:
                                    self.connections.removeAll { $0 === connection }
                                default: break
                                }
                            }
                            connection.start(queue: self.queue)
                            self.receive(connection, buffer: Data())
                            self.queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
                        }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 5) { if self.ready != nil { self.fail() } }
                    } catch { self.fail() }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        queue.async {
            self.cancelled = true
            self.listener?.cancel(); self.listener = nil
            self.connections.forEach { $0.cancel() }; self.connections = []
            let continuation = self.ready; self.ready = nil; continuation?.resume(throwing: MCPOAuthError.cancelled)
        }
    }
    private func fail() {
        let continuation = ready; ready = nil
        continuation?.resume(throwing: MCPOAuthError.unavailable)
        listener?.cancel(); listener = nil
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, 8192 - buffer.count)) { data, _, complete, error in
            var combined = buffer
            if let data { combined.append(data) }
            guard error == nil, combined.count <= 8192 else { connection.cancel(); return }
            guard combined.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || combined.count == 8192 { connection.cancel() } else { self.receive(connection, buffer: combined) }
                return
            }
            guard let text = String(data: combined, encoding: .utf8), let redirect = self.redirect,
                  let first = text.components(separatedBy: "\r\n").first else { connection.cancel(); return }
            let firstParts = first.split(separator: " ")
            let hosts = text.components(separatedBy: "\r\n").dropFirst().filter { $0.lowercased().hasPrefix("host:") }
            guard firstParts.count == 3, firstParts[0] == "GET", hosts.count == 1,
                  hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(redirect.port!)",
                  let url = URL(string: "http://127.0.0.1:\(redirect.port!)" + firstParts[1]) else { connection.cancel(); return }
            let result: Result<URL, MCPOAuthError>
            do { _ = try MCPOAuthProtocol.callbackCode(url, redirect: redirect, state: self.state); result = .success(url) }
            catch MCPOAuthError.denied { result = .failure(.denied) }
            catch { self.respond(connection, success: false); return }
            self.respond(connection, success: true)
            self.completion(result)
        }
    }
    private func respond(_ connection: NWConnection, success: Bool) {
        let body = success ? "Sign-in response received. You can return to OmniFlow." : "Invalid sign-in callback. Return to OmniFlow and try again."
        let response = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
