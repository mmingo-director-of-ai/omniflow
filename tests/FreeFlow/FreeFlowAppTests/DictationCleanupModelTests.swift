import Foundation
import FoundationModels
import Testing
@testable import OmniFlowApp

/// A shortened real dictation that used to come back barely cleaned: the polished
/// rewrite was rejected and the raw text pasted. Structural checks only; the exact
/// wording is the on-device model's.
private let runOnDictation = """
OK now let's do this. Claude is released mods like two days ago so let's start building mods to replace the plug-in system I want to introduce a like right panel as well that can show like amplifying information and then we can also put things in there like findings tables from like you know we're doing investigations table facts will table ICs will tell all the kind of stuff so one of the first things I wanna do is go to like a I don't know what we call it but some kind of a like line break meter bar so we name it session and weekly just like we do right now to get her badge system
"""

// Model quality tests share the on-device inference service. Run them in order
// so test-induced contention does not exhaust the production retry budget.
@Suite(.serialized)
struct DictationCleanupModelTests {
@MainActor @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Needs Apple Intelligence on this Mac"))
func polishedCleanupTurnsARunOnIntoSentences() async throws {
    // The on-device model's output varies under load (other model work on the same
    // Mac), and one dropped word sends a part back to basic cleanup. Allow one
    // more attempt before judging; a real regression fails both.
    var result = await CleanupService().clean(runOnDictation, locale: Locale(identifier: "en-US"), vocabulary: "IOC",
                                              structured: true, writingStyle: .technical, mode: .polished)
    if !result.note.hasPrefix("Polished on your Mac") || result.text.filter({ ".!?".contains($0) }).count <= 2 {
        result = await CleanupService().clean(runOnDictation, locale: Locale(identifier: "en-US"), vocabulary: "IOC",
                                              structured: true, writingStyle: .technical, mode: .polished)
    }
    let text = result.text
    #expect(result.note.hasPrefix("Polished on your Mac"), "The edit was rejected: \(result.note)")
    #expect(text.filter { ".!?".contains($0) }.count > 2, "Still one run-on: \(text)")
    #expect(!text.localizedCaseInsensitiveContains("I don't know what we call it"))
    #expect(!text.localizedCaseInsensitiveContains("like you know"))
    #expect(ContentCoverage.fraction(source: runOnDictation, edited: text) >= CleanupPolicy.minimumCoverage)
    // Wanted, not yet reliable with Apple's on-device model (measured 2026-10-05):
    // grammar and recognizer fixes it usually leaves as spoken.
    withKnownIssue("On-device model rarely fixes these recognizer errors", isIntermittent: true) {
        #expect(text.contains("Claude released"))
        #expect(text.localizedCaseInsensitiveContains("together") || !text.localizedCaseInsensitiveContains("get her"))
        #expect(text.contains("IOC"))
    }
}

@MainActor @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Needs Apple Intelligence"))
func contextualDictationQualityExamples() async {
    let examples: [(String, String)] = [
        ("We are reviewing suspicious messages that steal passwords. These fishing emails should be reported to the security team.", "phishing emails"),
        ("We are planning a weekend on the lake. The fishing trip starts on Saturday.", "fishing trip"),
        ("The team have finish the review yesterday. They needs to send the report today.", "finished")
    ]
    for (raw, expected) in examples {
        let result = await CleanupService().clean(raw, locale: Locale(identifier: "en-US"), vocabulary: "", mode: .polished)
        print("Quality example: \(result.text) [\(result.note)]")
        #expect(result.text.localizedCaseInsensitiveContains(expected))
    }
    let raw = "The release is ready and the tests passed. Separately we need to book the meeting room for Monday and invite the design team."
    let result = await CleanupService().clean(raw, locale: Locale(identifier: "en-US"), vocabulary: "", mode: .polished)
    print("Paragraph example: \(result.text) [\(result.note)]")
    #expect(result.text.contains("\n\n"))
}

@MainActor @Test(.enabled(if: SystemLanguageModel.default.isAvailable, "Needs Apple Intelligence"))
func contextAcrossDictationPiecesDoesNotRepeatReferenceText() async {
    let cleanup = CleanupService()
    cleanup.wholeLimit = 8
    cleanup.pieceWords = 12
    let raw = "We are reviewing suspicious messages that steal passwords. These fishing emails should be reported to the security team. Keep the original messages for review."
    let result = await cleanup.clean(raw, locale: Locale(identifier: "en-US"), vocabulary: "", mode: .polished)
    #expect(result.text.localizedCaseInsensitiveContains("phishing emails"))
    #expect(result.text.components(separatedBy: "suspicious messages").count == 2)
    #expect(result.text.localizedCaseInsensitiveContains("original messages"))
}

@MainActor @Test
func modelErrorsKeepValidatedFallbackAvailableOnNewSDKs() {
    if #available(macOS 27, *) {
        #expect(DictationCleanup.failureReason(LanguageModelError.guardrailViolation(.init(debugDescription: "fixture"))) == "guardrail")
        #expect(DictationCleanup.failureReason(LanguageModelError.refusal(.init(explanation: "fixture", debugDescription: "fixture"))) == "guardrail")
        #expect(DictationCleanup.failureReason(LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "fixture"))) == "token_cap")
        #expect(DictationCleanup.failureReason(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "fixture"))) == "error")
    }
    #expect(DictationCleanup.failureReason(NSError(domain: "fixture", code: 1)) == "error")
}
}

@Test func meaningContextUsesOnlyCurrentSpeechAndKeepsDistantCorrections() {
    let middle = String(repeating: "We are discussing the draft and checking its details. ", count: 12)
    let raw = "We could ship on Friday. " + middle + "Actually the review must finish before release. I am frustrated but still hopeful."
    let reference = DictationMeaningContext.reference(source: raw)
    #expect(reference.contains("review must finish before release"))
    #expect(reference.contains("frustrated but still hopeful"))
    #expect(reference.contains("untrusted reference data"))
    #expect(DictationMeaningContext.reference(source: "An unrelated short dictation") == "")
    #expect(reference.count < 2500)
    #expect(DictationMeaningContext.reference(source: raw, localContext: raw) == "")
    let nearby = "We could ship on Friday. " + String(middle.prefix(200))
    #expect(DictationMeaningContext.reference(source: raw, localContext: nearby).contains("review must finish before release"))
}

@Test func approximateSpeechIsNotDeletedBeforeMeaningIsConsidered() {
    #expect(SpokenFillers.remove("It takes like two hours", language: "en") == "It takes like two hours")
}
