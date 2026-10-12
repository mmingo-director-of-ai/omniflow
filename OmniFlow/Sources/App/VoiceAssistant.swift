import AppKit
import AVFoundation
import Combine
import FoundationModels
import NaturalLanguage
import os

@MainActor
final class VoiceAssistant: NSObject, ObservableObject {
    static let shared = VoiceAssistant()

    enum Phase { case idle, preparing, listening, finishing, thinking, speaking, needsDownload, failed }
    @Published private(set) var phase: Phase = .idle {
        didSet {
            if [.preparing, .listening, .finishing, .thinking].contains(phase) { focusLease.begin() }
            else { focusLease.end() }
        }
    }
    @Published private(set) var transcript = ""
    @Published private(set) var response = ""
    @Published private(set) var message = "Ask me anything, or ask what's happening on your Mac."
    @Published var spokenReplies: Bool = UserDefaults.standard.object(forKey: "voiceSpokenReplies") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(spokenReplies, forKey: "voiceSpokenReplies")
            if !spokenReplies { stopSpeaking(); speaker.shutdown() }
        }
    }
    @Published private(set) var shortcutAvailable = false
    @Published private(set) var siriVoice: SiriVoice?
    @Published private(set) var availableVoices: [SiriVoice] = []
    /// App Store build: installed system voices; "" selects automatically by reply language.
    @Published private(set) var premiumVoices: [SpeechVoiceInfo] = []
    @Published private(set) var premiumVoiceID = UserDefaults.standard.string(forKey: PremiumSpeechVoices.selectionKey) ?? ""
    @Published private(set) var voiceStatus = "Kokoro · on-device speech"
    @Published var speechRate = UserDefaults.standard.object(forKey: "voiceRate") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(speechRate, forKey: "voiceRate") }
    }
    @Published var speechPitch = UserDefaults.standard.object(forKey: "voicePitch") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(speechPitch, forKey: "voicePitch") }
    }
    private var input: VoiceInput?
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var shortcutHeld = false
    /// Push-to-talk was released after the microphone opened but before the
    /// analyzer was ready. The captured audio is finished, not discarded.
    private var finishWhenReady = false
    private let speaker: any ReplySpeaker = KokoroReplySpeaker()
    private lazy var transcriptUpdates = PartialThrottle { [weak self] in self?.transcript = $0 }
    private lazy var responseUpdates = PartialThrottle { [weak self] in self?.response = $0 }
    private var sentences = SpokenSentenceSplitter()
    private var replyStreaming = false
    /// Spoken replies stop after this many characters, as the whole-reply path did.
    private var spokenCharacters = 0
    private var speechFailure = false
    private var requestCursorContext: String?
    private var conversation = AssistantConversation()
    @Published private(set) var completedTurns: [AssistantConversationTurn] = []
    @Published private(set) var conversationID = UUID()
    @Published private(set) var voiceChatActive = false
    private var voicePause: Task<Void, Never>?
    private var voiceResume: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private let focusLease = OmniFlowInteractionLease(reason: "Voice and assistant interaction")
    let latency = VoiceTurnLatency()

    var isBusy: Bool { [.preparing, .listening, .finishing, .thinking].contains(phase) }

    private override init() {
        super.init()
        speaker.onFirstAudio = { [weak self] in
            self?.latency.mark(.ttsFirstAudio)
            self?.voiceStatus = "Kokoro is ready."
        }
        speaker.onFinished = { [weak self] in self?.speechFinished() }
        speaker.onFailure = { [weak self] error in self?.speechFailed(error) }
        refreshVoice()
        AppState.shared.$soundEnabled.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.stopSpeaking(); self?.speaker.shutdown() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.speaker.shutdown() }.store(in: &subscriptions)
        AssistantMemory.shared.$project.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates().dropFirst().sink { [weak self] project in
                guard let self, conversation.selectScope(project) else { return }
                completedTurns = []; conversationID = UUID()
                cancel()
                transcript = ""
                response = ""
                requestCursorContext = nil
            }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.cancel() }.store(in: &subscriptions)
    }

    func registerShortcut() {
        guard AgentPreferences.shared.enabled else {
            VoiceShortcut.shared.unregister(); shortcutAvailable = false; return
        }
        shortcutAvailable = VoiceShortcut.shared.register()
    }

    func refreshVoice() {
        voiceStatus = "Kokoro · " + KokoroReadingVoice.resolve(UserDefaults.standard.string(forKey: KokoroReplySpeaker.selectionKey)).title
    }

    func selectVoice(id: String) {
        UserDefaults.standard.set(KokoroReadingVoice.resolve(id).id, forKey: KokoroReplySpeaker.selectionKey)
        stopSpeaking()
        refreshVoice()
    }

    func previewVoice() {
        guard !isBusy, AppState.shared.soundEnabled else { return }
        stopSpeaking()
        speak("Hi, I'm OmniFlow. I can help with your Mac and keep you up to date on your agents.", preview: true)
    }

    func show() {
        requestCursorContext = AgentCursor.shared.enabled ? AgentCursor.shared.context?.modelData() : nil
        if !AppState.shared.notchlyEnabled || OmniFlowShellController.shared.isVisible {
            IslandWorkspace.shared.show(.assistant)
            return
        }
        if IslandWorkspace.shared.isVisible { IslandWorkspace.shared.section = .assistant; return }
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.voice)
    }

    func toggleMicrophone(presentInterface: Bool = true) {
        if WakeListener.shared.isCapturing { WakeListener.shared.finish(); return }
        if phase == .listening { finishListening() }
        else if isBusy { cancel() }
        else { beginListening(presentInterface: presentInterface) }
    }

    func shortcutPressed() {
        guard !shortcutHeld else { return }
        shortcutHeld = true
        beginListening()
    }

    func shortcutReleased() {
        guard shortcutHeld else { return }
        shortcutHeld = false
        if phase == .listening { finishListening() }
        else if phase == .preparing, input?.isCapturing == true {
            finishWhenReady = true
            message = "Finishing transcript…"
        } else if phase == .preparing {
            cancel()
            message = "Hold ⌃⌥Space until “Listening”, then speak. You can also click the mic."
        }
    }

    func beginListening(downloadIfNeeded: Bool = false, presentInterface: Bool = true, continuingVoiceChat: Bool = false) {
        guard AgentPreferences.shared.enabled else { message = "Enable the agent in Settings → Assistant & Mac."; return }
        if AppModel.shared.isActive { AppModel.shared.cancel() }
        WakeListener.shared.stop()
        cancel(keepVoiceChat: continuingVoiceChat)
        focusLease.begin()
        requestCursorContext = AgentCursor.shared.enabled ? AgentCursor.shared.context?.modelData() : nil
        if presentInterface { show() }
        transcript = ""
        response = ""
        message = "Preparing speech…"
        phase = .preparing
        latency.begin("push_to_talk")
        prewarmReply()
        let token = generation
        let input = VoiceInput()
        input.onMilestone = { [weak self] milestone in
            guard let self, generation == token else { return }
            latency.mark(milestone)
            if milestone == .micStarted, !finishWhenReady { message = "Listening…" }
        }
        self.input = input
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await input.start(downloadIfNeeded: downloadIfNeeded, onStatus: { [weak self] text in
                    guard self?.generation == token else { return }
                    self?.message = text
                }, onTranscript: { [weak self] text in
                    guard self?.generation == token else { return }
                    self?.transcriptUpdates.submit(text)
                    self?.scheduleVoicePause(text, token: token)
                }, onFailure: { [weak self] error in
                    guard self?.generation == token else { return }
                    self?.fail(error)
                })
                guard generation == token, !Task.isCancelled else { input.cancel(); return }
                phase = .listening
                if finishWhenReady { finishListening(); return }
                message = "Listening… click Stop or release ⌃⌥Space to ask."
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, self?.generation == token else { return }
                    self?.finishListening()
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    func finishListening() {
        guard phase == .listening, let input else { return }
        timeout?.cancel()
        voicePause?.cancel()
        phase = .finishing
        message = "Finishing transcript…"
        latency.mark(.endOfSpeech)
        SoundEngine.shared.play("heard")
        let token = generation
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.generation == token else { return }
            self?.failMessage("Speech recognition took too long. Try again or type your question.")
        }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await input.finish()
                guard generation == token, !Task.isCancelled else { return }
                timeout?.cancel()
                self.input = nil
                latency.mark(.finalTranscript)
                guard !text.isEmpty else {
                    failMessage("I didn't catch any speech. Check your microphone and try again.")
                    return
                }
                transcriptUpdates.reset()
                transcript = text
                await answer(text, token: token)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    /// `continuingTurn` keeps the latency timeline of a wake-phrase turn that is
    /// handing its finished transcript over; anything else starts a typed turn.
    func ask(_ text: String, reference: String? = nil, continuingTurn: Bool = false) {
        guard AgentPreferences.shared.enabled else { message = "Enable the agent in Settings → Assistant & Mac."; return }
        if AppModel.shared.isActive { AppModel.shared.cancel() }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        cancel()
        if !continuingTurn { latency.begin("typed") }
        focusLease.begin()
        show()
        if let reference { requestCursorContext = reference }
        transcript = question
        response = ""
        phase = .thinking
        message = "Thinking…"
        let token = generation
        work = Task { [weak self] in await self?.answer(question, token: token) }
    }

    func resume(_ savedTask: SavedAssistantTask) {
        guard AgentPreferences.shared.enabled else { message = "Enable the agent in Settings → Assistant & Mac."; return }
        guard !isBusy else { return }
        cancel()
        AssistantMemory.shared.project = savedTask.scope
        conversation.reset(scope: savedTask.scope)
        completedTurns = []; conversationID = UUID()
        latency.discard()
        focusLease.begin()
        let token = UUID()
        generation = token
        transcript = savedTask.question
        response = ""
        requestCursorContext = nil
        phase = .thinking
        work = Task { [weak self] in await self?.answer(savedTask.question, token: token, resumeTask: savedTask.id) }
    }

    private func answer(_ question: String, token: UUID, resumeTask: UUID? = nil) async {
        guard generation == token, !Task.isCancelled else { return }
        let started = Date()
        var succeeded = true
        let request = conversation.begin(question: question, scope: AssistantMemory.shared.project, fullContext: AtlasMetalAgent.enabled)
        defer {
            let success = succeeded && generation == token && !Task.isCancelled
            Task { await LocalTelemetry.shared.span("assistant.answer", start: started, success: success) }
        }
        phase = .thinking
        message = "Thinking…"
        let context = Self.sessionContext()
        var target: String?
        var showHome = false
        let reply: String
        switch resumeTask == nil ? VoiceCommand.parse(question) : .question {
        case .time: reply = "It's \(MacContext.time()) (\(TimeZone.current.abbreviation() ?? TimeZone.current.identifier))."
        case .date: reply = "Today is \(MacContext.date())."
        case .system: reply = MacContext.describe(.system)
        case .applications: reply = MacContext.describe(.applications)
        case .activeWindow: reply = MacContext.describe(.activeWindow)
        case .storage: reply = MacContext.describe(.storage)
        case .battery: reply = MacContext.describe(.battery)
        case .processes: reply = await MacDiagnostics.processes(spoken: true)
        case .memory: reply = MacDiagnostics.memory()
        case .status: reply = context.summary
        case .attention: reply = context.attentionSummary
        case .home:
            reply = "Here are your sessions."
            showHome = true
        case .show(let name):
            let matches = context.matching(name)
            if matches.count == 1 {
                target = matches[0].id
                reply = "Showing \(matches[0].name)."
            } else if matches.isEmpty {
                reply = "I couldn't find a connected session called \(name)."
            } else {
                reply = "I found \(matches.count) matching sessions: \(matches.prefix(5).map(\.name).joined(separator: ", ")). Say the project name to choose one."
            }
        case .mute:
            AppState.shared.soundEnabled = false
            reply = "Sound muted."
        case .unmute:
            AppState.shared.soundEnabled = true
            reply = "Sound on."
        case .question:
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3610))
                guard !Task.isCancelled, self?.generation == token else { return }
                self?.failMessage("The answer took too long. Please try a shorter question.")
            }
            if shouldSpeak() { beginSpokenReply() }
            reply = await Self.answerQuestion(question, context: context, cursorContext: requestCursorContext,
                conversation: request.turns, resumeTask: resumeTask, onFailure: { succeeded = false }) { [weak self] partial in
                guard let self, generation == token else { return }
                if !partial.isEmpty { latency.mark(.modelFirstToken) }
                responseUpdates.submit(partial)
                streamSpokenReply(partial)
            }
        }
        guard generation == token, !Task.isCancelled,
              request.scope == AssistantMemory.shared.project.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        timeout?.cancel()
        latency.mark(.replyDone)
        conversation.complete(request, answer: reply, succeeded: succeeded)
        completedTurns = conversation.archive
        responseUpdates.reset()
        response = reply
        if succeeded { ConversationHistory.shared.append(question: question, answer: reply, conversationID: conversationID, scope: request.scope) }
        phase = .idle
        message = "Ask another question whenever you're ready."
        if let target { AppState.shared.setFocus(target) }
        if showHome || target != nil {
            if !AppState.shared.notchlyEnabled || OmniFlowShellController.shared.isVisible {
                IslandWorkspace.shared.show(.sessions)
            } else {
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)
            }
        }
        if !succeeded { voiceChatActive = false }
        if completeSpokenReply(reply) { phase = .speaking }
        else {
            latency.finish(success: succeeded)
            if succeeded { scheduleVoiceResume() }
        }
    }

    func beginHandsFree() {
        cancel(preserveWakeCapture: true)
        focusLease.begin()
        show()
        transcript = ""; response = ""
        phase = .listening
        message = "Listening to your question… Pause when you're done."
        prewarmReply()
    }

    func updateHandsFree(_ text: String) { transcriptUpdates.submit(text) }

    func announce(_ text: String, spoken: Bool) {
        guard phase == .idle else { return }
        if !IslandWorkspace.shared.isVisible {
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.ambient)
        }
        ConversationHistory.shared.append(question: "", answer: text, source: "ambient")
        if spoken { speak(text) }
    }

    static func sessionContext() -> VoiceSessionContext {
        let state = AppState.shared
        return VoiceSessionContext(sessions: state.tasks.map { task in
            let agent: String
            if task.source == .claudeCode { agent = "Claude Code" }
            else if task.id.lowercased().contains("codex") { agent = "Codex" }
            else if task.id.lowercased().contains("gemini") { agent = "Gemini" }
            else if task.id.lowercased().contains("antigravity") { agent = "Antigravity" }
            else { agent = "Agent" }
            let index = min(max(0, task.stepIndex), max(0, task.steps.count - 1))
            return VoiceSession(id: task.id, name: task.name, agent: agent, status: task.state.rawValue,
                                latestStep: task.errorMessage ?? task.questionMessage ?? (task.steps.isEmpty ? "" : String(task.steps[index].prefix(240))))
        }, focusedID: state.focusTask?.id)
    }

    static func answerQuestion(_ question: String, context: VoiceSessionContext, cursorContext: String?,
                               conversation: [AssistantConversationTurn] = [],
                               resumeTask: UUID? = nil,
                               onFailure: (@MainActor () -> Void)? = nil,
                               onPartial: (@MainActor (String) -> Void)? = nil) async -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            onFailure?()
            return "Apple Intelligence isn't available right now. I can still tell you the time, report system information, list running apps, check battery or disk space, and show agent status."
        }
        do {
            return try await AtlasAssistant.answer(question, context: context, cursorContext: cursorContext,
                conversation: conversation, memory: AssistantMemory.shared, resumeTask: resumeTask,
                onProgress: { VoiceAssistant.shared.message = $0 }, onPartial: onPartial)
        } catch is CancellationError {
            onFailure?()
            return "The question was cancelled."
        } catch let error as AtlasContextError {
            onFailure?()
            return error.localizedDescription
        } catch let error as AtlasBridgeError {
            onFailure?()
            return error.localizedDescription
        } catch let error as AssistantMemoryError {
            onFailure?()
            return error.localizedDescription
        } catch let error as MetalAgentError {
            onFailure?()
            return error.localizedDescription
        } catch {
            onFailure?()
            return "The on-device model couldn't complete this Atlas run. Please try a shorter question."
        }
    }

    func cancel(preserveWakeCapture: Bool = false, keepVoiceChat: Bool = false) {
        voicePause?.cancel(); voiceResume?.cancel()
        if !keepVoiceChat { voiceChatActive = false }
        if !preserveWakeCapture { WakeListener.shared.stop() }
        generation = UUID()
        finishWhenReady = false
        transcriptUpdates.reset()
        responseUpdates.reset()
        conversation.cancel()
        work?.cancel(); work = nil
        timeout?.cancel(); timeout = nil
        input?.cancel(); input = nil
        stopSpeaking()
        phase = .idle
        message = "Ask me anything, or ask what's happening on your Mac."
    }

    /// Alternating capture/playback prevents the assistant from transcribing itself.
    func startVoiceChat() {
        guard AgentPreferences.shared.enabled else {
            message = "Enable the agent in Settings → Assistant & Mac."
            return
        }
        voiceChatActive = true
        beginListening(presentInterface: false, continuingVoiceChat: true)
    }

    private func scheduleVoicePause(_ text: String, token: UUID) {
        guard voiceChatActive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        voicePause?.cancel()
        voicePause = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, generation == token,
                  voiceChatActive, phase == .listening else { return }
            finishListening()
        }
    }

    private func scheduleVoiceResume() {
        guard voiceChatActive, phase == .idle else { return }
        let token = generation
        voiceResume?.cancel()
        voiceResume = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, generation == token,
                  voiceChatActive, phase == .idle else { return }
            beginListening(presentInterface: false, continuingVoiceChat: true)
        }
    }

    func readAloud(_ text: String) {
        guard !isBusy else { return }
        cancel()
        speak(text, preview: true)
    }

    /// Editing branches the dialogue, preserving the original and its tool results.
    func branchConversation(before index: Int) {
        let prior = Array(completedTurns.prefix(max(0, index)))
        newConversation()
        conversation.restore(prior, scope: AssistantMemory.shared.project)
        completedTurns = prior
        for turn in prior {
            ConversationHistory.shared.append(question: turn.question, answer: turn.answer,
                conversationID: conversationID, scope: AssistantMemory.shared.project)
        }
    }

    func newConversation() {
        cancel()
        conversation.reset(scope: AssistantMemory.shared.project)
        completedTurns = []; conversationID = UUID()
        transcript = ""
        response = ""
        requestCursorContext = nil
    }

    func openConversation(_ thread: ConversationThread) {
        cancel()
        AssistantMemory.shared.project = thread.scope
        conversation.restore(thread.records.map { .init(question: $0.question, answer: $0.answer) }, scope: thread.scope)
        conversationID = thread.id
        completedTurns = conversation.archive
        transcript = ""; response = ""; requestCursorContext = nil
        IslandWorkspace.shared.show(.assistant)
    }

    private func fail(_ error: Error) {
        failMessage(error.localizedDescription)
        if case VoiceInputError.modelDownloadRequired = error { phase = .needsDownload }
    }

    private func failMessage(_ text: String) {
        latency.finish(success: false)
        cancel()
        phase = .failed
        message = text
    }

    private func shouldSpeak(preview: Bool = false) -> Bool {
        guard (spokenReplies || voiceChatActive || preview) && AppState.shared.soundEnabled else { return false }
        return true
    }

    /// Start the voice and the on-device model while the user is still speaking.
    private func prewarmReply() {
        if shouldSpeak() { speaker.prepare() }
        AtlasAssistant.prewarm()
    }

    private func speak(_ text: String, preview: Bool = false) {
        guard shouldSpeak(preview: preview), !text.isEmpty else { return }
        beginSpokenReply()
        if completeSpokenReply(text, preview: preview) { phase = .speaking }
    }

    private func beginSpokenReply() {
        sentences = SpokenSentenceSplitter()
        spokenCharacters = 0
        speechFailure = false
        replyStreaming = true
        speaker.beginReply()
    }

    /// Speak each finished sentence while the rest of the reply is generated.
    private func streamSpokenReply(_ partial: String) {
        guard replyStreaming, !speechFailure else { return }
        for sentence in sentences.sentences(in: partial) { enqueueSpoken(sentence) }
    }

    /// Queue whatever the stream has not spoken yet. Returns true while audio
    /// remains to be played; `speechFinished` ends the turn.
    private func completeSpokenReply(_ text: String, preview: Bool = false) -> Bool {
        guard shouldSpeak(preview: preview), !text.isEmpty else { stopSpeaking(); return false }
        if speechFailure { reportSpeechFailure(); return false }
        if !replyStreaming { beginSpokenReply() }
        var rest = sentences.remainder(of: text)
        if rest == nil {
            // A streamed draft was replaced (a tool step or an error reply).
            // Stop it and speak the reply that was actually given.
            beginSpokenReply()
            rest = sentences.remainder(of: text)
        }
        for sentence in rest ?? [] { enqueueSpoken(sentence) }
        speaker.endReply()
        return replyStreaming
    }

    private func enqueueSpoken(_ sentence: String) {
        let remaining = 3000 - spokenCharacters
        guard remaining > 0 else { return }
        let text = String(sentence.prefix(remaining))
        spokenCharacters += text.count
        speaker.enqueue(text, rate: speechRate, pitch: speechPitch)
    }

    private func speechFinished() {
        replyStreaming = false
        if phase == .speaking { phase = .idle }
        latency.finish(success: true)
        scheduleVoiceResume()
    }

    private func speechFailed(_ error: Error) {
        replyStreaming = false
        voiceStatus = "Kokoro could not speak. Written replies still work."
        // Keep generating the written answer; report once it is complete.
        if phase == .thinking { speechFailure = true; return }
        reportSpeechFailure()
    }

    private func reportSpeechFailure() {
        voiceChatActive = false
        voiceResume?.cancel()
        speechFailure = false
        replyStreaming = false
        latency.finish(success: false)
        phase = .failed
        message = "Kokoro couldn’t speak this reply. You can still read the answer."
    }

    func stopSpeaking() {
        speaker.stop()
        replyStreaming = false
        speechFailure = false
        if phase == .speaking { phase = .idle }
    }

}

