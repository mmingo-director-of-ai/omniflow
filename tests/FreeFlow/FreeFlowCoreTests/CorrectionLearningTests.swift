import Foundation
import Testing
@testable import OmniFlowApp

private func pair(_ raw: String, _ cleaned: String, _ final: String, id: UUID = UUID(), minutes: Double = 0) -> CorrectionPair {
    CorrectionPair(entryID: id, date: Date(timeIntervalSince1970: 1_000_000 + minutes * 60), raw: raw, cleaned: cleaned, final: final)
}
private let dictionary: @Sendable (String) -> Bool = { !["ics", "iocs", "omniflow", "kyube"].contains($0.lowercased()) }

@Test func wordDiffFindsSubstitutionsIgnoringCaseAndPunctuation() {
    let ops = WordDiff.align(WordDiff.words("Check the ICs table, then ship."), WordDiff.words("check the IOCs table then ship"))
    #expect(ops.contains(.change(from: ["ICs"], to: ["IOCs"])))
    #expect(ops.filter { if case .change = $0 { true } else { false } }.count == 1)
}

@Test func repeatedSubstitutionBecomesARuleAndATerm() {
    let pairs = [pair("table ICs will tell", "Table ICs will tell.", "Table IOCs will tell."),
                 pair("export the ICs today", "Export the ICs today.", "Export the IOCs today.")]
    let rules = CorrectionLearner.suggestions(from: pairs, isKnownWord: dictionary)
    let replacement = rules.first { $0.kind == .replacement }
    #expect(replacement?.from == "ICs" && replacement?.to == "IOCs" && replacement?.count == 2)
    #expect(replacement?.safeToAutoApply == true)
    #expect(rules.contains { $0.kind == .term && $0.to == "IOCs" })
}

@Test func aSingleDictationTeachesNothing() {
    #expect(CorrectionLearner.suggestions(from: [pair("table ICs", "Table ICs.", "Table IOCs.")], isKnownWord: dictionary).isEmpty)
}

@Test func editingTheSameDictationTwiceCountsOnce() {
    let id = UUID()
    let pairs = [pair("table ICs", "Table ICs.", "Table IOC.", id: id), pair("table ICs", "Table ICs.", "Table IOCs.", id: id, minutes: 5)]
    #expect(CorrectionLearner.suggestions(from: pairs, isKnownWord: dictionary).isEmpty)
}

@Test func numbersAndNegationFlipsAreNeverLearned() {
    let numbers = [pair("send two servers", "Send two servers.", "Send three servers."), pair("buy two cases", "Buy two cases.", "Buy three cases.")]
    #expect(CorrectionLearner.suggestions(from: numbers).isEmpty)
    let negation = [pair("we can ship it", "We can ship it.", "We can't ship it."), pair("you can merge", "You can merge.", "You can't merge.")]
    #expect(CorrectionLearner.suggestions(from: negation).isEmpty)
}

@Test func restoringAWordTheModelChangedLearnsATermNotAReplacement() {
    let pairs = [pair("deploy omniflow tonight", "Deploy overflow tonight.", "Deploy OmniFlow tonight."),
                 pair("open omniflow settings", "Open overflow settings.", "Open OmniFlow settings.")]
    let rules = CorrectionLearner.suggestions(from: pairs, isKnownWord: dictionary)
    #expect(!rules.contains { $0.kind == .replacement })
    #expect(rules.contains { $0.kind == .term && $0.to == "OmniFlow" })
}

@Test func commonWordRulesNeverApplyWithoutReview() {
    let pairs = [pair("rotate them to get her", "Rotate them to get her.", "Rotate them together."),
                 pair("ship it to get her", "Ship it to get her.", "Ship it together.")]
    let rule = CorrectionLearner.suggestions(from: pairs).first { $0.kind == .replacement }
    #expect(rule?.from == "to get her" && rule?.to == "together" && rule?.safeToAutoApply == false)
}

