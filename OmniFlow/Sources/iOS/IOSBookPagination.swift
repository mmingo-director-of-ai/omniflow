import os
import UIKit

/// One chapter laid out into pages for the current size and appearance.
/// The chapter becomes a single attributed string (headings and paragraphs,
/// spaced like a book); TextKit fills page-sized containers in turn, and each
/// page keeps its character range so the same text can be drawn and
/// highlighted with exactly the layout that was measured.
struct IOSChapterPages: @unchecked Sendable {  // immutable once built
    let chapter: Int
    let text: NSAttributedString
    /// Character (UTF-16) range of each page in `text`.
    let pages: [NSRange]
    /// Where each shown block starts in `text`, by block index.
    let blockStarts: [Int: Int]

    /// The page holding a sentence, or nil if its block isn't shown.
    func page(of ref: ReaderSentenceRef, in document: ReaderDocument) -> Int? {
        guard ref.chapter == chapter, let start = blockStarts[ref.block] else { return nil }
        let offset = start + document.block(ref).sentences[ref.sentence].lowerBound
        return pages.firstIndex { NSLocationInRange(offset, $0) } ?? (pages.isEmpty ? nil : pages.count - 1)
    }

    /// The first spoken sentence that starts on a page, for "Read from this page".
    func firstSentence(onPage page: Int, in document: ReaderDocument) -> ReaderSentenceRef? {
        guard pages.indices.contains(page) else { return nil }
        let range = pages[page]
        for (block, start) in blockStarts.sorted(by: { $0.value < $1.value }) {
            let item = document.chapters[chapter].blocks[block]
            guard item.spoken else { continue }
            for (index, sentence) in item.sentences.enumerated() where NSLocationInRange(start + sentence.lowerBound, range) {
                return ReaderSentenceRef(chapter: chapter, block: block, sentence: index)
            }
        }
        return nil
    }

    static func layout(chapter index: Int, of document: ReaderDocument, appearance: IOSReaderAppearance, page size: CGSize) -> IOSChapterPages {
        let chapter = document.chapters[index]
        let text = NSMutableAttributedString()
        var starts: [Int: Int] = [:]
        let body = appearance.font(), heading = appearance.font(heading: true)
        let ink = UIColor(appearance.theme.ink)
        for (blockIndex, block) in chapter.blocks.enumerated() where ReaderReadAlongView.shows(block) {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            starts[blockIndex] = text.length
            let isHeading = block.kind == .heading
            let small = block.kind == .caption || block.kind == .footnote
            let font = isHeading ? heading : small ? body.withSize(body.pointSize * 0.8) : body
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = appearance.lineSpacing
            style.paragraphSpacing = font.pointSize * (isHeading ? 0.9 : 0.75)
            style.paragraphSpacingBefore = isHeading && text.length > 0 ? font.pointSize : 0
            style.hyphenationFactor = 0.6
            style.alignment = .natural
            text.append(NSAttributedString(string: block.text, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: ink]))
        }
        return IOSChapterPages(chapter: index, text: text, pages: paginate(text, size: size), blockStarts: starts)
    }

    /// Fills page-sized text containers one after another until the text runs out.
    static func paginate(_ text: NSAttributedString, size: CGSize) -> [NSRange] {
        guard text.length > 0, size.width > 40, size.height > 40 else { return [NSRange(location: 0, length: text.length)] }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var pages: [NSRange] = []
        var laidOut = 0
        while laidOut < text.length, pages.count < 5000 {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard characters.length > 0 else { break }
            pages.append(characters)
            laidOut = NSMaxRange(characters)
        }
        return pages.isEmpty ? [NSRange(location: 0, length: text.length)] : pages
    }
}

/// Laid-out chapters, built once per book, chapter, page size and appearance,
/// off the main thread (TextKit layout of a long chapter takes tens of
/// milliseconds). Turning pages or showing the controls never lays out again.
@MainActor
final class IOSPaginationCache {
    static let shared = IOSPaginationCache()
    struct Key: Hashable { var book: String; var chapter: Int; var width: Int; var height: Int; var appearance: IOSReaderAppearance }

    private var built: [Key: IOSChapterPages] = [:]
    private var building: [Key: Task<IOSChapterPages, Never>] = [:]
    nonisolated static let signposts = OSSignposter(subsystem: "com.mengohlabs.omniflow", category: "Reader")
    nonisolated static let log = Logger(subsystem: "com.mengohlabs.omniflow", category: "Reader")

    func cached(_ key: Key) -> IOSChapterPages? { built[key] }

    func pages(_ key: Key, document: ReaderDocument) async -> IOSChapterPages {
        if let done = built[key] { return done }
        let task = building[key] ?? Task.detached(priority: .userInitiated) {
            let state = Self.signposts.beginInterval("paginate", "chapter \(key.chapter)")
            defer { Self.signposts.endInterval("paginate", state) }
            let started = ContinuousClock.now
            let pages = IOSChapterPages.layout(chapter: key.chapter, of: document, appearance: key.appearance,
                                               page: CGSize(width: key.width, height: key.height))
            let elapsed = ContinuousClock.now - started
            Self.log.info("paginated chapter \(key.chapter, privacy: .public): \(pages.pages.count, privacy: .public) pages, \(pages.text.length, privacy: .public) characters in \(elapsed.components.attoseconds / 1_000_000_000_000_000 + elapsed.components.seconds * 1000, privacy: .public) ms")
            return pages
        }
        building[key] = task
        let pages = await task.value
        building[key] = nil
        built[key] = pages
        if built.count > 24 { built.remove(at: built.startIndex) }
        return pages
    }
}
