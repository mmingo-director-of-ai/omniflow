import AVFAudio
import Combine
import Foundation

/// App side of the OmniFlow keyboard. Opening OmniFlow from the keyboard starts
/// a session: the microphone stays open (the system shows its indicator) so
/// the app keeps running in the background, and the keyboard's mic button
/// starts and stops dictation. Audio is transcribed only between those taps.
/// The session ends itself after a quiet period, on an audio interruption, or
/// from the app.
@MainActor
final class KeyboardSessionController: ObservableObject {
    static let lengthKey = "omniflow.keyboard.sessionMinutes"
    static let lengths = [2, 5, 15]

    @Published private(set) var active = false
    @Published private(set) var listening = false
    @Published private(set) var expires: Date?
    /// A pairing from an unverified source, waiting for the user to allow it.
    @Published private(set) var pendingPairing: KeyboardBridge.Pairing?

    private let flow: IOSFlowModel
    private let engine: DictationEngine
    private let server = KeyboardServer()
    /// The live voice level while the keyboard is listening (read per frame by the banner).
    var level: Float { server.state.level }
    private var heartbeat: Timer?
    /// Copies the live voice bands into the served state while listening (no notification; the keyboard polls).
    private var meter: Timer?
    private var interruption: AnyCancellable?
    private var started: Date?
    private var work: Task<Void, Never>?

    init(flow: IOSFlowModel, engine: DictationEngine = IOSDictationEngine()) {
        self.flow = flow
        self.engine = engine
    }

