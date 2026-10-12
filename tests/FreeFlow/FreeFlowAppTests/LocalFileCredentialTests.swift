import Foundation
import Testing
@testable import OmniFlowApp

@Test(arguments: ["/Users/test/.ssh/id_ed25519", "/tmp/.ssh/copied-key", "/tmp/project/.env.production",
    "/Users/test/Library/Keychains/login.keychain-db", "/Users/test/.config/gcloud/application_default_credentials.json",
    "/Users/test/.codex/auth.json", "/Users/test/.docker/config.json", "/tmp/certificate.p12", "/tmp/private.pem", "/tmp/project/.envrc"])
func assistantRejectsKnownCredentialPaths(_ path: String) {
    #expect(LocalFiles.isCredentialPath(URL(fileURLWithPath: path)))
    #expect(throws: (any Error).self) { try LocalFiles.localURL(path) }
}

@Test func assistantRejectsCredentialSymlinksAndHidesThemFromListings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let credential = root.appendingPathComponent(".env")
    try "FAKE_SENTINEL_NOT_A_SECRET".write(to: credential, atomically: true, encoding: .utf8)
    let alias = root.appendingPathComponent("innocent.txt")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: credential)
    #expect(throws: (any Error).self) { try LocalFiles.localURL(alias.path) }
    let denied = LocalFiles.inspect(.init(operation: .read, path: alias.path, query: nil, offset: nil))
    #expect(denied.contains("Credential files"))
    #expect(!denied.contains("FAKE_SENTINEL"))
    let listing = LocalFiles.inspect(.init(operation: .list, path: root.path, query: nil, offset: nil))
    #expect(!listing.contains("innocent.txt"))
    #expect(!listing.contains(".env"))
    let normal = root.appendingPathComponent("meeting.txt")
    try "Deadline: Friday".write(to: normal, atomically: true, encoding: .utf8)
    let allowed = LocalFiles.inspect(.init(operation: .read, path: normal.path, query: nil, offset: nil))
    #expect(allowed.contains("Deadline: Friday"))
}
