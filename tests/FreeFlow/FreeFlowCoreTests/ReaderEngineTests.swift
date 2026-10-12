import Foundation
import Testing
@testable import OmniFlowApp

/// A voice that answers every sentence with a short tone, for engine tests.
@MainActor
private final class ToneVoice: ReaderVoiceSource {
    var onSentence: ((UInt32, [Float]?) -> Void)?
    var onExit: (() -> Void)?
    private(set) var isRunning = false
    private var next: UInt32 = 0
    var failing = false
    var requests: [String] = []

    func start() throws { isRunning = true }
    func request(_ text: String, rate: Double, pitch: Double) -> UInt32? {
        guard isRunning else { return nil }
        next += 1
        let id = next
        requests.append(text)
        let samples = failing ? nil : (0..<4800).map { Float(sin(Double($0) * 0.2)) * 0.3 }   // 100 ms
        Task { @MainActor in self.onSentence?(id, samples) }
        return id
    }
    func cancel(_ ids: [UInt32]) {}
    func stop() { isRunning = false }
}

@MainActor private func engine(_ voice: ToneVoice, store: ReaderPositionStore) -> ReaderEngine {
    let playback = ReaderPlayback()
    playback.muted = true
    return ReaderEngine(voice: voice, playback: playback, store: store, rate: { 1.3 }, pitch: { 1 })
}

private func paragraphBook(_ count: Int) -> ReaderDocument {
    let text = (0..<count).map { "Sentence number \($0) is here." }.joined(separator: " ")
    var block = ReaderBlock(kind: .paragraph, text: text, path: [4, 2], anchors: [ReaderTextAnchor(path: [4, 2, 1], blockOffset: 0, length: text.utf16.count)], sentences: [])
    block.sentences = ReaderSegmenter.sentences(in: text)
    return ReaderDocument(title: "Engine Test", author: "", language: "en", chapters: [ReaderChapter(title: "One", spineIndex: 0, idref: "c1", blocks: [block])])
}

@MainActor @Test func readerEngineReadsInOrderAndSavesItsPlace() async throws {
    let store = ReaderPositionStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)/positions.json"))
    defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
    let voice = ToneVoice()
    let reader = engine(voice, store: store)
    var moves: [Int] = []
    reader.onMove = { ref, move in if case .advanced = move { moves.append(ref.sentence) } }
    #expect(reader.load(paragraphBook(6), bookID: "b1", title: "Engine Test", start: nil))
    #expect(reader.play())
    for _ in 0..<100 where reader.status != .finished { try await Task.sleep(for: .milliseconds(50)) }
    #expect(reader.status == .finished)
    #expect(moves == [1, 2, 3, 4, 5])
    #expect(reader.stats.sentences == 6 && reader.stats.underruns <= 1)
    #expect(voice.requests.count == 6)
    // Pause reasons: an automatic pause resumes; a user pause in between keeps it paused.
    reader.seek(to: 0)
    reader.play()
    reader.pause(.dictation)
    #expect(reader.status == .paused)
    reader.release(.dictation, after: .milliseconds(10))
    try await Task.sleep(for: .milliseconds(100))
    #expect(reader.status == .playing || reader.status == .finished)
    reader.pause(.user); reader.pause(.assistant)
    reader.release(.assistant, after: .milliseconds(10))
    try await Task.sleep(for: .milliseconds(100))
    #expect(reader.status == .paused)
    // The place is saved and read back by a new session.
    reader.seek(to: 3)
    reader.savePositionNow(synchronously: true)
    let again = engine(ToneVoice(), store: store)
    #expect(again.savedEntry("b1")?.position.ref == reader.order[3])
    #expect(again.lastBookID == "b1")
    reader.close()
    #expect(reader.status == .idle && reader.document == nil)
}

@MainActor @Test func readerEngineFailsAfterThreeSilentSentences() async throws {
    let store = ReaderPositionStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)/positions.json"))
    defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
    let voice = ToneVoice()
    voice.failing = true
    let reader = engine(voice, store: store)
    reader.voiceStoppedMessage = "stopped"
    reader.load(paragraphBook(6), bookID: "b2", title: "Engine Test", start: nil)
    reader.play()
    for _ in 0..<40 where reader.status == .playing { try await Task.sleep(for: .milliseconds(25)) }
    #expect(reader.status == .failed("stopped"))
}
