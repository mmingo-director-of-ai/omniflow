import FoundationModels
import SwiftUI

/// The iOS assistant: a thin shell over Core's AtlasModelHost driven by the
/// native Atlas runner, like the Mac's, with iPhone context and one device
/// tool (searching your own dictations and notes). Everything runs on the
/// on-device model; nothing leaves the iPhone. Remote MCP servers arrive
/// with the shared OAuth flow.
@MainActor
final class IOSAssistantModel: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer: String = ""
        var failed = false
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var busy = false
    @Published private(set) var progress: String?
    private var task: Task<Void, Never>?
    private let speaker = KokoroReplySpeaker()
    private weak var flow: IOSFlowModel?

    init(flow: IOSFlowModel) {
        self.flow = flow
        speaker.onFailure = { [weak self] _ in self?.progress = "Kokoro could not speak. Your answer is still available in writing." }
    }

    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    var unavailableReason: String {
        switch SystemLanguageModel.default.availability {
        case .available: ""
        case .unavailable(.deviceNotEligible): "This iPhone can't run Apple Intelligence, which the assistant needs."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings to use the assistant."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready. Try again in a few minutes."
        default: "The on-device model isn't available right now."
        }
    }

    private var environment: AtlasHostEnvironment {
        // Atlas runs require two or three host tools (AtlasRuntimeSession validates 2...3).
        AtlasHostEnvironment(context: PhoneContext(), tools: [recallTool, noteTool], telemetry: ["runtime": "native", "platform": "iOS"])
    }

    func prewarm() {
        guard isAvailable else { return }
        AtlasModelHost.prewarm(environment: environment, servers: [])
    }

    func ask(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        speaker.stop()
        turns.append(Turn(question: text))
        let index = turns.count - 1
        let conversation = turns.dropLast().filter { !$0.failed && !$0.answer.isEmpty }.suffix(AssistantConversation.maximumTurns)
            .map { AssistantConversationTurn(question: $0.question, answer: $0.answer) }
        busy = true
        progress = "Thinking…"
        task = Task {
            defer { busy = false; progress = nil }
            do {
                let runner = NativeAtlasRunner<AtlasFrame>(launcher: nil)
                let answer = try await AtlasModelHost.answer(text, environment: environment, runner: runner, servers: [],
                    conversation: Array(conversation),
                    onProgress: { [weak self] in self?.progress = $0 },
                    onPartial: { [weak self] partial in self?.update(index) { $0.answer = partial } })
                try Task.checkCancellation()
                update(index) { $0.answer = answer }
                if UserDefaults.standard.bool(forKey: "voiceSpokenReplies") {
                    IOSReaderModel.shared.pauseForAssistant()
                    speaker.beginReply()
                    for sentence in SpokenSentenceSplitter.pieces(String(answer.prefix(3000))) {
                        speaker.enqueue(sentence, rate: 1, pitch: 1)
                    }
                    speaker.endReply()
                }
            } catch is CancellationError {
                update(index) { $0.answer = "Stopped."; $0.failed = true }
            } catch {
                #if DEBUG
                print("assistant failed: \(error)")
                #endif
                update(index) { $0.answer = "I couldn't finish that on this iPhone. Try asking again, a little more simply."; $0.failed = true }
            }
        }
    }

    func stop() { task?.cancel(); speaker.stop() }

    func clear() { stop(); turns = [] }

    private func update(_ index: Int, _ change: (inout Turn) -> Void) {
        guard turns.indices.contains(index) else { return }
        change(&turns[index])
    }

    // MARK: Device tool

    @Generable
    struct RecallArguments {
        @Guide(description: "Words to look for in the user's own dictations and notes")
        var query: String
    }

    /// Searches this iPhone's dictation history and notes (already on device, sealed at rest).
    private var recallTool: some AtlasNativeTool {
        AtlasHostTool<RecallArguments>(
            name: "searchMyDictations",
            description: "Search the user's own past dictations and notes on this iPhone by keywords. Returns matching excerpts with dates.") { [weak self] arguments in
            guard let self else { return "[]" }
            return Self.recall(arguments.query, entries: self.flow?.entries ?? [], notes: NotesModel.shared.notes)
        }
    }

    @Generable
    struct NoteArguments {
        @Guide(description: "Words from the note's title or first line")
        var title: String
    }

    /// Reads one whole note, for summarizing or answering from it.
    private var noteTool: some AtlasNativeTool {
        AtlasHostTool<NoteArguments>(
            name: "readMyNote",
            description: "Read the full text of one of the user's notes on this iPhone, found by words from its title. Returns the note or an empty result.") { arguments in
            Self.note(matching: arguments.title, in: NotesModel.shared.notes)
        }
    }

    /// The best-matching note's full text (capped), or "{}" when none matches.
    static func note(matching title: String, in notes: [DictationNote]) -> String {
        let terms = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        let best = notes.map { note in (note, terms.reduce(0) { $0 + (note.title.lowercased().contains($1) ? 2 : note.body.lowercased().contains($1) ? 1 : 0) }) }
            .filter { $0.1 > 0 }.max { ($0.1, $0.0.updated) < ($1.1, $1.0.updated) }?.0
        guard let best else { return "{}" }
        let payload = ["title": best.title, "updated": best.updated.formatted(date: .abbreviated, time: .shortened), "text": String(best.body.prefix(6000))]
        return String(decoding: (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// The best keyword matches, newest first, as compact JSON (capped).
    static func recall(_ query: String, entries: [DictationEntry], notes: [DictationNote], limit: Int = 6) -> String {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        guard !terms.isEmpty else { return "[]" }
        struct Hit: Encodable { let kind: String; let date: String; let text: String }
        var scored: [(score: Int, date: Date, hit: Hit)] = []
        func consider(_ kind: String, _ date: Date, _ text: String) {
            let lower = text.lowercased()
            let score = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            guard score > 0 else { return }
            scored.append((score, date, Hit(kind: kind, date: date.formatted(date: .abbreviated, time: .shortened), text: String(text.prefix(600)))))
        }
        for entry in entries where !entry.displayText.isEmpty { consider("dictation", entry.date, entry.displayText) }
        for note in notes where !note.body.isEmpty { consider("note", note.updated, note.body) }
        let best = scored.sorted { ($0.score, $0.date) > ($1.score, $1.date) }.prefix(limit).map(\.hit)
        let data = (try? JSONEncoder().encode(Array(best))) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private struct PhoneContext: AtlasContextProvider {
        var assistantIdentity: String { "You are Omni, a helpful assistant on this iPhone." }
        var nativeToolGuidance: String {
            "Use searchMyDictations to find what the user said or wrote before in their dictations and notes, and readMyNote to read a whole note. Quote briefly; never invent past dictations or notes."
        }
        func untrustedContextJSON() throws -> String {
            let context = ["surface": "iPhone app", "time": Date.now.formatted(date: .complete, time: .shortened)]
            return String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        }
    }
}

/// Chat with Omni: ask by typing or by voice; answers stream in.
struct AssistantView: View {
    @EnvironmentObject private var flow: IOSFlowModel
    @EnvironmentObject private var assistant: IOSAssistantModel
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !assistant.isAvailable {
                ContentUnavailableView {
                    Label { Text("Assistant unavailable").font(Theme.heading(22)) } icon: {
                        RedPandaView(state: .sleeping).frame(width: 96, height: 96)
                    }
                } description: { Text(assistant.unavailableReason) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if assistant.turns.isEmpty { welcome }
                        ForEach(assistant.turns) { turn in TurnView(turn: turn, live: assistant.busy && turn == assistant.turns.last) }
                        if let progress = assistant.progress {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(progress).font(.footnote).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                composer
            }
        }
        .background { Theme.backdrop }
        .navigationTitle("Assistant")
        .toolbar {
            if !assistant.turns.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { assistant.clear() }.disabled(assistant.busy)
                }
            }
        }
        .onAppear { assistant.prewarm() }
        #if DEBUG
        // Screenshots: `-OmniFlowDemoAsk "question"` asks once on open.
        .task {
            if let question = UserDefaults.standard.string(forKey: "OmniFlowDemoAsk"), assistant.turns.isEmpty { assistant.ask(question) }
        }
        #endif
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RedPandaView(state: .idle, cheerful: true).frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask Omni").font(Theme.heading(24)).foregroundStyle(Theme.ink)
                    Text("Runs on this iPhone with Apple Intelligence.").font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            ForEach(["What did I dictate about the design review?", "Summarize my notes from today", "Draft a short reply saying I'll be late"], id: \.self) { prompt in
                Button { assistant.ask(prompt) } label: {
                    Text(prompt).font(.subheadline).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .heroCard()
        .padding(.top, 12)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask anything", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
                .onSubmit(send)
            if draft.isEmpty && !assistant.busy {
                Button {
                    if flow.phase == .recording && flow.dictatingIntoNote { flow.stopRecording() }
                    else { typing = false; flow.dictate(destination: "Assistant") { text in draft = text } }
                } label: {
                    Group {
                        if flow.phase == .recording && flow.dictatingIntoNote { Image(systemName: "stop.fill") }
                        else { WaveformGlyph(size: 22) }
                    }
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(flow.phase == .recording && flow.dictatingIntoNote ? .white : Theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(flow.phase == .recording && flow.dictatingIntoNote ? Color.red : Theme.accent, in: Circle())
                }
                .accessibilityLabel(flow.phase == .recording ? "Stop dictating" : "Ask by voice")
                .disabled(flow.phase == .preparing || flow.phase == .finishing || (flow.isDictating && !flow.dictatingIntoNote))
            } else {
                Button {
                    if assistant.busy { assistant.stop() } else { send() }
                } label: {
                    Image(systemName: assistant.busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.onAccent)
                        .frame(width: 44, height: 44).background(Theme.accent, in: Circle())
                }
                .accessibilityLabel(assistant.busy ? "Stop" : "Send")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func send() {
        let text = draft
        draft = ""
        assistant.ask(text)
    }
}

private struct TurnView: View {
    let turn: IOSAssistantModel.Turn
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 48)
                Text(turn.question).font(.body).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if !turn.answer.isEmpty {
                Text(markdown(turn.answer))
                    .font(.body).foregroundStyle(turn.failed ? Theme.muted : Theme.ink)
                    .textSelection(.enabled)
                    .card(padding: 14)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.answer }
                        ShareLink(item: turn.answer)
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: turn.answer)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
