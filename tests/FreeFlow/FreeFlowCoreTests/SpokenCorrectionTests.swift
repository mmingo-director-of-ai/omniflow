import Testing
@testable import OmniFlowApp

@Test func spokenSelfCorrectionsKeepTheFinalDetail() {
    #expect(SpeechCorrections.resolve("Meet on Tuesday, no wait, Wednesday.") == "Meet on Wednesday.")
    #expect(SpeechCorrections.resolve("Meet on Tuesday, wait, Wednesday.") == "Meet on Wednesday.")
    #expect(SpeechCorrections.resolve("Use red, I meant blue paint.") == "Use blue paint.")
    #expect(SpeechCorrections.resolve("Send 2, no wait, 3 servers tomorrow.") == "Send 3 servers tomorrow.")
    #expect(SpeechCorrections.resolve("Turn left, no, I mean right at the gate.") == "Turn right at the gate.")
}

@Test func scratchThatRetractsWhatCameBefore() {
    #expect(SpeechCorrections.resolve("Ship it today. Scratch that. Ship it Monday.") == "Ship it Monday.")
    #expect(SpeechCorrections.resolve("We ship today, scratch that, we ship Monday.") == "We ship Monday.")
    #expect(SpeechCorrections.resolve("Call Sam. Book the room. Strike that. Email the team.") == "Call Sam. Email the team.")
    // Not a cue: part of an ordinary sentence.
    #expect(SpeechCorrections.resolve("Scratch that itch later.") == "Scratch that itch later.")
    #expect(SpeechCorrections.resolve("I want to forget that meeting.") == "I want to forget that meeting.")
}
