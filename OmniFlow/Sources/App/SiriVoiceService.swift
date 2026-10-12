import AVFoundation
import Foundation

struct SiriVoice: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let language: String

    var isVoice6: Bool { name == "en-US-G" && language == "en-US" }

    static func voice6(in voices: [SiriVoice]) -> SiriVoice? {
        let matching = voices.filter(\.isVoice6)
        return matching.first(where: { $0.id.contains(":fmvoice:") }) ?? matching.first
    }

    /// Apple's Siri neural voices; the helper never offers system or AVSpeech voices.
    var isSiri: Bool { id.contains(":fmvoice:") || id.contains(":natural:") }
    /// From the asset key `language:kind:gender:name:quality:version`.
    var gender: String? {
        let parts = id.split(separator: ":")
        return parts.count > 2 && ["male", "female", "neutral"].contains(String(parts[2])) ? String(parts[2]) : nil
    }

    var displayName: String {
        let region = Locale.current.localizedString(forRegionCode: String(language.split(separator: "-").last ?? "")) ?? language
        let base: String
        if isVoice6 { base = "Siri Voice 6" }
        else if name.hasPrefix(language + "-") { base = "Siri Voice \(name.dropFirst(language.count + 1))" }
        else { base = name.prefix(1).uppercased() + name.dropFirst() }
        let detail = [gender?.capitalized, region, id.contains(":natural:") ? "natural" : nil].compactMap { $0 }.joined(separator: " · ")
        return "\(base) (\(detail))"
    }

    static let selectionKey = "omniflow.siriVoice.id"

    /// The saved choice if it is still installed, otherwise Siri Voice 6, otherwise the first voice.
    static func preferred(in voices: [SiriVoice], selectedID: String? = UserDefaults.standard.string(forKey: selectionKey)) -> SiriVoice? {
        if let selectedID, let saved = voices.first(where: { $0.id == selectedID }) { return saved }
        return voice6(in: voices) ?? voices.first
    }

    /// The saved choice when it is not among the installed voices (Apple removed
    /// or is re-downloading it), rebuilt from its asset key so it can be named.
    /// Nil when nothing is saved, when it is installed, or when no voices were
    /// found at all (a failed lookup is not evidence the voice is gone).
    static func missingSelection(in voices: [SiriVoice], selectedID: String? = UserDefaults.standard.string(forKey: selectionKey)) -> SiriVoice? {
        guard let selectedID, !voices.isEmpty, !voices.contains(where: { $0.id == selectedID }) else { return nil }
        let parts = selectedID.split(separator: ":").map(String.init)
        return SiriVoice(id: selectedID, name: parts.count > 3 ? parts[3] : selectedID, language: parts.first ?? "")
    }

    /// Siri voices only, the user's language first, then by name.
    static func sorted(_ voices: [SiriVoice], preferredLanguage: String = Locale.preferredLanguages.first ?? "en-US") -> [SiriVoice] {
        voices.filter(\.isSiri).sorted {
            let a = $0.language == preferredLanguage, b = $1.language == preferredLanguage
            if a != b { return a }
            return ($0.language, $0.displayName) < ($1.language, $1.displayName)
        }
    }
}

enum SiriVoiceError: Error { case unavailable, failed, timedOut, noPremiumVoice }

/// The app never links the private framework. Crashes/API changes are contained in a helper process.
@MainActor
enum SiriVoiceService {
    static var helperURL: URL? {
        #if APPSTORE
        return nil
        #else
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NotchLeeSpeech")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        #endif
    }

    static func voice6() async throws -> SiriVoice? {
        guard let helperURL else { throw SiriVoiceError.unavailable }
        let data = try await SpeechProcess().run(helperURL, arguments: ["voices"], timeout: 10)
        return SiriVoice.voice6(in: try JSONDecoder().decode([SiriVoice].self, from: data))
    }

