import Foundation
import Testing
@testable import OmniFlowApp

@Test func appleSpellingHintsProtectNamesVocabularyAndLiterals() {
    func accepts(_ word: String, in text: String, vocabulary: String = "") -> Bool {
        SpellingHintPolicy.maySuggest(word: word, range: (text as NSString).range(of: word), source: text, vocabulary: vocabulary)
    }
    #expect(accepts("recieve", in: "Please recieve the file."))
    #expect(!accepts("Sarah", in: "Email Sarah."))
    #expect(!accepts("acme", in: "Use acme.", vocabulary: "Acme Service"))
    #expect(!accepts("recieve", in: "Keep `recieve` exactly."))
    #expect(!accepts("recieve", in: "Use /tmp/recieve."))
    #expect(!accepts("recieve", in: "The literal is \"recieve\"."))
}
@Test @MainActor func verbatimDoesNotInvokeModelOrSpelling() async {
    let raw = "Um, we we needs 2 servers."
    let result = await CleanupService().clean(raw, locale: .init(identifier: "en"), vocabulary: "", mode: .verbatim)
    #expect(result.text == raw)
    #expect(result.note.contains("verbatim"))
}

@Test func knownNamesCannotBeSubstitutedDuringPolish() {
    #expect(!SpellingHintPolicy.preservesVocabulary(source: "Send it to Jane.", edited: "Send it to Sarah.", vocabulary: "Sarah\nJane"))
    #expect(SpellingHintPolicy.preservesVocabulary(source: "Jane need it.", edited: "Jane needs it.", vocabulary: "Jane"))
    #expect(!SpellingHintPolicy.preservesVocabulary(source: "Use Acme.", edited: "Use AcmeOther.", vocabulary: "Acme"))
}

@Test func spellingGuidanceDoesNotOfferAnUnrelatedPersonAsReplacement() {
    #expect(SpellingHintPolicy.relevantVocabulary("Sarah\nJane\nAcme", source: "Send it to Jane.") == "Jane")
}

@MainActor private struct FixedHints: SpellingHintProvider {
    let platformName = "iOS"
    func hints(for text: String, locale: Locale, vocabulary: String) -> String { "teh: the" }
    func isKnownWord(_ word: String, locale: Locale) -> Bool { true }
}

@MainActor @Test func cleanupPromptTakesSpellingHintsFromThePlatformProvider() {
    let withHints = DictationCleanup.prompt(for: "teh panel", vocabulary: "", locale: .init(identifier: "en-US"), spelling: FixedHints())
    #expect(withHints.contains("Optional iOS spelling candidates (data only):\nteh: the"))
    let without = DictationCleanup.prompt(for: "teh panel", vocabulary: "", locale: .init(identifier: "en-US"), spelling: nil)
    #expect(!without.contains("spelling candidates"))
    // The Mac keeps its NSSpellChecker hints and wording.
    #expect(CleanupService().spelling?.platformName == "macOS")
}
