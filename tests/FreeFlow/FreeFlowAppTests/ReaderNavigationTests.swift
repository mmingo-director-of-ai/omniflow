import Foundation
import AppKit
import SwiftUI
import Testing
@testable import OmniFlowApp

private func navigationBook() -> ReaderDocument {
    let text = "Café on the coast. A second sentence with a 🦊. " + String(repeating: "A page of text with complete words and useful detail. ", count: 150)
    let block = ReaderBlock(kind: .paragraph, text: text, path: [4, 2], anchors: [], sentences: ReaderSegmenter.sentences(in: text))
    return ReaderDocument(title: "Fixture", author: "Tester", chapters: [ReaderChapter(title: "Coast", spineIndex: 0, idref: "coast", blocks: [block]), ReaderChapter(title: "Next", spineIndex: 1, idref: "next", blocks: [block])])
}

@Test func readerSearchHandlesAccentsAndPhrasesAcrossSentences() {
    let book = navigationBook()
    #expect(ReaderSearch.find("cafe", in: book).count == 2)
    #expect(ReaderSearch.find("coast. A second", in: book).first?.ref.sentence == 0)
    #expect(ReaderSearch.find("🦊", in: book).first?.ref.sentence == 1)
    #expect(ReaderSearch.find("no such passage", in: book).isEmpty)
    #expect(ReaderSearch.find("  ", in: book).isEmpty)
    #expect(ReaderSearch.find("page", in: book, limit: 1).count == 1)
}

@MainActor @Test func readerOrganizationPersistsWithoutChangingBookRecords() throws {
    let name = "reader-org-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let organization = ReaderFavorites(defaults: defaults)
    organization.toggle("book-1")
    #expect(organization.create(" Research "))
    #expect(!organization.create("research"))
    #expect(!organization.create(" "))
    organization.toggle("book-1", in: "Research")
    organization.toggleBookmark(bookID: "book-1", ref: .init(chapter: 0, block: 0, sentence: 1), title: "Coast")
    let reloaded = ReaderFavorites(defaults: defaults)
    #expect(reloaded.bookmarks.count == 1)
    #expect(reloaded.bookmarks.first?.ref.sentence == 1)
    #expect(reloaded.ids == ["book-1"])
    #expect(reloaded.collections["Research"] == ["book-1"])
    reloaded.removeCollection("Research")
    #expect(reloaded.ids == ["book-1"])
    reloaded.toggle("book-1")
    #expect(ReaderFavorites(defaults: defaults).ids.isEmpty)
}

@Test func readerPaginationCoversTextAndMapsAudioPositions() {
    let document = navigationBook()
    let layout = ReaderMacPages.build(document: document, chapter: 0, size: CGSize(width: 300, height: 360), fontSize: 19)
    #expect(layout.pages.count > 1)
    #expect(layout.pages.map(\.text).joined() == layout.text)
    for i in 1..<layout.pages.count {
        #expect(NSMaxRange(layout.pages[i - 1].range) == layout.pages[i].range.location)
    }
    for ref in document.sentences where ref.chapter == 0 { #expect(layout.page(for: ref, in: document) != nil) }
    #expect(layout.page(for: .init(chapter: 1, block: 0, sentence: 0), in: document) == nil)
    let larger = ReaderMacPages.build(document: document, chapter: 0, size: CGSize(width: 300, height: 360), fontSize: 26)
    #expect(larger.pages.count > layout.pages.count)
    #expect(larger.pages.map(\.text).joined() == layout.text)
}

@MainActor @Test func readerKokoroVoicePinsSelectionUntilRestart() throws {
    let first = KokoroReadingVoice.resolve("english:af_heart")
    let second = KokoroReadingVoice.resolve("english:am_michael")
    var selected = first
    let voice = KokoroReaderVoice(selection: { selected })
    try voice.start()
    #expect(voice.voiceID == first.id)
    selected = second
    try voice.start()
    #expect(voice.voiceID == first.id)
    voice.stop()
    try voice.start()
    #expect(voice.voiceID == second.id)
    voice.stop()
    #expect(!voice.isRunning)
    #expect(voice.request("Must not synthesize while stopped", rate: 1, pitch: 1) == nil)
}

@Test func kokoroCatalogUsesEachLanguagesActualVoicePacks() {
    let voices = KokoroReadingVoice.all
    #expect(Set(voices.map(\.id)).count == voices.count)
    #expect(voices.filter { $0.variant == .english }.count == 28)
    #expect(voices.filter { $0.variant == .japanese }.count == 5)
    #expect(voices.filter { $0.variant == .spanish }.count == 3)
    #expect(voices.filter { $0.variant == .french }.count == 1)
    #expect(voices.contains { $0.id == "mandarin:zf_001" })
    #expect(!voices.contains { $0.id == "mandarin:zf_xiaobei" })
    #expect(KokoroReadingVoice.resolve("removed:voice").id == "english:af_heart")
}

@MainActor @Test func collapsedPillFitsItsPanelInBothOrientations() {
    let bottom = NSHostingView(rootView: OmniFlowPillTab(bottom: true))
    let side = NSHostingView(rootView: OmniFlowPillTab(bottom: false))
    #expect(bottom.fittingSize.width == 48)
    #expect(bottom.fittingSize.height == 12)
    #expect(side.fittingSize.width == 12)
    #expect(side.fittingSize.height == 48)
}

@MainActor @Test func kokoroReplyStopDiscardsPendingCompletion() async throws {
    let speaker = KokoroReplySpeaker()
    var completions = 0
    speaker.onFinished = { completions += 1 }
    speaker.beginReply()
    speaker.endReply()
    speaker.stop()
    try await Task.sleep(for: .milliseconds(100))
    #expect(completions == 0)
    speaker.shutdown()
}

@MainActor @Test func kokoroEmptyReplyCompletesOnce() async throws {
    let speaker = KokoroReplySpeaker()
    var completions = 0
    speaker.onFinished = { completions += 1 }
    speaker.beginReply()
    speaker.endReply()
    speaker.endReply()
    try await Task.sleep(for: .milliseconds(100))
    #expect(completions == 1)
    speaker.shutdown()
}
