import Foundation

/// A span of text as UTF-16 offsets, the unit NSString, NSAttributedString and
/// UIKit/AppKit text views use. `range(in:)` converts it for Swift strings.
public struct TextSpan: Codable, Sendable, Hashable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public func range(in text: String) -> Range<String.Index>? { Range(nsRange, in: text) }
}

/// One change cleanup made, or proposed and refused, between what was said and
/// the cleaned text. History shows these as "what changed".
public struct CleanupEdit: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case punctuation, capitalization, filler, vocabulary, phonetic, grammar, contraction, retraction
        /// A change that fits none of the above, such as a refused change of meaning.
        case rewrite
    }
    public let original: String
    public let replacement: String
    public let kind: Kind
    public let accepted: Bool
    /// Why a refused change was not applied: "meaning", "numbers", "negation",
    /// "vocabulary", "deletion", "insertion", or "clause" when an accepted change
    /// went back with a refused one in the same clause. nil when accepted.
    public let refusalReason: String?
    /// Where `original` is in the dictated text. nil when a refused change could not be located.
    public let originalRange: TextSpan?
    /// Where `replacement` is in the cleaned text; nil for refused changes, which are not in it.
    public let replacementRange: TextSpan?

    public init(original: String, replacement: String, kind: Kind, accepted: Bool, refusalReason: String? = nil,
                originalRange: TextSpan?, replacementRange: TextSpan?) {
        self.original = original; self.replacement = replacement; self.kind = kind; self.accepted = accepted
        self.refusalReason = refusalReason; self.originalRange = originalRange; self.replacementRange = replacementRange
    }
}

/// Derives `CleanupEdit`s by aligning the dictated text with the final text word
/// by word, so ranges stay true after every cleanup step, and adds the refused
/// changes, which the final text does not contain.
enum CleanupEdits {
    private struct Word { let text: String; let key: String; let span: TextSpan }

