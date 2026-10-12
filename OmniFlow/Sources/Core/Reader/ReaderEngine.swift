import Combine
import Foundation

/// Where the Reader's speech comes from: one sentence of text in, 48 kHz mono
/// Float32 samples out. The Mac uses the Siri speech helper; iOS can use
/// `AVSpeechSynthesizer.write`. Each answer is matched to its request by id,
/// so answers may arrive in any order; the engine schedules them in reading
/// order. Every request gets exactly one `onSentence`, unless cancelled.
@MainActor
protocol ReaderVoiceSource: AnyObject {
    /// (request id, samples, or nil when that sentence failed)
    var onSentence: ((UInt32, [Float]?) -> Void)? { get set }
    /// The source stopped unexpectedly (for example, its voice was removed).
    var onExit: (() -> Void)? { get set }
    var isRunning: Bool { get }
    /// Gets ready to speak with its current voice; cheap when already running.
    func start() throws
    /// Queues one sentence and returns its id, or nil when not running.
    /// `rate` is 0.7–1.3 and `pitch` 0.8–1.2 (OmniFlow's voice settings).
    func request(_ text: String, rate: Double, pitch: Double) -> UInt32?
    func cancel(_ ids: [UInt32])
    func stop()
}

/// The platform-neutral reading session: the book's spoken sentences, the
/// look-ahead of synthesized speech, gapless playback with natural pauses,
/// pause reasons, and saved positions. A shell (the Mac's ReaderController,
/// or the iOS Reader) supplies the voice and connects it to its own UI,
/// media controls and interruptions.
@MainActor
final class ReaderEngine: ObservableObject {
    enum Status: Equatable { case idle, loading, ready, playing, paused, finished, failed(String) }
    enum PauseReason: Hashable { case user, dictation, assistant }
    /// Why the listening position moved, for shells that follow it.
    enum Move { case advanced, seeked, paused(PauseReason) }

    @Published private(set) var status: Status = .idle
    @Published private(set) var document: ReaderDocument?
    /// Position in `order`, the book's spoken sentences.
    @Published private(set) var index = 0
    private(set) var order: [ReaderSentenceRef] = []
    private(set) var chapterStarts: [Int: Int] = [:]
    private(set) var bookID: String?
    private var bookTitle = ""

    /// Counts and timings for this session (no text): sentences played, audio
    /// and pause seconds, and waits for speech that was not ready in time.
    struct Stats: Sendable { var sentences = 0, underruns = 0; var audioSeconds = 0.0, underrunSeconds = 0.0 }
    private(set) var stats = Stats()

    /// The listening position moved.
    var onMove: ((ReaderSentenceRef, Move) -> Void)?
    /// The voice stopped unexpectedly; the shell may look for voices again.
    var onVoiceLost: (() -> Void)?
    /// Paused for a minute: the voice and audio device were released.
    var onIdle: (() -> Void)?

    let playback: ReaderPlayback
    private let voice: any ReaderVoiceSource
    private let store: ReaderPositionStore
    private let rate: () -> Double
    private let pitch: () -> Double
    var pronunciation = ReaderPronunciation()
    /// Failure wording; the Mac names its Siri voice.
    var voiceUnavailableMessage = "The voice is unavailable, so the book can't be read aloud."
    var voiceStoppedMessage = "The voice stopped responding."

    private var pauses = Set<PauseReason>()
    private var generation: UInt64 = 0
    private var requested: [UInt32: Int] = [:]
    private var ready: [Int: [Float]] = [:]
    private var requestedThrough = -1
    private var scheduledThrough = -1
    private var failures = 0
    private var starvedSince: Date?
    private var syncBookID: String?
    private var saved = ReaderPositionStore.Saved()
    private var savedLoaded = false
    private var saveTask: Task<Void, Never>?
    private var idleTeardown: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var playStarted: Date?

