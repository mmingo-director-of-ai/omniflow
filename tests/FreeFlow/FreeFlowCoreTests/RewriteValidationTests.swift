import Testing
@testable import OmniFlowApp

@Test func mishearingsSoundAlike() {
    for (heard, meant) in [("their", "there"), ("to get her", "together"), ("cloud code", "Claude Code"), ("ICs", "IOCs"),
                           ("weather", "whether"), ("by", "buy"), ("a head", "ahead"), ("break", "broke"), ("its", "it's")] {
        #expect(PhoneticKey.soundsAlike(heard, meant), "\(heard) / \(meant): \(PhoneticKey.key(heard)) vs \(PhoneticKey.key(meant))")
    }
}

@Test func differentWordsDoNotSoundAlike() {
    for (a, b) in [("Tuesday", "Wednesday"), ("Sarah", "Priya"), ("staging", "production"), ("deploy", "delete"), ("left", "right")] {
        #expect(!PhoneticKey.soundsAlike(a, b), "\(a) / \(b): \(PhoneticKey.key(a)) vs \(PhoneticKey.key(b))")
    }
}

@Test func editValidatorAllowsFixesAndRefusesMeaningChanges() {
    func verdict(_ original: String, _ replacement: String, _ kind: String = "mishearing") -> Bool {
        if case .accepted = EditValidator.validate(ProposedEdit(original: original, replacement: replacement, kind: kind), vocabulary: ["IOCs"]) { return true }
        return false
    }
    #expect(verdict("to get her", "together"))
    #expect(verdict("table ICs", "table IOCs"))
    #expect(verdict("the plan sarah", "the plan. Sarah", "punctuation"))
    #expect(verdict("so um basically", "", "filler"))
    #expect(verdict("tuesday no wait wednesday", "Wednesday", "selfcorrection"))
    #expect(verdict("reports was", "reports were", "grammar"))
    #expect(!verdict("do not delete", "delete", "grammar"))           // negation
    #expect(!verdict("two servers", "three servers", "grammar"))      // number without a cue
    #expect(!verdict("tell Priya", "tell Sarah"))                      // name without sound support
    #expect(!verdict("deploy to staging", "deploy to production"))    // meaning
}

@Test func rewriteValidationKeepsFixesAndRevertsMeaningChanges() {
    let source = "put the files over their and we ship on tuesday"
    let result = RewriteValidation.validate(source: source, rewrite: "Put the files over there, and we ship on Wednesday.", vocabulary: [])
    // The homophone fix stays; the changed day takes its clause back to what was said.
    #expect(result.text == "Put the files over there, and we ship on tuesday.")
    #expect(result.counts["accepted.sound"] == 1 && result.counts["refused.meaning"] == 1 && result.revertedClauses == 1)
}

@Test func aRevertedStretchNeverLeavesAHalfEditedClause() {
    // The model replaced a needed verb; reverting only that word would read "We need the team needs…".
    let source = "we need to the team needs to finish the rollout"
    let result = RewriteValidation.validate(source: source, rewrite: "We need the team to finish the rollout.", vocabulary: [])
    #expect(result.text == "We need to the team needs to finish the rollout.")
}

@Test func rewriteValidationPreservesMarkdownAndRetractions() {
    let list = RewriteValidation.validate(source: "we need milk eggs and bread", rewrite: "We need:\n- milk\n- eggs\n- bread", vocabulary: [])
    #expect(list.text == "We need:\n- milk\n- eggs\n- bread.")
    let scratch = RewriteValidation.validate(source: "send the invoice today scratch that send it on monday",
                                             rewrite: "Send the invoice today. Scratch that. Send it on Monday.", vocabulary: [])
    #expect(scratch.text == "Send it on Monday.")
    // The model dropped only the cue and kept the retracted sentence.
    let cueOnly = RewriteValidation.validate(source: "send the invoice today scratch that send it on monday",
                                             rewrite: "Send the invoice today. Send it on Monday.", vocabulary: [])
    let unpunctuated = RewriteValidation.validate(source: "send the invoice today scratch that send it on monday",
                                                  rewrite: "send the invoice today scratch that send it on monday", vocabulary: [])
    #expect(unpunctuated.text == "Send it on monday.")
    // "Scratch that itch" is not a cue.
    #expect(RewriteValidation.validate(source: "i need to scratch that itch now", rewrite: "I need to scratch that itch now.", vocabulary: []).text == "I need to scratch that itch now.")
    #expect(RewriteValidation.validate(source: "scratch that itch now", rewrite: "Scratch that itch now.", vocabulary: []).text == "Scratch that itch now.")
    // The clause comes back as spoken; `ProperNouns` capitalizes the day afterwards.
    #expect(cueOnly.text == "Send it on monday.")
}

@Test func spelledLettersCollapseOnlyIntoVocabularyTerms() {
    #expect(RewriteValidation.collapseSpelledTerms("write a k q l query", vocabulary: ["KQL"]) == "write a KQL query")
    #expect(RewriteValidation.collapseSpelledTerms("check the i o c s", vocabulary: ["IOCs"]) == "check the IOCs")
    #expect(RewriteValidation.collapseSpelledTerms("write a k q l query", vocabulary: []) == "write a k q l query")
    #expect(RewriteValidation.collapseSpelledTerms("i a m here", vocabulary: ["KQL"]) == "i a m here")
}

