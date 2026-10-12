import AppKit
import Foundation

@main
enum WakeListenerTests {
    enum Failure: Error { case cancelledWhileOpeningIsland, cancelledWhileNavigating, notCancelledExplicitly }

    @MainActor static func main() async throws {
        UserDefaults.standard.setVolatileDomain([
            "wakePhraseEnabled": true,
            "localTelemetryEnabled": false,
            "voiceSpokenReplies": false
        ], forName: UserDefaults.argumentDomain)
        let state = AppState.shared
        let assistant = VoiceAssistant.shared
        let wake = WakeListener.shared

        // End of speech follows ~0.8 s of trailing quiet above the learned room floor.
        var detector = EndOfSpeechDetector()
        let start = Date()
        for tick in 0..<8 { detector.receive(level: 0.15, at: start.addingTimeInterval(Double(tick) * 0.125)) }
        precondition(!detector.heardSpeech, "Room noise must not count as speech")
        detector.receive(level: 0.75, at: start.addingTimeInterval(1))
        detector.receive(level: 0.2, at: start.addingTimeInterval(1.5))
        precondition(detector.heardSpeech && !detector.speechEnded(at: start.addingTimeInterval(1.5)))
        precondition(detector.speechEnded(at: start.addingTimeInterval(1.85)))
        detector.markSpeech(at: start.addingTimeInterval(5))
        precondition(!detector.speechEnded(at: start.addingTimeInterval(5.5)) && detector.speechEnded(at: start.addingTimeInterval(5.9)))

        precondition(WakeListener.canReconnect(after: NSError(domain: NSOSStatusErrorDomain, code: -1)))
        precondition(!WakeListener.canReconnect(after: VoiceInputError.microphoneDenied))
        wake.fail(VoiceInputError.microphoneDenied)
        precondition(wake.canRetry)
        wake.defaultMicrophoneChanged()
        precondition(!wake.canRetry, "Changing the system input must clear a stopped listener's failure")
        wake.stop()

        // A running Bluetooth stream can contain only zeroes. Never equate
        // receiving buffers with hearing sound; recover as soon as sound returns.
        let now = Date()
        wake.receivedAudio(level: 0, name: "Test microphone", at: now)
        precondition(wake.receivesAudio && wake.indicator == .ready)
        wake.receivedAudio(level: 0, name: "Test microphone", at: now.addingTimeInterval(9))
        precondition(wake.indicator == .quiet && wake.inputStatus.contains("No sound"))
        wake.receivedAudio(level: 0.4, name: "Test microphone", at: now.addingTimeInterval(10))
        precondition(wake.indicator == .ready && !wake.isQuiet)
        wake.stop()
        precondition(!wake.receivesAudio && wake.microphoneLevel == 0 && wake.indicator != .ready)

        state.mode = .hidden
        state.syncMode()
        precondition(state.mode == .compact, "Hands-free status must remain visible without agent sessions")

        // Match the presenter's synchronous view-then-mode transition without a
        // window, a microphone, live agent hooks, or any synthetic user sessions.
        let observer = NotificationCenter.default.addObserver(forName: .hookExpand, object: nil, queue: .main) { note in
            guard let view = note.object as? IslandView else { return }
            MainActor.assumeIsolated {
                state.view = view
                state.mode = .expanded
            }
        }
        defer { NotificationCenter.default.removeObserver(observer); assistant.cancel() }

        for restingMode in [IslandMode.hidden, .compact, .expanded] {
            state.mode = restingMode
            state.view = .overview
            await settle()
            wake.received(restingMode == .compact ? "Omni, what time is it?" : "Hey, Omni, what time is it?")
            await settle()
            guard wake.isCapturing, wake.indicator == .listening, assistant.phase == .listening,
                  assistant.transcript == "what time is it?",
                  state.view == .voice, state.mode == .expanded else {
                print("FAIL: opening the island from \(restingMode) cancelled the wake capture")
                throw Failure.cancelledWhileOpeningIsland
            }

            state.mode = .compact
            await settle()
            guard wake.isCapturing, assistant.phase == .listening else { throw Failure.cancelledWhileNavigating }
            assistant.cancel()
            await settle()
            guard !wake.isCapturing, assistant.phase == .idle else { throw Failure.notCancelledExplicitly }
        }
        print("End-of-speech detection; wake indicators distinguish sound and silence; Omni wake phrases survive navigation; explicit cancellation releases capture: passed")
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
}
