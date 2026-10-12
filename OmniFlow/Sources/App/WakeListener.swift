import AppKit
import Combine
import CoreAudio

enum WakeIndicatorState {
    case off, starting, ready, quiet, listening, paused, failed

    var label: String {
        switch self {
        case .off: "Wake phrase off"
        case .starting: "Starting microphone…"
        case .ready: "Say “Omni”"
        case .quiet: "No microphone sound"
        case .listening: "Listening to you…"
        case .paused: "Wake phrase paused"
        case .failed: "Check microphone"
        }
    }
}

/// Audio buffers can arrive continuously from a muted/disconnected Bluetooth mic.
/// Distinguish that from sound, without retaining audio or recognized words.
struct WakeAudioHealth {
    private var lastSoundAt: Date?
    private var firstBufferAt: Date?
    private(set) var isQuiet = false
    private(set) var detectedSound = false

    mutating func receive(level: Double, at date: Date) {
        if firstBufferAt == nil { firstBufferAt = date }
        if level > 0.05 { lastSoundAt = date; detectedSound = true }
        isQuiet = date.timeIntervalSince(lastSoundAt ?? firstBufferAt ?? date) >= 8
    }
}

/// Energy-based end of speech from the input meter (about eight levels per
/// second). Tracks the room's floor between utterances; never retains audio.
struct EndOfSpeechDetector {
    static let trailingSilence: TimeInterval = 0.8
    private(set) var noiseFloor: Double?
    private var lastSpeechAt: Date?

    var heardSpeech: Bool { lastSpeechAt != nil }

    mutating func receive(level: Double, at date: Date) {
        let floor = noiseFloor ?? min(level, 0.3)
        if level > max(0.35, floor + 0.15) {
            lastSpeechAt = date
        } else {
            noiseFloor = floor * 0.9 + level * 0.1
        }
    }

    func speechEnded(at date: Date) -> Bool {
        guard let lastSpeechAt else { return false }
        return date.timeIntervalSince(lastSpeechAt) >= Self.trailingSilence
    }

    /// The wake phrase itself is speech, even if its levels arrived earlier.
    mutating func markSpeech(at date: Date) { lastSpeechAt = date }
}

