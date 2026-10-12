// MCP OAuth in Core: PKCE, metadata discovery, dynamic registration, the
// loopback callback, refresh, and Keychain compatibility with items written
// by the original Mac implementation.
import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Synchronization
import Testing
@testable import OmniFlowApp

@MainActor
struct MCPOAuthCoreTests {
    nonisolated static let resource = "https://mcp.fixture.test/mcp"
    nonisolated static let issuer = "https://auth.fixture.test"

    nonisolated final class MemoryStore: MCPOAuthTokenStore {
        let items = Mutex<[String: MCPOAuthCredential]>([:])
        func load(resource: String) throws -> MCPOAuthCredential {
            guard let value = items.withLock({ $0[resource] }) else { throw MCPOAuthError.missing }
            return value
        }
        func save(_ credential: MCPOAuthCredential) throws { items.withLock { $0[credential.resource] = credential } }
        func delete(resource: String) throws { _ = items.withLock { $0.removeValue(forKey: resource) } }
    }

    /// A generic MCP authorization server: protected-resource metadata,
    /// authorization-server metadata, registration and token endpoints.
    nonisolated final class FakeServer: Sendable {
        let log = Mutex<[String]>([])
        let registered = Mutex<Data>(Data())
        let lastChallenge = Mutex<String?>(nil)
        let tokenCalls = Mutex(0)

        func reply(_ json: Any, status: Int = 200) -> MCPOAuthNetwork.Reply {
            MCPOAuthNetwork.Reply(status: status, data: try! JSONSerialization.data(withJSONObject: json), challenge: nil)
        }

        var loader: MCPOAuthNetwork.Loader {
            { [self] url, method, data, _ in
                log.withLock { $0.append(method + " " + url.absoluteString) }
                switch (method, url.absoluteString) {
                case ("GET", MCPOAuthCoreTests.resource):
                    return MCPOAuthNetwork.Reply(status: 401, data: Data(), challenge: #"Bearer resource_metadata="https://mcp.fixture.test/.well-known/oauth-protected-resource/mcp", scope="read""#)
                case ("GET", "https://mcp.fixture.test/.well-known/oauth-protected-resource/mcp"):
                    return reply(["resource": MCPOAuthCoreTests.resource, "authorization_servers": [MCPOAuthCoreTests.issuer]])
                case ("GET", "https://auth.fixture.test/.well-known/oauth-authorization-server"):
                    return reply(["issuer": MCPOAuthCoreTests.issuer, "authorization_endpoint": "https://auth.fixture.test/authorize",
                                  "token_endpoint": "https://auth.fixture.test/token", "registration_endpoint": "https://auth.fixture.test/register",
                                  "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"]])
                case ("POST", "https://auth.fixture.test/register"):
                    let raw = data ?? Data()
                    registered.withLock { $0 = raw }
                    let body = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
                    return reply(["client_id": "registered-client", "token_endpoint_auth_method": "none", "redirect_uris": body["redirect_uris"] ?? []], status: 201)
                case ("POST", "https://auth.fixture.test/token"):
                    tokenCalls.withLock { $0 += 1 }
                    let form = Dictionary(uniqueKeysWithValues: String(decoding: data ?? Data(), as: UTF8.self).split(separator: "&").map { pair -> (String, String) in
                        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                        return (parts[0], parts.count > 1 ? parts[1] : "")
                    })
                    if form["grant_type"] == "authorization_code" {
                        // PKCE: the verifier must hash to the challenge sent to /authorize.
                        guard form["code"] == "fixture-code", form["resource"] == MCPOAuthCoreTests.resource,
                              let verifier = form["code_verifier"], MCPOAuthProtocol.challenge(verifier) == lastChallenge.withLock({ $0 }) else {
                            return reply(["error": "invalid_grant"], status: 400)
                        }
                        return reply(["access_token": "access-1", "token_type": "Bearer", "refresh_token": "refresh-1", "expires_in": 3600])
                    }
                    guard form["grant_type"] == "refresh_token", form["refresh_token"] == "refresh-1", form["client_id"] == "registered-client" else {
                        return reply(["error": "invalid_grant"], status: 400)
                    }
                    return reply(["access_token": "access-2", "token_type": "Bearer", "refresh_token": "refresh-2", "expires_in": 3600])
                default:
                    return MCPOAuthNetwork.Reply(status: 404, data: Data(), challenge: nil)
                }
            }
        }
    }

