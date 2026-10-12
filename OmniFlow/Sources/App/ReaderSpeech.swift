import Foundation

#if !APPSTORE
/// The reader's own long-lived Siri speech helper (`NotchLeeSpeech serve`).
/// It is separate from the assistant's so a spoken reply never waits behind
/// the reader's look-ahead, and a reader failure never fails a reply. Each
/// sentence's audio is collected whole and handed over once synthesis is done.
@MainActor
final class ReaderSpeech: ReaderVoiceSource {
    /// (request id, 48 kHz mono Float32 samples or nil on failure)
    var onSentence: ((UInt32, [Float]?) -> Void)?
    /// The Siri voice `start()` uses; set by the shell from the voice settings.
    var voice: SiriVoice?
    var onExit: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private(set) var voiceID: String?
    private var nextID: UInt32 = 0
    private let collector = Collector()

    var isRunning: Bool { process?.isRunning == true }
    private let helper: URL?

    init(helper: URL? = SiriVoiceService.helperURL) { self.helper = helper }

    func start() throws {
        guard let voice else { throw SiriVoiceError.unavailable }
        try start(voice: voice)
    }

    func start(voice: SiriVoice) throws {
        if isRunning, voiceID == voice.id { return }
        stop()
        guard let helper else { throw SiriVoiceError.unavailable }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = helper
        child.arguments = ["serve", voice.id]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdout.fileHandleForReading.readabilityHandler = Self.pipeReader(owner: self, child: child, collector: collector)
        child.terminationHandler = Self.terminationHandler(owner: self)
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        voiceID = voice.id
        send(["prewarm": true])
    }

    /// Queues one sentence; returns its request id.
    func request(_ text: String, rate: Double, pitch: Double) -> UInt32? {
        guard isRunning else { return nil }
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        let id = nextID
        collector.begin(id)
        send(["id": id, "text": String(text.prefix(3000)), "rate": min(1.3, max(0.7, rate)), "pitch": min(1.2, max(0.8, pitch))])
        return id
    }

    // The pipe and termination handlers run on Foundation's threads. They are
    // built outside the main actor and hop to it explicitly (a closure formed
    // in a main-actor method would inherit its isolation and trap off main).

    /// Reads the helper's frames on the pipe's thread; results go to the main actor.
    nonisolated static func pipeReader(owner: ReaderSpeech, child: Process, collector: Collector) -> @Sendable (FileHandle) -> Void {
        let reader = SiriSpeechFrameReader()
        return { [weak owner] handle in
            let data = handle.availableData
            guard !data.isEmpty, let frames = reader.consume(data) else {
                handle.readabilityHandler = nil
                Task { @MainActor [weak owner] in owner?.exited(child) }
                return
            }
            for frame in frames {
                switch frame.kind {
                case UInt8(ascii: "A"): collector.append(frame.id, frame.payload)
                case UInt8(ascii: "D"), UInt8(ascii: "E"):
                    let pcm = collector.finish(frame.id)
                    let result = frame.kind == UInt8(ascii: "D") ? pcm.map(Self.samples) : nil
                    Task { @MainActor [weak owner] in owner?.onSentence?(frame.id, result) }
                default: break
                }
            }
        }
    }

    nonisolated static func terminationHandler(owner: ReaderSpeech) -> @Sendable (Process) -> Void {
        { [weak owner] child in Task { @MainActor [weak owner] in owner?.exited(child) } }
    }

    /// The helper's 48 kHz mono Int16 PCM as Float32.
    nonisolated static func samples(_ pcm: Data) -> [Float] {
        pcm.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
    }

    func cancel(_ ids: [UInt32]) {
        for id in ids { collector.discard(id); send(["cancel": id]) }
    }

    func stop() {
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; voiceID = nil
        collector.reset()
    }

    private func send(_ request: [String: any Sendable]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        try? input.write(contentsOf: data + Data([0x0A]))
    }

    private func exited(_ child: Process) {
        guard child === process else { return }
        process = nil; input = nil; voiceID = nil
        collector.reset()
        onExit?()
    }

    /// Per-request audio, filled on the pipe thread.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var audio: [UInt32: Data] = [:]
        func begin(_ id: UInt32) { lock.withLock { audio[id] = Data() } }
        func append(_ id: UInt32, _ chunk: Data) {
            lock.withLock {
                guard let count = audio[id]?.count else { return }
                guard chunk.count <= 24_000_000 - count else {
                    // An oversized sentence must fail as a whole, never play a
                    // truncated prefix or resume collecting its tail.
                    audio.removeValue(forKey: id)
                    return
                }
                // Mutate through Dictionary's accessor to avoid copying the
                // entire accumulated PCM for every incoming frame.
                audio[id]!.append(chunk)
            }
        }
        func finish(_ id: UInt32) -> Data? { lock.withLock { audio.removeValue(forKey: id) } }
        func discard(_ id: UInt32) { lock.withLock { _ = audio.removeValue(forKey: id) } }
        func reset() { lock.withLock { audio.removeAll() } }
    }
}
#endif
