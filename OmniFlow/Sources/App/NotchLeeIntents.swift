import AppIntents

struct TalkToNotchLeeIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Omni"
    static let description = IntentDescription("Open OmniFlow's local assistant. Your question is handled inside OmniFlow.")
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Siri may still own the microphone. Open the panel; its mic button starts capture.
        VoiceAssistant.shared.show()
        return .result()
    }
}

struct NotchLeeSessionSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get agent status in OmniFlow"
    static let description = IntentDescription("Read the latest status of the agent sessions connected to OmniFlow.")
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Display the result locally instead of passing private session text back to Siri.
        VoiceAssistant.shared.ask("status")
        return .result()
    }
}

struct NotchLeeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToNotchLeeIntent(), phrases: ["Talk to Omni in \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Talk to Omni", systemImageName: "mic")
        AppShortcut(intent: AgentStatusIntent(), phrases: ["Get agent status in \(.applicationName)", "What are my agents doing in \(.applicationName)"],
                    shortTitle: "Agent status", systemImageName: "list.bullet")
        AppShortcut(intent: OpenFreeFlowHistoryIntent(), phrases: ["Show my dictation history in \(.applicationName)"], shortTitle: "Dictation History", systemImageName: "clock.arrow.circlepath")
        AppShortcut(intent: StartFreeFlowDictationIntent(), phrases: ["Start local dictation in \(.applicationName)"], shortTitle: "Start Local Dictation", systemImageName: "waveform")
        AppShortcut(intent: FinishFreeFlowDictationIntent(), phrases: ["Finish local dictation in \(.applicationName)"], shortTitle: "Finish Local Dictation", systemImageName: "stop.circle")
        AppShortcut(intent: GetLatestDictationIntent(), phrases: ["Get my latest dictation from \(.applicationName)"], shortTitle: "Latest Dictation", systemImageName: "text.quote")
        AppShortcut(intent: CleanUpTextIntent(), phrases: ["Clean up text with \(.applicationName)"], shortTitle: "Clean Up Text", systemImageName: "wand.and.stars")
        AppShortcut(intent: TranslateTextIntent(), phrases: ["Translate text with \(.applicationName)"], shortTitle: "Translate Text", systemImageName: "translate")
        AppShortcut(intent: CancelFreeFlowDictationIntent(), phrases: ["Cancel local dictation in \(.applicationName)"], shortTitle: "Cancel Local Dictation", systemImageName: "xmark.circle")
    }
}
