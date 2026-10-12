import CryptoKit
import Foundation
import Testing
@testable import OmniFlowApp

/// Tests never touch the login Keychain: one in-memory key for the whole run.
enum VaultTestKey {
    static let installed: Void = { OmniFlowVault.keyProvider = OmniFlowEphemeralKeyProvider(key: SymmetricKey(size: .bits256)) }()
}

@Test func historyIsEncryptedOnDiskAndLegacyFilesMigrate() async throws {
    _ = VaultTestKey.installed
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = HistoryStore(directory: folder)
    let secret = DictationEntry(raw: "my private thought", text: "My private thought.", note: "", destination: "Notes")
    try await store.save(secret)
    let onDisk = try Data(contentsOf: folder.appendingPathComponent(secret.id.uuidString + ".json"))
    #expect(OmniFlowVault.isSealed(onDisk))
    #expect(String(decoding: onDisk, as: UTF8.self).contains("private") == false, "Transcript text was written in the clear")

    // A file from before encryption is still read, then rewritten sealed.
    let legacy = DictationEntry(raw: "old words", text: "Old words.", note: "", destination: "Mail")
    let legacyURL = folder.appendingPathComponent(legacy.id.uuidString + ".json")
    try JSONEncoder().encode(legacy).write(to: legacyURL)
    let loaded = try await HistoryStore(directory: folder).load()
    #expect(Set(loaded.entries.map(\.id)) == [secret.id, legacy.id] && loaded.unreadableCount == 0)
    #expect(OmniFlowVault.isSealed(try Data(contentsOf: legacyURL)), "Legacy plaintext was not migrated")
}

@Test func tamperedOrKeylessDataIsNeverReadOrOverwritten() throws {
    _ = VaultTestKey.installed
    let sealed = try OmniFlowVault.seal(Data("hello".utf8))
    var tampered = sealed; tampered[tampered.count - 1] ^= 0xFF
    #expect(throws: OmniFlowVault.VaultError.self) { try OmniFlowVault.open(tampered) }

    let keyless = OmniFlowEphemeralKeyProvider()   // e.g. a Keychain reset
    #expect(throws: OmniFlowVault.VaultError.self) { try OmniFlowVault.open(sealed, keys: keyless) }
    // Reading must not have created a key that would orphan the data.
    #expect(throws: OmniFlowVault.VaultError.self) { try keyless.key(createIfMissing: false) }
    // A different key can't read it either.
    let other = OmniFlowEphemeralKeyProvider(key: SymmetricKey(size: .bits256))
    #expect(throws: OmniFlowVault.VaultError.self) { try OmniFlowVault.open(sealed, keys: other) }
}

@Test func unreadableJournalIsSetAsideNotOverwritten() async throws {
    _ = VaultTestKey.installed
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Sealed with a key this run doesn't have, as after a Keychain reset.
    let foreign = OmniFlowEphemeralKeyProvider(key: SymmetricKey(size: .bits256))
    let original = try OmniFlowVault.seal(Data(#"{"question":"q","answer":"a"}"#.utf8), keys: foreign)
    try original.write(to: root.appendingPathComponent("conversations.jsonl"))
    let journal = JournalFile(root: root)
    #expect(await journal.load().isEmpty)
    try await journal.save([ConversationRecord(question: "new", answer: "new")])
    let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("conversations.unreadable-") }
    #expect(kept.count == 1)
    #expect(try Data(contentsOf: root.appendingPathComponent(kept[0])) == original, "Unreadable conversations were lost")
}

@Test func testBinariesCannotWriteTheRealDataFolder() throws {
    #expect(!OmniFlowVault.isAppProcess)
    let real = NotchLeeStorage.root.appendingPathComponent("vault-guard-\(UUID().uuidString).json")
    #expect(throws: OmniFlowVault.VaultError.self) { try OmniFlowVault.write(Data("x".utf8), to: real) }
    #expect(!FileManager.default.fileExists(atPath: real.path))
}
