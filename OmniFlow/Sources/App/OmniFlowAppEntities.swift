import AppIntents
import Combine
import CoreSpotlight
import Foundation
import NaturalLanguage

// Shortcuts, Siri and Spotlight access to OmniFlow's own data. Everything runs
// on this Mac; nothing here sends text anywhere.

// MARK: - Dictations

struct DictationEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Dictation", numericFormat: "\(placeholder: .int) dictations")
    static let defaultQuery = DictationQuery()

    let id: UUID
    @Property(title: "Text") var text: String
    @Property(title: "Date") var date: Date
    @Property(title: "Destination") var destination: String

    init(_ entry: DictationEntry) {
        id = entry.id
        text = entry.displayText
        date = entry.date
        destination = entry.destination
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String(text.prefix(80)))",
                              subtitle: "\(date.formatted(date: .abbreviated, time: .shortened)) · \(destination)",
                              image: .init(named: OmniFlowSymbol.dictate, isTemplate: true))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = String(text.prefix(80))
        attributes.contentDescription = text
        attributes.contentCreationDate = date
        attributes.keywords = ["dictation", "OmniFlow", destination]
        return attributes
    }
}

struct DictationQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [DictationEntity] {
        guard !OmniFlowAppLock.shared.isLocked else { throw OmniFlowLockError.locked }
        let wanted = Set(identifiers)
        return AppModel.shared.entries.filter { wanted.contains($0.id) }.map(DictationEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [DictationEntity] {
        guard !OmniFlowAppLock.shared.isLocked else { throw OmniFlowLockError.locked }
        return AppModel.shared.entries
            .filter { $0.displayText.localizedCaseInsensitiveContains(string) || $0.destination.localizedCaseInsensitiveContains(string) }
            .prefix(50).map(DictationEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [DictationEntity] {
        guard !OmniFlowAppLock.shared.isLocked else { throw OmniFlowLockError.locked }
        return AppModel.shared.entries.prefix(10).map(DictationEntity.init)
    }
}

struct GetLatestDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Dictation"
    static let description = IntentDescription("Returns the text of your most recent OmniFlow dictation.")
    static let supportedModes: IntentModes = .background
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<DictationEntity?> & ProvidesDialog {
        guard !OmniFlowAppLock.shared.isLocked else { throw OmniFlowLockError.locked }
        guard let entry = AppModel.shared.entries.first else {
            return .result(value: nil, dialog: "There are no saved dictations yet.")
        }
        return .result(value: DictationEntity(entry), dialog: "\(String(entry.displayText.prefix(200)))")
    }
}

struct CopyDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Dictation"
    static let description = IntentDescription("Copies a saved dictation to the clipboard.")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Dictation") var dictation: DictationEntity
    static var parameterSummary: some ParameterSummary { Summary("Copy \(\.$dictation)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard !OmniFlowAppLock.shared.isLocked else { throw OmniFlowLockError.locked }
        OmniFlowClipboard.copy(dictation.text, confirmation: "Dictation copied")
        return .result(value: dictation.text)
    }
}

// MARK: - Writing

enum CleanUpStrength: String, AppEnum {
    case light, polished
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Clean-up strength")
    static let caseDisplayRepresentations: [CleanUpStrength: DisplayRepresentation] = [
        .light: "Light (fillers and punctuation)", .polished: "Polished"
    ]
}

struct CleanUpTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Up Text"
    static let description = IntentDescription("Removes fillers and fixes punctuation with Apple's on-device model, keeping your meaning.")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Text", inputOptions: .init(multiline: true)) var text: String
    @Parameter(title: "Strength", default: .polished) var strength: CleanUpStrength
    static var parameterSummary: some ParameterSummary { Summary("Clean up \(\.$text)") { \.$strength } }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = AppModel.shared
        let result = await model.cleanup.clean(text, locale: Locale(identifier: model.localeID), vocabulary: model.effectiveVocabulary,
                                               writingStyle: model.writingStyle, mode: strength == .light ? .light : .polished)
        return .result(value: result.text)
    }
}

enum TranslationTarget: String, AppEnum {
    case english = "en", spanish = "es", french = "fr", german = "de", italian = "it", portuguese = "pt",
         japanese = "ja", korean = "ko", chinese = "zh-Hans", dutch = "nl"
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Language")
    static let caseDisplayRepresentations: [TranslationTarget: DisplayRepresentation] = [
        .english: "English", .spanish: "Spanish", .french: "French", .german: "German", .italian: "Italian",
        .portuguese: "Portuguese", .japanese: "Japanese", .korean: "Korean", .chinese: "Chinese (Simplified)", .dutch: "Dutch"
    ]
}

