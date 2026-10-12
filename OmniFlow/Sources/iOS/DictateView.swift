import SwiftUI

/// Record → review → Copy/Share. Idle shows a calm prompt and the last
/// dictation; recording fills the screen with the words as they arrive over a
/// voice-reactive aura; review lays out the result with its actions.
struct DictateView: View {
    @EnvironmentObject private var flow: IOSFlowModel
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var space

    private var live: Bool { flow.phase == .recording || flow.phase == .preparing || flow.phase == .finishing }

    var body: some View {
        ZStack {
            Theme.backdrop
            ListeningAura(active: flow.phase == .recording) { IOSMicrophone.shared.snapshot().level }
            ScrollView {
                Group {
                    switch flow.phase {
                    case .review: review
                    case .idle: idle
                    default: listening
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .defaultScrollAnchor(live ? .bottom : .top)
            .scrollDismissesKeyboard(.interactively)
            // The controls sit in the safe area so content always ends above them.
            .safeAreaInset(edge: .bottom, spacing: 0) { if flow.phase != .idle { controls } }
            // On the dashboard the mic floats in the corner, one tap from anywhere on the page.
            .overlay(alignment: .bottomTrailing) {
                if flow.phase == .idle {
                    Button(action: flow.startRecording) {
                        WaveformGlyph(size: 30).foregroundStyle(Theme.onAccent)
                            .frame(width: 64, height: 64)
                            .background(Theme.accent, in: Circle())
                            .shadow(color: Theme.accent.opacity(0.45), radius: 14, y: 6)
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Start dictation")
                    .padding(.trailing, 20).padding(.bottom, 16)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .navigationTitle(flow.phase == .review ? "Review" : flow.phase == .idle ? "Home" : "Dictate")
        .navigationBarTitleDisplayMode(live ? .inline : .large)
        .toolbar {
            if flow.phase == .recording, let started = flow.started {
                ToolbarItem(placement: .principal) { RecordingClock(since: started).transition(.scale.combined(with: .opacity)) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Recording is foreground-only: leaving the app keeps what was heard.
            if phase == .background, flow.phase == .recording || flow.phase == .preparing { flow.cancelRecording() }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: flow.phase)
        .sensoryFeedback(.start, trigger: flow.phase == .recording) { _, now in now }
        .sensoryFeedback(.success, trigger: flow.phase == .review) { _, now in now }
    }

    // MARK: Idle

    /// At rest the Dictate tab is the dashboard: welcome, numbers, recent dictations.
    private var idle: some View {
        DictationDashboard(dictate: flow.startRecording)
            .padding(.top, 4)
    }

    // MARK: Listening

    private var listening: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                RedPandaView(state: flow.phase == .finishing ? .thinking : .working)
                    .frame(width: 34, height: 34)
                    .matchedGeometryEffect(id: "panda", in: space)
                    .accessibilityHidden(true)
                Text(status).font(.subheadline.weight(.medium)).foregroundStyle(Theme.muted)
                    .contentTransition(.opacity)
            }
            .padding(.top, 16)
            if flow.transcript.isEmpty {
                Text(flow.phase == .preparing ? "Getting ready…" : "Start talking…")
                    .font(Theme.heading(28, weight: .regular))
                    .foregroundStyle(Theme.muted.opacity(0.7))
                    .phaseAnimator([0.45, 1.0]) { text, value in text.opacity(value) } animation: { _ in .easeInOut(duration: 1.1) }
            } else if let preview = flow.polishing, !preview.isEmpty {
                // Cleanup streams in place of the raw words.
                LiveTranscript(text: preview, font: Theme.heading(28, weight: .regular))
                    .foregroundStyle(Theme.ink)
            } else {
                LiveTranscript(text: flow.transcript, font: Theme.heading(28, weight: .regular))
                    .foregroundStyle(Theme.ink)
                    .opacity(flow.phase == .finishing ? 0.6 : 1)
            }
        }
    }

    private var status: String {
        switch flow.phase {
        case .preparing: "Getting the microphone ready"
        case .finishing: flow.polishing != nil ? "Polishing on this iPhone" : "Finishing up"
        default: "Listening"
        }
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = flow.message { notice(message) }
            if let translated = flow.translated, translated.didTranslate {
                OutputCard(title: "Translation", text: translated.text, note: translated.note, prominent: true) { flow.copy(translated.text) }
                OutputCard(title: flow.cleanedText == flow.transcript ? "Original" : "Polished", text: flow.cleanedText, note: flow.polished?.note) { flow.copy(flow.cleanedText) }
            } else {
                OutputCard(title: flow.cleanedText == flow.transcript ? "Transcript" : "Polished", text: flow.cleanedText,
                           note: flow.translated?.note ?? flow.polished?.note, prominent: true,
                           edit: editCurrent) { flow.copy(flow.cleanedText) }
            }
            if flow.cleanedText != flow.transcript {
                DisclosureGroup("What you said") {
                    Text(flow.transcript).font(.callout).foregroundStyle(Theme.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                .font(.subheadline.weight(.medium)).tint(Theme.accent)
                .card(padding: 14)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Translate", systemImage: "character.bubble").font(.subheadline.weight(.semibold))
                    Spacer()
                    if flow.translating { ProgressView().controlSize(.small) }
                    TranslationTargetPicker(selection: $flow.translationTargetID, languages: flow.languages)
                }
                if !flow.translationTargetID.isEmpty, flow.translated?.didTranslate != true, !flow.translating {
                    TranslationSetupView(sourceIdentifier: flow.locale.language.minimalIdentifier, targetIdentifier: flow.translationTargetID)
                }
            }
            .card(padding: 14)
            .onChange(of: flow.translationTargetID) { flow.translateTranscript() }
        }
        .padding(.top, 8)
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
    }

    private var editCurrent: ((String) -> Void)? {
        guard let id = flow.currentEntryID else { return nil }
        return { flow.edit(id, to: $0) }
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.footnote).foregroundStyle(Theme.ink)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.banner, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { flow.clearMessage() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 14) {
            ZStack {
                VoiceRing(listening: flow.phase == .recording, color: Theme.accent) { IOSMicrophone.shared.snapshot() }
                    .frame(width: 220, height: 220)
                    .opacity(flow.phase == .idle || flow.phase == .review ? 0.6 : 1)
                Button(action: flow.toggleRecording) {
                    ZStack {
                        Circle().fill(flow.phase == .recording ? Color.red : Theme.accent)
                            .shadow(color: (flow.phase == .recording ? Color.red : Theme.accent).opacity(0.35), radius: 16, y: 6)
                        RoundedRectangle(cornerRadius: flow.phase == .recording ? 6 : 13, style: .continuous)
                            .fill(.white)
                            .frame(width: flow.phase == .recording ? 24 : 0, height: flow.phase == .recording ? 24 : 0)
                        WaveformGlyph(size: 38).foregroundStyle(Theme.onAccent)
                            .opacity(flow.phase == .recording ? 0 : 1)
                            .scaleEffect(flow.phase == .recording ? 0.4 : 1)
                        if flow.phase == .preparing || flow.phase == .finishing { ProgressView().tint(.white).controlSize(.large) }
                    }
                    .frame(width: 84, height: 84)
                    .contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .disabled(flow.phase == .preparing || flow.phase == .finishing)
                .accessibilityLabel(flow.phase == .recording ? "Stop dictation" : "Start dictation")
            }
            if flow.phase == .review {
                Button("New dictation", systemImage: "plus") { flow.discardReview() }
                    .font(.subheadline.weight(.medium)).tint(Theme.muted)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [Theme.paper.opacity(0), Theme.paper.opacity(flow.phase == .recording ? 0 : 0.92)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

/// The prominent result is the screen's hero card; others are ordinary cards.
private struct OutputCardBackground: ViewModifier {
    let hero: Bool
    func body(content: Content) -> some View {
        if hero { content.heroCard() } else { content.card() }
    }
}

/// Buttons sink slightly under the finger.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// One block of output with Copy and Share.
struct OutputCard: View {
    let title: String
    let text: String
    let note: String?
    var prominent = false
    /// When set, an Edit button lets the user correct the text.
    var edit: ((String) -> Void)? = nil
    let copy: () -> Void
    @State private var copied = false
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).eyebrow()
            Text(text)
                .font(prominent ? Theme.heading(22, weight: .regular) : .body)
                .lineSpacing(prominent ? 4 : 2)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            if let note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(Theme.muted) }
            HStack(spacing: 10) {
                Button {
                    copy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered).tint(Theme.accent)
                if edit != nil {
                    Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(.bordered).tint(Theme.accent)
                }
            }
            .font(.subheadline.weight(.semibold))
            .sensoryFeedback(.success, trigger: copied) { _, now in now }
        }
        .modifier(OutputCardBackground(hero: prominent))
        .sheet(isPresented: $editing) { EditDictationSheet(text: text) { edit?($0) } }
    }
}

struct TranslationTargetPicker: View {
    @Binding var selection: String
    let languages: [TranslationLanguage]

    var body: some View {
        Picker("Translate to", selection: $selection) {
            Text("Off").tag("")
            ForEach(languages) { language in Text(language.name).tag(language.id) }
        }
        .pickerStyle(.menu)
        .tint(Theme.accent)
    }
}