    /// Plays the browser: follows the authorization URL to the loopback redirect.
    final class FakeBrowser: MCPOAuthPresenter {
        let server: FakeServer
        var opened: URL?
        init(server: FakeServer) { self.server = server }
        func presentationAnchor() -> ASPresentationAnchor? { nil }
        func openInBrowser(_ url: URL) -> Bool {
            opened = url
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            server.lastChallenge.withLock { $0 = value("code_challenge") }
            guard let redirect = value("redirect_uri"), let state = value("state"),
                  let callback = URL(string: redirect + "?code=fixture-code&state=\(state)") else { return false }
            Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: callback) }
            return true
        }
    }

    var server: MCPServerConfiguration {
        var server = MCPServerConfiguration()
        server.name = "Fixture"; server.transport = "http"; server.url = Self.resource; server.enabled = true; server.useOAuth = true
        return server
    }

    @Test func pkceMatchesRFC7636() {
        #expect(MCPOAuthProtocol.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func signInDiscoversRegistersAndExchangesWithPKCE() async throws {
        let fake = FakeServer()
        let store = MemoryStore()
        let oauth = MCPOAuth(store: store, load: fake.loader)
        let browser = FakeBrowser(server: fake)
        oauth.presenter = browser
        try await oauth.authorize(server: server, presentation: .defaultBrowser)
        let credential = try store.load(resource: Self.resource)
        #expect(credential.accessToken == "access-1" && credential.refreshToken == "refresh-1" && credential.clientID == "registered-client"
                && credential.issuer == Self.issuer && credential.tokenEndpoint == "https://auth.fixture.test/token" && credential.scope == "read")
        let registration = (try? JSONSerialization.jsonObject(with: fake.registered.withLock { $0 }) as? [String: Any]) ?? [:]
        #expect(registration["client_name"] as? String == "OmniFlow" && registration["token_endpoint_auth_method"] as? String == "none"
                && registration["application_type"] as? String == "native")
        let redirect = (registration["redirect_uris"] as? [String])?.first ?? ""
        #expect(redirect.hasPrefix("http://127.0.0.1:") && redirect.hasSuffix("/oauth/callback"))
        let opened = try #require(browser.opened)
        let query = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains { $0.name == "code_challenge_method" && $0.value == "S256" }
                && query.contains { $0.name == "resource" && $0.value == Self.resource }
                && !query.contains { $0.name == "code_verifier" })
        #expect(try await oauth.authorizationHeader(for: server) == "Bearer access-1")
        // The iOS path has no default browser: without an anchor, the
        // authentication-session presentation reports unavailable.
        await #expect(throws: MCPOAuthError.self) { try await oauth.authorize(server: server, presentation: .authenticationSession) }
    }

    @Test func expiredTokenRefreshesOnceAndRotates() async throws {
        let fake = FakeServer()
        let store = MemoryStore()
        try store.save(MCPOAuthCredential(resource: Self.resource, configuredClientID: "", issuer: Self.issuer,
            tokenEndpoint: "https://auth.fixture.test/token", clientID: "registered-client", accessToken: "access-1",
            refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(30), scope: "read"))
        let oauth = MCPOAuth(store: store, load: fake.loader)
        async let first = oauth.authorizationHeader(for: server)
        async let second = oauth.authorizationHeader(for: server)
        let headers = try await [first, second]
        #expect(headers == ["Bearer access-2", "Bearer access-2"] && fake.tokenCalls.withLock { $0 } == 1)
        let saved = try store.load(resource: Self.resource)
        #expect(saved.refreshToken == "refresh-2" && (saved.expiresAt ?? .distantPast) > Date().addingTimeInterval(3000))
        // A rejected refresh asks the user to sign in again.
        try store.save(MCPOAuthCredential(resource: Self.resource, configuredClientID: "", issuer: Self.issuer,
            tokenEndpoint: "https://auth.fixture.test/token", clientID: "registered-client", accessToken: "stale",
            refreshToken: "revoked", expiresAt: Date(), scope: nil))
        await #expect(throws: MCPOAuthError.expired) { try await MCPOAuth(store: store, load: fake.loader).authorizationHeader(for: server) }
    }

    // MARK: Keychain compatibility

    /// The original Mac implementation's query and insert, verbatim.
    nonisolated enum OriginalMacKeychain {
        static func query(resource: String) -> [String: Any] {
            let context = LAContext()
            context.interactionNotAllowed = true
            return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "NotchLee MCP OAuth",
                    kSecAttrAccount as String: SHA256.hash(data: Data(resource.utf8)).map { String(format: "%02x", $0) }.joined(),
                    kSecUseAuthenticationContext as String: context, kSecAttrSynchronizable as String: false]
        }
        static func save(_ credential: MCPOAuthCredential) -> OSStatus {
            var item = query(resource: credential.resource)
            item[kSecValueData as String] = try! JSONEncoder().encode(credential)
            item[kSecAttrLabel as String] = "NotchLee MCP sign-in"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil)
        }
        static func load(resource: String) -> MCPOAuthCredential? {
            var query = query(resource: resource)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return try? JSONDecoder().decode(MCPOAuthCredential.self, from: data)
        }
        static func attributes(resource: String) -> [String: Any]? {
            var query = query(resource: resource)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnAttributes as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? [String: Any]
        }
    }

    @Test func keychainItemsAreCompatibleWithTheOriginalMacCode() throws {
        // A unique test-only resource: real sign-ins are never touched.
        let resource = "https://keychain-compat-\(UUID().uuidString.lowercased()).fixture.test/mcp"
        let store = MCPOAuthKeychain()
        defer { try? store.delete(resource: resource) }
        let original = MCPOAuthCredential(resource: resource, configuredClientID: "", issuer: Self.issuer, tokenEndpoint: "https://auth.fixture.test/token",
                                          clientID: "client", accessToken: "written-by-mac", refreshToken: "r", expiresAt: nil, scope: nil)
        #expect(OriginalMacKeychain.save(original) == errSecSuccess)
        #expect(try store.load(resource: resource).accessToken == "written-by-mac", "Core could not read a Mac-written sign-in")
        var updated = original
        updated.accessToken = "updated-by-core"
        try store.save(updated)
        #expect(OriginalMacKeychain.load(resource: resource)?.accessToken == "updated-by-core", "the Mac query could not read a Core update")
        // The item a Core save creates is indistinguishable from the Mac one
        // (the login keychain does not report accessibility; the insert sets
        // WhenUnlockedThisDeviceOnly with the same code as before).
        func comparable(_ attributes: [String: Any]) -> [String: String] {
            attributes.filter { !["cdat", "mdat"].contains($0.key) }.mapValues { String(describing: $0) }
        }
        let macCreated = comparable(try #require(OriginalMacKeychain.attributes(resource: resource)))
        #expect(macCreated[kSecAttrAccessControl as String] == nil, "no access-control flags")
        try store.delete(resource: resource)
        try store.save(original)
        let coreCreated = comparable(try #require(OriginalMacKeychain.attributes(resource: resource)))
        #expect(coreCreated == macCreated && coreCreated[kSecAttrLabel as String] == "NotchLee MCP sign-in"
                && coreCreated[kSecAttrService as String] == "NotchLee MCP OAuth")
        #expect(OriginalMacKeychain.load(resource: resource)?.accessToken == "written-by-mac")
    }
}
