import AVFAudio

/// Owns the shared `AVAudioSession` configuration for user-started capture.
/// Recording is foreground-only; background capture is a separate opt-in
/// (launch plan §9) and is not configured here.
enum AudioSessionController {
    enum Failure: Error, Equatable {
        case microphoneDenied
    }

    /// Asks for microphone access only when the user starts a recording.
    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Activates the session for dictation. The caller must pair this with
    /// `deactivate()` when capture stops so other apps' audio resumes.
    static func activateForDictation() async throws {
        guard await requestMicrophone() else { throw Failure.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }

    /// A keyboard session keeps the microphone open in the background for
    /// minutes, so it mixes with other audio instead of ducking it.
    static func activateForKeyboardSession() async throws {
        guard await requestMicrophone() else { throw Failure.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }

    /// Ends an in-app dictation's audio unless a keyboard session still needs it.
    @MainActor static func deactivateUnlessHeld() {
        guard !IOSMicrophone.shared.heldForKeyboard else { return }
        try? deactivate()
    }

    static func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
