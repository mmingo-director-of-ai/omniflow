import Foundation
import Testing
@testable import OmniFlowApp

@Test func dictationVocabularyMergesUserTermsPacksAndReplacementTargets() {
    let vocabulary = DictationVocabulary(userVocabulary: "Pergamon\nmy term\n", enabledPacks: [.security],
        replacements: [PhraseReplacement(phrase: "ICs", replacement: "IOCs"), PhraseReplacement(phrase: "nb", replacement: "NotebookLM"),
                       PhraseReplacement(phrase: "off", replacement: "Ignored", enabled: false)])
    #expect(vocabulary.allTerms.prefix(2) == ["Pergamon", "my term"])
    #expect(vocabulary.allTerms.contains("MITRE ATT&CK") && vocabulary.allTerms.contains("NotebookLM"))
    #expect(vocabulary.allTerms.filter { $0.lowercased() == "pergamon" || $0 == "IOCs" }.count == 2)
    #expect(!vocabulary.allTerms.contains("Ignored"))
    #expect(DictationVocabulary(userVocabulary: "mine").text == "mine")
    #expect(VocabularyPack.security.preferenceKey == "omniflow.vocabularyPack.security")
}

@Test func dictationVocabularyReadsTheSavedPreferences() throws {
    let defaults = try #require(UserDefaults(suiteName: "DictationVocabularyTests"))
    defaults.removePersistentDomain(forName: "DictationVocabularyTests")
    defaults.set("Kyube", forKey: DictationVocabulary.userTermsKey)
    defaults.set(true, forKey: VocabularyPack.security.preferenceKey)
    defaults.set(try JSONEncoder().encode([PhraseReplacement(phrase: "ICs", replacement: "IOCs")]), forKey: DictationVocabulary.replacementsKey)
    let vocabulary = DictationVocabulary.current(defaults)
    #expect(vocabulary.userTerms == ["Kyube"] && vocabulary.enabledPacks == [.security])
    #expect(vocabulary.replacements == [.init(from: "ICs", to: "IOCs")])
    defaults.removePersistentDomain(forName: "DictationVocabularyTests")
}

@Test func replacementsFixKnownMishearingsBeforeCleanup() {
    let rules = [PhraseReplacement(phrase: "ICs", replacement: "IOCs"),
                 PhraseReplacement(phrase: "to get her badge", replacement: "together, the badge")]
    #expect(PhraseReplacements.apply("table facts will table ICs will tell to get her badge system", rules: rules)
            == "table facts will table IOCs will tell together, the badge system")
    #expect(PhraseReplacements.apply("Track the IOCs together, the badge system.", rules: rules) == "Track the IOCs together, the badge system.")
}