    init(voice: any ReaderVoiceSource, playback: ReaderPlayback = ReaderPlayback(), store: ReaderPositionStore,
         rate: @escaping () -> Double, pitch: @escaping () -> Double) {
        self.voice = voice; self.playback = playback; self.store = store; self.rate = rate; self.pitch = pitch
        playback.onPlayed = { [weak self] sentence, generation, seconds in
            Task { @MainActor in self?.played(sentence, generation: generation, seconds: seconds) }
        }
        voice.onSentence = { [weak self] id, samples in self?.synthesized(id, samples) }
        voice.onExit = { [weak self] in self?.voiceExited() }
    }

    var isPlaying: Bool { status == .playing }
    var currentRef: ReaderSentenceRef? { order.indices.contains(index) ? order[index] : nil }
    var charactersPerSecond: Double { 15 * rate() }

    /// Progress through the current chapter, by sentences.
    var chapterProgress: Double {
        guard let ref = currentRef, let start = chapterStarts[ref.chapter] else { return 0 }
        let end = chapterEnd(after: ref.chapter)
        return end > start ? Double(index - start) / Double(end - start) : 0
    }

    func chapterEnd(after chapter: Int) -> Int { chapterStarts.filter { $0.key > chapter }.map(\.value).min() ?? order.count }

    // MARK: - Book

    /// The reader's own saved position for a book, if any.
    func savedEntry(_ bookID: String, document: ReaderDocument? = nil) -> ReaderPositionStore.Entry? {
        saved = store.load(); savedLoaded = true
        let local = saved.books[bookID]
        guard let document, let shared = saved.books[document.syncIdentity] else { return local }
        return local.map { $0.position.updatedAt > shared.position.updatedAt ? $0 : shared } ?? shared
    }
    var lastBookID: String? { loadSaved(); return saved.lastBookID }

    func beginLoading() { close(); status = .loading }

    func fail(loading message: String) { status = .failed(message) }

    /// Index of each chapter's first spoken sentence in `order`.
    static func chapterStarts(_ order: [ReaderSentenceRef]) -> [Int: Int] {
        var starts: [Int: Int] = [:]
        for (i, ref) in order.enumerated() where starts[ref.chapter] == nil { starts[ref.chapter] = i }
        return starts
    }

    /// Opens a parsed book at `start` (or its first spoken sentence).
    @discardableResult
    func load(_ document: ReaderDocument, bookID: String, title: String, start: ReaderSentenceRef?) -> Bool {
        syncBookID = document.syncIdentity
        self.document = document
        self.bookID = bookID; bookTitle = title
        order = document.sentences
        chapterStarts = Self.chapterStarts(order)
        guard !order.isEmpty else { status = .failed("This book has no text to read aloud."); return false }
        index = start.flatMap { order.firstIndex(of: $0) } ?? 0
        loadSaved()
        saved.lastBookID = bookID
        status = .ready
        schedulePositionSave()
        Task { await LocalTelemetry.shared.gauge("reader.book.sentences", value: Double(order.count), unit: "count") }
        return true
    }

    func close() {
        stopPipeline()
        savePositionNow()
        voice.stop()
        playback.shutdown()
        document = nil; order = []; index = 0; bookID = nil; chapterStarts = [:]
        status = .idle
        pauses = []
    }

    // MARK: - Transport

    func togglePlay() { if status == .playing { pause(.user) } else { play() } }

    /// Starts or resumes reading; false (with `status` failed) if the voice can't start.
    @discardableResult
    func play() -> Bool {
        guard document != nil else { return false }
        pauses = []
        resumeTask?.cancel(); resumeTask = nil
        idleTeardown?.cancel(); idleTeardown = nil
        if status == .finished { seek(to: 0) }
        do { try voice.start() } catch {
            status = .failed(voiceUnavailableMessage)
            return false
        }
        status = .playing
        playStarted = .now
        starvedSince = nil
        failures = 0
        playback.setPaused(false)
        pump()
        Task { await LocalTelemetry.shared.event("reader.play") }
        return true
    }

