import AppKit
import Carbon
import Combine
import CoreAudio
import Foundation
import MediaPlayer

/// The Mac Reader: the Apple Books library (read-only), covers, the island,
/// media keys, Now Playing and interruptions (dictation, the assistant,
/// sleep) around the platform-neutral `ReaderEngine`, which reads the book
/// aloud with the selected Siri voice, pace and pitch (Settings › Assistant
/// voice).
///
/// Starts from Books' saved location (read from a copy of its library) when
/// it is ahead of the reader's own saved position. Never logs book text;
/// telemetry is counts and timings only.
@MainActor
final class ReaderController: ObservableObject {
    static let shared = ReaderController()

    typealias Status = ReaderEngine.Status
    typealias PauseReason = ReaderEngine.PauseReason
    typealias Stats = ReaderEngine.Stats

    @Published private(set) var book: ReaderBook?
    @Published private(set) var library: [ReaderBook] = []
    @Published private(set) var libraryError: String?
    @Published private(set) var libraryLoading = false
    @Published private(set) var readingVoiceName: String?
    let favorites = ReaderFavorites()

    /// Where this session started from, shown on the Reader page.
    @Published private(set) var startNote: String?
    /// Books' page when it is behind the listening place, offered as a jump.
    @Published private(set) var booksStart: ReaderSentenceRef?

    /// The open book's cover for the island (about 2× its displayed size) and
    /// for Now Playing; nil until decoded or when the book has none.
    @Published private(set) var cover: NSImage?
    private var artwork: NSImage?
    /// Decoded covers by book, so reopening a book never decodes again.
    private static var covers: [String: (thumb: NSImage, artwork: NSImage)] = [:]
    /// The screen is locked: the island's waveform holds still.
    @Published private(set) var screenLocked = false
    private var lockObservers: [NSObjectProtocol] = []

    /// The reading session (Core). Its state is republished here.
    let engine: ReaderEngine
    private var engineObservers = Set<AnyCancellable>()
    private var wasActive = false
    private var observers = Set<AnyCancellable>()
    private var observing = false
    private var commandsRegistered = false
    private let host: Host
    private let speech: KokoroReaderVoice

    var status: Status { engine.status }
    var document: ReaderDocument? { engine.document }
    /// Position in `order`, the book's spoken sentences.
    var index: Int { engine.index }
    var order: [ReaderSentenceRef] { engine.order }
    var stats: Stats { engine.stats }

    /// A book is loaded: the island shows the Reader card instead of Music.
    var isActive: Bool { document != nil && status != .idle }
    var isPlaying: Bool { status == .playing }
    var currentRef: ReaderSentenceRef? { engine.currentRef }
    var chapterTitle: String { currentRef.flatMap { document?.chapters[$0.chapter].title } ?? "" }
    /// Progress through the current chapter, by sentences.
    var chapterProgress: Double { engine.chapterProgress }
    var bookProgress: Double { order.isEmpty ? 0 : Double(index) / Double(order.count) }

    /// What the reader takes from the rest of the app. The app uses `.app`;
    /// the headless soak tests supply their own voice, settings and store.
    struct Host {
        var voice: @MainActor () -> SiriVoice?
        var refreshVoice: @MainActor () -> Void
        var rate: @MainActor () -> Double
        var setRate: @MainActor (Double) -> Void
        var pitch: @MainActor () -> Double
        var setReaderSpeaking: @MainActor (Bool) -> Void
        var helper: URL?
        var store: ReaderPositionStore
        /// Dictation, assistant, settings, sleep, media-key and Now Playing hooks.
        var integrates = true
        var muted = false

        @MainActor static var app: Host {
            Host(voice: { VoiceAssistant.shared.siriVoice ?? SiriVoice.preferred(in: VoiceAssistant.shared.availableVoices) },
                 refreshVoice: { VoiceAssistant.shared.refreshVoice() },
                 rate: { VoiceAssistant.shared.speechRate },
                 setRate: { VoiceAssistant.shared.speechRate = $0 },
                 pitch: { VoiceAssistant.shared.speechPitch },
                 setReaderSpeaking: { WakeListener.shared.setReaderSpeaking($0) },
                 helper: SiriVoiceService.helperURL,
                 store: .standard)
        }
    }