/// Coalesces streaming text into at most ~10 UI updates per second. The first
/// update is immediate and the latest pending one lands at the end of each
/// window; `reset` drops anything pending before a final value is assigned.
@MainActor
final class PartialThrottle {
    private let apply: @MainActor (String) -> Void
    private var lastApplied = ContinuousClock.now - .seconds(1)
    private var latest: String?
    private var flush: Task<Void, Never>?

    init(_ apply: @escaping @MainActor (String) -> Void) { self.apply = apply }

    func submit(_ text: String) {
        let wait = .milliseconds(100) - (ContinuousClock.now - lastApplied)
        guard wait > .zero else {
            reset(); lastApplied = .now
            apply(text)
            return
        }
        latest = text
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled, let latest else { return }
            flush = nil; self.latest = nil; lastApplied = .now
            apply(latest)
        }
    }

    func reset() {
        flush?.cancel(); flush = nil
        latest = nil
        lastApplied = .now - .seconds(1)
    }
}

/// Stage timings of one voice turn: OSSignposter intervals for Instruments and
/// one numeric LocalTelemetry span plus a one-line summary per completed turn.
@MainActor
final class VoiceTurnLatency {
    private struct Stage { let name: StaticString; let key: String; let from: VoiceMilestone; let to: VoiceMilestone }
    private static let stages = [
        Stage(name: "Mic start", key: "mic_start", from: .turnStarted, to: .micStarted),
        Stage(name: "Analyzer ready", key: "analyzer_ready", from: .turnStarted, to: .analyzerReady),
        Stage(name: "First partial", key: "first_partial", from: .turnStarted, to: .firstPartial),
        Stage(name: "Final transcript", key: "final_transcript", from: .endOfSpeech, to: .finalTranscript),
        Stage(name: "Model first token", key: "model_first_token", from: .finalTranscript, to: .modelFirstToken),
        Stage(name: "Reply", key: "reply", from: .finalTranscript, to: .replyDone),
        Stage(name: "TTS first audio", key: "tts_first_audio", from: .finalTranscript, to: .ttsFirstAudio),
        Stage(name: "Response", key: "end_of_speech_to_audio", from: .endOfSpeech, to: .ttsFirstAudio)
    ]
    private var origin = ""
    private var marks: [VoiceMilestone: Date] = [:]
    private var open: [String: OSSignpostIntervalState] = [:]

