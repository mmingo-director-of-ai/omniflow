import SwiftUI
import AppKit

struct SettingsView: View {
    var embeddedInShell = false
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var voice = VoiceAssistant.shared
    @ObservedObject private var agentPreferences = AgentPreferences.shared
    @ObservedObject private var cursor = AgentCursor.shared
    @ObservedObject private var wake = WakeListener.shared
    @ObservedObject private var cursorActions = CursorActions.shared
    @ObservedObject private var focusSettings = OmniFlowFocusSettings.shared
    @AppStorage("localTelemetryEnabled") private var localTelemetryEnabled = true

    @State private var statusMessage: String = ""
    @State private var microphones: [VoiceMicrophone] = []
    @State private var showDiff: Bool = false
    @State private var pendingHookJSON: String = ""
    @State private var hookNeedsUpdate: Bool = HookServer.hooksNeedUpdate()

    #if !APPSTORE
    @State private var geminiHooksInstalled: Bool = HookServer.geminiHooksInstalled()
    @State private var showGeminiDiff: Bool = false
    @State private var pendingGeminiJSON: String = ""
    @State private var geminiPendingInstall: Bool = true

    @State private var agyHooksInstalled: Bool = HookServer.agyHooksInstalled()
    @State private var showAgyDiff: Bool = false
    @State private var pendingAgyJSON: String = ""
    @State private var agyPendingInstall: Bool = true

    @State private var codexHooksInstalled: Bool = HookServer.codexHooksInstalled()
    @State private var showCodexDiff: Bool = false
    @State private var pendingCodexJSON: String = ""
    @State private var codexPendingInstall: Bool = true
    #endif

    // Hotkey
    @State private var hotkeyFlags: UInt    = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16   = AppState.shared.hotkeyCode

    // Bindings in minutes for the absence field
    private var absenceMinutes: Binding<Double> {
        Binding(
            get: { state.absenceInterval / 60 },
            set: { state.absenceInterval = max(1, $0) * 60 }
        )
    }

