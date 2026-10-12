import Foundation

import Testing
@testable import OmniFlowApp

@Test func fillerHedgesAreRemovedButMeaningfulNegationStays() {
    #expect(SpokenFillers.remove("go to like a I don't know what we call it but some kind of meter bar", language: "en")
            == "go to like a some kind of meter bar")
    #expect(SpokenFillers.remove("findings tables from like you know investigations", language: "en") == "findings tables from investigations")
    // Not filler: a real statement of not knowing, and other languages.
    #expect(SpokenFillers.remove("I don't know if we should deploy.", language: "en") == "I don't know if we should deploy.")
    #expect(SpokenFillers.remove("I don't know what we call it", language: "de") == "I don't know what we call it")
}

@Test func negationGuardIgnoresOnlyTheFillerHedge() {
    let raw = "Use a, I don't know what we call it, meter bar for the session."
    #expect(CleanupPolicy.accept(raw: raw, candidate: "Use a meter bar for the session.") != nil)
    // Dropping a real "don't" still fails.
    #expect(CleanupPolicy.accept(raw: "I don't know if we should deploy today.", candidate: "We should deploy today.") == nil)
    #expect(CleanupPolicy.accept(raw: "Do not deploy, I don't know what we call it, the hotfix.", candidate: "Deploy the hotfix.") == nil)
}

@Test func coverageRejectsSummariesButAllowsFillerRemovalAndFixes() {
    let raw = "so we can take all the lessons learned across the projects and revamp those skills and wire them into the second brain properly"
    let cleaned = "We can take all the lessons learned across the projects, revamp those skills and wire them into the second brain properly."
    let summary = "Revamp those skills and wire them in properly, as discussed earlier on."
    #expect(ContentCoverage.fraction(source: raw, edited: cleaned) > 0.95)
    #expect(CleanupPolicy.evaluate(raw: raw, candidate: summary, requireCoverage: true) == .failure(.contentDropped))
    #expect((try? CleanupPolicy.evaluate(raw: raw, candidate: cleaned, requireCoverage: true).get()) != nil)
    // Coverage is opt-in: chart formatting rewrites prose into data.
    #expect(CleanupPolicy.evaluate(raw: raw, candidate: "Learned lessons across the projects; revamp skills.", requireCoverage: false) != .failure(.contentDropped))
}

@Test func shortDictationsStayWholeAndLongOnesSplitAtBoundaries() {
    let short = Array(repeating: "word", count: 120).joined(separator: " ")
    #expect(DictationChunker.chunks(short) == [short])
    let sentence = "We should wire the status bar into the new panel today."   // 11 words
    let long = Array(repeating: sentence, count: 60).joined(separator: " ")   // 660 words
    let chunks = DictationChunker.chunks(long)
    #expect(chunks.count >= 2)
    #expect(chunks.allSatisfy { $0.hasSuffix(".") })
    #expect(chunks.joined(separator: " ") == long)
    // A run-on with no sentence ends still splits, before a discourse marker.
    let runOn = Array(repeating: "we wire the panel and then we revamp the bar so it looks right", count: 40).joined(separator: " ")
    let pieces = DictationChunker.chunks(runOn)
    #expect(pieces.count >= 2 && pieces.joined(separator: " ") == runOn)
    #expect(pieces.dropFirst().allSatisfy { ["so", "and", "then", "we"].contains(String($0.split(separator: " ")[0])) })
}

@Test func joinedPiecesContinueLowercaseFragments() {
    #expect(DictationChunker.join(["It shows amplifying information.", "so the main view stays clear."], structured: false)
            == "It shows amplifying information so the main view stays clear.")
    // The model capitalizes a piece cut mid-sentence; the source says it continues.
    #expect(DictationChunker.join(["We track ICs.", "Tell all the stuff."], sources: ["we track ICs", "tell all the stuff"], structured: false)
            == "We track ICs tell all the stuff.")
    #expect(DictationChunker.join(["First part.", "Second part.  \nSame line."], sources: ["first part.", "second part"], structured: false)
            == "First part. Second part. Same line.")
}

@Test func droppingANounIsRejectedEvenWhenTheWordAppearsElsewhere() {
    let raw = "Claude is released mods like two days ago so let's start building mods to replace the plug-in system."
    let dropped = "Claude is released two days ago, so let's start building mods to replace the plug-in system."
    #expect(ContentTerms.missing(source: raw, candidate: dropped) == ["mods"])
    #expect(CleanupPolicy.evaluate(raw: raw, candidate: dropped, requireCoverage: true) == .failure(.contentDropped))
    let kept = "Claude released mods two days ago, so let's start building mods to replace the plug-in system."
    #expect(ContentTerms.missing(source: raw, candidate: kept).isEmpty)
    #expect((try? CleanupPolicy.evaluate(raw: raw, candidate: kept, requireCoverage: true).get()) != nil)
}

@Test func contentTermsAreLemmaTolerantAndIgnoreFillerNouns() {
    #expect(ContentTerms.missing(source: "We need the mod for this stuff.", candidate: "We need the mods.").isEmpty)
    #expect(ContentTerms.missing(source: "Fix it within our set up.", candidate: "Fix it within our setup.").isEmpty)
    // Names and glossary terms count even when the tagger calls them something else.
    #expect(ContentTerms.missing(source: "Ask Sarah about the EDR rollout.", candidate: "Ask about the rollout.", vocabulary: "EDR") == ["edr", "sarah"])
    // An accidental immediate repeat may be removed.
    #expect(ContentTerms.missing(source: "Open the table table now.", candidate: "Open the table now.").isEmpty)
}

