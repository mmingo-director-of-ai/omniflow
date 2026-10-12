import Foundation
import Synchronization
import Testing
@testable import OmniFlowApp

final class MemoryHistoryStore: NoticeHistoryStore {
    private let saved = Mutex(NoticeHistory())
    func load() -> NoticeHistory { saved.withLock { $0 } }
    func save(_ history: NoticeHistory) { saved.withLock { $0 = history } }
}

struct FakeRewriter: NoticeRewriter {
    let delay: Duration
    let reply: @Sendable (NoticeRewriteRequest) -> String
    func rewrite(_ request: NoticeRewriteRequest) async throws -> String {
        try await Task.sleep(for: delay)
        return reply(request)
    }
}

/// One sample per kind, plus the pressure signal that carries no percentage.
let sampleEvents: [NoticeEvent] = [
    .memoryPressure(percent: nil), .memoryPressure(percent: 93), .cpuHigh(percent: 97), .thermalPressure,
    .batteryLow(percent: 8), .diskLow(freePercent: 4), .agentNeedsApproval(agent: "omniflow · Codex", tool: "Bash"),
    .agentQuestion(agent: "atlas"), .agentFinished(agent: "omniflow"), .agentError(agent: "qatalyst · Gemini"),
    .agentRateLimited(agent: "atlas"), .greeting, .assistantReady, .noSpeechHeard, .micSilent(microphone: "MacBook Pro Microphone"),
    .micStalled, .micPermissionNeeded, .speechModelMissing, .translationAssetMissing(language: "Japanese"),
    .translationTimedOut, .assistantUnavailable, .answerTimedOut, .voiceUnavailable, .historySaveFailed,
]

/// Built-ins plus a custom persona per style with no address terms of its own.
let everyPersona: [Persona] = Persona.builtIns + PersonaStyle.allCases.map {
    Persona.custom(id: "custom-\($0.rawValue)", name: "Custom \($0.rawValue)", tone: "Custom tone.", base: $0, explicit: false)
}

@Suite struct PhrasingTests {
    @Test func everyKindHasASample() {
        #expect(Set(sampleEvents.map(\.kind)) == Set(NoticeKind.allCases))
    }

