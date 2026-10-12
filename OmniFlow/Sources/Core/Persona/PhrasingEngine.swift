import Foundation
import Synchronization

/// Recently used templates and model outputs per notice kind, most recent last.
struct NoticeHistory: Codable, Sendable, Equatable {
    var templates: [String: [String]] = [:]
    var outputs: [String: [String]] = [:]
}

protocol NoticeHistoryStore: Sendable {
    func load() -> NoticeHistory
    func save(_ history: NoticeHistory)
}

/// Persists the no-repeat ring buffer in UserDefaults under `persona.noticeHistory`.
struct DefaultsNoticeHistoryStore: NoticeHistoryStore {
    static let key = "persona.noticeHistory"
    /// nil uses the standard defaults; tests pass a throwaway suite.
    let suiteName: String?

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    func load() -> NoticeHistory {
        guard let data = defaults.data(forKey: Self.key) else { return .init() }
        return (try? JSONDecoder().decode(NoticeHistory.self, from: data)) ?? .init()
    }
    func save(_ history: NoticeHistory) {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.key) }
    }
}

/// Small seedable generator so tests are reproducible; production uses the system RNG.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Phrases system notices in a persona's voice.
///
/// Tier 1 picks a template from the persona's pool, weighted against recent use so the
/// same line never repeats back-to-back and rarely within `noRepeatWindow` uses.
/// Tier 2 optionally asks an on-device rewriter for a fresh line under a hard timeout;
/// anything late, refused or factually altered falls back to Tier 1.
final class PhrasingEngine: Sendable {
    static let noRepeatWindow = 5
    static let historyLimit = noRepeatWindow * 2
    static let defaultTimeout: Duration = .milliseconds(400)
    static let maxLength = 160
    static let maxFlavorLength = 60

    private struct State {
        var history: NoticeHistory
        var rng: any RandomNumberGenerator
        var cache: [String: [String]] = [:]
    }

    private let state: Mutex<State>
    private let store: any NoticeHistoryStore

    init(store: any NoticeHistoryStore = DefaultsNoticeHistoryStore(suiteName: nil),
         rng: any RandomNumberGenerator & Sendable = SystemRandomNumberGenerator()) {
        self.store = store
        state = Mutex(State(history: store.load(), rng: rng))
    }

    /// The persona actually used: explicit personas collapse to Default while the gate is off.
    static func effective(_ persona: Persona, allowExplicit: Bool) -> Persona {
        persona.explicitLanguage && !allowExplicit ? .standard : persona
    }

    // MARK: Tier 1

    /// Instant, always-available phrasing.
    func phrase(_ event: NoticeEvent, as persona: Persona, allowExplicit: Bool, variation: Bool = true) -> Notice {
        let persona = Self.effective(persona, allowExplicit: allowExplicit)
        let pick = state.withLock { state in Self.pick(event, persona: persona, variation: variation, state: &state) }
        if variation { commit(kind: event.kind, template: pick.template, output: nil) }
        return Self.notice(event, line: pick.line, persona: persona, tier: .template)
    }

    // MARK: Tier 2

    /// Tier 2 when a rewriter is supplied and answers in time with a valid line; Tier 1 otherwise.
    /// Explicit personas stay on Tier 1: the on-device model's guardrails reject crude rewrites.
    func phrase(_ event: NoticeEvent, as persona: Persona, allowExplicit: Bool, variation: Bool = true,
                rewriter: (any NoticeRewriter)?, timeout: Duration = PhrasingEngine.defaultTimeout) async -> Notice {
        let persona = Self.effective(persona, allowExplicit: allowExplicit)
        guard variation, let rewriter, !persona.explicitLanguage else {
            return phrase(event, as: persona, allowExplicit: allowExplicit, variation: variation)
        }
        let kind = event.kind
        let cacheKey = persona.id + "|" + event.fingerprint
        let (pick, recent, cached) = state.withLock { state in
            let recent = state.history.outputs[kind.rawValue] ?? []
            let cached = state.cache[cacheKey]?.first { !recent.contains($0) }
            return (Self.pick(event, persona: persona, variation: true, state: &state), recent, cached)
        }
        if let cached {
            commit(kind: kind, template: nil, output: cached)
            return Self.notice(event, line: cached, persona: persona, tier: .model)
        }
        let source = pick.line
        let request = NoticeRewriteRequest(
            persona: persona, kind: kind, source: source, facts: event.coreSentence == nil ? event.facts : [:],
            avoid: Array(recent.suffix(Self.noRepeatWindow)),
            maxLength: event.coreSentence == nil ? Self.maxLength : Self.maxFlavorLength)
        // The generation keeps running past the deadline so a late answer can serve the next
        // identical event from the cache; only the wait is bounded.
        let work = Task { try await rewriter.rewrite(request) }
        let raw = await Self.first(of: work, within: timeout)
        if let raw, let line = RewriteValidator.validate(raw, event: event, source: source, persona: persona) {
            commit(kind: kind, template: nil, output: line)
            return Self.notice(event, line: line, persona: persona, tier: .model)
        }
        if raw == nil {
            Task { [weak self] in
                guard let late = try? await work.value,
                      let line = RewriteValidator.validate(late, event: event, source: source, persona: persona) else { return }
                self?.state.withLock { state in
                    state.cache[cacheKey, default: []].insert(line, at: 0)
                    state.cache[cacheKey] = Array(state.cache[cacheKey]!.prefix(4))
                }
            }
        }
        commit(kind: kind, template: pick.template, output: nil)
        return Self.notice(event, line: source, persona: persona, tier: .template)
    }