    convenience private init() { self.init(host: .app) }

    init(host: Host) {
        self.host = host
        let playback = ReaderPlayback()
        playback.muted = host.muted
        let speech = KokoroReaderVoice()
        self.speech = speech
        let voice: any ReaderVoiceSource = speech
        engine = ReaderEngine(voice: voice, playback: playback, store: host.store, rate: { host.rate() }, pitch: { host.pitch() })
        engine.voiceUnavailableMessage = "Kokoro could not start. Prepare a voice in Reader settings."
        engine.voiceStoppedMessage = "Kokoro stopped responding."
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked = locked }
            })
        }
        playback.onRouteChange = { [weak self] in
            Task { @MainActor in
                self?.engine.routeChanged()
                self?.updateWake()
            }
        }
        engine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &engineObservers)
        engine.$status.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.statusChanged() }.store(in: &engineObservers)
        engine.onMove = { [weak self] _, _ in self?.updateNowPlaying() }
        engine.onVoiceLost = { speech.stop() }
        speech.onFailure = { [weak self] message in
            guard let self else { return }
            self.engine.pause(.user)
            self.engine.seek(to: self.index)
            self.speech.stop()
            self.engine.fail(loading: message)
        }
        // Apple Books follow-along was removed: drop its per-book setting.
        UserDefaults.standard.removeObject(forKey: "omniflow.reader.keepBooksInStep.books")
    }

    /// Wake, Now Playing and the island follow the session's status.
    private func statusChanged() {
        updateWake()
        updateNowPlaying()
        // Reading opens first in the expanded island when a book starts,
        // and the selection falls back to the first page when it stops.
        // Kept here (always alive) so it holds while the island is compact.
        let active = isActive
        guard active != wasActive else { return }
        wasActive = active
        AppState.shared.carouselPanel = active ? .reader : (AppState.shared.carouselPanel == .reader ? nil : AppState.shared.carouselPanel)
        if !active, AppState.shared.carouselPanel == nil { AppState.shared.carouselPage = 0 }
    }

    // MARK: - Library

    func loadLibrary() {
        guard !libraryLoading else { return }
        libraryLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[ReaderBook], Error> in
                Result { try ReaderLibrary.books() }
            }.value
            libraryLoading = false
            switch result {
            case .success(let books): library = books; libraryError = nil
            case .failure(let error): libraryError = error.localizedDescription
            }
            await LocalTelemetry.shared.gauge("reader.library.books", value: Double(library.count), unit: "count")
        }
    }

    /// The menu, shortcut and island entry point: toggle the open book, or
    /// open the last one, or show the Reader page.
    func continueReading() {
        if document != nil { togglePlay(); return }
        if let id = engine.lastBookID {
            Task {
                if library.isEmpty { library = (try? await Task.detached { try ReaderLibrary.books() }.value) ?? [] }
                if let book = library.first(where: { $0.id == id }) { open(book, autoplay: true) }
                else { IslandWorkspace.shared.show(.reader) }
            }
        } else {
            IslandWorkspace.shared.show(.reader)
        }
    }

    func open(_ book: ReaderBook, autoplay: Bool) {
        if self.book?.id == book.id, document != nil { if autoplay { play() }; return }
        close()
        self.book = book
        engine.beginLoading()
        Task {
            let load = Task.detached(priority: .userInitiated) { () -> Result<(ReaderDocument, ReaderBooksLocation?), Error> in
                Result { (try ReaderEPUB.load(URL(fileURLWithPath: book.path)), try? ReaderLibrary.location(for: book.id)) }
            }
            // A book iCloud is still syncing can keep the file system busy:
            // say so and ask iCloud for it instead of looking stuck.
            let notice = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, self.book?.id == book.id, status == .loading else { return }
                startNote = "Waiting for iCloud to download this book…"
                Task.detached(priority: .utility) { ReaderLibrary.requestDownload(book.path) }
            }
            let loaded = await load.value
            notice.cancel()
            guard self.book?.id == book.id else { return }
            switch loaded {
            case .failure(let error):
                startNote = nil
                engine.fail(loading: error.localizedDescription)
            case .success(let (document, location)):
                let saved = engine.savedEntry(book.id, document: document)
                let order = document.sentences
                var start: ReaderSentenceRef?
                if !order.isEmpty {
                    let (ref, note) = startPosition(document, order: order, saved: saved, books: location)
                    start = ref
                    startNote = note
                }
                guard engine.load(document, bookID: book.id, title: book.title, start: start) else { return }
                loadCover(book: book, file: document.cover)
                if autoplay { play() }
            }
        }
    }

    /// Books' location when it is ahead of the reader's own (he read on in
    /// Books); otherwise the reader's. Books re-saves its page on every open
    /// and syncs from other devices, so a newer but earlier Books location
    /// never pulls listening back; the page offers "Start from Books' page".
    /// Without a Books location: the chapter its progress falls in.
    private func startPosition(_ document: ReaderDocument, order: [ReaderSentenceRef], saved: ReaderPositionStore.Entry?,
                               books: ReaderBooksLocation?) -> (ReaderSentenceRef, String) {
        let chapterStarts = ReaderEngine.chapterStarts(order)
        var mine: ReaderSentenceRef?
        if let saved {
            mine = saved.position.cfi.flatMap(ReaderCFI.init).flatMap { document.sentence(for: $0) }
            if mine == nil, order.contains(saved.position.ref) { mine = saved.position.ref }
        }
        var theirs = books?.cfi.flatMap(ReaderCFI.init).flatMap { document.sentence(for: $0) }
        var approximate = false
        if theirs == nil, let progress = books?.progress, progress > 0.005 {
            let chapter = order[min(order.count - 1, Int(Double(order.count) * min(1, progress)))].chapter
            theirs = chapterStarts[chapter].map { order[$0] }
            approximate = true
        }
        booksStart = nil
        switch (mine, theirs) {
        case let (mine?, theirs?) where theirs > mine:
            return (theirs, approximate ? "Starting at the chapter Apple Books shows." : "Starting where Apple Books left off.")
        case let (mine?, theirs?):
            if theirs < mine { booksStart = theirs; return (mine, "Continuing where you stopped listening. Apple Books is behind your listening place.") }
            return (mine, "Continuing where you stopped listening.")
        case let (mine?, nil): return (mine, "Continuing where you stopped listening.")
        case let (nil, theirs?): return (theirs, approximate ? "Starting at the chapter Apple Books shows." : "Starting where Apple Books left off.")
        case (nil, nil): return (order[0], "Starting at the beginning.")
        }
    }

    /// Jump to the page Books shows when it is behind the listening place.
    func startFromBooksPage() {
        guard let target = booksStart, let i = order.firstIndex(of: target) else { return }
        booksStart = nil
        startNote = "Starting where Apple Books left off."
        seek(to: i)
    }

    func close() {
        engine.close()
        speech.stop()
        readingVoiceName = nil
        book = nil; startNote = nil; booksStart = nil; cover = nil; artwork = nil
        host.setReaderSpeaking(false)
        if host.integrates {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    // MARK: - Transport

    func togglePlay() { status == .playing ? pause(.user) : play() }

    func play() {
        guard document != nil else { continueReading(); return }
        installObservers()
        readingVoiceName = KokoroReadingVoice.selected.title
        engine.pronunciation = ReaderPronunciation(vocabulary: .current())
        engine.play()
    }

    func pause(_ reason: PauseReason) {
        engine.pause(reason)
        if reason == .assistant, document != nil {
            engine.seek(to: index)
            speech.stop()
        }
    }

    func skipSentence(_ delta: Int) { engine.skipSentence(delta) }
    func skipParagraph(_ delta: Int) { engine.skipParagraph(delta) }
    func skipChapter(_ delta: Int) { engine.skipChapter(delta) }
    /// About `seconds` of listening, estimated from characters at the current pace.
    func skipSeconds(_ seconds: Double) { engine.skipSeconds(seconds) }

    func startChapter(_ chapter: Int) {
        guard document != nil else { return }
        engine.seek(to: engine.chapterStarts[chapter] ?? index)
        if status != .playing { play() }
    }

    func seek(to target: Int) { engine.seek(to: target) }

    func routeChanged() {
        engine.routeChanged()
        updateWake()
    }

    /// The pace (0.7–1.3) from the existing voice settings.
    func setRate(_ rate: Double) { host.setRate(min(1.3, max(0.7, (rate * 20).rounded() / 20))) }

    // MARK: - Cover

    /// Decodes the cover off the main thread at the two sizes used: 160 px for
    /// the island card and badge, 600 px for Now Playing.
    private func loadCover(book: ReaderBook, file: URL?) {
        if let cached = Self.covers[book.id] { cover = cached.thumb; artwork = cached.artwork; updateNowPlaying(); return }
        guard let file else { return }
        Task {
            let images = await Task.detached(priority: .utility) { () -> (CGImage, CGImage)? in
                guard let thumb = ReaderCover.thumbnail(file, pixels: 160), let large = ReaderCover.thumbnail(file, pixels: 600) else { return nil }
                return (thumb, large)
            }.value
            guard let images, self.book?.id == book.id else { return }
            let thumb = NSImage(cgImage: images.0, size: .zero), large = NSImage(cgImage: images.1, size: .zero)
            Self.covers[book.id] = (thumb, large)
            cover = thumb; artwork = large
            updateNowPlaying()
        }
    }

    // MARK: - Output level

    /// Loudness of what the Reader is playing right now (raw RMS, 0…1), read
    /// by the island waveform once per frame while it animates. Zero when
    /// paused. Cheap: a lookup in each sentence's precomputed envelope.
    nonisolated var outputLevel: Float { engine.playback.level() }
    /// The voice ring's input while a book plays, as the pill's comes from the mic:
    /// precomputed per sentence, looked up by playback position. Empty when paused.
    nonisolated var outputSpectrum: VoiceRing.Spectrum {
        let frame = engine.playback.spectrum()
        return (frame.bands, frame.peaks, engine.playback.level())
    }

    // MARK: - Interruptions

    private func installObservers() {
        guard !observing, host.integrates else { return }
        observing = true
        // Published fires before the change lands, synchronously on the main
        // thread: the book stops before dictation opens the microphone.
        AppModel.shared.$phase.sink { [weak self] phase in
            guard let self else { return }
            if [.starting, .recording, .processing].contains(phase) { pause(.dictation) }
            else { engine.release(.dictation, after: .milliseconds(600)) }
        }.store(in: &observers)
        VoiceAssistant.shared.$phase.sink { [weak self] phase in
            guard let self else { return }
            if [.preparing, .listening, .finishing, .thinking, .speaking].contains(phase) { pause(.assistant) }
            else { engine.release(.assistant, after: .milliseconds(500)) }
        }.store(in: &observers)
        // Pace and pitch apply from the next unscheduled sentence. Voice changes
        // are explicit actions, separate from automatic voice rediscovery.
        Publishers.Merge(VoiceAssistant.shared.$speechRate.dropFirst().map { _ in () },
                         VoiceAssistant.shared.$speechPitch.dropFirst().map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.voiceSettingsChanged() }.store(in: &observers)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification] {
            workspace.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in self?.pause(.user) }.store(in: &observers)
        }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.engine.savePositionNow(synchronously: true)
        }.store(in: &observers)
        registerRemoteCommands()
    }

    /// Pin the session voice across rediscovery and interruptions. Only an explicit
    /// selection may replace it; flush old scheduled audio before starting the new helper.
    func selectReadingVoice() {
        guard document != nil else { return }
        let resume = isPlaying
        engine.pause(.user)
        speech.stop()
        readingVoiceName = KokoroReadingVoice.selected.title
        engine.seek(to: index)
        if resume { play() }
    }

    private func voiceSettingsChanged() {
        #if !APPSTORE
        guard status == .playing || status == .paused else { return }
        engine.voiceSettingsChanged()
        updateNowPlaying()
        #endif
    }

    /// Wake listening stays on with headphones; through speakers the
    /// microphone would hear the book, so it pauses while reading.
    private func updateWake() {
        host.setReaderSpeaking(status == .playing && !Self.outputIsHeadphones())
    }

    static func outputIsHeadphones() -> Bool {
        var device = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        var source: UInt32 = 0
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr else { return false }
        return source == 0x6864706E // 'hdpn'
    }

    // MARK: - Now Playing and media keys

    private func registerRemoteCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (ReaderController) -> Void) {
            command.isEnabled = true
            command.addTarget(handler: Self.remoteCommandHandler { [weak self] in
                guard let self, document != nil else { return }
                action(self)
            })
        }
        on(center.playCommand) { $0.play() }
        on(center.pauseCommand) { $0.pause(.user) }
        on(center.togglePlayPauseCommand) { $0.togglePlay() }
        on(center.nextTrackCommand) { $0.skipParagraph(1) }
        on(center.previousTrackCommand) { $0.skipParagraph(-1) }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [30]
        on(center.skipForwardCommand) { $0.skipSeconds(30) }
        on(center.skipBackwardCommand) { $0.skipSeconds(-30) }
    }

    // MediaPlayer calls command handlers and asks for artwork on its own
    // queues. Closures formed inside this main-actor class would inherit its
    // isolation, and Swift 6 traps when they run off the main thread, so they
    // are built here, outside the actor, and hop to the main actor explicitly.
    // ReaderOffMainTests calls them from a background queue.

    /// A remote-command handler that runs `action` on the main actor.
    nonisolated static func remoteCommandHandler(_ action: @escaping @MainActor @Sendable () -> Void)
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    /// Now Playing artwork whose image request is safe from any queue.
    nonisolated static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func updateNowPlaying() {
        guard host.integrates else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let book, let document, let ref = currentRef, status != .idle else {
            center.nowPlayingInfo = nil
            return
        }
        let order = self.order, start = engine.chapterStarts[ref.chapter] ?? 0, end = engine.chapterEnd(after: ref.chapter)
        let charactersPerSecond = engine.charactersPerSecond
        func seconds(_ range: Range<Int>) -> Double {
            Double(range.reduce(0) { $0 + document.text(order[$1]).count }) / charactersPerSecond
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: document.chapters[ref.chapter].title,
            MPMediaItemPropertyArtist: book.author,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyPlaybackDuration: seconds(start..<end),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: seconds(start..<index),
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.artwork(artwork) }
        center.nowPlayingInfo = info
        center.playbackState = status == .playing ? .playing : .paused
    }
}

#if APPSTORE
/// The App Store build has no Siri voice helper: the Reader can't speak.
@MainActor
private final class ReaderNoVoice: ReaderVoiceSource {
    var onSentence: ((UInt32, [Float]?) -> Void)?
    var onExit: (() -> Void)?
    var isRunning: Bool { false }
    func start() throws { throw SiriVoiceError.unavailable }
    func request(_ text: String, rate: Double, pitch: Double) -> UInt32? { nil }
    func cancel(_ ids: [UInt32]) {}
    func stop() {}
}
#endif

/// ⌃⌥R: play or pause the Reader from anywhere.
@MainActor
final class ReaderShortcut {
    static let shared = ReaderShortcut()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    @discardableResult
    func register() -> Bool {
        if hotKey != nil { return true }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x4E4C5244 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in ReaderController.shared.continueReading() }
            return noErr
        }, 1, &event, nil, &handler) == noErr else { return false }
        if RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4E4C5244, id: 1),
                               GetApplicationEventTarget(), 0, &hotKey) != noErr {
            unregister(); return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil
    }
}

extension Notification.Name {
    static let readerVoiceSelectionChanged = Notification.Name("omniflow.reader.voiceSelectionChanged")
}