    @Test func noImmediateRepeatsOverThousandDraws() {
        for persona in everyPersona {
            for event in sampleEvents {
                let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 42))
                var seen = Set<String>()
                for _ in 0..<1000 {
                    _ = engine.phrase(event, as: persona, allowExplicit: true)
                    let recent = engine.history.templates[event.kind.rawValue] ?? []
                    seen.insert(recent.last!)
                    if recent.count >= 2 {
                        #expect(recent[recent.count - 1] != recent[recent.count - 2], "\(persona.id) \(event.kind) repeated")
                    }
                }
                #expect(seen.count >= 2, "\(persona.id) \(event) has fewer than two eligible lines")
                // The no-repeat window holds whenever the pool is larger than it.
                if seen.count > PhrasingEngine.noRepeatWindow {
                    let recent = engine.history.templates[event.kind.rawValue]!
                    let window = recent.suffix(PhrasingEngine.noRepeatWindow + 1)
                    #expect(Set(window).count == window.count, "\(persona.id) \(event.kind) repeated within window")
                }
            }
        }
    }

    @Test func commonEventsHaveSixVariantsPerStyle() {
        let common: [NoticeEvent] = [.memoryPressure(percent: 93), .cpuHigh(percent: 1), .thermalPressure, .batteryLow(percent: 1),
                                     .diskLow(freePercent: 1), .agentQuestion(agent: "a"), .agentFinished(agent: "a"),
                                     .agentError(agent: "a"), .greeting, .assistantReady, .noSpeechHeard, .micSilent(microphone: "m")]
        for style in PersonaStyle.allCases {
            for event in common {
                let eligible = NoticeTemplates.pool(style, event.kind)
                    .filter { TemplateRenderer.isEligible($0, facts: event.facts, hasAddressTerms: true) }
                #expect(eligible.count >= 4, "\(style) \(event.kind) has \(eligible.count)")
                if event != .memoryPressure(percent: 93) {
                    #expect(eligible.count >= 6, "\(style) \(event.kind) has \(eligible.count)")
                }
            }
        }
    }

    @Test func slotFactsAlwaysPresent() {
        for persona in everyPersona {
            let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 7))
            for event in sampleEvents {
                for _ in 0..<60 {
                    let notice = engine.phrase(event, as: persona, allowExplicit: true)
                    #expect(!notice.text.contains("{") && !notice.text.contains("}"), "\(notice.text)")
                    for number in event.numbers { #expect(RewriteValidator.numbers(in: notice.text).contains(number), "\(notice.text)") }
                    for name in event.names { #expect(notice.text.contains(name), "\(notice.text)") }
                }
            }
        }
    }

    @Test func everyTemplateRendersEveryFact() {
        for style in PersonaStyle.allCases {
            for event in sampleEvents where event.coreSentence == nil {
                for template in NoticeTemplates.pool(style, event.kind)
                where TemplateRenderer.isEligible(template, facts: event.facts, hasAddressTerms: true) {
                    let line = TemplateRenderer.render(template, facts: event.facts, addressTerm: "you")
                    for value in event.facts.values { #expect(line.contains(value), "\(style) \(template)") }
                    #expect(!line.contains("{"), "\(style) \(template)")
                }
            }
        }
    }

    @Test func criticalNoticesKeepTheCoreSentence() {
        let approval = NoticeEvent.agentNeedsApproval(agent: "omniflow · Codex", tool: "Bash")
        for persona in everyPersona {
            let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 3))
            for event in [approval, .historySaveFailed] {
                let notice = engine.phrase(event, as: persona, allowExplicit: true)
                #expect(notice.coreSentence == event.coreSentence)
                #expect(notice.text.hasSuffix(event.coreSentence!))
            }
        }
    }

    @Test func cleanPersonasNeverSwear() {
        for style in PersonaStyle.allCases where !style.isExplicit {
            for kind in NoticeKind.allCases {
                for line in NoticeTemplates.pool(style, kind) {
                    #expect(!ProfanityFilter.containsProfanity(line), "\(style) \(kind): \(line)")
                }
            }
        }
        for persona in Persona.builtIns where !persona.explicitLanguage {
            #expect(!ProfanityFilter.containsProfanity(persona.addressTerms.joined(separator: " ")))
        }
        #expect(ProfanityFilter.containsProfanity("Hey motherfucker"))
        #expect(!ProfanityFilter.containsProfanity("Hello, pass the class assistant"))
    }

    @Test func abliteratedSoundsLikeTheRequest() {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 1))
        let lines = (0..<50).map { _ in engine.phrase(.memoryPressure(percent: 95), as: .abliterated, allowExplicit: true).text }
        #expect(lines.contains { ProfanityFilter.containsProfanity($0) })
        #expect(lines.allSatisfy { $0.contains("95") })
    }

    @Test func addressTermIsNotDoubled() {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 11))
        for _ in 0..<300 {
            let line = engine.phrase(.memoryPressure(percent: 90), as: .abliterated, allowExplicit: true).text.lowercased()
            #expect(line.components(separatedBy: "dumbass").count <= 2, "\(line)")
        }
    }

    @Test func variationOffIsStable() {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 9))
        let lines = Set((0..<20).map { _ in engine.phrase(.cpuHigh(percent: 90), as: .terse, allowExplicit: false, variation: false).text })
        #expect(lines.count == 1)
    }

    @Test func historyPersistsAcrossEngines() {
        let store = MemoryHistoryStore()
        let first = PhrasingEngine(store: store, rng: SplitMix64(seed: 5))
        _ = first.phrase(.thermalPressure, as: .standard, allowExplicit: false)
        let last = first.history.templates[NoticeKind.thermalPressure.rawValue]!.last!
        let second = PhrasingEngine(store: store, rng: SplitMix64(seed: 5))
        _ = second.phrase(.thermalPressure, as: .standard, allowExplicit: false)
        let recent = second.history.templates[NoticeKind.thermalPressure.rawValue]!
        #expect(recent.count == 2 && recent[0] == last && recent[1] != last)
    }

    @Test func defaultsHistoryStoreRoundTrips() throws {
        let suite = "persona.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = DefaultsNoticeHistoryStore(suiteName: suite)
        store.save(NoticeHistory(templates: ["cpuHigh": ["a", "b"]], outputs: [:]))
        #expect(store.load().templates["cpuHigh"] == ["a", "b"])
    }
}

