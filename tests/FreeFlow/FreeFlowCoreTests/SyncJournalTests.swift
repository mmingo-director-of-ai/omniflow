import Foundation
import Testing
@testable import OmniFlowApp

@Test func syncJournalKeepsEditMadeDuringUpload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = SyncJournal(file: root.appendingPathComponent("journal"))
    let first = SyncValue(kind: .transcript, key: "one", modified: Date(timeIntervalSince1970: 1), payload: Data("first".utf8))
    let second = SyncValue(kind: .transcript, key: "one", modified: Date(timeIntervalSince1970: 2), payload: Data("second".utf8))
    try journal.put(first)
    try journal.put(second)
    try journal.acknowledge(first)
    #expect(try journal.snapshot().dirty.contains(second.recordName))
    #expect(try journal.snapshot().values[second.recordName] == second)
    try journal.acknowledge(second)
    #expect(try journal.snapshot().dirty.isEmpty)
}

@Test func syncJournalDeletionSurvivesOfflineEditAndRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("journal")
    let journal = SyncJournal(file: file)
    let deleted = SyncValue(kind: .transcript, key: "one", modified: Date(timeIntervalSince1970: 2), payload: nil)
    try journal.put(deleted, remote: true)
    let stale = SyncValue(kind: .transcript, key: "one", modified: Date(timeIntervalSince1970: 3), payload: Data("resurrection".utf8))
    try journal.put(stale)
    try journal.seed(stale)
    let reopened = SyncJournal(file: file)
    #expect(try reopened.snapshot().values[deleted.recordName] == deleted)
    #expect(try reopened.snapshot().dirty.isEmpty)
    #expect(try OmniFlowVault.isSealed(Data(contentsOf: file)))
}

@Test func syncJournalRejectsDifferentAccount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = SyncJournal(file: root.appendingPathComponent("journal"))
    try journal.bind(account: "first")
    try journal.bind(account: "first")
    #expect(throws: SyncFailure.self) { try journal.bind(account: "second") }
    #expect(try journal.snapshot().account == "first")
}

@Test func syncJournalPositionUsesLatestVisitNotFarthestPage() throws {
    let newer = SyncValue(kind: .position, key: "book", modified: Date(timeIntervalSince1970: 2), payload: Data("chapter1".utf8))
    let older = SyncValue(kind: .position, key: "book", modified: Date(timeIntervalSince1970: 1), payload: Data("chapter9".utf8))
    #expect(newer.wins(over: older))
    #expect(!older.wins(over: newer))
    let tie = SyncValue(kind: .position, key: "book", modified: newer.modified, nonce: newer.nonce + "z", payload: Data())
    #expect(tie.wins(over: newer))
    #expect(!newer.wins(over: tie))
}

@Test func syncJournalBookIdentityIgnoresLocationAndCover() {
    var document = ReaderDocument(title: "A", author: "B", chapters: [ReaderChapter(title: "One", spineIndex: 0, idref: "one", blocks: [])])
    let original = document.syncIdentity
    document.cover = URL(fileURLWithPath: "/different/device/cover.jpg")
    #expect(document.syncIdentity == original)
    document.chapters.append(ReaderChapter(title: "Two", spineIndex: 1, idref: "two", blocks: []))
    #expect(document.syncIdentity != original)
}
