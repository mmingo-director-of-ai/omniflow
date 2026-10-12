import Foundation
import Testing
@testable import OmniFlowApp

@Test func polishModesPreserveVerbatimAndResolveRestarts() {
    let raw = "Um, we need we need two servers, sorry, three servers."
    #expect(PolishMode.verbatim.prepare(raw, language: "en") == raw)
    #expect(PolishMode.light.prepare(raw, language: "en").localizedCaseInsensitiveContains("we need we need"))
    #expect(PolishMode.polished.prepare(raw, language: "en") == "We need three servers.")
    #expect(PolishMode.polished.prepare("I don't I don't want to deploy.", language: "en") == "I don't want to deploy.")
}
@Test func restartCleanupProtectsLiteralsAndEmphasis() {
    for raw in ["Keep `we need we need` exactly.", "Say \"we need we need\".", "It is very very important.", "I know that that works.", "Use RFC-2 and code 007."] {
        #expect(PolishMode.polished.prepare(raw, language: "en") == raw)
    }
    #expect(PolishMode.polished.prepare("wir brauchen wir brauchen zwei", language: "de") == "wir brauchen wir brauchen zwei")
}

@Test func explicitRepeatedClauseKeepsFinalName() {
    #expect(PolishMode.polished.prepare("Send it to Sarah, sorry, send it to Jane. Keep Friday.", language: "en") == "Send it to Jane. Keep Friday.")
    #expect(PolishMode.polished.prepare("Contact Alice Smith, actually, contact Bob Jones.", language: "en") == "Contact Bob Jones.")
    #expect(PolishMode.polished.prepare("Quote \"Send it to Sarah, sorry, send it to Jane\".", language: "en") == "Quote \"Send it to Sarah, sorry, send it to Jane\".")
}

@Test func spokenStatusCodesRequireNetworkAndLocalResponseContext() {
    #expect(PolishMode.technicalStatusCodes("The API is returning a for oh four. It should be a for oh one.") == "The API is returning a 404. It should be a 401.")
    #expect(PolishMode.technicalStatusCodes("The server returned five oh three.") == "The server returned 503.")
    for text in ["I waited for oh four hours.", "The API exists. I waited for oh four hours.",
                 "Keep \"HTTP four oh four\" as the label.", "Use `HTTP four oh four`.",
                 "The API failed.\n\nIt should be a for oh one.", "Call four oh four tomorrow."] {
        #expect(PolishMode.technicalStatusCodes(text) == text)
    }
}

@Test func explicitCorrectionsDoNotDependOnRecognizerPunctuation() {
    #expect(SpeechCorrections.resolve("schedule it for tuesday no wait wednesday afternoon") == "schedule it for wednesday afternoon")
    #expect(SpeechCorrections.resolve("we need two no sorry three more servers") == "we need three more servers")
    #expect(SpeechCorrections.resolve("I will handle the review actually Priya will handle the review and I will send the summary.") == "Priya will handle the review and I will send the summary.")
    for text in ["I will handle the review actually Priya will handle the review too.",
                 "Keep \"two no sorry three\".", "two people wait three hours", "Monday we meet Tuesday we travel"] {
        #expect(SpeechCorrections.resolve(text) == text)
    }
    #expect(PolishMode.separateTopics("The date is undecided. Back to the budget, keep a reserve.").contains("\n\nBack to"))
}

@Test func incompletePrepositionRestartsAreRemovedWithoutLosingEmphasis() {
    #expect(PolishMode.polished.prepare("within our within our setup", language: "en") == "within our setup")
    #expect(PolishMode.polished.prepare("in the in the next release", language: "en") == "in the next release")
    for literal in ["very very important", "in our hearts in our hearts", "Keep \"within our within our\"."] {
        #expect(PolishMode.polished.prepare(literal, language: "en") == literal)
    }
}

@Test func contextualPhrasesPreservePeoplePrepositionsAndLiterals() {
    #expect(PolishMode.contextualPhrases("Rotate the keys to get her with the certificates.") == "Rotate the keys together with the certificates.")
    #expect(PolishMode.contextualPhrases("These components fit to get her in the enclosure.") == "These components fit together in the enclosure.")
    #expect(PolishMode.contextualPhrases("Go to the store to so we can buy coffee.") == "Go to the store too so we can buy coffee.")
    #expect(PolishMode.contextualPhrases("Send the summary to the designers to so they can review it.").contains("designers too"))
    for text in ["Drive to get her with Maya.", "Priya needs a ride, so go to get her.",
                 "Which report should I refer to so we can agree?", "Who should I listen to so I understand?",
                 "Go to the person I speak to so we can agree.", "Keep \"components fit to get her\".", "Use `parts fit to get her`."] {
        #expect(PolishMode.contextualPhrases(text) == text)
    }
    #expect(PolishMode.light.prepare("components fit to get her", language: "en") == "components fit to get her")
}

@Test func brokenConclusionKeepsUncertaintyAndContrast() {
    let source = "So replacing the cable. Instead of the dock, maybe the next step."
    #expect(PolishMode.repairConclusionFragments(source) == "So replacing the cable instead of the dock may be the next step.")
    for text in ["Replacing the cable worked. Instead of the dock, maybe the next step.",
                 "Keep \"So replacing the cable. Instead of the dock, maybe the next step.\"",
                 "We could replace the cable or the dock.", "Switching to USB may be the fix."] {
        #expect(PolishMode.repairConclusionFragments(text) == text)
    }
}

@Test func apiSpellingRequiresContextAndProtectsAlternativesAndLiterals() {
    #expect(PolishMode.speechAPISpelling("The wrong API. Switching to speech, transcription or transcriber instead of diction transcriber.") == "The wrong API. Switching to SpeechTranscriber instead of DictationTranscriber.")
    for text in ["Discuss speech transcription or transcriber metadata in this API.",
                 "Her diction transcriber is helpful.", "The API docs say \"speech transcriber\".",
                 "The API docs use `diction transcriber`."] {
        #expect(PolishMode.speechAPISpelling(text) == text)
    }
}

@Test func developedExplanationSeparatesConcludingFix() {
    let explanation = "I thought the microphone was causing our transcription problems. We tested the connection and the input settings, but the results suggest that the recognition API was the issue."
    #expect(PolishMode.separateConclusions(explanation + " Switching to SpeechTranscriber may be the key here.") == explanation + "\n\nSwitching to SpeechTranscriber may be the key here.")
    for text in ["We tested it. Switching to USB may be the fix.",
                 explanation + " So we tested the microphone again.",
                 explanation + "\n\nSwitching to SpeechTranscriber may be the key here.",
                 explanation + " \"Switching to USB may be the fix.\""] {
        #expect(PolishMode.separateConclusions(text) == text)
    }
}
