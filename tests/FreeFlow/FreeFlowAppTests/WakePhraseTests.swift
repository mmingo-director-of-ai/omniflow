import Testing
@testable import OmniFlowApp

@Test(arguments: ["Omni", "Hey Omni", "Hey, Omni", "HEY—OMNI", "hey. omni"])
func omniWakeKeepsTheSpokenRequest(_ greeting: String) {
    #expect(WakePhrase.command(in: greeting + ", what time is it?") == "what time is it?")
    #expect(WakePhrase.command(in: greeting) == "")
}

@Test(arguments: ["omnipresent", "omnibus", "OmniFlow", "Hey NotchLee", "Notch Lee", "show my memory"])
func unrelatedWordsDoNotActivateOmni(_ text: String) {
    #expect(WakePhrase.command(in: text) == nil)
}
