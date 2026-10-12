import Foundation

/// One dictation the user corrected inside OmniFlow: what the recognizer heard,
/// what cleanup produced, and what the user kept. One pair per dictation; a later
/// edit of the same dictation replaces it.
struct CorrectionPair: Codable, Equatable, Sendable {
    let entryID: UUID
    var date: Date
    let raw: String
    let cleaned: String
    var final: String
}

/// Word-level alignment for learning. Compares case-insensitively, keeps the
/// original spellings, and ignores punctuation.
enum WordDiff {
    enum Op: Equatable { case same(String), change(from: [String], to: [String]) }

    static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’&-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’-")) }.filter { !$0.isEmpty }
    }

    static func align(_ a: [String], _ b: [String]) -> [Op] {
        let x = a.map { $0.lowercased() }, y = b.map { $0.lowercased() }
        guard a.count * b.count <= 400_000 else { return [.change(from: a, to: b)] }
        var lcs = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = [], from: [String] = [], to: [String] = []
        func flush() { if !from.isEmpty || !to.isEmpty { ops.append(.change(from: from, to: to)); from = []; to = [] } }
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] { flush(); ops.append(.same(b[j])); i += 1; j += 1 }
            else if j < y.count, i == x.count || lcs[i][j + 1] >= lcs[i + 1][j] { to.append(b[j]); j += 1 }
            else { from.append(a[i]); i += 1 }
        }
        flush()
        return ops
    }
}

/// A suggestion learned from corrections. Its id is stable across relearning, so
/// a decision (accepted or rejected) sticks when the count grows again.
struct LearnedRule: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case replacement, term, style }
    let kind: Kind
    let from: String
    let to: String
    /// Distinct dictations that showed it.
    var count: Int
    /// A short snippet of the corrected text, so the user can judge the rule.
    var example: String
    /// True when the rule may apply without review in automatic mode: a replacement
    /// whose "from" contains a word the dictionary does not know (so it cannot hit
    /// ordinary prose, unlike "to get her" in "I want to get her a gift"), or a term.
    var safeToAutoApply: Bool

    var id: String { kind.rawValue + ":" + from.lowercased() + "→" + to.lowercased() }

    var title: String {
        switch kind {
        case .replacement: "“\(from)” → “\(to)”"
        case .term: "Vocabulary: \(to)"
        case .style: to
        }
    }
}

/// Derives suggestions from correction pairs. Deterministic; nothing is learned
/// from a single dictation, from numbers, or from an edit that flips a negation.
enum CorrectionLearner {
    static let minimumDictations = 2
    static let fillers: Set<String> = ["like", "basically", "actually", "literally", "just", "really", "so", "um", "uh"]
    static let fillerPhrases = ["you know", "kind of", "sort of", "i mean"]

    static func suggestions(from pairs: [CorrectionPair], isKnownWord: (String) -> Bool = { _ in true }) -> [LearnedRule] {
        var found: [String: (rule: LearnedRule, entries: Set<UUID>)] = [:]
        func note(_ rule: LearnedRule, entry: UUID) {
            if var existing = found[rule.id] { existing.entries.insert(entry); found[rule.id] = existing }
            else { found[rule.id] = (rule, [entry]) }
        }
        for pair in latestPerEntry(pairs) {
            let cleaned = WordDiff.words(pair.cleaned), final = WordDiff.words(pair.final)
            let ops = WordDiff.align(cleaned, final)
            let changed = ops.reduce(0) { total, op in
                if case .change(let from, let to) = op { return total + max(from.count, to.count) } else { return total }
            }
            // A near-rewrite says nothing reliable about individual words.
            guard !cleaned.isEmpty, changed <= max(3, max(cleaned.count, final.count) / 2) else { continue }
            for op in ops {
                guard case .change(let from, let to) = op else { continue }
                let fromText = from.joined(separator: " "), toText = to.joined(separator: " ")
                if to.isEmpty {
                    let removed = fromText.lowercased()
                    if fillers.contains(removed) || fillerPhrases.contains(removed) {
                        note(LearnedRule(kind: .style, from: removed, to: "Remove “\(removed)” when it is filler",
                                         count: 0, example: "", safeToAutoApply: false), entry: pair.entryID)
                    }
                    continue
                }
                guard (1...3).contains(to.count), from.count <= 3, !excluded(fromText, toText) else { continue }
                let example = snippet(around: toText, in: pair.final)
                if !from.isEmpty, contains(phrase: fromText, in: pair.raw), fromText.lowercased() != toText.lowercased() {
                    let unknownFrom = from.contains { !isKnownWord($0) }
                    note(LearnedRule(kind: .replacement, from: fromText, to: toText, count: 0, example: example,
                                     safeToAutoApply: unknownFrom), entry: pair.entryID)
                } else if contains(phrase: toText, in: pair.raw) || fromText.lowercased() == toText.lowercased() {
                    // The model changed a word the speaker said (or its spelling); the user restored it.
                    note(LearnedRule(kind: .term, from: "", to: toText, count: 0, example: example, safeToAutoApply: true), entry: pair.entryID)
                }
                for word in to where word.count >= 2 && !isKnownWord(word) && !excluded("", word) {
                    note(LearnedRule(kind: .term, from: "", to: word, count: 0, example: example, safeToAutoApply: true), entry: pair.entryID)
                }
            }
            if DictationChunker.sentenceCount(pair.final) >= DictationChunker.sentenceCount(pair.cleaned) + 2 {
                note(LearnedRule(kind: .style, from: "split", to: "Split long run-on sentences into shorter ones",
                                 count: 0, example: "", safeToAutoApply: false), entry: pair.entryID)
            }
        }
        return found.values.filter { $0.entries.count >= minimumDictations }.map { item in
            var rule = item.rule; rule.count = item.entries.count; return rule
        }.sorted { ($0.count, $1.id) > ($1.count, $0.id) }
    }

