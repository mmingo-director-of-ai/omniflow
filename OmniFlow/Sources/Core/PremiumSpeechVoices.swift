import AVFoundation
import Foundation
import NaturalLanguage

/// A public speech-synthesis voice reduced to the facts voice selection needs,
/// so the filter can be tested with injected lists.
struct SpeechVoiceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let language: String
    let isPremium: Bool
    /// The user's own Personal Voice. Listed only after the user allows
    /// OmniFlow to use it, and used only when chosen explicitly.
    let isPersonal: Bool
    /// Novelty voices are selectable but never chosen automatically.
    let isExcluded: Bool

    init(id: String, name: String, language: String, isPremium: Bool, isPersonal: Bool = false, isExcluded: Bool = false) {
        self.id = id; self.name = name; self.language = language
        self.isPremium = isPremium; self.isPersonal = isPersonal; self.isExcluded = isExcluded
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(id: voice.identifier, name: voice.name, language: voice.language,
                  isPremium: voice.quality == .premium,
                  isPersonal: voice.voiceTraits.contains(.isPersonalVoice),
                  isExcluded: voice.voiceTraits.contains(.isNoveltyVoice))
    }

    var displayName: String {
        if isPersonal { return "Personal Voice · " + name }
        let base = name
        return base + " · " + (Locale.current.localizedString(forIdentifier: language) ?? language)
    }

    var baseLanguage: String { String(language.split(separator: "-").first ?? Substring(language)).lowercased() }
}

/// Installed system voices for spoken replies and Reader. The legacy name and
/// preference key are retained to preserve saved selections.
enum PremiumSpeechVoices {
    static let selectionKey = "omniflow.premiumVoice.id"

    #if os(macOS)
    static let missingNotice = "Install a voice in System Settings › Accessibility › Spoken Content to hear replies."
    #else
    static let missingNotice = "Install a voice in Settings › Accessibility › Read & Speak to hear replies."
    #endif

    /// Choosable voices: Personal Voices first, then installed system voices,
    /// the user's languages first (exact, then same base language), then by
    /// language and name.
    static func available(_ voices: [SpeechVoiceInfo], preferredLanguages: [String] = Locale.preferredLanguages) -> [SpeechVoiceInfo] {
        let preferred = preferredLanguages.map { $0.lowercased() }
        func rank(_ voice: SpeechVoiceInfo) -> Int {
            if let exact = preferred.firstIndex(of: voice.language.lowercased()) { return exact * 2 }
            if let base = preferred.firstIndex(where: { $0.split(separator: "-").first.map(String.init) == voice.baseLanguage }) { return base * 2 + 1 }
            return Int.max
        }
        return voices.sorted {
            if $0.isPersonal != $1.isPersonal { return $0.isPersonal }
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            return ($0.language, $0.name) < ($1.language, $1.name)
        }
    }

    /// Match the language automatically. Personal and novelty voices require
    /// explicit selection; every installed quality is allowed.
    static func preferred(in voices: [SpeechVoiceInfo], replyLanguage: String?, selectedID: String?,
                          preferredLanguages: [String] = Locale.preferredLanguages) -> SpeechVoiceInfo? {
        let choosable = available(voices, preferredLanguages: preferredLanguages)
        let saved = selectedID.flatMap { id in choosable.first { $0.id == id } }
        let candidates = choosable.filter { !$0.isPersonal && !$0.isExcluded }
        guard let replyLanguage = replyLanguage?.lowercased(), !replyLanguage.isEmpty else { return saved ?? candidates.first }
        let replyBase = String(replyLanguage.split(separator: "-").first ?? "")
        if let saved, saved.baseLanguage == replyBase { return saved }
        return candidates.first { $0.language.lowercased() == replyLanguage }
            ?? candidates.first { $0.baseLanguage == replyBase }
            ?? saved ?? candidates.first
    }

    static func installed() -> [SpeechVoiceInfo] { AVSpeechSynthesisVoice.speechVoices().map(SpeechVoiceInfo.init) }

    /// Dominant language of reply text, when it can be told with confidence.
    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.6 else { return nil }
        return language.rawValue
    }
}

/// A reading session keeps its voice even when discovery order, book language,
/// or installed voices change. A missing selected voice is an error, not consent
/// to substitute another. Reset this value only when opening/closing a book.
struct ReaderVoiceSelection {
    static let selectionKey = "omniflow.reader.premiumVoice.id"

    static func available(_ voices: [SpeechVoiceInfo]) -> [SpeechVoiceInfo] {
        PremiumSpeechVoices.available(voices)
    }

    private var selectedID: String?
    private var pinnedID: String?
    private var initialized = false

    mutating func resolve(in voices: [SpeechVoiceInfo], language: String?, selectedID: String?) -> SpeechVoiceInfo? {
        let selection = selectedID.flatMap { $0.isEmpty ? nil : $0 }
        if !initialized || selection != self.selectedID {
            initialized = true
            self.selectedID = selection
            pinnedID = selection
        }
        let available = Self.available(voices)
        if let pinnedID { return available.first { $0.id == pinnedID } }
        let choice = PremiumSpeechVoices.preferred(in: available, replyLanguage: language, selectedID: nil)
        pinnedID = choice?.id
        return choice
    }
}
