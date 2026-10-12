import Foundation
import CryptoKit

/// A book prepared for listening: chapters of blocks of sentences. Skipped
/// content (figures, tables, code, notes, page markers) stays in the model with
/// `spoken == false`, so positions and Books' locations stay exact.
/// Platform-agnostic: the iOS reader can reuse it unchanged.
struct ReaderDocument: Sendable, Equatable {
    var title: String
    var author: String
    var language: String?
    var chapters: [ReaderChapter]
    /// The cover image inside the package, when the book has one.
    var cover: URL? = nil

    /// Content identity is independent of Apple Books IDs, filenames and import
    /// folders. Different editions deliberately do not share sentence positions.
    var syncIdentity: String {
        var hash = SHA256()
        for chapter in chapters {
            hash.update(data: Data("\u{0}chapter\u{0}".utf8))
            for block in chapter.blocks {
                hash.update(data: Data(block.text.precomposedStringWithCanonicalMapping.utf8))
                hash.update(data: Data([0]))
            }
        }
        return "book-v1-" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every spoken sentence in reading order.
    var sentences: [ReaderSentenceRef] {
        var result: [ReaderSentenceRef] = []
        for (c, chapter) in chapters.enumerated() {
            for (b, block) in chapter.blocks.enumerated() where block.spoken {
                for s in block.sentences.indices { result.append(ReaderSentenceRef(chapter: c, block: b, sentence: s)) }
            }
        }
        return result
    }

    func block(_ ref: ReaderSentenceRef) -> ReaderBlock { chapters[ref.chapter].blocks[ref.block] }
    func text(_ ref: ReaderSentenceRef) -> String {
        let block = block(ref)
        return block.substring(block.sentences[ref.sentence])
    }
}

struct ReaderChapter: Sendable, Equatable {
    var title: String
    /// 0-based spine position; Books' CFI step `/6/N` is `2 * (spineIndex + 1)`.
    var spineIndex: Int
    var idref: String
    var blocks: [ReaderBlock]
}

enum ReaderBlockKind: String, Sendable, Codable {
    case paragraph, heading, listItem, quote
    case figure, caption, table, code, math, footnote, pageMarker, matter
}

struct ReaderBlock: Sendable, Equatable {
    var kind: ReaderBlockKind
    var text: String
    /// Element steps of the block's element from the document root (CFI even indices).
    var path: [Int]
    /// Where the block's text came from, for mapping a Books location to an offset.
    var anchors: [ReaderTextAnchor]
    /// UTF-16 ranges into `text`.
    var sentences: [Range<Int>]

    var spoken: Bool { [.paragraph, .heading, .listItem, .quote].contains(kind) && !sentences.isEmpty }

    func substring(_ range: Range<Int>) -> String {
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: min(range.lowerBound, utf16.count))
        let end = utf16.index(utf16.startIndex, offsetBy: min(range.upperBound, utf16.count))
        return String(text[start..<end])
    }
}

/// One text node's contribution to a block: its CFI path (element steps plus the
/// odd text-chunk index) and where it starts in the block text.
struct ReaderTextAnchor: Sendable, Equatable {
    var path: [Int]
    var blockOffset: Int
    var length: Int
}

struct ReaderSentenceRef: Hashable, Sendable, Codable, Comparable {
    var chapter: Int
    var block: Int
    var sentence: Int

    static func < (a: Self, b: Self) -> Bool { (a.chapter, a.block, a.sentence) < (b.chapter, b.block, b.sentence) }
}

/// A saved listening position. Sentence refs are tied to the parser version, so
/// the position also carries the sentence's CFI to survive parser changes.
struct ReaderPosition: Codable, Sendable, Equatable {
    var ref: ReaderSentenceRef
    var cfi: String?
    var updatedAt: Date
}

/// The parts of an EPUB CFI the reader needs: spine step and element/text path.
/// Books saves `epubcfi(/6/22[ch01]!/4/92[id]/1,:0,:1)` for the first character
/// of its visible page. Read-only: the reader never writes Books' locations.
struct ReaderCFI: Sendable, Equatable {
    var spineIndex: Int
    var idref: String?
    /// Steps after `!`, assertions dropped.
    var path: [Int]
    var offset: Int

    init(spineIndex: Int, idref: String? = nil, path: [Int], offset: Int) {
        self.spineIndex = spineIndex; self.idref = idref; self.path = path; self.offset = offset
    }

