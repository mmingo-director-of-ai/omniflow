import AppIntents

// Compiled into both the app and the widget extension. Widget buttons need the
// type in the extension; `.foreground` runs perform() in the OmniFlow app, so the
// extension build only carries an inert body.

struct WidgetStartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Start hands-free dictation in OmniFlow.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        #if !OMNIFLOW_WIDGET
        try FreeFlowIntentBridge.shared.run(.start)
        #endif
        return .result()
    }
}

struct WidgetAskOmniFlowIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Omni"
    static let description = IntentDescription("Open Omni, OmniFlow's on-device assistant.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        #if !OMNIFLOW_WIDGET
        VoiceAssistant.shared.show()
        #endif
        return .result()
    }
}

struct WidgetOpenMonitoringIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Monitoring"
    static let description = IntentDescription("Show system and agent monitoring in OmniFlow.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor func perform() async throws -> some IntentResult {
        #if !OMNIFLOW_WIDGET
        IslandWorkspace.shared.show(.system)
        #endif
        return .result()
    }
}

struct WidgetToggleFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Focus Follows Mouse"
    static let description = IntentDescription("Turn OmniFlow's focus-follows-mouse on or off.")
    static let supportedModes: IntentModes = [.foreground(.dynamic)]
    @MainActor func perform() async throws -> some IntentResult {
        #if !OMNIFLOW_WIDGET
        OmniFlowFocusController.shared.enabled.toggle()
        OmniFlowWidgetPublisher.shared.publish(force: true)
        #endif
        return .result()
    }
}

/// Drives the Control Center toggle; the value is the new state, not a flip.
struct WidgetSetFocusIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Focus Follows Mouse"
    static let description = IntentDescription("Turn OmniFlow's focus-follows-mouse on or off.")
    static let supportedModes: IntentModes = [.foreground(.dynamic)]
    @Parameter(title: "Enabled") var value: Bool
    @MainActor func perform() async throws -> some IntentResult {
        #if !OMNIFLOW_WIDGET
        OmniFlowFocusController.shared.enabled = value
        OmniFlowWidgetPublisher.shared.publish(force: true)
        #endif
        return .result()
    }
}