    /// Races the rewrite against the deadline without waiting for the loser. A task group
    /// would block until both children end, which is exactly the wait being bounded.
    private static func first(of work: Task<String, any Error>, within timeout: Duration) async -> String? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let deadline = Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: nil) }
            }
            Task {
                let value = try? await work.value
                if once.claim() { deadline.cancel(); continuation.resume(returning: value) }
            }
        }
    }

    private final class Once: Sendable {
        private let claimed = Mutex(false)
        func claim() -> Bool { claimed.withLock { claimed in defer { claimed = true }; return !claimed } }
    }

    // MARK: Selection

    var history: NoticeHistory { state.withLock { $0.history } }

    private func commit(kind: NoticeKind, template: String?, output: String?) {
        let snapshot = state.withLock { state in
            if let template { Self.append(template, to: &state.history.templates[kind.rawValue, default: []]) }
            if let output { Self.append(output, to: &state.history.outputs[kind.rawValue, default: []]) }
            return state.history
        }
        store.save(snapshot)
    }

    private static func append(_ value: String, to list: inout [String]) {
        list.append(value)
        if list.count > historyLimit { list.removeFirst(list.count - historyLimit) }
    }

    private static func pick(_ event: NoticeEvent, persona: Persona, variation: Bool,
                             state: inout State) -> (template: String, line: String) {
        let terms = addressTerms(for: persona)
        // Critical pools are flavor only; their facts live in the fixed core sentence.
        let facts = event.coreSentence == nil ? event.facts : [:]
        let eligible = NoticeTemplates.pool(persona.style, event.kind)
            .filter { TemplateRenderer.isEligible($0, facts: facts, hasAddressTerms: !terms.isEmpty) }
        // Every pool carries fact-only lines, so this only triggers for a malformed pool.
        guard !eligible.isEmpty else { return ("", event.coreSentence ?? fallbackLine(event)) }
        let template: String
        if !variation || eligible.count == 1 {
            template = eligible[0]
        } else {
            let recent = state.history.templates[event.kind.rawValue] ?? []
            let window = min(noRepeatWindow, eligible.count - 1)
            let blocked = Set(recent.suffix(window))
            let older = Set(recent.dropLast(window))
            let weights = eligible.map { blocked.contains($0) ? 0 : older.contains($0) ? 0.35 : 1.0 }
            template = eligible[weightedIndex(weights, rng: &state.rng)]
        }
        // Skip terms the line already uses, so "dumbass … dumbass" never renders.
        let fresh = terms.filter { !template.localizedCaseInsensitiveContains($0) }
        let choices = fresh.isEmpty ? terms : fresh
        let term = choices.isEmpty ? nil : choices[Int(state.rng.next() % UInt64(choices.count))]
        return (template, TemplateRenderer.render(template, facts: facts, addressTerm: term))
    }

    private static func weightedIndex(_ weights: [Double], rng: inout any RandomNumberGenerator) -> Int {
        let total = weights.reduce(0, +)
        var target = Double(rng.next() >> 11) * 0x1p-53 * total
        for (index, weight) in weights.enumerated() where weight > 0 {
            if target < weight { return index }
            target -= weight
        }
        return weights.lastIndex { $0 > 0 } ?? 0
    }

    /// Custom personas without their own terms borrow their base style's.
    static func addressTerms(for persona: Persona) -> [String] {
        if !persona.addressTerms.isEmpty { return persona.addressTerms }
        return Persona.builtIns.first { $0.style == persona.style }?.addressTerms ?? []
    }

    private static func notice(_ event: NoticeEvent, line: String, persona: Persona, tier: Notice.Tier) -> Notice {
        guard let core = event.coreSentence else {
            return Notice(text: line, coreSentence: nil, personaID: persona.id, tier: tier)
        }
        return Notice(text: line.isEmpty ? core : "\(line) \(core)", coreSentence: core, personaID: persona.id, tier: tier)
    }

    private static func fallbackLine(_ event: NoticeEvent) -> String {
        ([event.kind.rawValue] + event.facts.sorted { $0.key < $1.key }.map(\.value)).joined(separator: " · ")
    }
}

enum TemplateRenderer {
    static func slots(in template: String) -> Set<String> {
        var result = Set<String>()
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result.insert(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// Eligible when it shows every fact the event carries and can fill every slot it uses.
    static func isEligible(_ template: String, facts: [String: String], hasAddressTerms: Bool) -> Bool {
        var slots = slots(in: template)
        if slots.remove("you") != nil, !hasAddressTerms { return false }
        return slots == Set(facts.keys)
    }

    static func render(_ template: String, facts: [String: String], addressTerm: String?) -> String {
        var line = template
        for (key, value) in facts { line = line.replacingOccurrences(of: "{\(key)}", with: value) }
        if let addressTerm { line = line.replacingOccurrences(of: "{you}", with: addressTerm) }
        return line
    }
}