@Test func multiWordTermsMatchBySound() {
    #expect(RewriteValidation.matchSpokenTerms("ask cloud code to run it.", vocabulary: ["Claude Code"]) == "ask Claude Code to run it.")
    #expect(RewriteValidation.matchSpokenTerms("deploy to the cloud today", vocabulary: ["Claude Code", "Claude"]) == "deploy to the cloud today")
}

@Test func vocabularyTermsAreNeverRewrittenAway() {
    #expect(EditValidator.validate(ProposedEdit(original: "KQL query", replacement: "SQL query", kind: "rewrite"), vocabulary: ["KQL"]) == .refused("vocabulary"))
}

@MainActor @Test func properNounsAreCapitalized() {
    #expect(ProperNouns.capitalize("Tell priya and jamal the demo moved to wednesday.", vocabulary: []) == "Tell Priya and Jamal the demo moved to Wednesday.")
    #expect(ProperNouns.capitalize("Ask claude code to run the kql query.", vocabulary: ["Claude Code", "KQL"]) == "Ask Claude Code to run the KQL query.")
    #expect(ProperNouns.capitalize("I will mark the bug as fixed.", vocabulary: []) == "I will mark the bug as fixed.")
    #expect(ProperNouns.capitalize("Rework the tools and also wire them via the toolbar.", vocabulary: []) == "Rework the tools and also wire them via the toolbar.")
}

@Test func aContractionSaidAsOneWordStaysContracted() {
    #expect(RewriteValidation.validate(source: "check if there ready", rewrite: "Check if they are ready.", vocabulary: []).text == "Check if they're ready.")
    #expect(RewriteValidation.validate(source: "she don't think so", rewrite: "She does not think so.", vocabulary: []).text == "She doesn't think so.")
    // Two spoken words stay two words.
    #expect(RewriteValidation.validate(source: "it is fine", rewrite: "It is fine.", vocabulary: []).text == "It is fine.")
}

@Test func vocabularyNormalizationPreservesLiteralsAndOpeningPunctuation() {
    for text in ["Keep \"cloud code\" unchanged", "Use `cloud code`", "```text\ncloud code\n```", "Keep ‘cloud code’ as written"] {
        #expect(RewriteValidation.matchSpokenTerms(text, vocabulary: ["Claude Code"]) == text)
    }
    for text in ["Keep \"k q l\" unchanged", "Use `k q l`", "```text\nk q l\n```", "~~~text\nk q l\n~~~"] {
        #expect(RewriteValidation.collapseSpelledTerms(text, vocabulary: ["KQL"]) == text)
    }
    #expect(RewriteValidation.matchSpokenTerms("Ask (cloud code) today.", vocabulary: ["Claude Code"]) == "Ask (Claude Code) today.")
}

@Test func cleanupPreservesModalityConditionsAndPriority() {
    for (raw, changed) in [("we could ship", "we will ship"), ("we can ship", "we ship"),
                           ("ship only after review", "ship before review"), ("maybe ship", "ship"),
                           ("probably ready", "ready"), ("actually we could ship", "we will ship")] {
        #expect(EditValidator.validate(.init(original: raw, replacement: changed, kind: "rewrite"), vocabulary: []) == .refused("meaning"))
    }
    #expect(EditValidator.meaningAnchors("We'll ship if they can't reproduce it") == ["will", "if", "can"])
    let inserted = RewriteValidation.validate(source: "We ship tomorrow", rewrite: "We will ship tomorrow.", vocabulary: [])
    #expect(!inserted.text.contains("will"))
    #expect(EditValidator.validate(.init(original: "We could ship, actually we will ship", replacement: "we will ship", kind: "rewrite"), vocabulary: []) == .accepted("selfcorrection"))
}

@Test func refusedTailDeletionDoesNotCreateAFusedFragment() {
    let result = RewriteValidation.validate(source: "Do the crash fix first and the export later.",
                                            rewrite: "Do the crash fix first, then the export.", vocabulary: [])
    #expect(result.text.contains("export later"))
    #expect(!result.text.contains("export.later"))
    let connector = RewriteValidation.validate(source: "We can retain the system but I think we should soften the edges.",
                                               rewrite: "We can replace the system. I think we should soften the edges.", vocabulary: [])
    #expect(!connector.text.contains("but."))
}

@Test func omittedSentenceDoesNotUndoNextSentencesGrammar() {
    let result = RewriteValidation.validate(source: "OK now let's do this. Acme is released widgets two days ago.",
        rewrite: "Acme released widgets two days ago.", vocabulary: ["Acme"])
    #expect(result.text.contains("OK now let's do this."))
    #expect(result.text.contains("Acme released"))
    #expect(!result.text.contains("is released"))
    let tail = RewriteValidation.validate(source: "The report is ready. Do not send it.", rewrite: "The report is ready.", vocabulary: [])
    #expect(tail.text.contains("ready. Do not send it."))
    let middle = RewriteValidation.validate(source: "We have finish the review. Do not send it. Acme is released widgets yesterday.",
        rewrite: "We finished the review. Acme released widgets yesterday.", vocabulary: ["Acme"])
    #expect(middle.text.contains("We finished the review. Do not send it. Acme released widgets yesterday."))
}

@Test func additiveTooCannotBeDroppedAsAnEmptyFunctionWord() {
    #expect(EditValidator.validate(.init(original: "too", replacement: "", kind: "rewrite"), vocabulary: []) == .refused("meaning"))
    let result = RewriteValidation.validate(source: "I want to go to the store too so we can buy coffee.", rewrite: "I want to go to the store so we can buy coffee.", vocabulary: [])
    #expect(result.text.contains("store too"))
}
