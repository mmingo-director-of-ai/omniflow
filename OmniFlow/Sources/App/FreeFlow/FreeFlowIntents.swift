import AppIntents
import Foundation

/// A narrow main-actor boundary keeps intents on the same state machine as the app.
@MainActor
protocol FreeFlowIntentTarget: AnyObject {
    var phase: AppModel.Phase { get }
    var busy: Bool { get }
    var canRecord: Bool { get }
    var isLocalDictationSession: Bool { get }
    func openIntentPage(_ page: String)
    func begin(practice: Bool)
    func finish()
    func cancel(message: String)
}

extension AppModel: FreeFlowIntentTarget {
    func openIntentPage(_ page: String) {
        selectedPage = page
        onOpenHub?()
    }
}

enum FreeFlowIntentCommand: Equatable {
    case open, history, start, finish, cancel

    init?(url: URL) {
        guard ["omniflow", "freeflow"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        switch url.host?.lowercased() {
        case "open": self = .open
        case "history": self = .history
        case "start-local": self = .start
        case "finish-local": self = .finish
        case "cancel-local": self = .cancel
        default: return nil
        }
    }
}

enum FreeFlowIntentError: LocalizedError {
    case unavailable, notReady, busy, notRecording, stillStarting, externalSession
    var errorDescription: String? {
        switch self {
        case .unavailable: "OmniFlow is still opening. Try the action again."
        case .notReady: "Open OmniFlow and finish microphone and speech model setup before starting dictation."
        case .busy: "OmniFlow is already working. Finish or cancel the current action first."
        case .notRecording: "There is no active local dictation to control."
        case .stillStarting: "The microphone is still starting. Wait for the listening indicator, then finish."
        case .externalSession: "Use the OmniFlow dictation bar to control a session that types into another app."
        }
    }
}

@MainActor
final class FreeFlowIntentBridge {
    static let shared = FreeFlowIntentBridge()
    weak var model: (any FreeFlowIntentTarget)?

    static func register(model: AppModel) {
        shared.model = model
        NotchLeeShortcuts.updateAppShortcutParameters()
    }

    func run(_ command: FreeFlowIntentCommand) throws {
        guard let model else { throw FreeFlowIntentError.unavailable }
        switch command {
        case .open: model.openIntentPage("Home")
        case .history: model.openIntentPage("Recent")
        case .start:
            guard !model.busy else { throw FreeFlowIntentError.busy }
            guard model.canRecord else {
                model.openIntentPage("Home")
                throw FreeFlowIntentError.notReady
            }
            // Siri/Shortcuts owns focus. Never capture it as an insertion destination.
            model.openIntentPage("Home")
            model.begin(practice: true)
        case .finish:
            guard model.phase != .starting else { throw FreeFlowIntentError.stillStarting }
            guard model.phase == .recording else { throw FreeFlowIntentError.notRecording }
            guard model.isLocalDictationSession else { throw FreeFlowIntentError.externalSession }
            model.finish()
        case .cancel:
            guard [.starting, .recording, .processing].contains(model.phase) else { throw FreeFlowIntentError.notRecording }
            guard model.isLocalDictationSession else { throw FreeFlowIntentError.externalSession }
            model.cancel(message: "Local dictation cancelled from Shortcuts")
        }
    }
}

struct OpenFreeFlowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open OmniFlow"
    static let description = IntentDescription("Open the OmniFlow dictation window.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        try FreeFlowIntentBridge.shared.run(.open)
        return .result()
    }
}

struct OpenFreeFlowHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Dictation History"
    static let description = IntentDescription("Show transcripts saved locally in OmniFlow. This action does not return transcript text to Shortcuts.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        try FreeFlowIntentBridge.shared.run(.history)
        return .result()
    }
}

struct StartFreeFlowDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Local Dictation"
    static let description = IntentDescription("Start hands-free dictation in OmniFlow. Text stays in local history and is not typed into another app. Complete microphone and speech model setup first.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        try FreeFlowIntentBridge.shared.run(.start)
        return .result()
    }
}

struct FinishFreeFlowDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Local Dictation"
    static let description = IntentDescription("Stop a local OmniFlow recording and begin processing it. The finished transcript appears in history; this action does not wait for processing or return text.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        try FreeFlowIntentBridge.shared.run(.finish)
        return .result()
    }
}

struct CancelFreeFlowDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Local Dictation"
    static let description = IntentDescription("Cancel an active local OmniFlow dictation. Existing partial transcript checkpoints remain in history.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        try FreeFlowIntentBridge.shared.run(.cancel)
        return .result()
    }
}
