@preconcurrency import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// The iOS Reader: the shared `ReaderEngine` with the iPhone/iPad around it.
/// That means the AVSpeech voice, the audio session (background playback, calls
/// and other audio interrupting), and Now Playing, which gives Lock Screen,
/// Control Center and Dynamic Island controls. Positions are sealed in the
/// vault through `ReaderPositionStore`, so App Lock covers them like notes.
@MainActor
final class IOSReaderModel: ObservableObject {
    static let shared = IOSReaderModel()

    let engine: ReaderEngine
    private let voice = KokoroReaderVoice()
    @Published private(set) var book: IOSReaderBook?
    @Published private(set) var cover: UIImage?
    @Published private(set) var startNote: String?
    /// The Reader's pace (0.7–1.3), kept separately from spoken replies.
    @Published var rate: Double = UserDefaults.standard.object(forKey: "omniflow.reader.rate") as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(rate, forKey: "omniflow.reader.rate")
            engine.voiceSettingsChanged()
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var changes = Set<AnyCancellable>()
    private var commandsRegistered = false
    private var resumeAfterInterruption = false

    private init() {
        let rateSetting = { UserDefaults.standard.object(forKey: "omniflow.reader.rate") as? Double ?? 1.0 }
        engine = ReaderEngine(voice: voice, store: .standard, rate: rateSetting, pitch: { 1.0 })
        engine.voiceUnavailableMessage = "Kokoro could not start. Prepare a voice in Reader settings."
        voice.onFailure = { [weak self] message in
            guard let self else { return }
            self.engine.pause(.user)
            self.engine.seek(to: self.engine.index)
            self.voice.stop()
            self.engine.fail(loading: message)
        }
        engine.onMove = { [weak self] _, _ in self?.publishNowPlaying() }
        engine.onIdle = { [weak self] in self?.deactivateSession() }
        engine.onVoiceLost = { [weak self] in self?.voice.stop() }
        engine.$status.sink { [weak self] _ in
            Task { @MainActor in self?.publishNowPlaying() }
        }.store(in: &changes)
        observeAudioSession()
    }

    var isActive: Bool { book != nil && engine.status != .idle }
    var chapterTitle: String { engine.currentRef.flatMap { engine.document?.chapters[$0.chapter].title } ?? "" }
    var bookProgress: Double { engine.order.isEmpty ? 0 : Double(engine.index) / Double(engine.order.count) }

    /// Unpacks (off the main thread), parses and opens a book where the user
    /// stopped. Read-along opens it without starting the narration.
    func open(_ book: IOSReaderBook, autoplay: Bool = true) {
        if self.book?.id == book.id, engine.document != nil { if autoplay { play() }; return }
        engine.beginLoading()
        voice.resetSession()
        self.book = book
        cover = IOSReaderLibrary.shared.covers[book.id]
        startNote = nil
        Task {
            do {
                let package = try await IOSReaderLibrary.shared.prepare(book)
                let document = try await Task.detached(priority: .userInitiated) { try ReaderEPUB.load(package) }.value
                guard self.book?.id == book.id else { return }
                let saved = engine.savedEntry(book.id, document: document)
                startNote = saved == nil ? "Starting at the beginning." : "Continuing where you stopped listening."
                engine.pronunciation = ReaderPronunciation(vocabulary: .current())
                if engine.load(document, bookID: book.id, title: book.title, start: saved?.position.cfi.flatMap(ReaderCFI.init).flatMap { document.sentence(for: $0) } ?? saved?.position.ref), autoplay { play() }
            } catch {
                engine.fail(loading: error.localizedDescription)
            }
        }
    }

    func play() {
        activateSession()
        registerCommands()
        engine.play()
        publishNowPlaying()
    }

    func pauseForAssistant() {
        guard engine.document != nil else { return }
        engine.pause(.assistant)
        engine.seek(to: engine.index)
        voice.stop()
    }

    func togglePlay() { engine.isPlaying ? engine.pause(.user) : play() }

