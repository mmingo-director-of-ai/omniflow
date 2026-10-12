import SwiftUI
import AVFoundation

struct FlowSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Picker("Settings section", selection: $model.settingsTab) {
                Text("General").tag("General")
                Text("Dictation").tag("Dictation")
                Text("Personalization").tag("Personalization")
                Text("Privacy").tag("Privacy")
                Text("Assistant & Mac").tag("Companion")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .padding(6)
            .modifier(OmniFlowNavigationGlass(cornerRadius: 14))
            .frame(maxWidth: 720)
            Group {
            switch model.settingsTab {
            case "Companion":
                SettingsView(embeddedInShell: true)
            case "General":
            Form {
                Section("OmniFlow") {
                    Picker("Appearance", selection: $model.appearance) {
                        Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system")
                    }
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                    Toggle("Show the dictation bar", isOn: $model.showDictationBar)
                    LabeledContent("Voice pill position") {
                        HStack {
                            ForEach(OmniFlowPillZone.allCases, id: \.self) { zone in
                                Button(zone.title, systemImage: zone.symbol) {
                                    OmniFlowActivityPill.shared.dock(to: zone, on: NSApp.keyWindow?.screen)
                                }
                            }
                        }
                    }
                    Text("Drag the pill’s grip to see its three docking zones. The highlighted zone is where it will land. Placement is remembered for each display.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Open the main window on launch", isOn: $model.openHubOnLaunch)
                }
                Section("Shortcuts") {
                    LabeledContent("Push to talk", value: "Hold fn")
                    LabeledContent("Hands-free", value: "fn + space")
                    LabeledContent("Finish hands-free", value: "fn + space (or fn)")
                    LabeledContent("Cancel", value: "esc")
                    Text("Set “Press Globe key to” to “Do Nothing” in Keyboard Settings so macOS does not also open emoji. OmniFlow handles Fn while it runs. If system Dictation uses double-Fn, choose a different shortcut there.").font(.callout).foregroundStyle(.secondary)
                    Button("Open Keyboard Settings", action: model.openKeyboard)
                }
                OmniFlowLockSettings()
                OmniFlowSyncSettings()
                OmniFlowNotificationSettings()
                OmniFlowIslandPanelSettings()
                Section("Insights") {
                    Slider(value: $model.typingWPM, in: 20...120, step: 5) {
                        Text("Typing baseline: \(Int(model.typingWPM)) words/min")
                    }
                    Text("Used only to estimate typing time saved. Speaking speed is measured from your dictations.").font(.callout).foregroundStyle(.secondary)
                }
                if !model.settingsError.isEmpty { Text(model.settingsError).foregroundStyle(.red) }
            }.formStyle(.grouped).toggleStyle(OmniFlowSwitchStyle()).scrollContentBackground(.hidden)
            case "Dictation":
            Form {
                OmniFlowVoicePermissionsSection(model: model)
                Section("Microphone") {
                    Toggle("Reduce background noise", isOn: $model.reduceBackgroundNoise).disabled(model.busy)
                    Text("Uses Apple voice processing for noise and echo reduction. It may lower other audio. It does not identify your voice or guarantee rejection of other speakers.").font(.callout).foregroundStyle(.secondary)
                    LabeledContent("Last microphone check", value: model.audioProcessingStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Open Apple microphone modes") { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
                    Text("While recording, choose Voice Isolation in Apple's microphone modes when available. A close microphone or headset helps separate your speech. Thinking pauses do not end recording; the recording limit still applies.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Dictation") {
                    Toggle("Focus follows mouse", isOn: $model.focusFollowsMouse)
                    if model.focusFollowsMouse {
                        Button(model.pointerFocusPaused ? "Resume mouse-follow focus" : "Pause mouse-follow focus", action: model.togglePointerFocusPause)
                        Text("You can also pause from the menu bar or dictation bar. Pause lasts until you resume or relaunch OmniFlow.").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("System-wide while OmniFlow runs: hover over a window’s title bar, controls or content to raise it without clicking. The Focus & pointer page controls timing, raising and exclusions. Hover focus pauses throughout dictation, processing and delivery.").font(.callout).foregroundStyle(.secondary)
                    Toggle("Follow the focused text field", isOn: $model.followFocus).disabled(model.busy)
                    Text("Follows clicks and keyboard focus during recording and cleanup, then captures the destination immediately before paste. Once live text is written, it stays in that field. Pointer movement cannot redirect a recording: hover focus is paused until processing and delivery finish.").font(.callout).foregroundStyle(.secondary)
                    Toggle("Stream text into supported fields", isOn: $model.liveTextEnabled).disabled(model.busy)
                    Text("Native editable fields show live text. Other editors get one final paste; the dictation bar stays live.").font(.callout).foregroundStyle(.secondary)
                    Picker("Spoken language", selection: $model.localeID) {
                        ForEach(model.languages, id: \.self) { id in Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id) }
                    }.disabled(model.busy || model.preparing)
                    LabeledContent("Speech model", value: model.speechStatus)
                    Button(model.preparing ? "Preparing…" : "Prepare speech model") { model.checkSpeech(download: true) }.disabled(model.preparing || model.busy)
                    Picker("Recording limit", selection: $model.recordingLimit) {
                        Text("1 minute").tag(60); Text("3 minutes").tag(180); Text("5 minutes").tag(300)
                    }.disabled(model.busy)
                }
                Section("Translation") {
                    Picker("Output language", selection: $model.translationTargetID) {
                        Text("Same as spoken language").tag("")
                        ForEach(model.translationLanguages) { Text($0.name).tag($0.id) }
                    }.disabled(model.busy)
                    if !model.translationTargetID.isEmpty {
                        TranslationSetupView(sourceIdentifier: model.localeID, targetIdentifier: model.translationTargetID)
                    }
                    Text("Translation happens after cleanup. If a language is unavailable, the source text is preserved. Originals are saved when history is enabled.").font(.callout).foregroundStyle(.secondary)
                }
                Section("Apple Intelligence") {
                    Picker("Cleanup", selection: $model.polishMode) {
                        ForEach(PolishMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.disabled(model.busy)
                    Picker("Writing style", selection: $model.writingStyle) {
                        ForEach(WritingStyle.allCases, id: \.self) { style in Text(style.title).tag(style) }
                    }.disabled(model.polishMode != .polished || model.busy)
                    Text("APA-inspired prose spells ordinary counts below 10, with numerals for technical quantities. ASD-STE100-inspired technical is not certified STE100. Styles apply during on-device cleanup; they do not create citations.").font(.callout).foregroundStyle(.secondary)
                    Picker("Output style", selection: $model.outputStyle) {
                        Text("Natural prose").tag("natural")
                        Text("Structured Markdown").tag("markdown")
                        Text("Agent prompt").tag(AgentLayout.outputStyle)
                    }.disabled((model.polishMode != .polished && model.outputStyle != AgentLayout.outputStyle) || model.busy)
                    Text("Agent prompt lays dictation out for coding agents: each sentence on its own line, a blank line where the topic shifts, and spoken lists as bullets. Only line breaks and bullets change, never your words. Set it for your coding apps under Personalization.").font(.callout).foregroundStyle(.secondary)
                    Text(model.modelStatus).foregroundStyle(.secondary)
                    Text("Polished repairs grammar and flow, removes restarts and keeps explicit corrections. Light cleanup preserves phrasing. Verbatim skips cleanup; your explicit replacements and translation still apply. Apple spelling suggestions guide the local model, with your vocabulary taking priority. Rewrites are checked for meaning; uncertain results keep basic cleanup. Originals are saved when history is enabled.").font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).toggleStyle(OmniFlowSwitchStyle()).scrollContentBackground(.hidden)
            case "Personalization":
                DictationPreferencesView(store: model.dictationPreferences).disabled(model.busy)
            default:
            Form {
                OmniFlowVoicePermissionsSection(model: model)
                Section("Local history") {
                    Toggle("Save dictations and conversations", isOn: $model.saveHistory).disabled(model.busy)
                    Text("Transcripts and unfinished drafts are encrypted on this Mac. Optional iCloud sync copies completed transcripts and reading positions to your private iCloud account. Audio is never saved, and dictation does not use cloud inference.")
                    Text("History, conversations and assistant memory are encrypted on disk with a key in your login Keychain, and are restricted to your user account. If that key is removed, the encrypted files can’t be read. History stays until you move it to Trash or the retention period expires.").font(.callout).foregroundStyle(.secondary)
                    Picker("Keep completed dictations", selection: $model.retention) {
                        Text("Forever").tag(HistoryRetention.forever)
                        Text("7 days").tag(HistoryRetention.sevenDays)
                        Text("30 days").tag(HistoryRetention.thirtyDays)
                        Text("90 days").tag(HistoryRetention.ninetyDays)
                    }.disabled(model.busy || model.managingHistory)
                    Text("Expired completed dictations move to Trash. Interrupted, failed and ready-to-copy drafts stay. Empty Trash yourself to permanently erase them. Local usage metrics reflect retained history.").font(.callout).foregroundStyle(.secondary)
                    if !model.retentionNote.isEmpty { Text(model.retentionNote).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Open history folder", action: model.revealHistory)
                        Spacer()
                        Button("Move history to Trash…", action: model.clearHistory).disabled(model.busy || model.managingHistory || model.entries.isEmpty)
                    }
                }
                Section("Text insertion") {
                    Text("OmniFlow pastes into the selected destination after checking it has not changed. It restores the clipboard after verified insertion. For editors without confirmation, use Restore previous clipboard after checking the paste. Text in other apps follows their privacy rules.").font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).toggleStyle(OmniFlowSwitchStyle()).scrollContentBackground(.hidden)
            }
            }.frame(maxWidth: 800, maxHeight: .infinity)
                .background(Color.flowSurface)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared by both voice settings surfaces. A granted permission never implies
/// an input signal; show authorization, capture health and model readiness apart.
struct OmniFlowVoicePermissionsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var wake = WakeListener.shared

    var body: some View {
        Section {
            HStack {
                Text("Microphone access")
                Spacer()
                Label(model.microphonePermission.label,
                      systemImage: model.micReady ? "checkmark.circle" : "exclamationmark.triangle")
                if !model.micReady {
                    Button(model.microphonePermission.actionTitle, action: model.requestMicrophone)
                }
            }
            if !model.micReady { Text(model.microphonePermission.guidance).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Text("Accessibility")
                Spacer()
                Label(model.accessibilityReady ? "Allowed" : "Not allowed",
                      systemImage: model.accessibilityReady ? "checkmark.circle" : "exclamationmark.triangle")
                if !model.accessibilityReady { Button("Open Accessibility settings", action: model.requestAccessibility) }
            }
            LabeledContent("Fn shortcut", value: model.hotkeyReady ? "Ready" : (model.accessibilityReady ? "Unavailable" : "Needs Accessibility"))
            if model.accessibilityReady && !model.hotkeyReady {
                Text("Keyboard monitoring could not start. Check OmniFlow in Input Monitoring, then recheck permissions.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Input Monitoring") { model.openSettings("Privacy_ListenEvent") }
            }
            OmniFlowDictationMicrophonePicker(model: model)
            if model.phase == .starting || model.phase == .recording {
                ProgressView(value: model.level).accessibilityLabel("Dictation microphone input level")
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                if !model.transcript.isEmpty { Text(model.transcript).lineLimit(3).textSelection(.enabled) }
                HStack {
                    Button("Finish recording", action: model.finish).disabled(model.phase != .recording)
                    Button("Cancel recording") { model.cancel() }
                }
            } else if wake.enabled && wake.microphoneUID.isEmpty && wake.receivesAudio {
                ProgressView(value: wake.microphoneLevel).accessibilityLabel("System microphone input level")
                Text(wake.isQuiet ? "Permission allowed · no sound reaching OmniFlow" : "Microphone audio is reaching OmniFlow")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let issue = model.microphoneIssue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open Sound input", action: model.openSoundInput)
                Button("Recheck permissions", action: model.refreshPermissions)
                Spacer()
                Button("Test dictation") { model.begin(practice: true) }.disabled(!model.canRecord || model.busy)
            }
        } header: { Text("Permissions & input") }
        footer: {
            Text("Microphone access is required for voice. Accessibility enables Fn, pointer focus and insertion into other apps; you can test dictation here without it. Voice processing stays on this Mac; no separate Speech Recognition permission is needed. Testing here never pastes into another app.")
        }
        .onAppear { model.refreshPermissions() }
    }
}

/// Notification and Spotlight preferences. Stored in UserDefaults by their owners.
struct OmniFlowNotificationSettings: View {
    @State private var ambient = OmniFlowNotifications.shared.ambientEnabled
    @State private var approvals = OmniFlowNotifications.shared.approvalsEnabled
    @State private var spotlight = OmniFlowSpotlight.shared.enabled

    var body: some View {
        Section("Notifications & Spotlight") {
            Toggle("Notify me when an ambient rule fires", isOn: $ambient)
                .onChange(of: ambient) { _, value in OmniFlowNotifications.shared.ambientEnabled = value }
            Toggle("Notify me when an agent needs permission", isOn: $approvals)
                .onChange(of: approvals) { _, value in OmniFlowNotifications.shared.approvalsEnabled = value }
            Text("Permission notifications include Allow and Deny. They apply only to the request they show, and only while it is still waiting.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Show dictations in Spotlight", isOn: $spotlight)
                .onChange(of: spotlight) { _, value in OmniFlowSpotlight.shared.enabled = value }
            Text("Spotlight's index stays on this Mac, but anyone using your account can search it. Turning this off removes dictations from the index.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct OmniFlowLockSettings: View {
    @ObservedObject private var lock = OmniFlowAppLock.shared

    var body: some View {
        Section("Privacy lock") {
            Toggle("Require \(lock.biometryName) to see history, memory and conversations",
                   isOn: Binding(get: { lock.enabled }, set: { lock.setEnabled($0) }))
                .disabled(!lock.canAuthenticate && !lock.enabled)
            Picker("Lock after", selection: $lock.idleMinutes) {
                Text("1 minute away from OmniFlow").tag(1)
                Text("5 minutes away from OmniFlow").tag(5)
                Text("15 minutes away from OmniFlow").tag(15)
                Text("Only when the Mac sleeps or locks").tag(0)
            }.disabled(!lock.enabled)
            Button("Lock now", systemImage: "lock") { lock.lock() }.disabled(!lock.enabled)
            Text("OmniFlow always locks when your Mac sleeps, the screen locks, or OmniFlow restarts. Dictation, agent sessions and monitoring keep working while locked; Shortcuts can't read dictations, and dictations are kept out of Spotlight.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Dictation's microphone. "System default" follows macOS; a named microphone
/// stays in use even if the Mac's default input changes.
struct OmniFlowDictationMicrophonePicker: View {
    @ObservedObject var model: AppModel
    @State private var microphones = VoiceMicrophone.available()

    var body: some View {
        Picker("Dictation microphone", selection: $model.dictationMicrophoneUID) {
            Text("System default · " + (model.dictationMicrophoneUID.isEmpty ? model.microphoneInputName : VoiceMicrophone.health().name)).tag("")
            ForEach(microphones) { microphone in Text(microphone.name).tag(microphone.id) }
            if !model.dictationMicrophoneUID.isEmpty && !microphones.contains(where: { $0.id == model.dictationMicrophoneUID }) {
                Text("Chosen microphone (not connected)").tag(model.dictationMicrophoneUID)
            }
        }
        .disabled(model.busy)
        HStack {
            if let note = DictationInputDevice.plan(uid: model.dictationMicrophoneUID).note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Refresh microphones") { microphones = VoiceMicrophone.available() }
        }
    }
}


/// Which media pages the island carousel shows, and the news feeds to read.
struct OmniFlowIslandPanelSettings: View {
    @AppStorage(NotchLeePanel.musicKey) private var music = true
    @AppStorage(NotchLeePanel.weatherKey) private var weather = true
    @AppStorage(NotchLeePanel.newsKey) private var news = true
    @ObservedObject private var feeds = NewsFeedService.shared
    @State private var newFeed = ""
    @State private var feedError: String?

    var body: some View {
        Section("Island pages") {
            #if !APPSTORE
            Toggle("Music (what's playing, with controls)", isOn: $music)
            #endif
            Toggle("Weather", isOn: $weather)
            Toggle("News", isOn: $news)
            if news {
                ForEach(feeds.feeds, id: \.self) { feed in
                    HStack {
                        Text(feed).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button { feeds.removeFeed(feed) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(feed)")
                    }
                }
                HStack {
                    TextField("RSS or Atom feed address", text: $newFeed).textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add feed", action: add).disabled(newFeed.isEmpty)
                }
                if let feedError { Text(feedError).font(.callout).foregroundStyle(.red) }
                Text("Headlines are fetched only while the News page is showing. A one-line digest is written on this Mac by Apple Intelligence when it's available.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        feedError = feeds.addFeed(newFeed) ? nil : "Enter a full web address, such as https://example.org/feed.xml."
        if feedError == nil { newFeed = "" }
    }
}