    static func latestPerEntry(_ pairs: [CorrectionPair]) -> [CorrectionPair] {
        var latest: [UUID: CorrectionPair] = [:]
        for pair in pairs where latest[pair.entryID].map({ pair.date >= $0.date }) ?? true { latest[pair.entryID] = pair }
        return latest.values.sorted { $0.date < $1.date }
    }

    /// Numbers and negation never become rules: "two" → "three" or "can" → "can't"
    /// are content decisions, not recognizer habits.
    static func excluded(_ from: String, _ to: String) -> Bool {
        !NumericContent.values(from).isEmpty || !NumericContent.values(to).isEmpty
            || CleanupPolicy.negationCount(from) != CleanupPolicy.negationCount(to)
    }

    static func contains(phrase: String, in text: String) -> Bool {
        let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?![\p{L}\p{N}_])"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func snippet(around phrase: String, in text: String) -> String {
        guard let range = text.range(of: phrase, options: .caseInsensitive) else { return String(text.prefix(80)) }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines) + (end == text.endIndex ? "" : "…")
    }
}

/// Correction pairs and rule decisions, encrypted at rest in OmniFlow's vault.
struct CorrectionStore: Sendable {
    let directory: URL
    static let maximumPairs = 500

    struct Decisions: Codable, Sendable {
        var accepted: [String: LearnedRule] = [:]
        var rejected: Set<String> = []
    }

    static var standard: CorrectionStore { CorrectionStore(directory: NotchLeeStorage.root.appendingPathComponent("Corrections", isDirectory: true)) }

    private var pairsURL: URL { directory.appendingPathComponent("pairs.json") }
    private var decisionsURL: URL { directory.appendingPathComponent("decisions.json") }

    func loadPairs() -> [CorrectionPair] { (try? read([CorrectionPair].self, from: pairsURL)) ?? [] }
    func loadDecisions() -> Decisions { (try? read(Decisions.self, from: decisionsURL)) ?? Decisions() }

    func savePairs(_ pairs: [CorrectionPair]) throws { try write(Array(pairs.suffix(Self.maximumPairs)), to: pairsURL) }
    func saveDecisions(_ decisions: Decisions) throws { try write(decisions, to: decisionsURL) }

    func removeAll() {
        try? FileManager.default.removeItem(at: pairsURL)
        try? FileManager.default.removeItem(at: decisionsURL)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(type, from: OmniFlowVault.read(url).plaintext)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try OmniFlowVault.write(JSONEncoder().encode(value), to: url)
    }
}