enum OmniFlowIntentError: LocalizedError {
    case translationUnavailable(String)
    var errorDescription: String? {
        switch self { case .translationUnavailable(let note): note }
    }
}

struct TranslateTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate Text"
    static let description = IntentDescription("Translates text on your Mac with Apple's installed translation languages.")
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Text", inputOptions: .init(multiline: true)) var text: String
    @Parameter(title: "To", default: .english) var target: TranslationTarget
    static var parameterSummary: some ParameterSummary { Summary("Translate \(\.$text) to \(\.$target)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let source = Locale.Language(identifier: recognizer.dominantLanguage?.rawValue ?? "en")
        let result = await TranslationService().translate(text, source: source, target: Locale.Language(identifier: target.rawValue))
        guard result.didTranslate else { throw OmniFlowIntentError.translationUnavailable(result.note) }
        return .result(value: result.text)
    }
}

// MARK: - Agent sessions

struct AgentSessionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent session")
    static let defaultQuery = AgentSessionQuery()
    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Agent") var agent: String
    @Property(title: "Status") var status: String

    @MainActor init(_ task: AgentTask) {
        id = task.id
        name = task.name
        agent = switch task.source { case .claudeCode: "Claude Code"; case .agent: "Agent"; case .n8n: "n8n" }
        status = task.state.spokenStatus
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(agent) · \(status)", image: .init(systemName: "terminal"))
    }
}

struct AgentSessionQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [AgentSessionEntity] {
        AppState.shared.tasks.filter { identifiers.contains($0.id) }.map(AgentSessionEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [AgentSessionEntity] {
        AppState.shared.tasks.map(AgentSessionEntity.init)
    }
}

struct AgentStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Agent Status"
    static let description = IntentDescription("Lists the coding-agent sessions OmniFlow is watching and what each is doing.")
    static let supportedModes: IntentModes = .background
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[AgentSessionEntity]> & ProvidesDialog {
        let sessions = AppState.shared.tasks.map(AgentSessionEntity.init)
        let summary = sessions.isEmpty ? "No agent sessions are running."
            : sessions.map { "\($0.name): \($0.status)" }.joined(separator: ". ")
        return .result(value: sessions, dialog: "\(summary)")
    }
}

struct ShowAgentSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Agent Session"
    static let description = IntentDescription("Brings an agent session to the front of the island.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @Parameter(title: "Session") var session: AgentSessionEntity
    @MainActor func perform() async throws -> some IntentResult {
        AppState.shared.setFocus(session.id)
        AppState.shared.view = .overview
        // By identity: while a book is open, page 0 is Reading, not Sessions.
        AppState.shared.carouselPanel = .sessions
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)
        return .result()
    }
}

extension BotState {
    var spokenStatus: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .thinking: "thinking"
        case .searching: "searching"
        case .approval: "waiting for approval"
        case .question: "has a question"
        case .error: "error"
        case .finished: "finished"
        case .ratelimit: "rate limited"
        case .sleeping: "sleeping"
        case .dizzy: "confused"
        }
    }
}

// MARK: - Spotlight

/// Opt-in: dictations become searchable in Spotlight. The index is local to this Mac.
@MainActor
final class OmniFlowSpotlight {
    static let shared = OmniFlowSpotlight()
    static let key = "omniflow.spotlight.dictations"
    private var pending: Task<Void, Never>?
    private var subscription: AnyCancellable?

    func start() {
        guard subscription == nil else { return }
        subscription = AppModel.shared.$entries.dropFirst().sink { _ in
            Task { @MainActor in OmniFlowSpotlight.shared.refresh() }
        }
        refresh()
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set { UserDefaults.standard.set(newValue, forKey: Self.key); refresh() }
    }

    /// Debounced so a burst of history edits produces one index pass.
    func refresh() {
        pending?.cancel()
        pending = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            // Spotlight would show dictation text without asking, so the lock disables it.
            if enabled && !OmniFlowAppLock.shared.enabled {
                let entities = AppModel.shared.entries.filter { !$0.unfinished }.prefix(500).map(DictationEntity.init)
                try? await CSSearchableIndex.default().deleteAppEntities(ofType: DictationEntity.self)
                try? await CSSearchableIndex.default().indexAppEntities(Array(entities))
            } else {
                try? await CSSearchableIndex.default().deleteAppEntities(ofType: DictationEntity.self)
            }
        }
    }
}
