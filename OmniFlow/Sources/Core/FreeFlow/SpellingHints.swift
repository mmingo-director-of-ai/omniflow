import Foundation
#if os(iOS)
import UIKit
#endif

/// Platform spelling suggestions for the cleanup prompt: optional hints only,
/// never applied directly and never written to a system dictionary.
@MainActor
protocol SpellingHintProvider {
    /// Named in the prompt ("Optional macOS spelling candidates").
    var platformName: String { get }
    /// Up to eight "word: guess, guess" lines for likely misspellings in `text`.
    func hints(for text: String, locale: Locale, vocabulary: String) -> String
    /// Whether the platform dictionary knows `word`; unknown corrected words become
    /// vocabulary suggestions when learning from the user's corrections.
    func isKnownWord(_ word: String, locale: Locale) -> Bool
}

enum SpellingHintPolicy {
    static func relevantVocabulary(_ vocabulary: String, source: String) -> String {
        let sourceWords = Set(source.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        return vocabulary.components(separatedBy: .newlines).filter { line in
            // Spoken API names arrive as separate words (Speech Transcriber).
            // Offer the canonical casing as a hint, never a forced replacement.
            let expanded = line.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            let words = expanded.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
            if sourceWords.contains(line.lowercased()) { return true }
            return words.contains { sourceWords.contains($0) }
        }.joined(separator: "\n")
    }

    static func preservesVocabulary(source: String, edited: String, vocabulary: String) -> Bool {
        for line in vocabulary.components(separatedBy: .newlines) {
            let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}_])"#
            if source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil,
               edited.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil { return false }
        }
        return true
    }

    static func maySuggest(word: String, range: NSRange, source: String, vocabulary: String) -> Bool {
        guard word.count >= 3, word.count <= 40, word.allSatisfy(\.isLetter),
              word == word.lowercased(), !source.contains("`"), !source.contains("~~~") else { return false }
        let terms = vocabulary.lowercased().components(separatedBy: CharacterSet.letters.inverted)
        guard !terms.contains(word.lowercased()) else { return false }
        // Public literal validator detects whether removing the token would change a protected literal.
        guard let swiftRange = Range(range, in: source) else { return false }
        var without = source; without.replaceSubrange(swiftRange, with: "")
        return DictationLiterals.preserved(source: source, candidate: without)
    }
}

#if os(iOS)
/// UITextChecker hints, bounded and filtered exactly like the Mac's.
@MainActor
final class UIKitSpellingHints: SpellingHintProvider {
    let platformName = "iOS"

    func hints(for text: String, locale: Locale, vocabulary: String) -> String {
        guard text.count <= 5000 else { return "" }
        let requested = locale.identifier.replacingOccurrences(of: "-", with: "_")
        let languageCode = locale.language.languageCode?.identifier
        let available = UITextChecker.availableLanguages
        guard let language = available.first(where: { $0 == requested })
            ?? available.first(where: { Locale(identifier: $0).language.languageCode?.identifier == languageCode }) else { return "" }
        let checker = UITextChecker()
        for term in vocabulary.components(separatedBy: .newlines) where !term.isEmpty { checker.ignoreWord(term) }
        let source = text as NSString
        var offset = 0, hints: [String] = []
        for _ in 0..<16 {
            let range = checker.rangeOfMisspelledWord(in: text, range: NSRange(location: 0, length: source.length),
                                                      startingAt: offset, wrap: false, language: language)
            guard range.location != NSNotFound, range.length > 0,
                  range.location >= offset, range.location <= source.length,
                  range.length <= source.length - range.location else { break }
            offset = NSMaxRange(range)
            let word = source.substring(with: range)
            guard SpellingHintPolicy.maySuggest(word: word, range: range, source: text, vocabulary: vocabulary) else { continue }
            let guesses = (checker.guesses(forWordRange: range, in: text, language: language) ?? [])
                .filter { !$0.isEmpty && $0.count <= 60 && !$0.contains("\n") }.prefix(3)
            if !guesses.isEmpty { hints.append("\(word): \(guesses.joined(separator: ", "))") }
            if hints.count == 8 { break }
        }
        return hints.joined(separator: "\n")
    }

    func isKnownWord(_ word: String, locale: Locale) -> Bool {
        let language = locale.identifier.replacingOccurrences(of: "-", with: "_")
        let available = UITextChecker.availableLanguages
        guard let match = available.first(where: { $0 == language }) ?? available.first(where: { $0.hasPrefix(locale.language.languageCode?.identifier ?? "en") })
        else { return true }
        let range = UITextChecker().rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
                                                          startingAt: 0, wrap: false, language: match)
        return range.location == NSNotFound
    }
}

extension DictationCleanup {
    /// Cleanup with this device's spelling hints (UITextChecker).
    static func onDevice() -> DictationCleanup { DictationCleanup(spelling: UIKitSpellingHints()) }
}
#endif