    private static func words(_ text: String) -> [Word] {
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let word = source.substring(with: match.range)
            return Word(text: word, key: EditValidator.words(word).joined(separator: " "),
                        span: TextSpan(location: match.range.location, length: match.range.length))
        }
    }

    static func compute(source: String, result: String, refused: [RewriteValidation.Refusal] = [], vocabulary: [String] = []) -> [CleanupEdit] {
        let a = words(source), b = words(result)
        let x = a.map(\.key), y = b.map(\.key)
        var lcs = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var edits: [CleanupEdit] = []
        var from: [Int] = [], to: [Int] = []
        // Zero-length spans for a pure insertion or deletion sit after the previous word.
        func span(_ indices: [Int], in list: [Word], before next: Int) -> TextSpan {
            guard let first = indices.first, let last = indices.last else {
                let end = next > 0 ? list[next - 1].span.location + list[next - 1].span.length : 0
                return TextSpan(location: end, length: 0)
            }
            return TextSpan(location: list[first].span.location,
                            length: list[last].span.location + list[last].span.length - list[first].span.location)
        }
        func flush(_ i: Int, _ j: Int) {
            guard !from.isEmpty || !to.isEmpty else { return }
            let original = from.map { a[$0].text }.joined(separator: " "), replacement = to.map { b[$0].text }.joined(separator: " ")
            edits.append(CleanupEdit(original: original, replacement: replacement,
                                     kind: classify(original: original, replacement: replacement, vocabulary: vocabulary), accepted: true,
                                     originalRange: span(from, in: a, before: i), replacementRange: span(to, in: b, before: j)))
            from = []; to = []
        }
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] {
                flush(i, j)
                // Same word, different punctuation or capitals.
                if a[i].text != b[j].text {
                    edits.append(CleanupEdit(original: a[i].text, replacement: b[j].text,
                                             kind: classify(original: a[i].text, replacement: b[j].text, vocabulary: vocabulary), accepted: true,
                                             originalRange: a[i].span, replacementRange: b[j].span))
                }
                i += 1; j += 1
            } else if j < y.count, i == x.count || lcs[i][j + 1] >= lcs[i + 1][j] { to.append(j); j += 1 }
            else { from.append(i); i += 1 }
        }
        flush(i, j)

        // Refused changes, located in the dictated text in order where possible.
        var cursor = source.startIndex
        for refusal in refused {
            var located: TextSpan?
            if !refusal.original.isEmpty,
               let range = source.range(of: refusal.original, options: [.caseInsensitive], range: cursor..<source.endIndex)
                ?? source.range(of: refusal.original, options: [.caseInsensitive]) {
                located = TextSpan(location: source.utf16.distance(from: source.startIndex, to: range.lowerBound),
                                   length: source.utf16.distance(from: range.lowerBound, to: range.upperBound))
                cursor = range.upperBound
            }
            edits.append(CleanupEdit(original: refusal.original, replacement: refusal.replacement,
                                     kind: classify(original: refusal.original, replacement: refusal.replacement, vocabulary: vocabulary),
                                     accepted: false, refusalReason: refusal.reason, originalRange: located, replacementRange: nil))
        }
        return edits.sorted { ($0.originalRange?.location ?? .max, $0.accepted ? 0 : 1) < ($1.originalRange?.location ?? .max, $1.accepted ? 0 : 1) }
    }

    static func classify(original: String, replacement: String, vocabulary: [String]) -> CleanupEdit.Kind {
        let from = EditValidator.words(original), to = EditValidator.words(replacement)
        func letters(_ text: String) -> String { String(text.filter { $0.isLetter || $0.isNumber }) }
        if letters(original).lowercased() == letters(replacement).lowercased() {
            // Same letters: an apostrophe added or removed ("its" → "it's"), capitals, or punctuation.
            func apostrophes(_ text: String) -> Int { text.filter { $0 == "'" || $0 == "’" }.count }
            if apostrophes(original) != apostrophes(replacement) { return .contraction }
            // Words split or joined at the wrong place ("to get her" → "together").
            if from.count != to.count { return .phonetic }
            return letters(original) != letters(replacement) ? .capitalization : .punctuation
        }
        if from.count == 1 && RewriteValidation.contractions[to.joined(separator: " ")].map({ $0.lowercased() == from[0] }) == true
            || to.count == 1 && RewriteValidation.contractions[from.joined(separator: " ")].map({ $0.lowercased() == to[0] }) == true
            || from.count == 1 && to.count == 1 && RewriteValidation.contractions.values.contains(where: { $0.lowercased() == to[0] })
                && PhoneticKey.soundsAlike(from[0], to[0]) {
            return .contraction
        }
        let lowerOriginal = " " + from.joined(separator: " ") + " "
        if original.range(of: #"(?i)\b(scratch|strike|delete|forget)\s+that\b"#, options: .regularExpression) != nil
            || EditValidator.cues.filter({ $0 != "no" }).contains(where: { lowerOriginal.contains(" " + $0 + " ") }) && to.count < from.count {
            return .retraction
        }
        let replaced = " " + to.joined(separator: " ") + " "
        if vocabulary.contains(where: { term in
            let key = " " + EditValidator.words(term).joined(separator: " ") + " "
            return key.count > 2 && replaced.contains(key) && !lowerOriginal.contains(key)
        }) { return .vocabulary }
        if EditValidator.isSubsequence(to, of: from) {
            let removed = EditValidator.removedWords(from, keeping: to)
            if removed.allSatisfy({ EditValidator.fillers.contains($0) }) || EditValidator.hasStutter(from) { return .filler }
        }
        // Homophones ("their" → "there", "by" → "buy") are mishearings even between small words.
        if !from.isEmpty, PhoneticKey.key(from.joined()) == PhoneticKey.key(to.joined()) { return .phonetic }
        let changedFrom = EditValidator.removedWords(from, keeping: to), changedTo = EditValidator.removedWords(to, keeping: from)
        // An ending added or dropped ("needs" → "need", "deploy" → "deployed") is grammar, not a mishearing.
        if !changedFrom.isEmpty, changedFrom.count == changedTo.count,
           zip(changedFrom, changedTo).allSatisfy({ $0.hasPrefix($1) || $1.hasPrefix($0) || EditValidator.functionWords.contains($0) && EditValidator.functionWords.contains($1) }) {
            return .grammar
        }
        if !from.isEmpty, !to.isEmpty, PhoneticKey.soundsAlike(from.joined(separator: " "), to.joined(separator: " ")) { return .phonetic }
        if (changedFrom + changedTo).allSatisfy({ EditValidator.functionWords.contains($0) || EditValidator.fillers.contains($0) })
            || changedFrom.count == changedTo.count && zip(changedFrom, changedTo).allSatisfy({ EditValidator.inflection($0, $1) }) {
            return .grammar
        }
        return .rewrite
    }
}
