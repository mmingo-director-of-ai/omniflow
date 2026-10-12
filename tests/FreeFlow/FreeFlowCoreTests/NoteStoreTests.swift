import Foundation
import Testing
@testable import OmniFlowApp

@Test func dictatedNotesGrowByParagraph() {
    var note = DictationNote()
    #expect(note.title == note.created.formatted(date: .abbreviated, time: .shortened))
    note.append("  Ship the dashboard today.  ")
    note.append("")
    note.append("Then the notes tab.")
    #expect(note.body == "Ship the dashboard today.\n\nThen the notes tab.")
    #expect(note.title == "Ship the dashboard today.")
    #expect(note.preview == "Then the notes tab.")
    #expect(note.wordCount == 8)
}

@Test func notesRoundTripSealedOnDisk() async throws {
    // The shared test key; without it a parallel vault test can swap keys mid-test.
    _ = VaultTestKey.installed
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = NoteStore(directory: folder)
    var older = DictationNote(updated: .now.addingTimeInterval(-60)); older.body = "Older"
    let newer = DictationNote(body: "Newer")
    try await store.save(older)
    try await store.save(newer)
    let loaded = try await store.load()
    #expect(loaded.notes.map(\.body) == ["Newer", "Older"] && loaded.unreadableCount == 0)
    let raw = try Data(contentsOf: folder.appendingPathComponent(newer.id.uuidString + ".json"))
    #expect(OmniFlowVault.isSealed(raw), "Notes must be encrypted at rest")
    try await store.delete(older.id)
    #expect(try await store.load().notes.map(\.id) == [newer.id])
}

@Test func unreadableNotesAreCountedNotHidden() async throws {
    _ = VaultTestKey.installed
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = NoteStore(directory: folder)
    try await store.save(DictationNote(body: "Fine"))
    // A sealed file that no longer opens (wrong key, damaged bytes).
    try (OmniFlowVault.magic + Data(repeating: 7, count: 40))
        .write(to: folder.appendingPathComponent(UUID().uuidString + ".json"))
    let loaded = try await store.load()
    #expect(loaded.notes.map(\.body) == ["Fine"])
    #expect(loaded.unreadableCount == 1)
}
