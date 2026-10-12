import Foundation

/// How strongly a persona leans into its voice.
enum PersonaIntensity: String, Codable, Sendable, CaseIterable {
    case mild, medium, spicy
}

/// The template pool a persona draws its Tier 1 lines from. Custom personas pick one as
/// their base; their free-text tone only affects Tier 2 rewrites and the assistant fragment.
enum PersonaStyle: String, Codable, Sendable, CaseIterable {
    case standard, friendly, terse, sarcastic, drillSergeant, abliterated

    /// Styles whose templates contain profanity or insults aimed at the user.
    var isExplicit: Bool { self == .abliterated }
}

/// A voice for system notices and the assistant. Pure data: safe on macOS and iOS.
struct Persona: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var summary: String
    /// Tone guidance for the on-device model (Tier 2 rewrites and the assistant fragment).
    var toneInstructions: String
    var explicitLanguage: Bool
    var intensity: PersonaIntensity
    /// Ways the persona addresses the user; fills the `{you}` template slot.
    var addressTerms: [String]
    var style: PersonaStyle
    var isBuiltIn: Bool

    /// Custom tone text is capped: the on-device context window is small and the
    /// fragment rides along with every assistant session.
    static let maxToneLength = 280
    static let maxAddressTerms = 8
    static let maxNameLength = 40

    /// Rules appended after every tone, built-in or custom, so user text cannot override them.
    static let safetyRules = """
    Never use slurs. Never mock race, ethnicity, nationality, religion, gender, sexuality, disability, age or appearance. \
    Never threaten anyone or mention self-harm. Only tease the user; never insult other people. \
    Keep every fact, number and name exactly as given.
    """

    /// A stable fragment AtlasAssistant/VoiceAssistant can append to session instructions.
    /// Deterministic per persona (no timestamps, no recent phrasings) so prewarmed
    /// sessions keep their cache. Explicit personas get a tone-only fragment: profanity
    /// lives in Tier 1 templates, because asking the on-device model to swear is likely
    /// to trip its guardrails and fail ordinary answers.
    var instructionsFragment: String {
        if id == Persona.standard.id { return "" }
        let tone = explicitLanguage
            ? "Be blunt, teasing and irreverent with the user, like an old friend who gives them a hard time. Stay accurate and helpful."
            : String(toneInstructions.prefix(Persona.maxToneLength))
        // An explicit custom persona's name may itself be profane; keep it out of the instructions.
        let name = explicitLanguage ? "" : "Voice: \(displayName). "
        return "\(name)\(tone) \(Persona.safetyRules)"
    }
}

extension Persona {
    static let standard = Persona(
        id: "default", displayName: "Default", summary: "Clear and neutral. OmniFlow's usual voice.",
        toneInstructions: "Write plainly and calmly. Short sentences, no jokes.",
        explicitLanguage: false, intensity: .mild, addressTerms: [], style: .standard, isBuiltIn: true)

    static let friendly = Persona(
        id: "friendly", displayName: "Friendly", summary: "Warm, upbeat and encouraging.",
        toneInstructions: "Be warm and encouraging, like a supportive teammate. Light enthusiasm, no gushing.",
        explicitLanguage: false, intensity: .mild, addressTerms: ["friend", "buddy", "pal"], style: .friendly, isBuiltIn: true)

    static let terse = Persona(
        id: "terse", displayName: "Terse", summary: "Professional and minimal. Facts first.",
        toneInstructions: "Be terse and professional. Lead with the fact. No pleasantries, no filler.",
        explicitLanguage: false, intensity: .mild, addressTerms: [], style: .terse, isBuiltIn: true)

    static let sarcastic = Persona(
        id: "sarcastic", displayName: "Sarcastic", summary: "Dry wit and gentle eye-rolling.",
        toneInstructions: "Use dry, deadpan sarcasm. Gently roll your eyes at the situation, never cruel.",
        explicitLanguage: false, intensity: .medium, addressTerms: ["genius", "chief", "boss"], style: .sarcastic, isBuiltIn: true)

    static let drillSergeant = Persona(
        id: "drill-sergeant", displayName: "Drill Sergeant", summary: "Loud, urgent and demanding. Clean language.",
        toneInstructions: "Bark orders like a drill sergeant. Urgent, loud, demanding, but no profanity.",
        explicitLanguage: false, intensity: .medium, addressTerms: ["recruit", "soldier", "private"], style: .drillSergeant, isBuiltIn: true)

    static let abliterated = Persona(
        id: "abliterated", displayName: "Abliterated",
        summary: "Crude, profane and insulting — aimed at you, all in fun. Requires explicit language.",
        toneInstructions: "Be crude and profane. Insult the user playfully, like a foul-mouthed friend roasting them.",
        explicitLanguage: true, intensity: .spicy,
        addressTerms: ["dumbass", "motherfucker", "genius", "jackass", "dipshit", "hotshot"], style: .abliterated, isBuiltIn: true)

    static let builtIns: [Persona] = [.standard, .friendly, .terse, .sarcastic, .drillSergeant, .abliterated]

    /// A user-defined persona. Explicit language is forced on when the base style is
    /// explicit or the user's own text contains profanity, so the gate always applies.
    static func custom(id: String = UUID().uuidString, name: String, tone: String, base: PersonaStyle,
                       explicit: Bool, addressTerms: [String] = []) -> Persona {
        let terms = addressTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(maxAddressTerms).map { String($0.prefix(30)) }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        let tone = String(tone.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxToneLength))
        let isExplicit = explicit || base.isExplicit || ProfanityFilter.containsProfanity(([name, tone] + terms).joined(separator: " "))
        return Persona(id: id, displayName: name.isEmpty ? "Custom" : name, summary: tone.isEmpty ? "Custom voice" : tone,
                       toneInstructions: tone, explicitLanguage: isExplicit, intensity: isExplicit ? .spicy : .medium,
                       addressTerms: terms, style: base, isBuiltIn: false)
    }
}

/// Word-boundary profanity check, used to keep clean personas clean and to gate custom text.
enum ProfanityFilter {
    static let words = ["fuck", "fucking", "fucked", "fucker", "motherfucker", "motherfucking", "shit", "shitty", "bullshit",
                        "ass", "asshole", "dumbass", "jackass", "dipshit", "damn", "goddamn", "bitch", "dick", "crap",
                        "hell", "piss", "pissed", "bastard", "douche", "douchebag", "cock", "prick", "twat", "wanker", "arse"]

    static func containsProfanity(_ text: String) -> Bool {
        let tokens = text.lowercased().split { !$0.isLetter }
        return tokens.contains { token in words.contains(String(token)) || token.hasPrefix("fuck") || token.hasSuffix("fucker") }
    }
}
