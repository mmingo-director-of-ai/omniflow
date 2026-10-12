import Testing
@testable import OmniFlowApp

@Test func localCorrectionsExtendToClosedDetailFamilies() {
    #expect(SpeechCorrections.resolve("Use red, no, blue paint in March, actually April.") == "Use blue paint in April.")
    #expect(SpeechCorrections.resolve("Turn left, I mean right at the gate.") == "Turn right at the gate.")
    #expect(SpeechCorrections.resolve("Do not use red, no, blue paint.") == "Do not use blue paint.")
    #expect(SpeechCorrections.resolve("Use red and blue paint.") == "Use red and blue paint.")
    #expect(SpeechCorrections.resolve("Use red, no, never blue paint.") == "Use red, no, never blue paint.")
}

@Test func numericPresentationPreservesLiteralSpellings() {
    for style in [WritingStyle.apa, .technical] {
        let text = "Keep 007, +2, RFC-2, 2-factor, user@2.com, https://example.com/2 and \"two\"."
        #expect(style.format(text) == text)
    }
}

@Test func correctionsDoNotRewriteQuotedCodeOrIdentifiers() {
    for text in ["Use `2, no, 3` exactly.", "Say \"Monday, no, Tuesday\".", "Read /Monday, no, Tuesday.", "Use v2, no, 3.", "Use RFC-2, no, 3."] {
        #expect(SpeechCorrections.resolve(text) == text)
    }
}

@Test func cleanupRejectsChangedLiteralAndCorrectedDetails() {
    #expect(CleanupPolicy.accept(raw: "Do not use red, no, blue paint.", candidate: "Do not use blue paint.") != nil)
    #expect(CleanupPolicy.accept(raw: "Use red, no, blue paint.", candidate: "Use green paint.") == nil)
    for pair in [("Use RFC-2.", "Use ABC-2."), ("Use 007.", "Use seven."), ("Use https://example.com/path.", "Use https://other.com/path."), ("Say \"two\".", "Say \"2\".")] {
        #expect(CleanupPolicy.accept(raw: pair.0, candidate: pair.1) == nil)
    }
}
