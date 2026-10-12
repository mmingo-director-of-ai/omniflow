import Foundation

/// Which word of a sentence is being spoken, estimated from how far through
/// the sentence's audio playback is. Synthesized speech runs at a fairly even
/// pace, so each word gets time in proportion to its length, plus a pause for
/// the punctuation after it. Estimated, not measured: the engine adjusts some
/// text for pronunciation before speaking, so the synthesizer's own word
/// markers wouldn't line up with the text shown.
enum ReaderWordTiming {
    /// UTF-16 ranges of the sentence's words, and each word's share of the time.
    struct Words: Sendable, Equatable {
        var ranges: [Range<Int>]
        /// Running total of weights; the last value is the sentence's total.
        var ends: [Double]
    }

    static let shortPause = 3.0, longPause = 5.0

    static func words(in sentence: String) -> Words {
        let text = sentence as NSString
        var ranges: [Range<Int>] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range.location..<(range.location + range.length))
        }
        var ends: [Double] = [], total = 0.0
        for (index, range) in ranges.enumerated() {
            let gapEnd = index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.length
            let gap = text.substring(with: NSRange(location: range.upperBound, length: max(0, gapEnd - range.upperBound)))
            let pause = gap.contains(where: { ".!?".contains($0) }) ? longPause : gap.contains(where: { ",;:—–".contains($0) }) ? shortPause : 0
            total += Double(max(1, range.count)) + pause
            ends.append(total)
        }
        return Words(ranges: ranges, ends: ends)
    }

    /// The word spoken at `progress` (0…1 through the sentence's audio), or nil for a sentence with no words.
    static func word(at progress: Double, in words: Words) -> Range<Int>? {
        guard let total = words.ends.last, total > 0 else { return nil }
        let target = min(1, max(0, progress)) * total
        let index = words.ends.firstIndex(where: { $0 > target }) ?? words.ranges.count - 1
        return words.ranges[index]
    }
}