    func close() {
        engine.savePositionNow(synchronously: true)
        engine.close()
        voice.resetSession()
        book = nil; cover = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateSession()
    }

    /// An explicit preference change restarts at a sentence boundary and
    /// discards queued audio from the previous voice. Automatic discovery does not.
    func readingVoiceChanged() {
        guard book != nil, engine.document != nil else { return }
        let wasPlaying = engine.isPlaying
        engine.pause(.user)
        voice.stop()
        engine.seek(to: engine.index)
        do {
            try voice.start()
            if wasPlaying { play() }
        } catch {
            engine.fail(loading: error.localizedDescription)
        }
    }

    // MARK: - Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        // Spoken audio: other apps' audio pauses, and the system treats it like an audiobook.
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification,
                     UIApplication.didBecomeActiveNotification, UIApplication.protectedDataWillBecomeUnavailableNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let event = note.name.rawValue
                Task { @MainActor in
                    guard let self else { return }
                    ReaderVoiceTrace.record(event, ["voice": self.voice.voiceID ?? "nil", "playing": self.engine.isPlaying])
                }
            })
        }
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            Task { @MainActor in
                guard let self else { return }
                ReaderVoiceTrace.record("interruption", ["type": type?.rawValue ?? 999, "playing": self.engine.isPlaying])
                switch type {
                case .began:
                    // A call or another app took the audio: pause, and resume afterwards if the system says so.
                    self.resumeAfterInterruption = self.engine.isPlaying
                    if self.engine.isPlaying { self.engine.pause(.user) }
                case .ended:
                    if self.resumeAfterInterruption, options?.contains(.shouldResume) == true { self.play() }
                    self.resumeAfterInterruption = false
                default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            Task { @MainActor in
                guard let self, self.engine.document != nil else { return }
                ReaderVoiceTrace.record("route_change", ["reason": reason?.rawValue ?? 999, "playing": self.engine.isPlaying])
                // Headphones unplugged: pause rather than continue out of the speaker.
                if reason == .oldDeviceUnavailable, self.engine.isPlaying { self.engine.pause(.user) }
                self.engine.routeChanged()
            }
        })
    }

    // MARK: - Now Playing (Lock Screen, Control Center, Dynamic Island)

    private func registerCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let commands = MPRemoteCommandCenter.shared()
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        Self.handle(commands.playCommand) { $0.play() }
        Self.handle(commands.pauseCommand) { $0.engine.pause(.user) }
        Self.handle(commands.togglePlayPauseCommand) { $0.togglePlay() }
        Self.handle(commands.skipForwardCommand) { $0.engine.skipSeconds(15) }
        Self.handle(commands.skipBackwardCommand) { $0.engine.skipSeconds(-15) }
        Self.handle(commands.nextTrackCommand) { $0.engine.skipChapter(1) }
        Self.handle(commands.previousTrackCommand) { $0.engine.skipChapter(-1) }
    }

    /// Remote commands arrive on a MediaPlayer queue: the handler is built
    /// outside the main actor and hops to it, so nothing isolated runs off main.
    nonisolated private static func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (IOSReaderModel) -> Void) {
        command.addTarget { @Sendable _ in
            Task { @MainActor in action(IOSReaderModel.shared) }
            return .success
        }
    }

    /// MediaPlayer asks for the image on its own queue (this crashed when the
    /// closure was main-actor isolated): built outside the main actor.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    /// Book, chapter and an estimated time (about four seconds a sentence at normal pace), so the scrubber moves.
    private func publishNowPlaying() {
        guard let book, engine.document != nil else { return }
        let pace = max(0.5, rate)
        let seconds = { (count: Int) in Double(count) * 4 / pace }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle.isEmpty ? book.title : chapterTitle,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackProgress: bookProgress,
        ]
        if !engine.order.isEmpty {
            info[MPMediaItemPropertyPlaybackDuration] = seconds(engine.order.count)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds(engine.index)
        }
        if let cover {
            info[MPMediaItemPropertyArtwork] = Self.artwork(cover)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = engine.isPlaying ? .playing : .paused
    }
}