    /// Every installed Siri voice, for the response-voice picker.
    static func voices() async throws -> [SiriVoice] {
        guard let helperURL else { throw SiriVoiceError.unavailable }
        let data = try await SpeechProcess().run(helperURL, arguments: ["voices"], timeout: 10)
        return SiriVoice.sorted(try JSONDecoder().decode([SiriVoice].self, from: data))
    }
}

@MainActor
final class SpeechProcess {
    private var process: Process?
    private var result: CheckedContinuation<Data, Error>?
    private var deadline: Task<Void, Never>?

    func run(_ executable: URL, arguments: [String], input: Data? = nil, timeout: Double) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let child = Process()
                let output = Pipe()
                let stdin = Pipe()
                child.executableURL = executable
                child.arguments = arguments
                child.standardOutput = output
                child.standardError = FileHandle.nullDevice
                child.standardInput = stdin
                result = continuation
                process = child
                do {
                    try child.run()
                    try output.fileHandleForWriting.close()
                    // Drain while the helper runs: waiting for termination first
                    // deadlocks once the voice inventory fills the stdout pipe.
                    Task.detached(priority: .utility) { [weak self] in
                        let handle = output.fileHandleForReading
                        defer { try? handle.close() }
                        var data = Data()
                        var oversized = false
                        do {
                            while let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
                                if chunk.count <= 1_048_576 - data.count { data.append(chunk) }
                                else { oversized = true }
                            }
                            child.waitUntilExit()
                            await self?.finish(child.terminationStatus == 0 && !oversized
                                ? .success(data) : .failure(SiriVoiceError.failed))
                        } catch { await self?.finish(.failure(error)) }
                    }
                    if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
                    try stdin.fileHandleForWriting.close()
                    deadline = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(timeout))
                        guard !Task.isCancelled else { return }
                        self?.finish(.failure(SiriVoiceError.timedOut))
                    }
                } catch { finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ outcome: Result<Data, Error>) {
        guard let result else { return }
        self.result = nil
        deadline?.cancel(); deadline = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        result.resume(with: outcome)
    }
}

/// Speaks one reply as a queue of sentences that may arrive while the reply is
/// still being generated. `endReply` marks the last sentence; `onFinished`
/// follows once all queued audio has played.
#if !APPSTORE
/// Frames from the long-lived helper: 1-byte kind, little-endian UInt32 request
/// id and payload length, then the payload. Read on the pipe's handler thread.
final class SiriSpeechFrameReader: @unchecked Sendable {
    struct Frame { let kind: UInt8; let id: UInt32; let payload: Data }
    private var buffer = Data()

    /// Returns nil when the stream is malformed.
    func consume(_ data: Data) -> [Frame]? {
        buffer.append(data)
        var frames: [Frame] = []
        while buffer.count >= 9 {
            let header = buffer.prefix(9)
            let kind = header[header.startIndex]
            let id = header.dropFirst().prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            let length = Int(header.dropFirst(5).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
            guard [UInt8(ascii: "R"), UInt8(ascii: "A"), UInt8(ascii: "D"), UInt8(ascii: "E")].contains(kind),
                  length <= 24_000_000 else { return nil }
            guard buffer.count >= 9 + length else { break }
            frames.append(Frame(kind: kind, id: id, payload: Data(buffer.dropFirst(9).prefix(length))))
            buffer = Data(buffer.dropFirst(9 + length))
        }
        return frames
    }
}

/// Which helper requests still belong to the current reply. Audio frames are
/// routed on the pipe thread without a main-actor hop.
final class SiriSpeechRouting: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted: [UInt32: UInt64] = [:]
    private var lastProgress = Date()

    func accept(_ id: UInt32, generation: UInt64) { lock.withLock { accepted[id] = generation; lastProgress = .now } }
    func generation(for id: UInt32) -> UInt64? { lock.withLock { lastProgress = .now; return accepted[id] } }
    func remove(_ id: UInt32) { lock.withLock { _ = accepted.removeValue(forKey: id) } }
    func clear() { lock.withLock { accepted = [:] } }
    var idleSeconds: TimeInterval { lock.withLock { Date().timeIntervalSince(lastProgress) } }
}