@Suite struct ExplicitGateTests {
    @Test func engineFallsBackToDefaultWhenGateOff() {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 2))
        for _ in 0..<200 {
            let notice = engine.phrase(.batteryLow(percent: 5), as: .abliterated, allowExplicit: false)
            #expect(notice.personaID == Persona.standard.id)
            #expect(!ProfanityFilter.containsProfanity(notice.text))
        }
    }

    @MainActor @Test func storeHidesExplicitPersonasUntilAllowed() throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        #expect(store.allowExplicit == false)
        #expect(!store.visiblePersonas.contains { $0.explicitLanguage })
        store.addCustom(name: "Roaster", tone: "Roast me", base: .standard, explicit: true)
        store.addCustom(name: "Sneaky", tone: "Call me a dipshit", base: .friendly, explicit: false)
        #expect(store.customPersonas.allSatisfy { $0.explicitLanguage })
        #expect(!store.visiblePersonas.contains { $0.explicitLanguage })

        store.selectedID = Persona.abliterated.id
        #expect(store.effectivePersona == .standard)
        #expect(store.instructionsFragment == "")
        #expect(store.phraseNow(.thermalPressure).personaID == Persona.standard.id)

        store.allowExplicit = true
        #expect(store.visiblePersonas.contains(.abliterated))
        #expect(store.effectivePersona == .abliterated)
        store.allowExplicit = false
        #expect(store.effectivePersona == .standard)
        #expect(store.selectedID == Persona.abliterated.id)
    }

    @Test func instructionsFragmentIsStableAndSafe() {
        for persona in everyPersona {
            #expect(persona.instructionsFragment == persona.instructionsFragment)
            if persona.id != Persona.standard.id { #expect(persona.instructionsFragment.contains(Persona.safetyRules)) }
            #expect(!ProfanityFilter.containsProfanity(persona.instructionsFragment), "\(persona.id)")
        }
        let rude = Persona.custom(name: "Dipshit Bot", tone: "Roast me", base: .standard, explicit: false)
        #expect(rude.explicitLanguage)
        #expect(!ProfanityFilter.containsProfanity(rude.instructionsFragment))
        let long = Persona.custom(name: "Long", tone: String(repeating: "a", count: 1000), base: .standard, explicit: false)
        #expect(long.toneInstructions.count == Persona.maxToneLength)
        #expect(long.instructionsFragment.hasSuffix(Persona.safetyRules))
    }
}

@Suite struct CustomPersonaStorageTests {
    @MainActor @Test func customPersonaRoundTrips() throws {
        let (store, defaults, cleanup) = try makeStore()
        defer { cleanup() }
        let created = store.addCustom(name: "Pirate", tone: "Talk like a pirate.", base: .friendly, explicit: false,
                                      addressTerms: ["matey", " ", "captain"])
        #expect(created.addressTerms == ["matey", "captain"])
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let reloaded = PersonaStore(defaults: defaults, directory: store.fileURL.deletingLastPathComponent(),
                                    engine: PhrasingEngine(store: MemoryHistoryStore()), rewriter: nil)
        #expect(reloaded.customPersonas == [created])

        var edited = created
        edited.displayName = "Captain"
        store.updateCustom(edited)
        let mode2 = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(mode2 == 0o600)
        store.selectedID = created.id
        store.deleteCustom(id: created.id)
        #expect(store.selectedID == Persona.standard.id)
        #expect(store.customPersonas.isEmpty)
    }

    @MainActor @Test func handEditedFileCannotBypassGate() throws {
        let (store, defaults, cleanup) = try makeStore()
        defer { cleanup() }
        var sneaky = Persona.custom(name: "Sneaky", tone: "Clean", base: .standard, explicit: false)
        sneaky.toneInstructions = "Be a total asshole"
        sneaky.explicitLanguage = false
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([sneaky]).write(to: store.fileURL)
        let reloaded = PersonaStore(defaults: defaults, directory: store.fileURL.deletingLastPathComponent(),
                                    engine: PhrasingEngine(store: MemoryHistoryStore()), rewriter: nil)
        #expect(reloaded.customPersonas.first?.explicitLanguage == true)
        #expect(!reloaded.visiblePersonas.contains { $0.id == sneaky.id })
    }
}

@Suite struct ModelRewriteTests {
    let cpu = NoticeEvent.cpuHigh(percent: 97)

