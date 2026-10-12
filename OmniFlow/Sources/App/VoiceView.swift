import SwiftUI

struct VoiceView: View {
    @ObservedObject private var voice = VoiceAssistant.shared
    @ObservedObject private var cursor = AgentCursor.shared
    @ObservedObject private var wake = WakeListener.shared
    @ObservedObject private var workspace = IslandWorkspace.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Talk to OmniFlow").font(.system(size: 14, weight: .semibold))
                    Text(voice.shortcutAvailable ? "Hold ⌃⌥Space to talk" : "Click the mic to talk")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if voice.phase == .speaking {
                    Button("Stop speaking", systemImage: "stop.fill") { voice.stopSpeaking() }
                        .labelStyle(.iconOnly).buttonStyle(.press).help("Stop speaking")
                }
                Toggle("Spoken replies", isOn: $voice.spokenReplies)
                    .toggleStyle(OmniFlowSwitchStyle()).controlSize(.mini)
                    .font(.system(size: 11))
            }
            .padding(.leading, 64)
            .frame(height: 40)

            if wake.enabled {
                HStack(spacing: 8) {
                    WakeStatusIndicator(showsText: true)
                    if wake.receivesAudio {
                        ProgressView(value: wake.microphoneLevel)
                            .frame(width: 54)
                            .tint(wake.isCapturing ? .blue : .green)
                            .accessibilityLabel("Microphone input level")
                    }
                    Spacer(minLength: 0)
                }
                .help(wake.inputStatus)
            }

            if cursor.enabled {
                Label(cursor.status, systemImage: "cursorarrow")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).help(cursor.status)
            }

            FloatingChatReply()
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(NotchLeeTheme.sage)
                Text(voice.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if voice.voiceChatActive {
                    Button("End voice chat") { voice.cancel() }.controlSize(.small)
                }
                if voice.phase == .needsDownload {
                    Button("Prepare speech") { voice.beginListening(downloadIfNeeded: true) }.controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                TextField("Ask OmniFlow anything…", text: $workspace.assistantDraft)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .accessibilityLabel("Ask OmniFlow")
                    .onSubmit(submit)
                    .disabled(voice.isBusy)
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.press).accessibilityLabel("Ask")
                .disabled(voice.isBusy || workspace.assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(action: { voice.toggleMicrophone() }) {
                    Image(systemName: voice.isBusy ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(voice.phase == .listening ? Color.blue : NotchLeeTheme.sage)
                }
                .buttonStyle(.press)
                .accessibilityLabel(voice.phase == .listening ? "Stop and ask" : (voice.isBusy ? "Cancel" : "Start listening"))
                .help(voice.phase == .listening ? "Stop and ask" : "Start listening")
            }
            .padding(10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(14)
        .background(CardBackground(wash: nil))
        .onExitCommand {
            voice.cancel()
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)
        }
    }

    private func submit() {
        let text = workspace.assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !voice.isBusy else { return }
        workspace.assistantDraft = ""
        voice.ask(text)
    }
}

/// Shared by the resting island, its header and the assistant page. State comes
/// from actual microphone callbacks, rather than just the enabled preference.
struct WakeStatusIndicator: View {
    @ObservedObject private var wake = WakeListener.shared
    @ObservedObject private var voice = VoiceAssistant.shared
    var showsText = false
    private var indicator: WakeIndicatorState { voice.phase == .listening ? .listening : wake.indicator }

    private var color: Color {
        switch indicator {
        case .ready: .green
        case .listening: .blue
        case .quiet, .failed: .orange
        default: .secondary
        }
    }

    private var symbol: String {
        switch indicator {
        case .listening: "waveform"
        case .quiet, .failed: "exclamationmark.triangle.fill"
        case .off, .paused: "mic.slash"
        default: "mic.fill"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).frame(width: 16, height: 18)
            if showsText { Text(indicator.label).lineLimit(1) }
        }
        .font(.system(size: showsText ? 11 : 12, weight: .medium))
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(indicator.label)
        .accessibilityValue(wake.inputStatus)
        .help("\(indicator.label) · \(wake.inputStatus)")
    }
}

struct IslandVoiceButton: View {
    @ObservedObject private var wake = WakeListener.shared
    @ObservedObject private var voice = VoiceAssistant.shared

    var body: some View {
        Button { voice.toggleMicrophone() } label: {
            Group {
                if wake.enabled { WakeStatusIndicator() }
                else {
                    Image(systemName: voice.phase == .listening ? "waveform" : "mic")
                        .foregroundStyle(voice.phase == .listening ? Color.blue : Color(hex: "#C6CBD4"))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 24)
            .background(voice.phase == .listening ? Color.blue.opacity(0.16) : .clear, in: Capsule())
        }
        .buttonStyle(.press)
        .help(wake.enabled ? "\(wake.indicator.label) · \(wake.inputStatus)" : "Talk to OmniFlow · hold ⌃⌥Space")
        .accessibilityLabel("Talk to OmniFlow")
        .accessibilityValue(wake.enabled ? wake.indicator.label : "Hold Control–Option–Space to talk")
    }
}

/// Streaming text stays above the speaking indicator on the headless surface.
struct FloatingChatReply: View {
    @ObservedObject private var voice = VoiceAssistant.shared
    @ObservedObject private var privacy = OmniFlowAppLock.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if privacy.isLocked {
                    Label("Unlock OmniFlow to read this conversation", systemImage: "lock")
                } else if !voice.response.isEmpty {
                    Text(voice.response).textSelection(.enabled)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if !voice.transcript.isEmpty {
                    Text(voice.transcript).foregroundStyle(.secondary)
                } else {
                    Text(voice.message).foregroundStyle(.secondary)
                }
            }.font(.system(size: 14)).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: voice.response.isEmpty)
        .accessibilityLabel("Conversation reply")
    }
}
