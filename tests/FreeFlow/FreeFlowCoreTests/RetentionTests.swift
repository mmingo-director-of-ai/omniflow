import Foundation
import Testing
@testable import OmniFlowApp

@Test func retentionProtectsRecoveryAndRejectsLateWrites() async throws {
    _ = VaultTestKey.installed
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let trash = folder.appendingPathComponent("test-trash")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let store = HistoryStore(directory: folder, trashItem: { url in
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
    })
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let old = now.addingTimeInterval(-8 * 86400)
    var expired = DictationEntry(date: old, raw: "old", text: "old", note: "", destination: "Notes", state: .delivered)
    try await store.save(expired)
    let protectedStates: [DictationEntry.State] = [.recording, .processing, .ready, .needsCopy, .failed, .cancelled]
    for state in protectedStates {
        try await store.save(.init(date: old, raw: "recover", text: "", note: "", destination: "Notes", state: state))
    }
    let pasted = DictationEntry(date: old, raw: "pasted", text: "pasted", note: "", destination: "Warp", state: .pasteSent)
    try await store.save(pasted)
    let excluded = DictationEntry(date: old, raw: "retry", text: "retry", note: "", destination: "Notes", state: .delivered)
    try await store.save(excluded)
    let result = try await store.applyRetention(.sevenDays, now: now, excludingIDs: [excluded.id])
    #expect(Set(result.trashedIDs) == Set([expired.id, pasted.id]))
    #expect(result.failedIDs.isEmpty)
    #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent(expired.id.uuidString + ".json").path))
    expired.revision = 99
    try await store.save(expired)
    #expect(try await store.load().entries.count == protectedStates.count + 1)
}

@Test func retentionForeverBoundaryAndTrashFailure() async throws {
    _ = VaultTestKey.installed
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = HistoryStore(directory: folder, trashItem: { _ in throw CocoaError(.fileWriteNoPermission) })
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let entry = DictationEntry(date: now.addingTimeInterval(-7 * 86400), raw: "keep", text: "keep", note: "", destination: "Notes", state: .delivered)
    try await store.save(entry)
    #expect(HistoryRetention.default == .thirtyDays)
    let forever = try await store.applyRetention(.forever, now: now)
    #expect(forever.trashedIDs.isEmpty && forever.failedIDs.isEmpty)
    #expect(try await store.applyRetention(.sevenDays, now: now).failedIDs.isEmpty)
    let result = try await store.applyRetention(.sevenDays, now: now.addingTimeInterval(1))
    #expect(result.failedIDs == [entry.id])
    #expect(result.trashedIDs.isEmpty)
    #expect(try await store.load().entries == [entry])
    #expect(HistoryRetention.allCases.map(\.rawValue) == [0, 7, 30, 90])
}

@Test(arguments: [(HistoryRetention.thirtyDays, 30), (.ninetyDays, 90)])
func retentionHonorsLongerWindows(policy: HistoryRetention, days: Int) async throws {
    _ = VaultTestKey.installed
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let trash = folder.appendingPathComponent("test-trash")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let store = HistoryStore(directory: folder, trashItem: { url in
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
    })
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let inside = DictationEntry(date: now.addingTimeInterval(-Double(days) * 86400 + 1), raw: "keep", text: "keep", note: "", destination: "Notes", state: .delivered)
    let outside = DictationEntry(date: now.addingTimeInterval(-Double(days) * 86400 - 1), raw: "expire", text: "expire", note: "", destination: "Notes", state: .delivered)
    try await store.save(inside)
    try await store.save(outside)
    try Data("broken".utf8).write(to: folder.appendingPathComponent("corrupt.json"))
    let result = try await store.applyRetention(policy, now: now)
    #expect(result.trashedIDs == [outside.id])
    let loaded = try await store.load()
    #expect(loaded.entries == [inside])
    #expect(loaded.unreadableCount == 1)
}