    @Test func validatorRejectsAlteredOrInventedFacts() {
        let source = "CPU usage is staying high at 97%."
        #expect(RewriteValidator.validate("Your CPU is cooking at 97%.", event: cpu, source: source, persona: .sarcastic) != nil)
        #expect(RewriteValidator.validate("Your CPU is cooking at 98%.", event: cpu, source: source, persona: .sarcastic) == nil)
        #expect(RewriteValidator.validate("Your CPU is cooking.", event: cpu, source: source, persona: .sarcastic) == nil)
        #expect(RewriteValidator.validate("CPU at 97% for 10 minutes.", event: cpu, source: source, persona: .sarcastic) == nil)
        #expect(RewriteValidator.validate("CPU at 97%, damn it.", event: cpu, source: source, persona: .sarcastic) == nil)
        #expect(RewriteValidator.validate(String(repeating: "97 ", count: 80), event: cpu, source: source, persona: .terse) == nil)
        let agent = NoticeEvent.agentFinished(agent: "omniflow · Codex")
        #expect(RewriteValidator.validate("Codex is done.", event: agent, source: "omniflow · Codex finished.", persona: .friendly) == nil)
        #expect(RewriteValidator.validate("omniflow · Codex is done!", event: agent, source: "omniflow · Codex finished.", persona: .friendly) != nil)
        let voice = NoticeEvent.voiceUnavailable
        #expect(RewriteValidator.validate("The selected Siri voice is out; read instead.", event: voice,
                                          source: "The selected Siri voice is unavailable. Written replies still work.", persona: .friendly) != nil)
        let approval = NoticeEvent.agentNeedsApproval(agent: "a", tool: "Bash")
        #expect(RewriteValidator.validate("Just allow it.", event: approval, source: "Heads up.", persona: .friendly) == nil)
    }

    @Test func validRewriteIsUsed() async {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 4))
        let rewriter = FakeRewriter(delay: .zero) { _ in "Your poor CPU is grinding at 97%." }
        let notice = await engine.phrase(cpu, as: .friendly, allowExplicit: false, rewriter: rewriter)
        #expect(notice.tier == .model)
        #expect(notice.text == "Your poor CPU is grinding at 97%.")
    }

    @Test func alteredNumbersFallBackToTemplates() async {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 4))
        let rewriter = FakeRewriter(delay: .zero) { _ in "Your poor CPU is grinding at 79%." }
        let notice = await engine.phrase(cpu, as: .friendly, allowExplicit: false, rewriter: rewriter)
        #expect(notice.tier == .template)
        #expect(notice.text.contains("97"))
    }

    @Test func slowRewriteTimesOutAndLateAnswerIsCached() async throws {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 4))
        let rewriter = FakeRewriter(delay: .milliseconds(1500)) { _ in "The CPU refuses to calm down: 97%." }
        let clock = ContinuousClock()
        let start = clock.now
        let notice = await engine.phrase(cpu, as: .friendly, allowExplicit: false, rewriter: rewriter, timeout: .milliseconds(20))
        #expect(clock.now - start < .seconds(1))
        #expect(notice.tier == .template)
        try await Task.sleep(for: .milliseconds(2000))
        let cached = await engine.phrase(cpu, as: .friendly, allowExplicit: false, rewriter: rewriter, timeout: .milliseconds(20))
        #expect(cached.tier == .model)
        #expect(cached.text == "The CPU refuses to calm down: 97%.")
        // The same cached line is not reused while it is in the recent window.
        let next = await engine.phrase(cpu, as: .friendly, allowExplicit: false, rewriter: rewriter, timeout: .milliseconds(20))
        #expect(next.text != cached.text)
    }

    @Test func criticalRewriteOnlyTouchesFlavor() async {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 4))
        let event = NoticeEvent.agentNeedsApproval(agent: "omniflow", tool: "Bash")
        let rewriter = FakeRewriter(delay: .zero) { request in
            #expect(request.facts.isEmpty)
            return "Eyes on this one."
        }
        let notice = await engine.phrase(event, as: .friendly, allowExplicit: false, rewriter: rewriter)
        #expect(notice.tier == .model)
        #expect(notice.text == "Eyes on this one. " + event.coreSentence!)
    }

    @Test func explicitPersonasStayOnTemplates() async {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 4))
        let rewriter = FakeRewriter(delay: .zero) { _ in "CPU at 97%." }
        let notice = await engine.phrase(cpu, as: .abliterated, allowExplicit: true, rewriter: rewriter)
        #expect(notice.tier == .template)
    }

    @Test func rewriteRequestCarriesRecentLines() async {
        let engine = PhrasingEngine(store: MemoryHistoryStore(), rng: SplitMix64(seed: 4))
        let seen = Mutex<[[String]]>([])
        let rewriter = FakeRewriter(delay: .zero) { request in
            let takes = ["one", "two", "three"]
            return seen.withLock { seen in
                seen.append(request.avoid)
                return "CPU busy at 97%, take \(takes[seen.count - 1])."
            }
        }
        for _ in 0..<3 { _ = await engine.phrase(cpu, as: .friendly, allowExplicit: false, rewriter: rewriter) }
        #expect(seen.withLock { $0 } == [[], ["CPU busy at 97%, take one."], ["CPU busy at 97%, take one.", "CPU busy at 97%, take two."]])
    }
}

@MainActor
func makeStore() throws -> (PersonaStore, UserDefaults, () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("persona-\(UUID().uuidString)")
    let suite = "persona.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = PersonaStore(defaults: defaults, directory: directory,
                             engine: PhrasingEngine(store: MemoryHistoryStore()), rewriter: nil)
    return (store, defaults, {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suite)
    })
}