/// The learning loop for both apps: record corrections, list suggestions with
/// accept/reject, and expose what applies. Nothing applies without being listed.
@MainActor
final class CorrectionLearningModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case off, review, automatic
        var id: Self { self }
        var title: String {
            switch self {
            case .off: "Off"
            case .review: "Suggest for review"
            case .automatic: "Apply automatically"
            }
        }
    }
    enum Status: Equatable, Sendable { case pending, accepted, rejected, automatic }

    nonisolated static let modeKey = "omniflow.learning.mode"

    @Published var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) } }
    @Published private(set) var suggestions: [LearnedRule] = []
    @Published private(set) var decisions = CorrectionStore.Decisions()
    @Published private(set) var pairCount = 0

    private let store: CorrectionStore
    private let defaults: UserDefaults
    private let isKnownWord: @MainActor (String) -> Bool
    private var pairs: [CorrectionPair] = []

    /// `isKnownWord` is the platform dictionary (NSSpellChecker / UITextChecker); it
    /// decides which corrected words are new vocabulary and which rules are safe.
    init(store: CorrectionStore = .standard, defaults: UserDefaults = .standard, isKnownWord: @escaping @MainActor (String) -> Bool = { _ in true }) {
        self.store = store; self.defaults = defaults; self.isKnownWord = isKnownWord
        mode = Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .review
        pairs = store.loadPairs(); decisions = store.loadDecisions(); pairCount = pairs.count
        relearn()
    }

    /// Call when the user saves an edit of a dictation's result. A later edit of the
    /// same dictation replaces its pair, so one dictation never counts twice.
    func record(entryID: UUID, raw: String, cleaned: String, final: String, date: Date = .now) {
        guard mode != .off, !raw.isEmpty, cleaned != final else { return }
        if let index = pairs.firstIndex(where: { $0.entryID == entryID }) {
            pairs[index].final = final; pairs[index].date = date
        } else {
            pairs.append(CorrectionPair(entryID: entryID, date: date, raw: raw, cleaned: cleaned, final: final))
        }
        try? store.savePairs(pairs)
        pairCount = pairs.count
        let before = Set(suggestions.map(\.id))
        relearn()
        let added = suggestions.filter { !before.contains($0.id) }.count
        Task { await LocalTelemetry.shared.span("learning.pair", start: .now, attributes: [
            "pairs": String(pairs.count), "suggested": String(suggestions.count), "suggested.new": String(added),
            "accepted": String(decisions.accepted.count)]) }
    }

    func status(of rule: LearnedRule) -> Status {
        if decisions.rejected.contains(rule.id) { return .rejected }
        if decisions.accepted[rule.id] != nil { return .accepted }
        return mode == .automatic && rule.safeToAutoApply ? .automatic : .pending
    }

    func accept(_ rule: LearnedRule) {
        decisions.rejected.remove(rule.id); decisions.accepted[rule.id] = rule
        try? store.saveDecisions(decisions)
        Task { await LocalTelemetry.shared.span("learning.rule", start: .now, attributes: ["decision": "accepted", "kind": rule.kind.rawValue]) }
    }

    func reject(_ rule: LearnedRule) {
        decisions.accepted[rule.id] = nil; decisions.rejected.insert(rule.id)
        try? store.saveDecisions(decisions)
        Task { await LocalTelemetry.shared.span("learning.rule", start: .now, attributes: ["decision": "rejected", "kind": rule.kind.rawValue]) }
    }

    /// Forget one dictation's pair (the dictation was deleted).
    func removePair(entryID: UUID) {
        guard pairs.contains(where: { $0.entryID == entryID }) else { return }
        pairs.removeAll { $0.entryID == entryID }
        try? store.savePairs(pairs); pairCount = pairs.count
        relearn()
    }

    /// Forget every pair and decision.
    func clearAll() {
        store.removeAll(); pairs = []; decisions = .init(); pairCount = 0; suggestions = []
    }

    /// Forget the transcript pairs (history cleared or expired); decisions stay.
    func removePairs(olderThan cutoff: Date? = nil) {
        pairs = cutoff.map { cutoff in pairs.filter { $0.date >= cutoff } } ?? []
        try? store.savePairs(pairs); pairCount = pairs.count
        relearn()
    }

    /// Accepted rules, plus safe suggestions in automatic mode; never rejected ones.
    var applied: [LearnedRule] {
        guard mode != .off else { return [] }
        var rules = Array(decisions.accepted.values)
        if mode == .automatic { rules += suggestions.filter { $0.safeToAutoApply && status(of: $0) == .automatic } }
        return rules.sorted { $0.id < $1.id }
    }
    var learnedReplacements: [DictationVocabulary.Replacement] { applied.filter { $0.kind == .replacement }.map { .init(from: $0.from, to: $0.to) } }
    var learnedTerms: [String] { applied.filter { $0.kind == .term }.map(\.to) }
    var learnedStyles: [String] { applied.filter { $0.kind == .style }.map(\.to) }

    /// Every rule to list: suggestions and accepted rules no longer suggested.
    var listed: [LearnedRule] {
        let current = Set(suggestions.map(\.id))
        return suggestions + decisions.accepted.values.filter { !current.contains($0.id) }.sorted { $0.id < $1.id }
    }

    /// What applies, read straight from the stored files (for callers outside the
    /// app's model). Accepted rules always; in automatic mode, safe suggestions.
    nonisolated static func appliedRules(store: CorrectionStore, defaults: UserDefaults,
                                         isKnownWord: (String) -> Bool = { _ in true }) -> [LearnedRule] {
        let mode = Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .review
        guard mode != .off else { return [] }
        let decisions = store.loadDecisions()
        var rules = Array(decisions.accepted.values)
        if mode == .automatic {
            let accepted = Set(decisions.accepted.keys)
            rules += CorrectionLearner.suggestions(from: store.loadPairs(), isKnownWord: isKnownWord)
                .filter { $0.safeToAutoApply && !decisions.rejected.contains($0.id) && !accepted.contains($0.id) }
        }
        return rules.sorted { $0.id < $1.id }
    }

    private func relearn() {
        let known = isKnownWord
        suggestions = CorrectionLearner.suggestions(from: pairs) { word in MainActor.assumeIsolated { known(word) } }
    }
}