    var isActive: Bool { marks[.turnStarted] != nil }

    func begin(_ origin: String) {
        discard()
        self.origin = origin
        mark(.turnStarted)
    }

    func mark(_ milestone: VoiceMilestone, at date: Date = .now) {
        guard milestone == .turnStarted || isActive, marks[milestone] == nil else { return }
        marks[milestone] = date
        let signposter = VoiceSignpost.signposter
        for stage in Self.stages {
            if stage.to == milestone, let state = open.removeValue(forKey: stage.key) {
                signposter.endInterval(stage.name, state)
            }
            if stage.from == milestone, marks[stage.to] == nil {
                open[stage.key] = signposter.beginInterval(stage.name, id: signposter.makeSignpostID())
            }
        }
    }

    func finish(success: Bool) {
        guard let started = marks[.turnStarted] else { return }
        var attributes = ["voice.origin": origin]
        var summary = ["voice.turn", "origin=" + origin, success ? "ok" : "failed"]
        for stage in Self.stages {
            guard let from = marks[stage.from], let to = marks[stage.to] else { continue }
            let milliseconds = String(Int((max(0, to.timeIntervalSince(from)) * 1000).rounded()))
            attributes["latency." + stage.key + ".ms"] = milliseconds
            summary.append(stage.key + "=" + milliseconds + "ms")
        }
        discard()
        let line = summary.joined(separator: " ")
        Task {
            await LocalTelemetry.shared.span("voice.turn", start: started, success: success, attributes: attributes)
            await LocalTelemetry.shared.event(line, success: success)
        }
    }

    func discard() {
        for (key, state) in open {
            guard let stage = Self.stages.first(where: { $0.key == key }) else { continue }
            VoiceSignpost.signposter.endInterval(stage.name, state)
        }
        open = [:]
        marks = [:]
    }
}
