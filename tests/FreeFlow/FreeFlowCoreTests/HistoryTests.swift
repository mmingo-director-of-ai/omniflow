import Foundation
import Testing
@testable import OmniFlowApp

@Test func historySurvivesRelaunchAndRejectsStaleWrites() async throws {
    _ = VaultTestKey.installed
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = HistoryStore(directory: folder)
    var entry = DictationEntry(raw: "hello", text: "", note: "Listening", destination: "Notes", state: .recording)
    try await store.save(entry)
    entry.raw = "hello world"; entry.text = "Hello world."; entry.state = .ready; entry.revision = 2
    try await store.save(entry)
    var stale = entry; stale.raw = "hello"; stale.revision = 1
    try await store.save(stale)
    let reopened = HistoryStore(directory: folder)
    let loaded = try await reopened.load()
    #expect(loaded.entries.count == 1)
    #expect(loaded.entries.first?.raw == "hello world")
    #expect(loaded.entries.first?.text == "Hello world.")
    #expect(loaded.entries.first?.state == .ready)
    let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(entry.id.uuidString + ".json").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func corruptRecordDoesNotHideRecoverableDraft() async throws {
    _ = VaultTestKey.installed
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = HistoryStore(directory: folder)
    let draft = DictationEntry(raw: "Unfinished thought", text: "", note: "Listening", destination: "Notes", state: .recording)
    try await store.save(draft)
    try Data("invalid JSON".utf8).write(to: folder.appendingPathComponent("broken.json"))
    let loaded = try await HistoryStore(directory: folder).load()
    #expect(loaded.entries.count == 1)
    #expect(loaded.entries.first?.raw == "Unfinished thought")
    #expect(loaded.entries.first?.state == .recording)
    #expect(loaded.unreadableCount == 1)
}