    private var positionRange: ClosedRange<CGFloat> {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == state.islandDisplayID
        } ?? NSScreen.main
        let length = state.islandEdge.isVertical ? (screen?.frame.height ?? 900) : (screen?.frame.width ?? 1440)
        return -(length / 2)...(length / 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embeddedInShell {
                OmniFlowPageHeading("Settings", subtitle: "Make OmniFlow feel at home on your Mac.")
                    .padding(24)
            }
            Form {
                companionOptions
                OmniFlowVoicePermissionsSection(model: model)
                agentOptions
                voiceOptions
                wakeOptions
                Section("Sound") {
                    Toggle("Enable sounds", isOn: $state.soundEnabled)
                    LabeledContent("Volume") {
                        Slider(value: $state.soundVolume, in: 0...0.2)
                            .accessibilityLabel("Sound volume").disabled(!state.soundEnabled)
                        Text("\(Int(state.soundVolume / 0.2 * 100))%")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                }
                diagnosticsOptions
                #if !APPSTORE
                accessOptions
                cursorOptions
                #endif
                notchlyOptions
                if !embeddedInShell {
                    Section("Startup") {
                        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        if !model.settingsError.isEmpty { Text(model.settingsError).foregroundStyle(.red) }
                    }
                }
                Section {
                    agentConnections
                }
                Section("About") {
                    LabeledContent("Version", value: OmniFlowBuildStamp.current.version)
                    LabeledContent("Build", value: OmniFlowBuildStamp.current.build)
                    LabeledContent("Commit") { Text(OmniFlowBuildStamp.current.sha).monospaced().textSelection(.enabled) }
                }
                if !statusMessage.isEmpty {
                    Text(statusMessage).font(.callout)
                        .foregroundStyle(statusMessage.hasPrefix("❌") ? Color.red : Color.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.flowSurface)
            .toggleStyle(OmniFlowSwitchStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var companionOptions: some View {
        Section {
            if !embeddedInShell {
                Picker("Appearance", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Show the dictation bar", isOn: $model.showDictationBar)
            }
            Toggle("Show island", isOn: $state.notchlyEnabled)
            Toggle("Show OmniFlow in the Dock", isOn: $focusSettings.values.showInDock)
            HStack {
                Button("Focus & pointer") { IslandWorkspace.shared.show(.focus) }
                Button("Monitoring") { IslandWorkspace.shared.show(.system) }
                Button("Shortcuts") {
                    OmniFlowShortcutGuideCoordinator.shared.openForFrontmostApp()
                    IslandWorkspace.shared.show(.shortcuts)
                }
            }
        } header: { Text("Companion") }
        footer: { Text("Dictation and the assistant remain available when the island is off.") }
    }

    private var agentOptions: some View {
        Section {
            Toggle("Enable agent", isOn: Binding(get: { agentPreferences.enabled }, set: { agentPreferences.setEnabled($0) }))
            #if APPSTORE
            Text("The agent uses Apple Intelligence. Dictation is independent of this setting.")
                .font(.callout).foregroundStyle(.secondary)
            #else
            Toggle("Use stronger local model", isOn: Binding(get: { agentPreferences.useStrongerModel }, set: { agentPreferences.setStrongerModel($0) }))
                .disabled(!agentPreferences.enabled)
            Text("The standard agent uses Apple Intelligence. The stronger model uses GLM on your Mac’s GPU through MLX and keeps about 18–22 GB of memory ready while OmniFlow is open. Requires the installed GLM model. Dictation is independent of these settings.")
                .font(.callout).foregroundStyle(.secondary)
            #endif
        } header: { Text("Agent") }
    }

    private var voiceOptions: some View {
        Section {
            Picker("Assistant microphone", selection: $wake.microphoneUID) {
                Text("System default").tag("")
                ForEach(microphones) { microphone in Text(microphone.name).tag(microphone.id) }
                if !wake.microphoneUID.isEmpty && !microphones.contains(where: { $0.id == wake.microphoneUID }) {
                    Text("Selected microphone disconnected").tag(wake.microphoneUID)
                }
            }.disabled(voice.isBusy)
            Button("Refresh microphones") { microphones = VoiceMicrophone.available() }
            Toggle("Speak replies", isOn: $voice.spokenReplies)
            KokoroReaderSettings(assistant: true) { voice.stopSpeaking(); voice.refreshVoice() }
            Text(voice.voiceStatus).font(.callout).foregroundStyle(.secondary)
            LabeledContent("Pace") {
                Slider(value: $voice.speechRate, in: 0.7...1.3, step: 0.05).accessibilityLabel("Voice pace")
                Text(voice.speechRate, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().frame(width: 42, alignment: .trailing)
            }
            HStack {
                Button(voice.phase == .speaking ? "Stop preview" : "Preview voice") {
                    if voice.phase == .speaking { voice.stopSpeaking() } else { voice.previewVoice() }
                }.disabled(voice.isBusy || !state.soundEnabled)
                Button("Refresh availability") { voice.refreshVoice() }
                Spacer()
                Button("Open assistant") { voice.show() }
            }
        } header: { Text("Assistant voice") }
        footer: {
            Text(voice.shortcutAvailable
                ? "Hold Control–Option–Space to ask the assistant. Use Fn for dictation. Speech is processed on this Mac; language support may need to download first."
                : "Use the assistant’s microphone button to talk. Its keyboard shortcut is unavailable. Speech is processed on this Mac.")
        }
        .onAppear { voice.refreshVoice(); microphones = VoiceMicrophone.available() }
    }

    private var wakeOptions: some View {
        Section {
            Toggle("Listen for “Omni” or “Hey Omni”", isOn: $wake.enabled).disabled(!agentPreferences.enabled)
            LabeledContent("Status") { WakeStatusIndicator(showsText: true) }
            if wake.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: wake.microphoneLevel)
                        .help(wake.audioFormat).accessibilityLabel("Microphone input level")
                    Text(wake.inputStatus).font(.callout).foregroundStyle(.secondary)
                }
            }
            if wake.canRetry { Button("Retry wake listening") { wake.retry() } }
        } header: { Text("Hands free") }
        footer: {
            Text("The meter moves when speech reaches the microphone. Wake listening uses on-device recognition and more power than Siri’s dedicated wake detector. Speech before “Omni” is discarded; audio is never saved.")
        }
    }

    private var diagnosticsOptions: some View {
        Section {
            Toggle("Keep local performance telemetry", isOn: $localTelemetryEnabled)
            HStack {
                Button("Open conversations") { OmniFlowShellController.shared.showFlowPage("Conversations") }
                Button("Manage memory") { IslandWorkspace.shared.show(.memory) }
                Spacer()
                Button("Show local data folder") {
                    try? NotchLeeStorage.prepare(NotchLeeStorage.root)
                    NSWorkspace.shared.open(NotchLeeStorage.root)
                }
            }
            LabeledContent("On-device assistant", value: AtlasRunnerSelection.status)
                .font(.callout).foregroundStyle(.secondary)
        } header: { Text("Local history and diagnostics") }
        footer: {
            Text("Performance logs stay on this Mac for 14 days. They contain timings and event types, never prompts, transcripts, file contents or email text. No remote collector is configured.")
        }
    }

    #if !APPSTORE
    @ViewBuilder private var accessOptions: some View {
        Section("Connections") {
            LabeledContent("Local tools and remote services") {
                Button("Manage connections") { IslandWorkspace.shared.show(.connections) }
            }
        }
        Section {
            Text("OmniFlow can inspect processes, memory, files and the current window. macOS controls access to protected folders and other apps.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Accessibility…") { cursor.requestAccessibility() }
                Button("Screen Recording…") { CGRequestScreenCaptureAccess() }
                Button("Full Disk Access…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
        } header: { Text("Local access") }
        footer: {
            Text("Speech and AI run on this Mac. Enabled remote MCP tools can send the arguments needed for their requests. Transcripts and telemetry stay local.")
        }
    }

    private var cursorOptions: some View {
        Section {
            Toggle("Use the OmniFlow pointer", isOn: $cursor.enabled)
            LabeledContent("Size") {
                Slider(value: $cursor.pointerScale, in: AgentPointerAppearance.scaleRange, step: 0.05)
                    .accessibilityLabel("Agent cursor size")
                Text("\(Int((cursor.pointerScale * 100).rounded()))%")
                    .monospacedDigit().frame(width: 46, alignment: .trailing)
            }
            ColorPicker("Outline color", selection: Binding(
                get: { Color(hex: cursor.pointerColorHex) },
                set: { value in
                    guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                    cursor.pointerColorHex = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                        Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                }), supportsOpacity: false)
            HStack {
                Button("Open cursor actions") { cursorActions.engage(at: NSEvent.mouseLocation) }
                Button("Reset appearance") { cursor.resetAppearance() }
            }
            Text(cursor.status).font(.callout).textSelection(.enabled)
            if cursor.enabled && !cursorActions.gesturesAvailable {
                Text("Cursor gestures need Accessibility access.").foregroundStyle(.secondary)
            }
            if !cursor.hasAccessibility { Button("Enable Accessibility…") { cursor.requestAccessibility() } }
            if cursor.pointerUnavailable {
                Button("macOS pointer colors…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display")!)
                }
            }
        } header: { Text("Agent cursor") }
        footer: {
            Text("⌘ right-click for actions · ⌘ drag to capture a region · ⌃⌥C for selection actions. Ordinary right-click keeps the app’s menu; supported apps also offer Ask OmniFlow in Services. The arrow keeps a white fill; text and resize cursors stay native. Context is captured only when you ask, and password fields are excluded.")
        }
    }
    #endif

    @ViewBuilder private var notchlyOptions: some View {
        Section("Island") {
            Toggle("Liquid Glass on the island", isOn: $state.liquidGlass)
            Toggle("Expand on hover", isOn: $state.expandOnHover)
            LabeledContent("Position along edge") {
                Slider(value: $state.islandXOffset, in: positionRange, step: 1).accessibilityLabel("Island position")
                Button("Center") { state.islandXOffset = 0 }
            }
            Text("Drag the island along any screen edge. The slider adjusts its position on that edge.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Close after inactivity") {
                TextField("Seconds", value: $state.autoCloseInterval, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 64)
                Text("seconds")
            }
            LabeledContent("Hide when idle") {
                TextField("Minutes", value: absenceMinutes, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 64)
                Text("minutes")
            }
            Toggle("Show the island with a shortcut", isOn: $state.hotkeyEnabled)
            if state.hotkeyEnabled {
                LabeledContent("Island shortcut") {
                    ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode)
                        .onChange(of: hotkeyFlags) { _, v in state.hotkeyFlags = v }
                        .onChange(of: hotkeyCode) { _, v in state.hotkeyCode = v }
                }
            }
        }
    }

    private var agentConnections: some View {
                DisclosureGroup("Agent connections") {
                    VStack(alignment: .leading, spacing: 18) {
                // MARK: Hooks
                GroupBox("Claude Code Hooks") {
                    VStack(alignment: .leading, spacing: 10) {
                        if hookNeedsUpdate {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Hook timeout outdated — update to fix approvals")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            }
                            #if APPSTORE
                            Button("Update hooks") { installHooksAppStore() }
                            #else
                            Button("Update hooks") { installHooks() }
                            #endif
                        }
                        #if APPSTORE
                        Text("~/.claude/coucou/nb-hook")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button("Install hooks") { installHooksAppStore() }
                                .buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent)
                            Button("Uninstall") { uninstallHooksAppStore() }
                                .buttonStyle(.bordered)
                        }
                        #else
                        Text("nb-hook : \(HookServer.hookScriptPath)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button("Install hooks") { installHooks() }
                                .buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent)
                            Button("Uninstall") { uninstallHooks() }
                                .buttonStyle(.bordered)
                        }
                        #endif

                        #if !APPSTORE
                        if showDiff {
                            ScrollView {
                                Text(pendingHookJSON)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 140)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)

                            HStack {
                                Button("Confirm & write") { confirmInstall() }
                                    .buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent)
                                Button("Cancel") { showDiff = false; pendingHookJSON = "" }
                                    .buttonStyle(.bordered)
                            }
                        }
                        #endif
                    }
                    .padding(6)
                }

