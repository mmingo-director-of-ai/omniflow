import Foundation
import Testing
@testable import OmniFlowApp

@Test func removesUnambiguousEnglishFillers() {
    #expect(SpeechDisfluencies.clean("Close at, um, the pill options for Miter, Atlas, and Miter Defend.", language: "en") == "Close at the pill options for Miter, Atlas, and Miter Defend.")
    #expect(SpeechDisfluencies.clean("Um, do not deploy. Uh, keep two servers.", language: "en") == "Do not deploy. Keep two servers.")
    #expect(SpeechDisfluencies.clean("We should uh keep it.", language: "en") == "We should keep it.")
}
@Test func fillerCleanupPreservesLiteralAndMeaningfulText() {
    for input in ["Keep `um` and \"uh\" exactly.", "Use /tmp/um and um_value and UM.", "~~~text\num, uh\n~~~", "Um is a quoted token: 'um'.", "I like it, you know the answer, and it is well made."] {
        #expect(SpeechDisfluencies.clean(input, language: "en") == input)
    }
    #expect(SpeechDisfluencies.clean("Wir fahren um acht.", language: "de") == "Wir fahren um acht.")
    #expect(SpeechDisfluencies.clean("um, um", language: "en") == "um, um")
}

@Test func explicitTerminologyRulesFollowFillerCleanupWithoutCascading() {
    let input = "Close at, um, the pill options for Miter, Atlas, and Miter Defend."
    let rules: [PhraseReplacement] = [
        .init(phrase: "Miter, Atlas, and Miter Defend", replacement: "MITRE ATT&CK, ATLAS, and MITRE D3FEND"),
        .init(phrase: "Miter", replacement: "MITRE"),
        .init(phrase: "Miter Defend", replacement: "MITRE D3FEND")
    ]
    let cleaned = SpeechDisfluencies.clean(input, language: "en")
    #expect(PhraseReplacements.apply(cleaned, rules: rules) == "Close at the pill options for MITRE ATT&CK, ATLAS, and MITRE D3FEND.")
    #expect(PhraseReplacements.apply("Miter is an organization.", rules: rules) == "MITRE is an organization.")
}