@Test func technicalStyleKeepsIdiomaticOne() {
    #expect(WritingStyle.technical.format("One of the first things is the bar.") == "One of the first things is the bar.")
    #expect(WritingStyle.technical.format("Pick this one and no one else.") == "Pick this one and no one else.")
    #expect(WritingStyle.technical.format("Restart one server and two workers.") == "Restart 1 server and 2 workers.")
}

@Test func namesAndGlossaryTermsTheSpeakerNeverSaidAreRejected() {
    let raw = "We can take all the lessons learned across the projects and revamp those skills."
    let invented = "We can take all the lessons learned across the OmniFlow project and revamp those skills."
    #expect(ContentTerms.added(source: raw, candidate: invented, vocabulary: "OmniFlow; MCP") == ["omniflow"])
    #expect(CleanupPolicy.evaluate(raw: raw, candidate: invented, requireCoverage: true, vocabulary: "OmniFlow; MCP") == .failure(.contentAdded))
    // Example words leaking into the edit are inserted nouns too.
    #expect(ContentTerms.added(source: "I want to introduce a right panel", candidate: "I want to introduce a settings page right panel.") == ["page", "settings"])
    #expect(ContentTerms.added(source: "ask sarah about omniflow", candidate: "Ask Sarah about OmniFlow.", vocabulary: "OmniFlow").isEmpty)
}

@Test func approximateLikeBeforeAQuantityPreservesUncertainty() {
    #expect(SpokenFillers.remove("Claude released mods like two days ago", language: "en") == "Claude released mods like two days ago")
    #expect(SpokenFillers.remove("it took like 5 minutes", language: "en") == "it took like 5 minutes")
    #expect(SpokenFillers.remove("it looks like two people", language: "en") == "it looks like two people")
    #expect(SpokenFillers.remove("I like two of them", language: "en") == "I like two of them")
}

@Test func longDictationKeepsBlankLineParagraphs() {
    let first = String(repeating: "The release passed its tests. ", count: 12).trimmingCharacters(in: .whitespaces)
    let second = String(repeating: "The meeting starts on Monday. ", count: 12).trimmingCharacters(in: .whitespaces)
    let pieces = DictationChunker.chunks(first + "\n\n" + second)
    let joined = DictationChunker.join(pieces, sources: pieces, structured: false)
    #expect(joined == first + "\n\n" + second)
    #expect(DictationChunker.join(["First topic.  \n\nSecond topic."], structured: false) == "First topic.\n\nSecond topic.")
}

@MainActor @Test func nearbyDictationContextIsBoundedAndSeparateFromEditableText() {
    let prompt = DictationCleanup.prompt(for: "These fishing emails need review.", vocabulary: "",
        locale: Locale(identifier: "en-US"), spelling: nil,
        preceding: String(repeating: "x", count: 2000) + " We are discussing password theft.",
        following: "Keep the suspicious messages." + String(repeating: "y", count: 1000))
    #expect(prompt.contains("password theft"))
    #expect(prompt.contains("context only"))
    #expect(!prompt.contains(String(repeating: "x", count: 1001)))
    #expect(!prompt.contains(String(repeating: "y", count: 501)))
    let editable = prompt.components(separatedBy: "Edit the speech between the tags below.").last ?? ""
    #expect(editable.contains("These fishing emails need review."))
    #expect(!editable.contains("password theft"))
}

@Test func contextualHomophoneEditsAndParagraphsPassValidation() {
    let raw = "These fishing emails steal passwords. Separately book the meeting room."
    let edited = "These phishing emails steal passwords.\n\nSeparately, book the meeting room."
    let result = RewriteValidation.validate(source: raw, rewrite: edited, vocabulary: [])
    #expect(result.text == edited)
    #expect(result.refused.isEmpty)
}

@Test func brokenAuxiliaryGrammarCanBeRepairedWithoutLosingTheClause() {
    let fixed = RewriteValidation.validate(source: "The team have finish the review yesterday.",
        rewrite: "The team finished the review yesterday.", vocabulary: [])
    #expect(fixed.text == "The team finished the review yesterday.")
    #expect(fixed.refused.isEmpty)
    #expect(EditValidator.validate(.init(original: "could ship", replacement: "shipped", kind: "grammar"), vocabulary: []) == .refused("meaning"))
}

@Test func explicitTopicParagraphsPreserveLiteralsAndRelatedSentences() {
    #expect(PolishMode.separateTopics("The tests passed. Separately, book the room.") == "The tests passed.\n\nSeparately, book the room.")
    #expect(PolishMode.separateTopics("The tests passed. We can release.") == "The tests passed. We can release.")
    let quoted = "Keep \"First. Separately, second.\" exactly."
    #expect(PolishMode.separateTopics(quoted) == quoted)
    let code = "`First. Separately, second.`"
    #expect(PolishMode.separateTopics(code) == code)
}

@Test func securitySpellingNeedsContextAndProtectsLiteralFishing() {
    let security = "We are reviewing suspicious messages that steal passwords. These fishing emails need review."
    #expect(PolishMode.contextualSpelling(security) == security.replacingOccurrences(of: "fishing emails", with: "phishing emails"))
    for unchanged in [
        "Read the fishing emails.",
        "The fishing emails include my account password.",
        "The fishing emails describe our lake trip and contain the account password.",
        "Suspicious messages steal passwords.\n\nRead the fishing emails.",
        "Keep the phrase \"fishing emails\" in this suspicious message.",
        "Keep `fishing emails` in this suspicious message.",
        "The fishing trip starts Saturday. Report suspicious messages."
    ] {
        #expect(PolishMode.contextualSpelling(unchanged) == unchanged)
    }
    #expect(PolishMode.contextualSpelling("SUSPICIOUS FISHING EMAILS") == "SUSPICIOUS PHISHING EMAILS")
}
