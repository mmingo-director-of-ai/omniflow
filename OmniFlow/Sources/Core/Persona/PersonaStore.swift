import Foundation
import Observation

/// Selected persona and phrasing preferences. New keys use the `persona.` prefix; no
/// existing preference key is read or written. Custom personas live in a 0600 JSON file.
@Observable @MainActor
final class PersonaStore {
    enum Key {
        static let selected = "persona.selectedID"
        static let allowExplicit = "persona.allowExplicitLanguage"
        static let variation = "persona.variationEnabled"
        static let modelRewrite = "persona.modelRewriteEnabled"
    }

    static let shared = PersonaStore()

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchLee/LocalData", isDirectory: true)
    }

    var selectedID: String { didSet { defaults.set(selectedID, forKey: Key.selected) } }
    /// Off by default. While off, explicit personas are hidden and never used.
    var allowExplicit: Bool { didSet { defaults.set(allowExplicit, forKey: Key.allowExplicit) } }
    var variationEnabled: Bool { didSet { defaults.set(variationEnabled, forKey: Key.variation) } }
    var modelRewriteEnabled: Bool { didSet { defaults.set(modelRewriteEnabled, forKey: Key.modelRewrite) } }
    private(set) var customPersonas: [Persona] = []
    private(set) var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored let engine: PhrasingEngine
    @ObservationIgnored var rewriter: (any NoticeRewriter)?

    init(defaults: UserDefaults = .standard, directory: URL = PersonaStore.defaultDirectory,
         engine: PhrasingEngine? = nil, rewriter: (any NoticeRewriter)? = PersonaStore.onDeviceRewriter()) {
        self.defaults = defaults
        fileURL = directory.appendingPathComponent("personas.json")
        self.engine = engine ?? PhrasingEngine(store: DefaultsNoticeHistoryStore(suiteName: nil))
        self.rewriter = rewriter
        selectedID = defaults.string(forKey: Key.selected) ?? Persona.standard.id
        allowExplicit = defaults.bool(forKey: Key.allowExplicit)
        variationEnabled = defaults.object(forKey: Key.variation) as? Bool ?? true
        modelRewriteEnabled = defaults.bool(forKey: Key.modelRewrite)
        customPersonas = Self.load(fileURL)
    }

    static func onDeviceRewriter() -> (any NoticeRewriter)? {
        #if canImport(FoundationModels)
        FoundationModelsNoticeRewriter()
        #else
        nil
        #endif
    }

    // MARK: Personas

    var allPersonas: [Persona] { Persona.builtIns + customPersonas }

    /// What the picker shows: explicit personas only once the user allows explicit language.
    var visiblePersonas: [Persona] { allPersonas.filter { allowExplicit || !$0.explicitLanguage } }

    var selectedPersona: Persona { allPersonas.first { $0.id == selectedID } ?? .standard }

    /// The persona in force. Turning the gate off while an explicit persona is selected
    /// falls back to Default without forgetting the selection.
    var effectivePersona: Persona { PhrasingEngine.effective(selectedPersona, allowExplicit: allowExplicit) }

    /// Append to assistant session instructions. Stable per persona for prewarm caching.
    var instructionsFragment: String { effectivePersona.instructionsFragment }

    @discardableResult
    func addCustom(name: String, tone: String, base: PersonaStyle, explicit: Bool, addressTerms: [String] = []) -> Persona {
        let persona = Persona.custom(name: name, tone: tone, base: base, explicit: explicit, addressTerms: addressTerms)
        customPersonas.append(persona)
        persist()
        return persona
    }

    func updateCustom(_ persona: Persona) {
        guard let index = customPersonas.firstIndex(where: { $0.id == persona.id }) else { return }
        customPersonas[index] = Persona.custom(id: persona.id, name: persona.displayName, tone: persona.toneInstructions,
                                               base: persona.style, explicit: persona.explicitLanguage,
                                               addressTerms: persona.addressTerms)
        persist()
    }

    func deleteCustom(id: String) {
        customPersonas.removeAll { $0.id == id }
        if selectedID == id { selectedID = Persona.standard.id }
        persist()
    }

    // MARK: Phrasing

    /// Tier 1 only: instant, for synchronous UI paths.
    func phraseNow(_ event: NoticeEvent) -> Notice {
        engine.phrase(event, as: selectedPersona, allowExplicit: allowExplicit, variation: variationEnabled)
    }

    /// Tier 2 when enabled and in time, Tier 1 otherwise.
    func phrase(_ event: NoticeEvent, timeout: Duration = PhrasingEngine.defaultTimeout) async -> Notice {
        await engine.phrase(event, as: selectedPersona, allowExplicit: allowExplicit, variation: variationEnabled,
                            rewriter: modelRewriteEnabled ? rewriter : nil, timeout: timeout)
    }

    #if canImport(FoundationModels)
    /// Call when the island opens or the persona changes so the first rewrite is warm.
    func prewarm() {
        guard modelRewriteEnabled, let rewriter = rewriter as? FoundationModelsNoticeRewriter else { return }
        let persona = effectivePersona
        Task { await rewriter.prewarm(for: persona) }
    }
    #endif

    // MARK: Storage

    private static func load(_ url: URL) -> [Persona] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([Persona].self, from: data) else { return [] }
        // Re-normalise on load so a hand-edited file cannot bypass the explicit gate.
        return saved.filter { !$0.isBuiltIn }.map {
            Persona.custom(id: $0.id, name: $0.displayName, tone: $0.toneInstructions, base: $0.style,
                           explicit: $0.explicitLanguage, addressTerms: $0.addressTerms)
        }
    }

    private func persist() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(customPersonas).write(to: fileURL, options: .atomic)
            // An atomic write replaces the file, so the mode is set after every write.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastError = nil
        } catch {
            lastError = "Custom personas could not be saved: \(error.localizedDescription)"
        }
    }
}