    func pause(_ reason: PauseReason) {
        pauses.insert(reason)
        guard status == .playing else { return }
        status = .paused
        playback.setPaused(true)
        savePositionNow()
        if let ref = currentRef { onMove?(ref, .paused(reason)) }
        // Release the voice and audio device after a minute paused.
        idleTeardown?.cancel()
        idleTeardown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, status == .paused else { return }
            stopPipeline()
            voice.stop()
            playback.shutdown()
            onIdle?()
        }
    }

    /// Resumes after an automatic pause once nothing else holds it.
    func release(_ reason: PauseReason, after delay: Duration) {
        guard pauses.contains(reason) else { return }
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            pauses.remove(reason)
            if pauses.isEmpty, status == .paused { play() }
        }
    }

    func skipSentence(_ delta: Int) { seek(to: index + delta) }

    func skipParagraph(_ delta: Int) {
        guard let ref = currentRef else { return }
        if delta > 0 {
            seek(to: order[index...].firstIndex { ($0.chapter, $0.block) != (ref.chapter, ref.block) } ?? order.count - 1)
        } else {
            // Back: the start of this paragraph, or of the previous one when already at its start.
            let start = order[..<index].lastIndex { ($0.chapter, $0.block) != (ref.chapter, ref.block) }.map { $0 + 1 } ?? 0
            if start < index - 1 { seek(to: start); return }
            guard start > 0 else { seek(to: 0); return }
            let previous = order[start - 1]
            seek(to: order[..<start].lastIndex { ($0.chapter, $0.block) != (previous.chapter, previous.block) }.map { $0 + 1 } ?? 0)
        }
    }

    func skipChapter(_ delta: Int) {
        guard let ref = currentRef else { return }
        let starts = chapterStarts.values.sorted()
        if delta > 0 { seek(to: starts.first { $0 > index } ?? index) }
        else {
            let current = chapterStarts[ref.chapter] ?? 0
            seek(to: index - current > 3 ? current : (starts.last { $0 < current } ?? 0))
        }
    }

    /// About `seconds` of listening, estimated from characters at the current pace.
    func skipSeconds(_ seconds: Double) {
        let budget = abs(seconds) * charactersPerSecond
        var i = index, chars = 0.0
        while chars < budget {
            let next = i + (seconds > 0 ? 1 : -1)
            guard order.indices.contains(next), let document else { break }
            chars += Double(document.text(order[next]).count)
            i = next
        }
        seek(to: i)
    }

    func startChapter(_ chapter: Int) {
        guard let start = chapterStarts[chapter] else { return }
        seek(to: start)
        if status != .playing { play() }
    }

    func seek(to target: Int) {
        guard !order.isEmpty else { return }
        stopPipeline()
        index = min(max(0, target), order.count - 1)
        if status == .finished { status = .paused }
        if status == .playing { pump() }
        schedulePositionSave()
        onMove?(order[index], .seeked)
    }

    /// The output route changed and scheduled audio was lost: restart the current sentence.
    func routeChanged() {
        guard status == .playing || status == .paused else { return }
        let wasPlaying = status == .playing
        seek(to: index)
        if wasPlaying { pump() }
    }

    /// Voice, pace or pitch changed: applies from the next sentence not yet scheduled.
    func voiceSettingsChanged() {
        guard status == .playing || status == .paused else { return }
        voice.cancel(Array(requested.keys))
        requested = [:]; ready = [:]
        requestedThrough = scheduledThrough
        pump()
    }

    // MARK: - Pipeline

    private func stopPipeline() {
        generation &+= 1
        voice.cancel(Array(requested.keys))
        requested = [:]; ready = [:]
        starvedSince = nil
        requestedThrough = index - 1
        scheduledThrough = index - 1
        playback.flush(generation: generation)
    }

    /// Keep at least two sentences and about 20 seconds synthesized ahead, and
    /// the current and next sentence scheduled on the player.
    private func pump() {
        guard status == .playing, let document else { return }
        if requestedThrough < index - 1 { requestedThrough = index - 1 }
        if scheduledThrough < index - 1 { scheduledThrough = index - 1 }
        while scheduledThrough < index + 1, let samples = ready.removeValue(forKey: scheduledThrough + 1) {
            scheduledThrough += 1
            if let starved = starvedSince { stats.underrunSeconds += Date().timeIntervalSince(starved); starvedSince = nil }
            playback.schedule(samples, sentence: scheduledThrough, pauseAfter: pause(after: scheduledThrough), generation: generation)
            if let started = playStarted {
                playStarted = nil
                Task { await LocalTelemetry.shared.span("reader.first_audio", start: started) }
            }
        }
        func secondsAhead() -> Double {
            guard requestedThrough >= index else { return 0 }
            return Double((index...requestedThrough).reduce(0) { $0 + document.text(order[$1]).count }) / charactersPerSecond
        }
        while requestedThrough + 1 < order.count, requested.count + ready.count < 8,
              requestedThrough - index < 1 || secondsAhead() < 20 {
            let next = requestedThrough + 1
            let text = pronunciation.spoken(document.text(order[next]))
            guard let id = voice.request(text, rate: rate(), pitch: pitch()) else { break }
            requested[id] = next
            requestedThrough = next
        }
    }

    private func synthesized(_ id: UInt32, _ samples: [Float]?) {
        guard let sentence = requested.removeValue(forKey: id) else { return }
        if samples == nil {
            failures += 1
            if failures >= 3 { fail(voiceStoppedMessage); return }
        } else { failures = 0 }
        ready[sentence] = samples ?? []
        pump()
    }

    private func played(_ sentence: Int, generation: UInt64, seconds: Double) {
        guard generation == self.generation, sentence == index else { return }
        stats.sentences += 1
        stats.audioSeconds += seconds
        index += 1
        if index >= order.count {
            index = order.count - 1
            status = .finished
            savePositionNow()
            return
        }
        if scheduledThrough < index && ready[index] == nil {
            starvedSince = .now
            stats.underruns += 1
            Task { await LocalTelemetry.shared.event("reader.underrun") }
        }
        schedulePositionSave()
        pump()
        onMove?(order[index], .advanced)
    }

    /// Pause after a sentence: sentence 220 ms, paragraph 550 ms, before a
    /// heading 700 ms, after one 450 ms, chapter 1.4 s; shorter at a faster pace.
    private func pause(after sentence: Int) -> Double {
        guard let document, sentence + 1 < order.count else { return 0.4 }
        let a = order[sentence], b = order[sentence + 1]
        let seconds: Double
        if a.chapter != b.chapter { seconds = 1.4 }
        else if a.block == b.block { seconds = 0.22 }
        else if document.block(b).kind == .heading { seconds = 0.7 }
        else if document.block(a).kind == .heading { seconds = 0.45 }
        else { seconds = 0.55 }
        return seconds / max(0.7, rate())
    }

    private func voiceExited() {
        guard status == .playing else { return }
        failures += 1
        if failures >= 3 { fail(voiceStoppedMessage); return }
        // The chosen voice may have been removed: let the shell find voices
        // again, then carry on from the current sentence.
        onVoiceLost?()
        let token = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, status == .playing, generation == token else { return }
            seek(to: index)
            play()
        }
    }

    private func fail(_ message: String) {
        stopPipeline()
        status = .failed(message)
        savePositionNow()
        Task { await LocalTelemetry.shared.event("reader.failed", success: false) }
    }

    // MARK: - Positions

    private func loadSaved() {
        guard !savedLoaded else { return }
        saved = store.load()
        savedLoaded = true
    }

    private func schedulePositionSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.saveTask = nil
            self?.savePositionNow()
        }
    }

    func savePositionNow(synchronously: Bool = false) {
        saveTask?.cancel(); saveTask = nil
        guard let bookID, let document, let ref = currentRef else { return }
        loadSaved()
        saved.books[bookID] = .init(title: bookTitle, position: ReaderPosition(ref: ref, cfi: document.cfi(for: ref)?.string, updatedAt: .now))
        if let syncBookID { saved.books[syncBookID] = saved.books[bookID] }
        saved.lastBookID = bookID
        let snapshot = saved, store = store
        if synchronously { try? store.save(snapshot) }
        else { Task.detached(priority: .utility) { try? store.save(snapshot) } }
    }
}
