import AppKit

/// Bounded spelling hints from macOS. Never modifies text or the system dictionary.
@MainActor
final class AppleSpellingService: SpellingHintProvider {
    let platformName = "macOS"
    func hints(for text: String, locale: Locale, vocabulary: String) -> String {
        guard text.count <= 5000 else { return "" }
        let checker = NSSpellChecker.shared
        let requested = locale.identifier.replacingOccurrences(of: "-", with: "_")
        let languageCode = locale.language.languageCode?.identifier
        guard let language = checker.availableLanguages.first(where: { $0 == requested })
            ?? checker.availableLanguages.first(where: { Locale(identifier: $0).language.languageCode?.identifier == languageCode }) else { return "" }
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        let known = vocabulary.components(separatedBy: .newlines).filter { !$0.isEmpty }
        checker.setIgnoredWords(known, inSpellDocumentWithTag: tag)
        let source = text as NSString
        var offset = 0, hints: [String] = []
        for _ in 0..<16 {
            let range = checker.checkSpelling(of: text, startingAt: offset, language: language, wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0,
                  range.location >= offset, range.location <= source.length,
                  range.length <= source.length - range.location else { break }
            offset = NSMaxRange(range)
            let word = source.substring(with: range)
            // Skip literal/code spans, user terminology, uppercase abbreviations and proper names.
            guard SpellingHintPolicy.maySuggest(word: word, range: range, source: text, vocabulary: vocabulary) else { continue }
            let guesses = (checker.guesses(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: tag) ?? [])
                .filter { !$0.isEmpty && $0.count <= 60 && !$0.contains("\n") }.prefix(3)
            if !guesses.isEmpty { hints.append("\(word): \(guesses.joined(separator: ", "))") }
            if hints.count == 8 { break }
        }
        return hints.joined(separator: "\n")
    }

    func isKnownWord(_ word: String, locale: Locale) -> Bool {
        let checker = NSSpellChecker.shared
        let requested = locale.identifier.replacingOccurrences(of: "-", with: "_")
        let languageCode = locale.language.languageCode?.identifier
        guard let language = checker.availableLanguages.first(where: { $0 == requested })
            ?? checker.availableLanguages.first(where: { Locale(identifier: $0).language.languageCode?.identifier == languageCode }) else { return true }
        let range = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}

/// The Mac's dictation cleanup: the shared Core pipeline with NSSpellChecker hints.
@MainActor
final class CleanupService: DictationCleanup {
    init() { super.init(spelling: AppleSpellingService()) }
}