@Test func repeatedFillerRemovalBecomesAStyleSuggestion() {
    let pairs = [pair("it's like broken", "It's like broken.", "It's broken."), pair("we like need it", "We like need it.", "We need it.")]
    #expect(CorrectionLearner.suggestions(from: pairs).contains { $0.kind == .style && $0.from == "like" })
}

@MainActor @Test func decisionsStickAndOnlyListedRulesApply() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("learning-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(UserDefaults(suiteName: "learning-\(UUID().uuidString)"))
    let model = CorrectionLearningModel(store: CorrectionStore(directory: directory), defaults: defaults, isKnownWord: dictionary)
    #expect(model.mode == .review)
    model.record(entryID: UUID(), raw: "table ICs", cleaned: "Table ICs.", final: "Table IOCs.")
    model.record(entryID: UUID(), raw: "export ICs", cleaned: "Export ICs.", final: "Export IOCs.")
    let rule = try #require(model.suggestions.first { $0.kind == .replacement })
    #expect(model.status(of: rule) == .pending && model.applied.isEmpty)   // review mode applies nothing unaccepted
    model.reject(rule)
    model.record(entryID: UUID(), raw: "the ICs", cleaned: "The ICs.", final: "The IOCs.")
    #expect(model.status(of: rule) == .rejected)
    model.mode = .automatic
    #expect(!model.applied.contains { $0.id == rule.id })                  // rejected stays rejected
    #expect(model.learnedTerms.contains("IOCs"))                             // safe term applies automatically
    // Persisted, encrypted, and reloaded.
    let reloaded = CorrectionLearningModel(store: CorrectionStore(directory: directory), defaults: defaults, isKnownWord: dictionary)
    #expect(reloaded.pairCount == 3 && reloaded.status(of: rule) == .rejected)
    let stored = try Data(contentsOf: directory.appendingPathComponent("pairs.json"))
    #expect(OmniFlowVault.isSealed(stored))
    reloaded.clearAll()
    #expect(reloaded.pairCount == 0 && reloaded.listed.isEmpty)
}

@MainActor @Test func learningOffCapturesNothing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("learning-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(UserDefaults(suiteName: "learning-\(UUID().uuidString)"))
    let model = CorrectionLearningModel(store: CorrectionStore(directory: directory), defaults: defaults)
    model.mode = .off
    model.record(entryID: UUID(), raw: "a b", cleaned: "A b.", final: "A c.")
    #expect(model.pairCount == 0)
}

@Test func nearRewritesTeachNothing() {
    let pairs = [pair("one two three four five six seven eight", "Alpha beta gamma delta epsilon zeta eta theta.", "Completely different words written here by the user now."),
                 pair("nine ten eleven twelve", "Iota kappa lambda mu nu xi omicron pi.", "Completely different words written here by the user now.")]
    #expect(CorrectionLearner.suggestions(from: pairs).isEmpty)
}

@Test func learnedRulesJoinTheVocabularyAfterTheUsersOwn() {
    let vocabulary = DictationVocabulary(userVocabulary: "Kyube", replacements: [PhraseReplacement(phrase: "ICs", replacement: "IOC list")],
                                         learnedReplacements: [.init(from: "ICs", to: "IOCs"), .init(from: "get her", to: "together")],
                                         learnedTerms: ["Pergamon"])
    #expect(vocabulary.allTerms == ["Kyube", "IOC list", "Pergamon", "IOCs", "together"])
    // User rules come first, so they win an overlap with a learned rule.
    #expect(PhraseReplacements.apply("table ICs", rules: vocabulary.replacementRules) == "table IOC list")
}

@MainActor @Test func cleanupInstructionsAreUnchangedWithoutLearnedStyles() {
    let plain = DictationCleanup.instructions(structured: true, writingStyle: .technical, mode: .polished)
    #expect(plain == DictationCleanup.instructions(structured: true, writingStyle: .technical, mode: .polished, preferences: []))
    let styled = DictationCleanup.instructions(structured: true, writingStyle: .technical, mode: .polished, preferences: ["Remove “like” when it is filler"])
    #expect(styled.hasPrefix(plain) && styled.contains("learned from their own corrections: Remove “like” when it is filler."))
}
