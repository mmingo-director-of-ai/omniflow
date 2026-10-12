import AppIntents

// Compiled into the iOS app and its widget extension. Widgets, controls, the
// Action button and Shortcuts all run these; `.foreground` intents perform in
// the app, so the extension build (OMNIFLOW_IOS_WIDGET) only carries inert bodies.
// The app needs no App Group for any of them.

enum OmniFlowLaunchAction: Sendable {
    case dictate, translate, newNote, stop
}

#if !OMNIFLOW_IOS_WIDGET
/// Hands widget and shortcut requests to the app's UI. A request that arrives
/// before the UI sets `handle` (a cold launch) waits for it, like PairingInbox.
@MainActor
final class OmniFlowLaunchRouter {
    static let shared = OmniFlowLaunchRouter()
    private var waiting: OmniFlowLaunchAction?
    var handle: ((OmniFlowLaunchAction) -> Void)? {
        didSet { if let waiting, let handle { self.waiting = nil; handle(waiting) } }
    }

    func request(_ action: OmniFlowLaunchAction) {
        if let handle { handle(action) } else { waiting = action }
    }
}
#endif

struct OmniFlowDictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Open OmniFlow and start dictating on your device.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        #if !OMNIFLOW_IOS_WIDGET
        OmniFlowLaunchRouter.shared.request(.dictate)
        #endif
        return .result()
    }
}

struct OmniFlowTranslateIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Translation"
    static let description = IntentDescription("Open OmniFlow and translate what you say, on your device.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        #if !OMNIFLOW_IOS_WIDGET
        OmniFlowLaunchRouter.shared.request(.translate)
        #endif
        return .result()
    }
}

struct OmniFlowNewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Start a new note in OmniFlow and dictate into it.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        #if !OMNIFLOW_IOS_WIDGET
        OmniFlowLaunchRouter.shared.request(.newNote)
        #endif
        return .result()
    }
}

/// The Live Activity's stop button. LiveActivityIntent runs in the app's
/// process without bringing it forward, so recording stops where you are.
struct OmniFlowStopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stop OmniFlow dictation or translation.")
    static let isDiscoverable = false
    @MainActor func perform() async throws -> some IntentResult {
        #if !OMNIFLOW_IOS_WIDGET
        OmniFlowLaunchRouter.shared.request(.stop)
        #endif
        return .result()
    }
}

#if !OMNIFLOW_IOS_WIDGET
/// Spotlight, Siri, Shortcuts and the Action button (Settings › Action Button ›
/// Shortcut › OmniFlow). Only one provider may exist in the app.
struct OmniFlowAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OmniFlowDictateIntent(),
                    phrases: ["Dictate with \(.applicationName)", "Start \(.applicationName) dictation"],
                    // App Shortcuts take only SF Symbol names; "waveform" is the closest to our mark.
                    shortTitle: "Dictate", systemImageName: "waveform")
        AppShortcut(intent: OmniFlowTranslateIntent(),
                    phrases: ["Translate with \(.applicationName)"],
                    shortTitle: "Translate", systemImageName: "character.bubble.fill")
        AppShortcut(intent: OmniFlowNewNoteIntent(),
                    phrases: ["New \(.applicationName) note"],
                    shortTitle: "New Note", systemImageName: "square.and.pencil")
    }
}
#endif