    private var idleLength: TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: Self.lengthKey) as? Int ?? 5
        return TimeInterval(minutes * 60)
    }

    /// Entry point for every pairing URL. Unverified sources need the user's go-ahead.
    func requestBegin(_ pairing: KeyboardBridge.Pairing, sourceApplication: String?) {
        switch KeyboardBridge.decide(sourceApplication: sourceApplication) {
        case .start: pendingPairing = nil; begin(pairing)
        case .confirm: pendingPairing = pairing
        }
    }

    func allowPending() {
        guard let pairing = pendingPairing else { return }
        pendingPairing = nil
        begin(pairing)
    }

    /// Once dictation is on, go back to the app the keyboard was in.
    private func returnToHost(_ pairing: KeyboardBridge.Pairing) {
        guard let host = pairing.hostBundleID else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            HostAppReturn.open(host)
        }
    }

    func denyPending() { pendingPairing = nil }

    /// Opened from the keyboard with a fresh pairing. A new pairing replaces
    /// the old one (the keyboard pairs again whenever it can't reach us).
    private func begin(_ pairing: KeyboardBridge.Pairing) {
        guard !active else {
            do { try listen(pairing) } catch { end(message: "Keyboard dictation couldn't start. Tap the mic on the keyboard again."); return }
            extend(); publish()
            returnToHost(pairing)
            return
        }
        work = Task {
            do {
                try await engine.prepare(locale: flow.locale)
                try await AudioSessionController.activateForKeyboardSession()
                IOSMicrophone.shared.heldForKeyboard = true
                try IOSMicrophone.shared.open()
                try listen(pairing)
            } catch {
                server.stop()
                IOSMicrophone.shared.heldForKeyboard = false
                IOSMicrophone.shared.close()
                update { $0.phase = .off; $0.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                return
            }
            active = true
            interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.end(message: "Dictation stopped because another app took the microphone.") }
            heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            extend()
            update { $0.phase = .ready; $0.message = nil; $0.liveText = "" }
            // The Lock Screen / Dynamic Island shows the session; it must start while OmniFlow is in front.
            OmniFlowLiveActivity.shared.start(.dictate)
            OmniFlowLiveActivity.shared.update(.ready)
            returnToHost(pairing)
        }
    }

    func end(message: String? = nil) {
        guard active else { return }
        work?.cancel()
        engine.cancel()
        heartbeat?.invalidate(); heartbeat = nil
        stopMeter()
        interruption = nil
        IOSMicrophone.shared.heldForKeyboard = false
        IOSMicrophone.shared.close()
        try? AudioSessionController.deactivate()
        active = false; listening = false; expires = nil
        OmniFlowLiveActivity.shared.end()
        update { $0.phase = .off; $0.liveText = ""; $0.expires = nil; $0.message = message }
        server.stop()
    }

    private func listen(_ pairing: KeyboardBridge.Pairing) throws {
        try server.start(pairing, handler: { [weak self] command, components in self?.handle(command, components) },
                         onLockout: { [weak self] in self?.end(message: "Keyboard dictation turned off after repeated unauthorized requests.") })
    }

    private func handle(_ command: KeyboardBridge.Command, _ components: URLComponents) {
        switch command {
        case .start: startListening()
        case .stop: stopListening()
        case .cancel: cancelListening()
        case .consume:
            let id = components.queryItems?.first { $0.name == "id" }?.value.flatMap(UUID.init(uuidString:))
            if let id, server.state.result?.id == id { update { $0.result = nil } }
        case .state: break
        }
    }

    private func startListening() {
        guard active, !listening else { return }
        guard !flow.isDictating else { update { $0.message = "OmniFlow is already dictating in the app." }; return }
        listening = true
        started = .now
        extend()
        update { $0.phase = .listening; $0.liveText = ""; $0.message = nil }
        OmniFlowLiveActivity.shared.update(.listening)
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.listening else { return }
                let snapshot = IOSMicrophone.shared.snapshot()
                self.server.state.bands = snapshot.bands
                self.server.state.level = snapshot.level
            }
        }
        work = Task {
            do {
                flow.polisher.prewarm(locale: flow.locale)
                try await engine.start(locale: flow.locale, vocabulary: flow.effectiveVocabulary,
                                       onText: { [weak self] text in self?.update { $0.liveText = text } },
                                       onLevel: { _ in })
            } catch {
                listening = false
                stopMeter()
                OmniFlowLiveActivity.shared.update(.ready)
                update { $0.phase = .ready; $0.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }

    private func stopMeter() {
        meter?.invalidate(); meter = nil
        server.state.bands = []; server.state.level = 0
    }

    /// The Live Activity's Stop button while dictating from the keyboard.
    func stopFromIsland() { stopListening() }

    private func stopListening() {
        guard listening else { return }
        stopMeter()
        update { $0.phase = .finishing }
        OmniFlowLiveActivity.shared.update(.cleaning)
        work = Task {
            let heard = ((try? await engine.finish()) ?? server.state.liveText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Same cleanup as in-app dictation; the keyboard keeps showing "Finishing…" meanwhile.
            let text = heard.isEmpty ? "" : await flow.polisher.polish(heard, locale: flow.locale, styles: flow.learning.learnedStyles).text
            listening = false
            extend()
            OmniFlowLiveActivity.shared.update(.ready)
            if text.isEmpty {
                update { $0.phase = .ready; $0.liveText = ""; $0.message = "Nothing was heard." }
            } else {
                flow.recordKeyboardDictation(raw: heard, text: text, duration: started.map { Date.now.timeIntervalSince($0) })
                update { $0.phase = .ready; $0.liveText = ""; $0.result = .init(id: UUID(), text: text) }
            }
        }
    }

    private func cancelListening() {
        guard listening else { return }
        stopMeter()
        engine.cancel()
        listening = false
        update { $0.phase = .ready; $0.liveText = "" }
    }

    private func extend() {
        expires = Date.now.addingTimeInterval(idleLength)
    }

    private func tick() {
        guard active else { return }
        #if DEBUG
        // Device check that the session survives in the background (never prints the pairing).
        print("keyboard-session alive listening=\(listening) listener=\(server.isListening)")
        #endif
        if !listening, let expires, expires <= .now { end() }
    }

    /// Mutates the state the keyboard reads and tells it to look.
    private func update(_ change: (inout KeyboardBridge.State) -> Void) {
        var state = server.state
        change(&state)
        state.expires = expires
        server.state = state
        KeyboardBridge.post()
    }

    private func publish() { update { _ in } }
}
