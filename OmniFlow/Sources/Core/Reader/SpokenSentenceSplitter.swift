import Foundation
import NaturalLanguage

/// Splits a streaming reply into sentences for speech. A sentence is handed
/// over only once more text follows it, and only while each new snapshot
/// extends the text already queued; a replaced draft stops the stream.
struct SpokenSentenceSplitter {
    private(set) var queued = ""
    private(set) var diverged = false

    mutating func sentences(in partial: String) -> [String] {
        guard !diverged else { return [] }
        guard partial.hasPrefix(queued) else { diverged = true; return [] }
        let pieces = Self.pieces(String(partial.dropFirst(queued.count)))
        guard pieces.count > 1 else { return [] }
        let complete = pieces.dropLast()
        queued += complete.joined()
        return complete.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The unspoken sentences of the final reply, or nil when it does not
    /// continue what was already queued.
    mutating func remainder(of reply: String) -> [String]? {
        guard !diverged, reply.hasPrefix(queued) else { return nil }
        let rest = String(reply.dropFirst(queued.count))
        queued = reply
        return Self.pieces(rest).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Sentence pieces that tile `text` exactly, so the queued prefix stays exact.
    static func pieces(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var starts: [String.Index] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.append(range.lowerBound); return true
        }
        guard !starts.isEmpty else { return [text] }
        starts[0] = text.startIndex
        return starts.indices.map { index in
            String(text[starts[index]..<(index + 1 < starts.count ? starts[index + 1] : text.endIndex)])
        }
    }
}
