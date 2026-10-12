import AppKit
import SwiftUI

@MainActor
final class IslandWorkspace: ObservableObject {
    static let shared = IslandWorkspace()
    @Published var section: WorkspaceSection = .dictation
    @Published var assistantDraft = ""
    var isVisible: Bool { OmniFlowShellController.shared.isVisible || (AppState.shared.notchlyEnabled && AppState.shared.mode == .expanded && AppState.shared.view == .workspace) }

    func show(_ section: WorkspaceSection = .dictation) {
        self.section = section
        OmniFlowShellController.shared.show(section)
    }

    func showInNotch(_ section: WorkspaceSection) {
        guard AppState.shared.notchlyEnabled else { show(section); return }
        self.section = section
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.workspace)
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case dictation = "Dictation", assistant = "Chat", sessions = "Agent sessions", system = "Monitoring", focus = "Focus & pointer", shortcuts = "Shortcuts", ambient = "Ambient abilities", memory = "Memory", history = "Transcripts", reader = "Reader", connections = "Connections", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dictation: return OmniFlowSymbol.dictate
        case .assistant: return "bubble.left.and.bubble.right"
        case .sessions: return "terminal"
        case .focus: return "cursorarrow.motionlines"
        case .shortcuts: return "command"
        case .ambient: return "bell.badge"
        case .memory: return "brain"
        case .history: return "text.bubble"
        case .reader: return "book"
        case .system: return "desktopcomputer"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .settings: return "gearshape"
        }
    }
}