                // MARK: Codex CLI / Gemini CLI / Antigravity Hooks
                #if !APPSTORE
                GroupBox("Codex CLI Hooks") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(codexHooksInstalled
                             ? "Hooks installed — run /hooks in Codex to trust them, then restart Codex"
                             : "~/.codex/hooks.json")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button("Install hooks") { triggerCodexPreview(install: true) }
                                .buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent)
                            Button("Uninstall") { triggerCodexPreview(install: false) }
                                .buttonStyle(.bordered)
                        }
                        if showCodexDiff {
                            ScrollView {
                                Text(pendingCodexJSON)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 140)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            HStack {
                                Button("Confirm & write") { confirmCodexOp() }
                                    .buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent)
                                Button("Cancel") { showCodexDiff = false; pendingCodexJSON = "" }
                                    .buttonStyle(.bordered)
                            }
                        }
                        Text("After installing, open Codex and run /hooks to review and trust the OmniFlow hooks.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Gemini CLI Hooks") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(geminiHooksInstalled
                             ? "Hooks installed — restart Gemini CLI to activate"
                             : "~/.gemini/settings.json")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button("Install hooks") { triggerGeminiPreview(install: true) }
                                .buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent)
                            Button("Uninstall") { triggerGeminiPreview(install: false) }
                                .buttonStyle(.bordered)
                        }
                        if showGeminiDiff {
                            ScrollView {
                                Text(pendingGeminiJSON)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 140)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            HStack {
                                Button("Confirm & write") { confirmGeminiOp() }
                                    .buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent)
                                Button("Cancel") { showGeminiDiff = false; pendingGeminiJSON = "" }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Antigravity Hooks") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(agyHooksInstalled
                             ? "Hooks installed — restart Antigravity to activate"
                             : "~/.gemini/config/hooks.json")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button("Install hooks") { triggerAgyPreview(install: true) }
                                .buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent)
                            Button("Uninstall") { triggerAgyPreview(install: false) }
                                .buttonStyle(.bordered)
                        }
                        if showAgyDiff {
                            ScrollView {
                                Text(pendingAgyJSON)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 140)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            HStack {
                                Button("Confirm & write") { confirmAgyOp() }
                                    .buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent)
                                Button("Cancel") { showAgyDiff = false; pendingAgyJSON = "" }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(6)
                }
                #endif

                    }
                }

    }

    // MARK: - App Store: hooks via NSOpenPanel + security-scoped bookmark

    #if APPSTORE
    /// Opens NSOpenPanel to select ~/.claude, then writes hooks directly.
    /// NSOpenPanel grants sandbox access immediately — no security-scoped bookmark needed.
    private func pickClaudeFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Select your .claude folder (press ⇧⌘. to show hidden files)"
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // getpwuid bypasses CFFIXED_USER_HOME and always returns the real user home
        let realHomePath = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? "/Users/\(NSUserName())"
        panel.directoryURL = URL(fileURLWithPath: realHomePath)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.lastPathComponent == ".claude" else {
            statusMessage = "❌ Select the .claude folder (hidden, in your Home directory)."
            return nil
        }
        return url
    }

    private func installHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        let alert = NSAlert()
        alert.messageText = "Install OmniFlow hooks in ~/.claude?"
        alert.informativeText = "Will write:\n• ~/.claude/coucou/nb-hook\n• ~/.claude/settings.json (backup created first)"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookServer.shared.installAndWriteClaudeHooksAppStore(claudeURL: claudeURL)
            hookNeedsUpdate = false
            statusMessage = "✓ Hooks installed — restart VS Code to activate."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func uninstallHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        do {
            try HookServer.shared.uninstallClaudeHooksAppStore(claudeURL: claudeURL)
            statusMessage = "✓ Hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif

    private func installHooks() {
        do {
            pendingHookJSON = try HookServer.shared.previewClaudeHooks()
            showDiff = true
            statusMessage = "Review the JSON below before confirming."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmInstall() {
        do {
            try HookServer.shared.writeClaudeHooks()
            showDiff = false
            statusMessage = "✓ Hooks installed in ~/.claude/settings.json"
            pendingHookJSON = ""
            hookNeedsUpdate = false
        } catch {
            statusMessage = "❌ Write error: \(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            try HookServer.shared.uninstallClaudeHooks()
            statusMessage = "✓ Hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    #if !APPSTORE
    private func triggerCodexPreview(install: Bool) {
        do {
            codexPendingInstall = install
            pendingCodexJSON = try HookServer.shared.previewCodexHooks(install: install)
            showCodexDiff = true
            statusMessage = "Review the JSON below before confirming."
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmCodexOp() {
        do {
            try HookServer.shared.writeCodexHooks()
            showCodexDiff = false
            pendingCodexJSON = ""
            codexHooksInstalled = codexPendingInstall
            statusMessage = codexPendingInstall
                ? "✓ Codex hooks installed in ~/.codex/hooks.json — run /hooks in Codex to trust them."
                : "✓ Codex hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerGeminiPreview(install: Bool) {
        do {
            geminiPendingInstall = install
            pendingGeminiJSON = try HookServer.shared.previewGeminiHooks(install: install)
            showGeminiDiff = true
            statusMessage = "Review the JSON below before confirming."
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmGeminiOp() {
        do {
            try HookServer.shared.writeGeminiHooks()
            showGeminiDiff = false
            pendingGeminiJSON = ""
            geminiHooksInstalled = geminiPendingInstall
            statusMessage = geminiPendingInstall
                ? "✓ Gemini CLI hooks installed in ~/.gemini/settings.json"
                : "✓ Gemini CLI hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerAgyPreview(install: Bool) {
        do {
            agyPendingInstall = install
            pendingAgyJSON = try HookServer.shared.previewAgyHooks(install: install)
            showAgyDiff = true
            statusMessage = "Review the JSON below before confirming."
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmAgyOp() {
        do {
            try HookServer.shared.writeAgyHooks()
            showAgyDiff = false
            pendingAgyJSON = ""
            agyHooksInstalled = agyPendingInstall
            statusMessage = agyPendingInstall
                ? "✓ Antigravity hooks installed in ~/.gemini/config/hooks.json"
                : "✓ Antigravity hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif
}

// MARK: - Shortcut recorder button

struct ShortcutRecorderButton: View {
    @Binding var flags: UInt
    @Binding var code: UInt16
    @State private var isRecording = false

    var body: some View {
        Button {
            guard !isRecording else { return }
            isRecording = true
            var token: Any?
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard !mods.isEmpty else { return event }
                DispatchQueue.main.async {
                    self.flags = mods.rawValue
                    self.code = event.keyCode
                    self.isRecording = false
                    if let t = token { NSEvent.removeMonitor(t) }
                }
                return nil
            }
        } label: {
            Text(isRecording ? "Press keys…" : shortcutLabel)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isRecording ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.press)
    }

    private var shortcutLabel: String {
        let f = NSEvent.ModifierFlags(rawValue: flags)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += keyChar(code)
        return s.isEmpty ? "None" : s
    }

    private func keyChar(_ c: UInt16) -> String {
        let map: [UInt16: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 31:"O", 32:"U",
            34:"I", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M", 49:"Space", 50:"`", 27:"-"
        ]
        return map[c] ?? "·"
    }
}