/// Opt-in, local SpeechAnalyzer wake phrase. Pre-wake text is memory-only and discarded
/// every 40 seconds without restarting capture. It never enters the language model,
/// transcript store or telemetry. Capture stays open and muted during replies.
@MainActor
final class WakeListener: ObservableObject {
    static let shared = WakeListener()
    @Published var enabled = UserDefaults.standard.bool(forKey: "wakePhraseEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "wakePhraseEnabled")
            failed = false
            canRetry = false
            if !enabled { stop() }
            reconcile()
        }
    }
    @Published private(set) var status = "Wake phrase off"
    @Published private(set) var isCapturing = false
    @Published private(set) var canRetry = false
    @Published private(set) var microphoneName = ""
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var receivesAudio = false
    @Published private(set) var recognizedSpeech = false
    @Published private(set) var isQuiet = false
    @Published private(set) var audioFormat = ""
    @Published var microphoneUID = UserDefaults.standard.string(forKey: VoiceMicrophone.preferenceKey) ?? "" {
        didSet {
            guard microphoneUID != oldValue else { return }
            UserDefaults.standard.set(microphoneUID, forKey: VoiceMicrophone.preferenceKey)
            if isCapturing { VoiceAssistant.shared.cancel() }
            retry()
        }
    }
    var indicator: WakeIndicatorState {
        if !enabled { return .off }
        if isCapturing { return .listening }
        if canRetry { return .failed }
        if receivesAudio { return isQuiet ? .quiet : .ready }
        return input == nil ? .paused : .starting
    }
    var inputStatus: String {
        if isQuiet { return "No sound from \(microphoneName). Check mute or choose another microphone." }
        if receivesAudio { return "\(microphoneName) · \(recognizedSpeech ? "Speech detected" : "Audio connected")" }
        return status
    }
    private var input: VoiceInput?
    private var work: Task<Void, Never>?
    private var rotation: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var latest = ""
    private var generation = UUID()
    private var failed = false
    private var finishing = false
    private var pauses = Set<String>()
    private var recovery: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var audioHealth = WakeAudioHealth()
    private var endOfSpeech = EndOfSpeechDetector()
    private var loggedFormat = ""
    private var loggedDiagnosticFormat = ""
    /// Capture stays warm while a reply is generated or spoken, but nothing it
    /// hears can wake the assistant: input is not echo-cancelled.
    private var muted = false
    private var unmuting: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var defaultInputObserver: AudioObjectPropertyListenerBlock?
    private static let listeningStatus = "Listening for “Omni” or “Hey Omni”"

    func launch() {
        SoundEngine.shared.preload(["wake", "heard"])
        // Keep observing even after a recording fails. An observer owned only by
        // the active recording disappears exactly when a new route is needed.
        if defaultInputObserver == nil {
            let observer: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.defaultMicrophoneChanged() }
            }
            var address = VoiceMicrophone.defaultInputAddress
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, observer) == noErr {
                defaultInputObserver = observer
            }
        }
        VoiceAssistant.shared.$phase.sink { [weak self] phase in
            guard let self else { return }
            if isCapturing && phase == .listening { return }
            // A successful manual recording means missing assets/permissions have
            // been resolved. Resume wake listening after that interaction finishes.
            if phase == .listening { failed = false; canRetry = false }
            if phase == .thinking || phase == .speaking { mute() }
            else if phase != .idle && phase != .failed { stop(); status = "Wake phrase paused during replies" }
            else { Task { @MainActor [weak self] in self?.unmute(); self?.reconcile() } }
        }.store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        for (pause, resume, reason) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")
        ] {
            workspace.publisher(for: pause).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.pauses.insert(reason); self?.stop()
            }.store(in: &subscriptions)
            workspace.publisher(for: resume).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.pauses.remove(reason); self?.reconcile()
            }.store(in: &subscriptions)
        }
        reconcile()
    }

    func setDictationActive(_ active: Bool) {
        if active { pauses.insert("dictation"); stop() }
        else { pauses.remove("dictation"); reconcile() }
    }

    /// The Reader is reading a book through speakers: capture is not
    /// echo-cancelled, so the wake phrase pauses until it stops.
    func setReaderSpeaking(_ speaking: Bool) {
        guard speaking != pauses.contains("reader") else { return }
        if speaking { pauses.insert("reader"); stop() }
        else { pauses.remove("reader"); reconcile() }
    }

    func stop(preserveAudioHealth: Bool = false) {
        generation = UUID()
        work?.cancel(); work = nil
        rotation?.cancel(); rotation = nil
        silence?.cancel(); silence = nil
        recovery?.cancel(); recovery = nil
        unmuting?.cancel(); unmuting = nil
        input?.cancel(); input = nil
        muted = false
        isCapturing = false
        latest = ""
        finishing = false
        microphoneLevel = 0; receivesAudio = false; recognizedSpeech = false
        if !preserveAudioHealth { isQuiet = false; audioHealth = WakeAudioHealth() }
        if !enabled { status = "Wake phrase off"; canRetry = false }
    }

    func retry() {
        failed = false; canRetry = false
        recoveryAttempts = 0
        stop(); reconcile()
    }

    func defaultMicrophoneChanged() {
        guard enabled, microphoneUID.isEmpty else { return }
        if isCapturing { VoiceAssistant.shared.cancel() }
        retry()
    }

    static func canReconnect(after error: Error) -> Bool {
        if let input = error as? VoiceInputError, [.inputChanged, .stalledInput].contains(input) { return true }
        let system = error as NSError
        // CoreAudio can briefly fail to create the input while USB/Bluetooth
        // routes settle. Retry this transient failure, with the same three-attempt cap.
        return system.domain == NSOSStatusErrorDomain && system.code == -1
    }

    private func mute() {
        guard input != nil, !isCapturing else { stop(); status = "Wake phrase paused during replies"; return }
        unmuting?.cancel(); unmuting = nil
        muted = true
        rotation?.cancel(); rotation = nil
        status = "Wake phrase paused during replies"
    }

    /// Speech output can still be in the analyzer's pipeline; give it a moment
    /// to drain, then discard everything heard during the reply.
    private func unmute() {
        guard muted, let reader = input, unmuting == nil else { return }
        let token = generation
        unmuting = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            unmuting = nil
            guard generation == token, muted, [.idle, .failed].contains(VoiceAssistant.shared.phase) else { return }
            reader.resetTranscript()
            muted = false
            status = receivesAudio ? Self.listeningStatus : "Waiting for microphone audio…"
            scheduleRotation()
        }
    }

    /// Discard pre-wake text every 40 seconds without restarting capture.
    private func scheduleRotation() {
        rotation?.cancel()
        rotation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(40))
                guard !Task.isCancelled, let self, !isCapturing, !finishing else { return }
                input?.resetTranscript()
            }
        }
    }

    /// `muted` starts a fresh capture during a reply, ready for the next wake phrase.
    private func reconcile(muted startMuted: Bool = false) {
        guard AgentPreferences.shared.enabled, enabled, pauses.isEmpty, !failed, input == nil,
              startMuted || [.idle, .failed].contains(VoiceAssistant.shared.phase) else { return }
        let reader = VoiceInput()
        input = reader
        muted = startMuted
        let token = UUID(); generation = token
        status = startMuted ? "Wake phrase paused during replies" : "Starting wake phrase…"
        work = Task { [weak self] in
            do {
                try await reader.start(downloadIfNeeded: false,
                    onStatus: { [weak self] text in
                        guard let self, generation == token else { return }
                        status = text
                    },
                    onTranscript: { [weak self] text in
                        guard let self, generation == token else { return }
                        if !recognizedSpeech && !text.isEmpty {
                            recognizedSpeech = true
                            Task { await LocalTelemetry.shared.event("voice.wake.speech_detected") }
                        }
                        received(text)
                    },
                    onFailure: { [weak self] error in
                        guard let self, generation == token else { return }
                        fail(error)
                    },
                    onActivity: { [weak self] level, name in
                        guard let self, generation == token else { return }
                        receivedAudio(level: level, name: name)
                    },
                    onFormat: { [weak self] description in
                        guard let self, generation == token, audioFormat != description else { return }
                        audioFormat = description
                        // Log a format once, and again only when it changes. The signal
                        // diagnostic that follows each capture start is logged once per format.
                        let format = String(description.split(separator: ";", maxSplits: 1)[0])
                        let diagnostic = description.contains(";")
                        guard diagnostic ? loggedDiagnosticFormat != format : loggedFormat != format else { return }
                        if diagnostic { loggedDiagnosticFormat = format } else { loggedFormat = format }
                        Task { await LocalTelemetry.shared.span("voice.input.format", start: .now, attributes: ["audio.format": description]) }
                    })
                guard let self, generation == token, !Task.isCancelled else { return }
                if muted {
                    if [.idle, .failed].contains(VoiceAssistant.shared.phase) { unmute() }
                    return
                }
                status = receivesAudio ? Self.listeningStatus : "Waiting for microphone audio…"
                scheduleRotation()
            } catch {
                guard let self, generation == token, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    func receivedAudio(level: Double, name: String, at date: Date = .now) {
        if !receivesAudio {
            receivesAudio = true
            microphoneName = name
            if !isCapturing { status = Self.listeningStatus }
            Task { await LocalTelemetry.shared.event("voice.wake.audio_ready") }
        }
        // Learn the room floor continuously, not only after a wake phrase.
        endOfSpeech.receive(level: level, at: date)
        if isCapturing && !finishing && !latest.isEmpty && endOfSpeech.speechEnded(at: date) { finish() }
        let hadSound = audioHealth.detectedSound
        audioHealth.receive(level: level, at: date)
        if !hadSound && audioHealth.detectedSound {
            Task { await LocalTelemetry.shared.event("voice.wake.sound_detected") }
        }
        if isQuiet != audioHealth.isQuiet {
            isQuiet = audioHealth.isQuiet
            if isQuiet { Task { await LocalTelemetry.shared.event("voice.wake.silent_input") } }
        }
        if abs(microphoneLevel - level) > 0.02 { microphoneLevel = level }
        recoveryAttempts = 0
    }

    func fail(_ error: Error) {
        let wasCapturing = isCapturing
        stop(); failed = true
        if wasCapturing { VoiceAssistant.shared.cancel() }
        canRetry = true
        status = Self.canReconnect(after: error) ? "The microphone connection isn't ready. Check your Mac's input and retry." : error.localizedDescription
        let systemError = error as NSError
        Task { await LocalTelemetry.shared.span("voice.wake.failure", start: .now, success: false,
            attributes: ["error.type": String(systemError.domain.prefix(100)), "error.code": String(systemError.code)]) }
        if Self.canReconnect(after: error), enabled, pauses.isEmpty, recoveryAttempts < 3 {
            recoveryAttempts += 1
            status = "Reconnecting microphone…"
            recovery = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                failed = false; canRetry = false
                reconcile()
            }
        }
    }

    // Shared entry point for live speech and hardware-free lifecycle regression checks.
    func received(_ text: String) {
        guard AgentPreferences.shared.enabled, enabled, !finishing, !muted, let command = WakePhrase.command(in: text) else { return }
        if !isCapturing {
            isCapturing = true
            endOfSpeech.markSpeech(at: .now)
            SoundEngine.shared.play("wake")
            rotation?.cancel()
            VoiceAssistant.shared.beginHandsFree()
            VoiceAssistant.shared.latency.begin("wake")
            status = "Listening to your question…"
            rotation = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finish()
            }
            Task { await LocalTelemetry.shared.event("voice.wake_phrase") }
        }
        guard command != latest else { return }
        latest = String(command.prefix(2000))
        VoiceAssistant.shared.updateHandsFree(latest)
        silence?.cancel()
        // Secondary signal: a transcript that stops changing ends the request
        // even when room noise keeps the level detector above its threshold.
        if !latest.isEmpty {
            silence = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        }
    }

    func finish() {
        guard isCapturing, !finishing, let reader = input else { return }
        finishing = true
        VoiceAssistant.shared.latency.mark(.endOfSpeech)
        SoundEngine.shared.play("heard")
        silence?.cancel(); silence = nil
        rotation?.cancel(); rotation = nil
        let token = generation
        let fallback = latest
        rotation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, generation == token else { return }
            // Don't leave the island listening forever if SpeechAnalyzer stalls
            // while finalizing. The latest partial command is already local.
            stop()
            VoiceAssistant.shared.latency.mark(.finalTranscript)
            if fallback.isEmpty { VoiceAssistant.shared.cancel(); reconcile() }
            else { VoiceAssistant.shared.ask(fallback, continuingTurn: true); reconcile(muted: true) }
        }
        work = Task { [weak self] in
            let final = try? await reader.finish()
            guard let self, generation == token, !Task.isCancelled else { return }
            rotation?.cancel(); rotation = nil
            let command = final.flatMap { WakePhrase.command(in: $0) } ?? fallback
            input = nil; isCapturing = false; latest = ""; finishing = false
            VoiceAssistant.shared.latency.mark(.finalTranscript)
            if command.isEmpty { VoiceAssistant.shared.cancel(); reconcile() }
            else {
                // The finished reader is terminal; reopen capture now, muted,
                // so it is warm again when the reply ends.
                VoiceAssistant.shared.ask(command, continuingTurn: true)
                reconcile(muted: true)
            }
        }
    }
}