struct NotchLeeWorkspace: View {
    @ObservedObject private var workspace = IslandWorkspace.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Island", selection: $workspace.section) {
                    ForEach(WorkspaceSection.allCases) { section in
                        Label(section.rawValue, symbol: section.symbol).tag(section)
                    }
                }
                .pickerStyle(.menu).labelsHidden()
                Spacer()
                Button("Open OmniFlow", systemImage: "macwindow") { workspace.show(workspace.section) }
                    .labelStyle(.iconOnly).help("Open in the OmniFlow companion window")
            }
            .padding(12)
            Group {
                if workspace.section == .connections {
                    VStack(spacing: 16) {
                        Text("Manage your connections in OmniFlow.").foregroundStyle(.secondary)
                        Button("Open connections") { workspace.show(.connections) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if [.dictation, .assistant, .memory, .history, .reader].contains(workspace.section) {
                    OmniFlowLockGate(compact: true) { WorkspaceSectionContent(section: workspace.section) }
                } else { WorkspaceSectionContent(section: workspace.section) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NotchLeeTheme.canvas, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .preferredColorScheme(.dark)
        .foregroundStyle(NotchLeeTheme.paper)
        .tint(NotchLeeTheme.accent)
    }
}

/// Both surfaces render the same feature views and state; neither owns a session.
struct WorkspaceSectionContent: View {
    let section: WorkspaceSection
    var body: some View {
        switch section {
        case .dictation: OmniFlowDictationView()
        case .assistant: WorkspaceAssistantView()
        case .sessions: OmniFlowAgentSessionsView()
        case .ambient: AmbientSettingsView()
        case .memory: AssistantMemoryView()
        case .history: OmniFlowTranscriptWorkspace()
        case .reader: ReaderPageView()
        case .system: OmniFlowMonitoringView()
        case .focus: OmniFlowFocusSettingsView(
            onOpenMonitoring: { IslandWorkspace.shared.show(.system) },
            onOpenShortcuts: { IslandWorkspace.shared.show(.shortcuts) },
            onOpenPointerSettings: { IslandWorkspace.shared.show(.settings) })
        case .shortcuts: OmniFlowShortcutGuideView()
        case .connections:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    OmniFlowPageHeading("Connections", subtitle: "Choose the tools and services your assistant can use.")
                    #if !APPSTORE
                    MCPSettingsView()
                    #else
                    Text("External tool connections are available in the direct distribution build.").foregroundStyle(.secondary)
                    #endif
                }.padding(28).frame(maxWidth: 920)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .settings: SettingsView()
        }
    }
}

struct OmniFlowPageHeading: View {
    let title: String
    let subtitle: String
    init(_ title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(OmniFlowBrand.heading(27)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(OmniFlowBrand.body()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WorkspaceAssistantView: View {
    @ObservedObject private var voice = VoiceAssistant.shared
    @ObservedObject private var agent = AgentPreferences.shared
    @ObservedObject private var wake = WakeListener.shared
    @ObservedObject private var workspace = IslandWorkspace.shared
    @ObservedObject private var connections = LocalMCPConfiguration.shared
    @ObservedObject private var focus = OmniFlowFocusController.shared
    @ObservedObject private var history = ConversationHistory.shared
    @FocusState private var composing: Bool
    @State private var copied = false
    @State private var search = ""
    @State private var showThreads = true
    @State private var renaming: ConversationThread?
    @State private var threadTitle = ""
    @State private var deleting: ConversationThread?
    @State private var context = ""
    @State private var editingContext = false
    @State private var exportError: String?
    @State private var voiceModePresented = false

    private var threads: [ConversationThread] {
        history.conversations.filter { thread in
            search.isEmpty || thread.title.localizedCaseInsensitiveContains(search) ||
            thread.records.contains { $0.question.localizedCaseInsensitiveContains(search) || $0.answer.localizedCaseInsensitiveContains(search) }
        }
    }


    private var hasConversation: Bool { !voice.completedTurns.isEmpty || !voice.transcript.isEmpty || !voice.response.isEmpty || voice.isBusy }

    var body: some View {
        GeometryReader { geometry in
            if voiceModePresented || voice.voiceChatActive {
                DedicatedChatVoiceView {
                    voice.cancel()
                    voiceModePresented = false
                }
            } else {
            HStack(alignment: .top, spacing: 20) {
                if showThreads && geometry.size.width >= 700 {
                    threadList.frame(width: 210)
                    Divider()
                }
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    OmniFlowPageHeading("Chat", subtitle: AtlasMetalAgent.enabled ? "GLM · on this Mac" : "Apple Intelligence · on this Mac")
                                    Spacer()
                                    Menu {
                                        Button("Apple Intelligence") { agent.setStrongerModel(false) }
                                        Button("GLM · higher memory use") { agent.setStrongerModel(true) }
                                    } label: { Label("Model", systemImage: "cpu") }
                                    .disabled(voice.isBusy || voice.voiceChatActive)
                                    Button("Conversations", systemImage: "sidebar.left") { showThreads.toggle() }
                                        .labelStyle(.iconOnly).help("Show or hide conversations")
                                    Menu {
                                        ForEach(threads) { thread in
                                            Button(thread.title) { open(thread) }
                                        }
                                    } label: { Image(systemName: "clock") }
                                    .help("Open a saved conversation")
                                    Button("Export chat", systemImage: "square.and.arrow.up") { exportChat() }
                                        .labelStyle(.iconOnly).disabled(voice.completedTurns.isEmpty)
                                }
                                if hasConversation {
                                    Button("New conversation", systemImage: "square.and.pencil") {
                                        voice.newConversation()
                                        workspace.assistantDraft = ""
                                        context = ""
                                        composing = true
                                    }.buttonStyle(.borderless).font(.callout)
                                        .disabled(voice.isBusy || voice.phase == .speaking)
                                }
                            }
                            if hasConversation { conversation }
                            else { welcome }
                            if voice.isBusy || voice.phase == .failed || voice.phase == .needsDownload {
                                status
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
                    }
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    if !agent.enabled {
                        HStack {
                            Text("The agent is off.").foregroundStyle(.secondary)
                            Button("Enable Chat") { agent.setEnabled(true) }
                        }.padding(12)
                    }
                    composer
                }.frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }.padding(geometry.size.width < 500 ? 18 : 30)
            }
        }
        .onChange(of: voice.voiceChatActive) { _, active in
            if active { composing = false; voiceModePresented = true }
        }
        .sheet(isPresented: $editingContext) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Context for your next message").font(.title2)
                Text("Paste an excerpt to reference. It is sent as reference material, separate from your instruction. Up to 4,000 characters.").foregroundStyle(.secondary)
                TextEditor(text: $context).frame(minHeight: 200)
                    .onChange(of: context) { _, value in if value.count > 4000 { context = String(value.prefix(4000)) } }
                HStack {
                    Text("\(context.count)/4,000").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import text file") { importContext() }
                    Button("Done") { editingContext = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 540)
        }
        .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $threadTitle)
            Button("Save") { if let thread = renaming { history.rename(thread.id, title: threadTitle) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let thread = deleting {
                    if voice.conversationID == thread.id { voice.newConversation() }
                    history.deleteConversation(thread.id)
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("The saved messages will be removed from this Mac.") }
        .alert("File operation failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var threadList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("New chat", systemImage: "square.and.pencil") {
                voice.newConversation(); workspace.assistantDraft = ""; context = ""; composing = true
            }.disabled(voice.isBusy)
            TextField("Search chats", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(threads) { thread in
                        Button { open(thread) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(thread.title).lineLimit(2).font(.callout)
                                Text(thread.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(voice.conversationID == thread.id ? OmniFlowBrand.interactiveAccent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(voice.isBusy)
                        .contextMenu {
                            Button("Rename") { threadTitle = thread.title; renaming = thread }
                            Button("Delete", role: .destructive) { deleting = thread }
                        }
                    }
                }
            }
            Text(history.enabled ? "Saved locally · 30-day history" : "History saving is off")
                .font(.caption).foregroundStyle(.secondary)
            if let error = history.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Button("Connections", systemImage: "point.3.connected.trianglepath.dotted") { workspace.section = .connections }
                .buttonStyle(.borderless).font(.caption)
        }
    }

    private func open(_ thread: ConversationThread) {
        voice.openConversation(thread)
        workspace.assistantDraft = ""; context = ""
    }

    private func importContext() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a UTF-8 text excerpt (up to 4,000 characters)."
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 16_000 else {
                    exportError = "Choose a small text excerpt, up to 4,000 characters. Larger documents can be searched through a connected resource."
                    return
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                guard text.count <= 4000 else { exportError = "This excerpt exceeds 4,000 characters."; return }
                context = text
            } catch { exportError = "Could not read the text file: " + error.localizedDescription }
        }
    }

    private func exportChat() {
        let text = voice.completedTurns.map { "## You\n\n\($0.question)\n\n## OmniFlow\n\n\($0.answer)" }.joined(separator: "\n\n---\n\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OmniFlow Chat.md"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = error.localizedDescription }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 18) {
                Image("NovaReference").resizable().scaledToFit().frame(width: 72, height: 80)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("A little help, right here.").font(OmniFlowBrand.heading(22))
                    Text("Ask about your Mac, your files, or your connected agents. Voice recognition and replies are processed on this Mac.")
                        .font(OmniFlowBrand.body()).foregroundStyle(.secondary).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("TRY ASKING").font(.caption.weight(.medium)).tracking(1.1).foregroundStyle(.secondary)
                prompt("What's using memory on my Mac?", symbol: "memorychip")
                prompt("Which of my agents needs attention?", symbol: "terminal")
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(OmniFlowBrand.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    private func prompt(_ question: String, symbol: String) -> some View {
        Button {
            workspace.assistantDraft = question
            composing = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(OmniFlowBrand.interactiveAccent).frame(width: 20)
                Text(question).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
            }.font(OmniFlowBrand.body(13)).padding(12)
                .background(OmniFlowBrand.contentBackground, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.press).help("Add this question to the composer")
    }

    private var currentTurnIsSaved: Bool {
        !voice.isBusy && voice.completedTurns.last == AssistantConversationTurn(question: voice.transcript, answer: voice.response)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(Array(voice.completedTurns.enumerated()), id: \.offset) { index, turn in
                VStack(alignment: .leading, spacing: 12) {
                    Label("You", systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
                    Text(turn.question).textSelection(.enabled)
                    Label("OmniFlow", systemImage: "waveform").font(.caption).foregroundStyle(OmniFlowBrand.interactiveAccent)
                    AssistantReplyView(source: turn.answer)
                    HStack(spacing: 16) {
                        Button("Copy", systemImage: "doc.on.doc") { _ = OmniFlowClipboard.copy(turn.answer, confirmation: "Answer copied") }
                        Button("Read aloud", systemImage: "speaker.wave.2") { voice.readAloud(turn.answer) }.disabled(voice.isBusy)
                        Button("Edit & branch", systemImage: "pencil") {
                            voice.branchConversation(before: index)
                            workspace.assistantDraft = turn.question; composing = true
                        }.disabled(voice.isBusy)
                        Button("Retry in new branch", systemImage: "arrow.clockwise") {
                            voice.branchConversation(before: index); voice.ask(turn.question)
                        }.disabled(voice.isBusy)
                    }.buttonStyle(.borderless).font(.caption)

                }
            }
            if !voice.transcript.isEmpty && !currentTurnIsSaved {
                VStack(alignment: .leading, spacing: 10) {
                    Label("You", systemImage: "person.crop.circle").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(voice.transcript).font(OmniFlowBrand.body(15)).lineSpacing(5).textSelection(.enabled)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(OmniFlowBrand.cardBackground, in: RoundedRectangle(cornerRadius: 18))
            }
            if !voice.response.isEmpty && !currentTurnIsSaved {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("OmniFlow", systemImage: "waveform").font(.caption.weight(.semibold))
                            .foregroundStyle(OmniFlowBrand.interactiveAccent)
                        Spacer()
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
                            copied = OmniFlowClipboard.copy(voice.response, confirmation: "Response copied")
                        }.buttonStyle(.borderless).font(.caption)
                            .help("Copy this response on this Mac")
                    }
                    AssistantReplyView(source: voice.response).font(OmniFlowBrand.body(15)).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 4)
                    .onChange(of: voice.response) { _, _ in copied = false }
            }
        }
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 12) {
            if voice.isBusy { ProgressView().controlSize(.small).padding(.top, 2) }
            else { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            VStack(alignment: .leading, spacing: 10) {
                Text(voice.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if voice.phase == .needsDownload {
                    Button("Prepare speech support") { voice.beginListening(downloadIfNeeded: true) }
                }
            }
            Spacer(minLength: 0)
        }.padding(16).background(OmniFlowBrand.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if voice.voiceChatActive {
                HStack {
                    Label(voice.phase == .listening ? "Listening · pause to send" : "Voice chat active", systemImage: "waveform")
                    Spacer()
                    Button("End voice chat", role: .destructive) { voice.cancel() }
                }.font(.callout).padding(12)
                    .background(OmniFlowBrand.interactiveAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 14) {
                if !context.isEmpty {
                    HStack {
                        Button("Reference · \(context.count) characters", systemImage: "doc.text") { editingContext = true }
                        Button("Remove reference", systemImage: "xmark.circle.fill") { context = "" }.labelStyle(.iconOnly)
                    }.font(.caption).buttonStyle(.borderless)
                }
                TextField("Ask OmniFlow…", text: $workspace.assistantDraft, axis: .vertical)
                    .textFieldStyle(.plain).font(OmniFlowBrand.body(15))
                    .lineLimit(2...6).focused($composing).onSubmit(send)
                    .accessibilityLabel("Message to OmniFlow")
                HStack(spacing: 10) {
                    Button("Add context", systemImage: "paperclip") { editingContext = true }
                        .labelStyle(.iconOnly).help("Attach a text excerpt")
                    Button("Voice chat", systemImage: "waveform.circle") { startVoiceMode() }
                        .labelStyle(.iconOnly).help("Start voice chat; pause for two seconds to send each turn")
                        .disabled(!agent.enabled || voice.isBusy || voice.voiceChatActive)
                    if voice.phase == .listening {
                        Label("Listening", systemImage: "waveform").font(.caption)
                            .foregroundStyle(OmniFlowBrand.interactiveAccent)
                    } else {
                        Text("⌃⌥Space to talk").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if voice.isBusy || voice.phase == .speaking {
                        Button("Cancel") { voice.cancel() }.buttonStyle(.borderless).font(.caption)
                    }
                    Button { startVoiceMode() } label: {
                        Image(systemName: voice.phase == .listening ? "stop.fill" : "mic")
                            .frame(width: 30, height: 28)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .disabled(voice.isBusy && voice.phase != .listening)
                    .accessibilityLabel(voice.phase == .listening ? "Finish listening and ask" : "Talk to OmniFlow")
                    .help(voice.phase == .listening ? "Finish listening and ask" : "Talk to OmniFlow")
                    Button(action: send) { Image(systemName: "arrow.up").frame(width: 30, height: 28) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                        .tint(OmniFlowBrand.interactiveAccent)
                        .disabled(!agent.enabled || workspace.assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voice.isBusy)
                        .accessibilityLabel("Send message").help("Send message")
                }
            }.padding(18)
                .background(OmniFlowBrand.cardBackground, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(OmniFlowBrand.hairline, lineWidth: 1))
            ViewThatFits(in: .horizontal) {
                HStack { replyToggle; Spacer(minLength: 10); wakeStatus }
                VStack(alignment: .leading, spacing: 8) { replyToggle; wakeStatus }
            }
        }
    }

    private var replyToggle: some View {
        Toggle("Spoken replies", isOn: $voice.spokenReplies).toggleStyle(OmniFlowSwitchStyle()).controlSize(.mini).font(.caption)
    }
    @ViewBuilder private var wakeStatus: some View {
        if wake.enabled { WakeStatusIndicator(showsText: true).help(wake.inputStatus) }
        else { Label("Voice processed on this Mac", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
    }

    private var contextRail: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your workspace").font(OmniFlowBrand.heading(16))
                railLink("Monitoring", detail: "See what's happening on your Mac", symbol: "chart.bar", section: .system)
                Divider()
                railLink("Focus & pointer", detail: focus.status, symbol: "cursorarrow", section: .focus)
                Divider()
                railLink("Connections", detail: "\(connections.servers.filter(\.enabled).count) enabled", symbol: "point.3.connected.trianglepath.dotted", section: .connections)
            }.padding(20).background(OmniFlowBrand.cardBackground, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 12) {
                Label("Saved on this Mac", systemImage: "clock").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text("\(history.conversations.count)").font(OmniFlowBrand.heading(30)).monospacedDigit()
                Text("Saved conversations").font(.callout).foregroundStyle(.secondary)
                Button("View transcripts", systemImage: "arrow.right") { workspace.section = .history }
                    .buttonStyle(.borderless).font(.callout)
            }.padding(20)
            Text("Remote connections receive approved tool calls. Manage their access in Connections.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3).padding(.horizontal, 8)
        }
    }
    private func railLink(_ title: String, detail: String, symbol: String, section: WorkspaceSection) -> some View {
        Button { workspace.section = section } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(OmniFlowBrand.interactiveAccent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.multilineTextAlignment(.leading)
        }.buttonStyle(.press)
    }
    private func startVoiceMode() {
        guard agent.enabled else { return }
        composing = false
        voiceModePresented = true
        voice.startVoiceChat()
    }

    private func send() {
        let question = workspace.assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard agent.enabled, !question.isEmpty, !voice.isBusy else { return }
        workspace.assistantDraft = ""
        let reference = context.isEmpty ? nil : context
        context = ""
        voice.ask(question, reference: reference)
    }
}

/// Voice mode replaces the chat workspace; it never exposes a text composer.
private struct DedicatedChatVoiceView: View {
    @ObservedObject private var voice = VoiceAssistant.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("omniflow.chat.voiceCaptions") private var captions = true
    let end: () -> Void

    private var title: String {
        switch voice.phase {
        case .preparing: "Getting ready"
        case .listening: "I'm listening"
        case .finishing: "Got it"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .failed, .needsDownload: "Let's try again"
        case .idle: voice.voiceChatActive ? "Ready for you" : "Voice paused"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    HStack {
                        Label("Voice mode", systemImage: "waveform").font(.headline)
                        Spacer()
                        Toggle("Captions", isOn: $captions).toggleStyle(OmniFlowSwitchStyle()).controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || (!voice.isBusy && voice.phase != .speaking))) { timeline in
                        let breath = reduceMotion ? 0.0 : sin(timeline.date.timeIntervalSinceReferenceDate * 2.5)
                        ZStack {
                            Circle().fill(OmniFlowBrand.interactiveAccent.opacity(0.06)).scaleEffect(1.2 + breath * 0.04)
                            Circle().stroke(OmniFlowBrand.interactiveAccent.opacity(0.2), lineWidth: 1).scaleEffect(1.08 + breath * 0.03)
                            Circle().fill(OmniFlowBrand.interactiveAccent.opacity(0.18))
                            Image(systemName: voice.phase == .listening ? "mic.fill" : "waveform")
                                .font(.system(size: 48, weight: .light)).foregroundStyle(OmniFlowBrand.interactiveAccent)
                                .scaleEffect(1 + breath * 0.06)
                        }
                    }.frame(width: min(180, geometry.size.height * 0.27), height: min(180, geometry.size.height * 0.27))
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text(title).font(OmniFlowBrand.heading(28)).accessibilityAddTraits(.isHeader)
                        Text(voice.phase == .listening ? "Speak naturally. Pause when you're done." : voice.message)
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if captions {
                        ScrollView {
                            VStack(spacing: 12) {
                                if !voice.transcript.isEmpty { Text(voice.transcript).foregroundStyle(.secondary) }
                                if !voice.response.isEmpty { Text(voice.response).textSelection(.enabled) }
                            }.font(.body).lineSpacing(5).frame(maxWidth: .infinity)
                        }.defaultScrollAnchor(.bottom, for: .sizeChanges)
                            .frame(height: min(180, geometry.size.height * 0.24))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 18) {
                        if voice.phase == .listening {
                            Button("Finish turn", systemImage: "checkmark") { voice.finishListening() }
                        } else if voice.phase == .speaking {
                            Button("Speak now", systemImage: "mic.fill") {
                                voice.beginListening(presentInterface: false, continuingVoiceChat: true)
                            }
                        } else if !voice.isBusy {
                            Button("Resume voice", systemImage: "mic.fill") {
                                if voice.phase == .needsDownload { voice.beginListening(downloadIfNeeded: true, presentInterface: false) }
                                else { voice.startVoiceChat() }
                            }
                        }
                        Button("End voice mode", systemImage: "phone.down.fill", action: end)
                            .tint(.red).keyboardShortcut(.cancelAction)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Your conversation stays in Chat.").font(.caption).foregroundStyle(.secondary)
                }.padding(30).frame(maxWidth: 640).frame(minHeight: max(0, geometry.size.height - 4))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct OmniFlowTranscriptWorkspace: View {
    @State private var dictations = true
    var body: some View {
        VStack(spacing: 0) {
            Picker("Transcript type", selection: $dictations) {
                Text("Dictations").tag(true)
                Text("Conversations").tag(false)
            }.pickerStyle(.segmented).frame(maxWidth: 300).padding(.top, 20)
            if dictations { OmniFlowDictationView(historyOnly: true) }
            else { TranscriptListView() }
        }
    }
}

struct TranscriptListView: View {
    @ObservedObject private var history = ConversationHistory.shared
    @State private var search = ""
    @State private var clear = false
    @State private var copied: UUID?
    private var threads: [ConversationThread] {
        history.conversations.filter { thread in search.isEmpty || thread.records.contains { ($0.question + $0.answer).localizedCaseInsensitiveContains(search) } }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                OmniFlowPageHeading("Conversations", subtitle: "Find a conversation and pick up a useful thought.")
                ViewThatFits(in: .horizontal) {
                    HStack { retention; Spacer(); clearButton }
                    VStack(alignment: .leading, spacing: 12) { retention; clearButton }
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search saved conversations", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }
                            .labelStyle(.iconOnly).buttonStyle(.press).foregroundStyle(.secondary)
                    }
                }.padding(14).background(OmniFlowBrand.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                if let error = history.error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                if threads.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No saved conversations yet" : "No matching conversations",
                        systemImage: search.isEmpty ? "text.bubble" : "magnifyingglass",
                        description: Text(search.isEmpty ? "Completed conversations appear here when saving is enabled." : "Try another word or clear your search."))
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(threads) { thread in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(thread.title).font(.headline).lineLimit(2)
                                    Spacer()
                                    Button("Continue", systemImage: "arrow.right") { VoiceAssistant.shared.openConversation(thread) }
                                        .disabled(VoiceAssistant.shared.isBusy)
                                }
                                ForEach(thread.records) { record in
                            VStack(alignment: .leading, spacing: 16) {
                                Text(record.date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                                if !record.question.isEmpty {
                                    Text(record.question).font(OmniFlowBrand.body(15).weight(.medium)).textSelection(.enabled)
                                }
                                AssistantReplyView(source: record.answer).font(OmniFlowBrand.body()).lineSpacing(5).textSelection(.enabled)
                                HStack(spacing: 16) {
                                    Button { history.feedback(record.id, useful: true) } label: {
                                        Image(systemName: record.feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    }.accessibilityLabel("Mark response useful").help("Useful response")
                                    Button { history.feedback(record.id, useful: false) } label: {
                                        Image(systemName: record.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                    }.accessibilityLabel("Mark response not useful").help("Not useful")
                                    Spacer()
                                    Button(copied == record.id ? "Copied" : "Copy", systemImage: copied == record.id ? "checkmark" : "doc.on.doc") {
                                        NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
                                        if OmniFlowClipboard.copy(record.answer, confirmation: "Answer copied") { copied = record.id }
                                    }
                                }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                                .background(OmniFlowBrand.cardBackground, in: RoundedRectangle(cornerRadius: 18))
                                }
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 960).frame(maxWidth: .infinity, alignment: .topLeading)
        }.confirmationDialog("Clear all saved transcripts on this Mac?", isPresented: $clear) {
            Button("Clear history", role: .destructive) { history.clear() }
        }
    }
    private var retention: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Save conversations", isOn: $history.enabled).toggleStyle(OmniFlowSwitchStyle()).controlSize(.small)
            Text("30 days · up to 500 saved turns · no microphone audio")
                .font(.caption).foregroundStyle(.secondary)
            Text("Long entries may be shortened in saved history.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var clearButton: some View {
        Button("Clear history", role: .destructive) { clear = true }.disabled(history.records.isEmpty)
    }
}
