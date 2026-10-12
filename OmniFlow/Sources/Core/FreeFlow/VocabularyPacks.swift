import Foundation

/// Optional term lists a user can switch on in Settings › Vocabulary. They are
/// never enabled on the user's behalf.
public enum VocabularyPack: String, CaseIterable, Identifiable, Sendable {
    case security

    public var id: Self { self }
    public var preferenceKey: String { "omniflow.vocabularyPack." + rawValue }

    public var title: String {
        switch self { case .security: "Security terms" }
    }

    public var terms: [String] {
        switch self {
        case .security:
            ["IOC", "IOCs", "EDR", "XDR", "SIEM", "SOAR", "KQL", "SPL", "EQL", "MITRE ATT&CK", "TTP", "TTPs", "Sigma", "YARA",
             "CrowdStrike", "SentinelOne", "Splunk", "Elastic", "Wazuh", "Kyube", "Pergamon", "Atlas", "OmniFlow", "MCP"]
        }
    }
}

/// The one source of dictation terms for every consumer: the recognizer's
/// contextual strings and the cleanup glossary.
/// User terms come from `vocabulary` (one per line), packs from their switches,
/// and replacement rules from `phraseReplacements`, all in UserDefaults.
public struct DictationVocabulary: Equatable, Sendable {
    public struct Replacement: Equatable, Sendable {
        public let from: String
        public let to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public static let userTermsKey = "vocabulary"
    public static let replacementsKey = "phraseReplacements"

    public var userTerms: [String]
    public var enabledPacks: [VocabularyPack]
    public var replacements: [Replacement]
    /// Learned from the user's corrections and listed in Settings › Vocabulary
    /// (accepted, or safe ones in automatic mode). They come after the user's own.
    public var learnedReplacements: [Replacement]
    public var learnedTerms: [String]

    public init(userTerms: [String], enabledPacks: [VocabularyPack] = [], replacements: [Replacement] = [],
                learnedReplacements: [Replacement] = [], learnedTerms: [String] = []) {
        self.userTerms = userTerms; self.enabledPacks = enabledPacks; self.replacements = replacements
        self.learnedReplacements = learnedReplacements; self.learnedTerms = learnedTerms
    }

    public init(userVocabulary: String, enabledPacks: [VocabularyPack] = [], replacements: [PhraseReplacement] = [],
                learnedReplacements: [Replacement] = [], learnedTerms: [String] = []) {
        self.init(userTerms: userVocabulary.components(separatedBy: .newlines),
                  enabledPacks: enabledPacks,
                  replacements: replacements.filter(\.enabled).map { Replacement(from: $0.phrase, to: $0.replacement) },
                  learnedReplacements: learnedReplacements, learnedTerms: learnedTerms)
    }

    /// The saved vocabulary, packs, enabled replacement rules and learned rules.
    /// Learned rules come from the encrypted vault and are skipped if it can't be read.
    public static func current(_ defaults: UserDefaults = .standard) -> DictationVocabulary {
        let rules = defaults.data(forKey: replacementsKey).flatMap { try? JSONDecoder().decode([PhraseReplacement].self, from: $0) } ?? []
        let learned = CorrectionLearningModel.appliedRules(store: .standard, defaults: defaults)
        return DictationVocabulary(userVocabulary: defaults.string(forKey: userTermsKey) ?? "",
                                   enabledPacks: VocabularyPack.allCases.filter { defaults.bool(forKey: $0.preferenceKey) },
                                   replacements: rules,
                                   learnedReplacements: learned.filter { $0.kind == .replacement }.map { .init(from: $0.from, to: $0.to) },
                                   learnedTerms: learned.filter { $0.kind == .term }.map(\.to))
    }

    /// The user's replacement rules first, then learned ones, as rules for the
    /// replacements-before-cleanup pass (earlier rules win overlaps).
    public var replacementRules: [PhraseReplacement] {
        (replacements + learnedReplacements).map { PhraseReplacement(phrase: $0.from, replacement: $0.to) }
    }

    public var packTerms: [String] { enabledPacks.flatMap(\.terms) }

    /// User terms, then pack terms, then replacement targets (the words the user
    /// wants written), then learned terms and targets: trimmed, at most 60
    /// characters, deduplicated ignoring case.
    public var allTerms: [String] {
        var seen = Set<String>()
        return (userTerms + packTerms + replacements.map(\.to) + learnedTerms + learnedReplacements.map(\.to))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 60 && seen.insert($0.lowercased()).inserted }
    }

    /// `allTerms`, one per line, for APIs that take the vocabulary text.
    public var text: String { allTerms.joined(separator: "\n") }
}
