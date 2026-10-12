import Foundation

struct ReaderSearchHit: Identifiable, Sendable {
    var ref: ReaderSentenceRef
    var chapterTitle: String
    var excerpt: String
    var id: ReaderSentenceRef { ref }
}

enum ReaderSearch {
    /// Search blocks so phrases spanning sentence boundaries still match.
    static func find(_ query: String, in document: ReaderDocument, limit: Int = 200) -> [ReaderSearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        var hits: [ReaderSearchHit] = []
        for (c, chapter) in document.chapters.enumerated() {
            for (b, block) in chapter.blocks.enumerated() where block.spoken {
                if Task.isCancelled { return [] }
                let text = block.text as NSString
                let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
                guard match.location != NSNotFound else { continue }
                let sentence = block.sentences.firstIndex { $0.contains(match.location) } ?? 0
                let start = max(0, match.location - 55), end = min(text.length, match.location + match.length + 100)
                let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                let excerpt = (start > 0 ? "…" : "") + text.substring(with: range) + (end < text.length ? "…" : "")
                hits.append(.init(ref: .init(chapter: c, block: b, sentence: sentence), chapterTitle: chapter.title, excerpt: excerpt))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }
}
