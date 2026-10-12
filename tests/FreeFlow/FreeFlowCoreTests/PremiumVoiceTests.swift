import Testing
@testable import OmniFlowApp

private let lee = SpeechVoiceInfo(id: "lee", name: "Lee", language: "en-AU", isPremium: true)
private let ava = SpeechVoiceInfo(id: "ava", name: "Ava", language: "en-US", isPremium: true)
private let amelie = SpeechVoiceInfo(id: "amelie", name: "Amélie", language: "fr-CA", isPremium: true)
private let compact = SpeechVoiceInfo(id: "samantha", name: "Samantha", language: "en-US", isPremium: false)
/// Enhanced quality is not Premium and is excluded too.
private let enhanced = SpeechVoiceInfo(id: "lee-enhanced", name: "Lee", language: "en-AU", isPremium: false)
private let personal = SpeechVoiceInfo(id: "me", name: "My Voice", language: "en-US", isPremium: false, isPersonal: true)
private let novelty = SpeechVoiceInfo(id: "bells", name: "Bells", language: "en-US", isPremium: true, isExcluded: true)

@Test func allInstalledVoiceQualitiesAreOffered() {
    let voices = [compact, enhanced, amelie, novelty, lee, ava, personal]
    #expect(Set(PremiumSpeechVoices.available(voices).map(\.id)) == Set(voices.map(\.id)))
    for voice in voices {
        #expect(PremiumSpeechVoices.preferred(in: voices, replyLanguage: nil, selectedID: voice.id)?.id == voice.id)
    }
    #expect(PremiumSpeechVoices.preferred(in: [], replyLanguage: nil, selectedID: nil) == nil)
}

@Test func replyLanguageChoosesTheBestPremiumMatch() {
    let voices = [compact, enhanced, lee, ava, amelie]
    // The saved voice wins when it suits the reply's language.
    #expect(PremiumSpeechVoices.preferred(in: voices, replyLanguage: "en", selectedID: "lee", preferredLanguages: ["en-US"])?.id == "lee")
    // A French reply switches to a French Premium voice.
    #expect(PremiumSpeechVoices.preferred(in: voices, replyLanguage: "fr", selectedID: "lee", preferredLanguages: ["en-US"])?.id == "amelie")
    // Automatic: the user's own region first.
    #expect(PremiumSpeechVoices.preferred(in: voices, replyLanguage: "en", selectedID: nil, preferredLanguages: ["en-US"])?.id == "ava")
    // No Premium voice for the language: keep the saved Premium voice rather than going silent.
    #expect(PremiumSpeechVoices.preferred(in: voices, replyLanguage: "de", selectedID: "lee", preferredLanguages: ["en-US"])?.id == "lee")
    // An explicitly selected Enhanced voice is respected.
    #expect(PremiumSpeechVoices.preferred(in: voices, replyLanguage: nil, selectedID: "lee-enhanced", preferredLanguages: ["en-US"])?.id == "lee-enhanced")
}

@Test func personalVoiceIsListedFirstButOnlyUsedWhenChosen() {
    let voices = [ava, lee, personal, amelie]
    #expect(PremiumSpeechVoices.available(voices, preferredLanguages: ["en-US"]).map(\.id) == ["me", "ava", "lee", "amelie"])
    #expect(personal.displayName.hasPrefix("Personal Voice"))
    // Automatic never picks it.
    #expect(PremiumSpeechVoices.preferred(in: voices, replyLanguage: "en", selectedID: nil, preferredLanguages: ["en-US"])?.id == "ava")
    // Chosen, it speaks replies in its language...
    #expect(PremiumSpeechVoices.preferred(in: voices, replyLanguage: "en", selectedID: "me", preferredLanguages: ["en-US"])?.id == "me")
    // ...a French reply still switches to a French Premium voice...
    #expect(PremiumSpeechVoices.preferred(in: voices, replyLanguage: "fr", selectedID: "me", preferredLanguages: ["en-US"])?.id == "amelie")
    // ...and with no Premium voice installed it is still used rather than staying silent.
    #expect(PremiumSpeechVoices.preferred(in: [personal], replyLanguage: "de", selectedID: "me", preferredLanguages: ["en-US"])?.id == "me")
    // Not chosen and no Premium voice: replies stay written.
    #expect(PremiumSpeechVoices.preferred(in: [personal], replyLanguage: "en", selectedID: nil) == nil)
}

@Test func readerVoiceStaysPinnedUntilExplicitSelectionChanges() {
    var session = ReaderVoiceSelection()
    #expect(session.resolve(in: [ava, lee], language: "en-US", selectedID: nil)?.id == "ava")
    #expect(session.resolve(in: [lee, ava, amelie], language: "fr", selectedID: nil)?.id == "ava")
    #expect(session.resolve(in: [lee, amelie], language: "fr", selectedID: nil) == nil)
    #expect(session.resolve(in: [ava, lee], language: "fr", selectedID: nil)?.id == "ava")
    #expect(session.resolve(in: [ava, lee], language: "fr", selectedID: "lee")?.id == "lee")
}

@Test func readerExplicitVoiceNeverSilentlyFallsBack() {
    var session = ReaderVoiceSelection()
    #expect(session.resolve(in: [ava, amelie], language: "fr", selectedID: "ava")?.id == "ava")
    #expect(session.resolve(in: [amelie], language: "fr", selectedID: "ava") == nil)
    #expect(session.resolve(in: [compact, enhanced], language: "en", selectedID: "samantha")?.id == "samantha")
    #expect(session.resolve(in: [personal], language: "fr", selectedID: "me")?.id == "me")
}

@Test func readerAllowsEveryInstalledVoiceWithoutChangingReplySelection() {
    var session = ReaderVoiceSelection()
    #expect(session.resolve(in: [personal, ava], language: "en-US", selectedID: nil)?.id == "ava")
    #expect(PremiumSpeechVoices.preferred(in: [personal, ava], replyLanguage: "en", selectedID: "me")?.id == "me")
    let voices = [personal, compact, enhanced, novelty, ava]
    #expect(Set(ReaderVoiceSelection.available(voices).map(\.id)) == Set(voices.map(\.id)))
    for voice in voices {
        #expect(session.resolve(in: voices, language: "fr", selectedID: voice.id)?.id == voice.id)
    }
}