/// The chosen Siri voice through one persistent helper per app session. The helper keeps
/// the daemon connection and voice warm and streams each sentence's audio as it
/// is synthesized; no reply audio is written to disk.
@MainActor
final class SiriReplySpeaker: ReplySpeaker {
    var onFirstAudio: (@MainActor () -> Void)?
    var onFinished: (@MainActor () -> Void)?
    var onFailure: (@MainActor (Error) -> Void)?
    /// Set once discovery finishes; sentences wait for an in-flight discovery.
    var voice: SiriVoice?
    var discovery: Task<SiriVoice?, Never>?

    private let playback = SpeechPlayback()
    private let routing = SiriSpeechRouting()
    private var process: Process?
    private var input: FileHandle?
    private var servedVoice: String?
    private var nextID: UInt32 = 0
    private var generation: UInt64 = 0
    private var outstanding = Set<UInt32>()
    private var waiting: [(String, Double, Double)] = []
    private var waitingForVoice: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var ended = false
    private var active = false

    func prepare() {
        guard let voice, (try? ensureHelper(voice)) != nil else { return }
        send(["prewarm": true])
    }

    func beginReply() {
        stop()
        active = true
        let token = generation
        playback.reset(generation: token) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, active, generation == token else { return }
                onFirstAudio?()
            }
        }
    }

    func enqueue(_ sentence: String, rate: Double, pitch: Double) {
        guard active else { return }
        guard let voice else {
            waiting.append((sentence, rate, pitch))
            waitForVoice()
            return
        }
        do {
            try ensureHelper(voice)
            nextID = nextID == UInt32.max ? 1 : nextID + 1
            let id = nextID
            routing.accept(id, generation: generation)
            outstanding.insert(id)
            send(["id": id, "text": String(sentence.prefix(3000)), "rate": min(1.3, max(0.7, rate)), "pitch": min(1.2, max(0.8, pitch))])
            startWatchdog()
        } catch { fail(error) }
    }

    func endReply() {
        guard active else { return }
        ended = true
        completeIfDrained()
    }

    func stop() {
        active = false
        for id in outstanding { send(["cancel": id]) }
        generation &+= 1
        routing.clear()
        playback.reset(generation: generation, onFirstAudio: nil)
        outstanding = []
        waiting = []
        waitingForVoice?.cancel(); waitingForVoice = nil
        watchdog?.cancel(); watchdog = nil
        ended = false
    }

    func shutdown() {
        stop()
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; servedVoice = nil
        playback.shutdown()
    }

    private func waitForVoice() {
        guard waitingForVoice == nil else { return }
        let token = generation
        waitingForVoice = Task { [weak self] in
            let found = await self?.discovery?.value
            guard let self, !Task.isCancelled, generation == token else { return }
            waitingForVoice = nil
            guard let found else { fail(SiriVoiceError.unavailable); return }
            voice = found
            let pending = waiting
            waiting = []
            for (sentence, rate, pitch) in pending { enqueue(sentence, rate: rate, pitch: pitch) }
            if ended { completeIfDrained() }
        }
    }

    private func ensureHelper(_ voice: SiriVoice) throws {
        if let process, process.isRunning, servedVoice == voice.id { return }
        guard voice.isSiri, let helperURL = SiriVoiceService.helperURL else { throw SiriVoiceError.unavailable }
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = helperURL
        child.arguments = ["serve", voice.id]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = SiriSpeechFrameReader()
        let routing = routing, playback = playback
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let frames = reader.consume(data) else {
                handle.readabilityHandler = nil
                Task { @MainActor [weak self] in self?.helperExited(child) }
                return
            }
            for frame in frames {
                switch frame.kind {
                case UInt8(ascii: "A"):
                    if let generation = routing.generation(for: frame.id) { playback.schedule(frame.payload, generation: generation) }
                case UInt8(ascii: "D"), UInt8(ascii: "E"):
                    let failed = frame.kind == UInt8(ascii: "E")
                    Task { @MainActor [weak self] in self?.requestEnded(frame.id, failed: failed) }
                default: break
                }
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor [weak self] in self?.helperExited(child) }
        }
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        servedVoice = voice.id
    }

    private func send(_ request: [String: any Sendable]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        do { try input.write(contentsOf: data + Data([0x0A])) }
        catch { if active { fail(SiriVoiceError.failed) } }
    }

    private func requestEnded(_ id: UInt32, failed: Bool) {
        routing.remove(id)
        guard outstanding.remove(id) != nil else { return }
        if failed { fail(SiriVoiceError.failed) } else { completeIfDrained() }
    }

    private func completeIfDrained() {
        guard active, ended, outstanding.isEmpty, waiting.isEmpty, waitingForVoice == nil else { return }
        watchdog?.cancel(); watchdog = nil
        let token = generation
        playback.finishWhenDrained(generation: token) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, active, generation == token else { return }
                active = false
                onFinished?()
            }
        }
    }

    private func helperExited(_ child: Process) {
        guard child === process else { return }
        if child.isRunning { child.terminate() }
        process = nil; input = nil; servedVoice = nil
        // The next sentence respawns the helper; only the current reply fails.
        if active && !outstanding.isEmpty { fail(SiriVoiceError.failed) }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let token = generation
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, generation == token else { return }
                // Re-armed by the next sentence once everything queued so far is done.
                guard !outstanding.isEmpty else { watchdog = nil; return }
                if routing.idleSeconds > 20 { watchdog = nil; fail(SiriVoiceError.timedOut); return }
            }
        }
    }

    private func fail(_ error: Error) {
        guard active else { return }
        stop()
        onFailure?(error)
    }
}
#else
/// App Store build: installed Premium AVSpeech voices, or the user's Personal
/// Voice when chosen, with the same sentence queue. No Enhanced, compact or
/// default fallback; without a usable voice the reply stays written.
@MainActor
final class SystemReplySpeaker: NSObject, ReplySpeaker, AVSpeechSynthesizerDelegate {
    var onFirstAudio: (@MainActor () -> Void)?
    var onFinished: (@MainActor () -> Void)?
    var onFailure: (@MainActor (Error) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var queued = Set<ObjectIdentifier>()
    private var startedAudio = false
    private var ended = false
    private var active = false
    /// Chosen once per reply from its first sentence's language.
    private var replyVoice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare() {}

    func beginReply() {
        stop()
        active = true
    }

    func enqueue(_ sentence: String, rate: Double, pitch: Double) {
        guard active else { return }
        if replyVoice == nil {
            let selected = PremiumSpeechVoices.preferred(in: PremiumSpeechVoices.installed(),
                replyLanguage: PremiumSpeechVoices.language(of: sentence),
                selectedID: UserDefaults.standard.string(forKey: PremiumSpeechVoices.selectionKey))
            replyVoice = selected.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
        }
        guard let replyVoice else {
            stop()
            onFailure?(SiriVoiceError.noPremiumVoice)
            return
        }
        let utterance = AVSpeechUtterance(string: String(sentence.prefix(3000)))
        utterance.voice = replyVoice
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(min(1.3, max(0.7, rate))))
        utterance.pitchMultiplier = Float(min(1.2, max(0.8, pitch)))
        queued.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    func endReply() {
        guard active else { return }
        ended = true
        if queued.isEmpty { complete() }
    }

    func stop() {
        queued = []
        startedAudio = false
        ended = false
        active = false
        replyVoice = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    func shutdown() { stop() }

    // AVSpeechSynthesizer may call back off the main thread; hop explicitly.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, active, queued.contains(id), !startedAudio else { return }
            startedAudio = true
            onFirstAudio?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, active, queued.remove(id) != nil else { return }
            if ended && queued.isEmpty { complete() }
        }
    }

    private func complete() {
        active = false
        onFinished?()
    }
}
#endif