    init?(_ string: String) {
        guard string.hasPrefix("epubcfi("), string.hasSuffix(")") else { return nil }
        var body = String(string.dropFirst(8).dropLast())
        // Range form `parent,start,end`: the start is parent + start.
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3 { body = parts[0] + parts[1] }
        let halves = body.split(separator: "!", maxSplits: 1).map(String.init)
        guard halves.count == 2 else { return nil }
        let package = Self.steps(halves[0])
        guard package.count >= 2, package[0].step == 6, package[1].step >= 2 else { return nil }
        spineIndex = package[1].step / 2 - 1
        idref = package[1].assertion
        var content = halves[1]
        var offset = 0
        if let colon = content.lastIndex(of: ":") {
            offset = Int(content[content.index(after: colon)...].prefix { $0.isNumber }) ?? 0
            content = String(content[..<colon])
        }
        path = Self.steps(content).map(\.step)
        self.offset = offset
        guard !path.isEmpty else { return nil }
    }

    private static func steps(_ text: String) -> [(step: Int, assertion: String?)] {
        text.split(separator: "/").compactMap { piece in
            let number = Int(piece.prefix { $0.isNumber })
            guard let number else { return nil }
            var assertion: String?
            if let open = piece.firstIndex(of: "["), let close = piece.lastIndex(of: "]"), open < close {
                assertion = String(piece[piece.index(after: open)..<close])
            }
            return (number, assertion)
        }
    }

    var string: String {
        "epubcfi(/6/\(2 * (spineIndex + 1))\(idref.map { "[\($0)]" } ?? "")!/" + path.map(String.init).joined(separator: "/") + ":\(offset))"
    }
}

extension ReaderDocument {
    /// The sentence containing a Books location, or the chapter start when the
    /// location points into skipped content or cannot be resolved.
    func sentence(for cfi: ReaderCFI) -> ReaderSentenceRef? {
        switch place(of: cfi) {
        case .before(let chapter): return firstSpoken(from: ReaderSentenceRef(chapter: chapter, block: 0, sentence: 0))
        case .at(let c, let b, let offset):
            let sentence = chapters[c].blocks[b].sentences.lastIndex { $0.lowerBound <= offset } ?? 0
            return firstSpoken(from: ReaderSentenceRef(chapter: c, block: b, sentence: sentence))
        }
    }

    enum Place: Equatable {
        /// Inside a block, at a UTF-16 offset of its text.
        case at(chapter: Int, block: Int, offset: Int)
        /// Before the start of a chapter (a skipped spine item, or past a chapter's last block).
        case before(chapter: Int)
    }

    /// Where a Books location falls in this document.
    func place(of cfi: ReaderCFI) -> Place {
        guard let c = chapters.firstIndex(where: { $0.spineIndex == cfi.spineIndex }) else {
            return .before(chapter: chapters.firstIndex { $0.spineIndex > cfi.spineIndex } ?? chapters.count)
        }
        let blocks = chapters[c].blocks
        // The deepest block whose element contains the location; otherwise the
        // first block after it in document order.
        // An element split into several blocks (by a nested list or code) has
        // one path; the text node itself decides.
        let exact = blocks.indices.first { blocks[$0].anchors.contains { $0.path == cfi.path } }
        let containing = blocks.indices.filter { cfi.path.starts(with: blocks[$0].path) && !blocks[$0].path.isEmpty }
        guard let b = exact ?? containing.max(by: { blocks[$0].path.count < blocks[$1].path.count })
                ?? blocks.firstIndex(where: { !$0.path.lexicographicallyPrecedes(cfi.path) }) else { return .before(chapter: c + 1) }
        let block = blocks[b]
        var offset = 0
        if let anchor = block.anchors.first(where: { $0.path == cfi.path }) {
            offset = anchor.blockOffset + min(cfi.offset, anchor.length)
        } else if let anchor = block.anchors.first(where: { !$0.path.lexicographicallyPrecedes(cfi.path) }) {
            offset = anchor.blockOffset
        }
        return .at(chapter: c, block: b, offset: offset)
    }

    /// `ref` itself when spoken, otherwise the next spoken sentence.
    func firstSpoken(from ref: ReaderSentenceRef) -> ReaderSentenceRef? {
        let all = sentences
        return all.first { $0 >= ref } ?? all.last
    }

    /// The CFI of a sentence start, so a saved position survives re-parsing.
    func cfi(for ref: ReaderSentenceRef) -> ReaderCFI? {
        let chapter = chapters[ref.chapter], block = chapter.blocks[ref.block]
        let start = block.sentences[ref.sentence].lowerBound
        guard let anchor = block.anchors.last(where: { $0.blockOffset <= start }) else { return nil }
        return ReaderCFI(spineIndex: chapter.spineIndex, idref: chapter.idref, path: anchor.path, offset: max(0, start - anchor.blockOffset))
    }
}
