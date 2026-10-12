import AVFoundation
import Speech

struct FlowError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// AVAudioEngine startup and voice-processing configuration can block. Keep the
/// engine on its own actor so they cannot starve the UI or the main-run-loop Fn tap.
///
/// Enabling Apple voice processing takes 1.2-1.7 s (measured); starting an engine
/// that already has it takes ~50 ms. So the configured engine is kept, stopped,
/// between dictations: a stopped engine does not hold the microphone. It is rebuilt
/// when the input device, the noise setting or the audio route changes.
actor DictationAudioCapture {
    struct Started: Sendable {
        let engineID: ObjectIdentifier
        let processingStatus: String
        let microphoneName: String
        let reusedEngine: Bool
    }
    private struct Configuration: Equatable {
        let deviceID: AudioDeviceID?
        let defaultInput: AudioDeviceID?
        let voiceProcessing: Bool
    }
    private var engine: AVAudioEngine?
    private var directCapture: VoiceMicrophoneCapture?
    private var configuration: Configuration?
    private var running = false
    private var routeObserver: NSObjectProtocol?
    private var stream: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?

    /// Builds and configures the engine without starting it (no microphone use).
    func warm(reduceBackgroundNoise: Bool, device: DictationInputDevice.Plan) {
        guard !running else { return }
        guard reduceBackgroundNoise && device.allowsVoiceProcessing else { discard(); return }
        _ = try? configured(reduceBackgroundNoise: reduceBackgroundNoise, device: device)
    }

    private func configured(reduceBackgroundNoise: Bool, device: DictationInputDevice.Plan) throws -> (AVAudioEngine, Bool, Bool) {
        // A chosen non-default microphone is bound directly; voice processing would
        // silently switch back to the default input, so it is skipped for that device.
        let voiceProcessing = reduceBackgroundNoise && device.allowsVoiceProcessing
        let wanted = Configuration(deviceID: device.deviceID, defaultInput: VoiceMicrophone.defaultInputID(), voiceProcessing: voiceProcessing)
        if let engine, configuration == wanted { return (engine, voiceProcessing, true) }
        discard()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let id = device.deviceID, !DictationInputDevice.bind(input, to: id) {
            throw FlowError("OmniFlow couldn't open \(device.name). Choose another microphone in Settings.")
        }
        if voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) }
            catch { throw FlowError("Apple voice processing is unavailable for this microphone. Try another microphone or turn off Reduce background noise in Dictation settings.") }
            guard input.isVoiceProcessingEnabled else { throw FlowError("Voice processing did not start. Check Dictation settings before trying again.") }
        }
        engine.prepare()
        self.engine = engine; configuration = wanted
        let identity = ObjectIdentifier(engine)
        // A route or format change invalidates the configured engine.
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { await self?.routeChanged(identity) }
        }
        return (engine, voiceProcessing, false)
    }

    private func routeChanged(_ identity: ObjectIdentifier) {
        guard let engine, ObjectIdentifier(engine) == identity else { return }
        configuration = nil
        if running {
            // A route can stop delivering callbacks altogether. End the stream
            // immediately instead of waiting for a mismatched buffer or watchdog.
            stream?.finish(throwing: VoiceInputError.inputChanged)
        }
        discard()
    }

    private func discard() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        if running { engine?.stop(); engine?.inputNode.removeTap(onBus: 0) }
        engine = nil; configuration = nil; running = false; stream = nil
    }

    func start(format: AVAudioFormat, reduceBackgroundNoise: Bool, device: DictationInputDevice.Plan,
               continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
               onLevel: @escaping @Sendable (Double) -> Void,
               onFirstBuffer: @escaping @Sendable (Date) -> Void,
               onSpectrum: (@Sendable (_ bands: [Float], _ peaks: [Float]) -> Void)? = nil) async throws -> Started {
        try Task.checkCancellation()
        guard !running else { throw FlowError("A recording is already active.") }
        let inputHealth = VoiceMicrophone.health(uid: device.uid)
        if let error = inputHealth.error { throw error }
        if !reduceBackgroundNoise || !device.allowsVoiceProcessing {
            // Standard input does not need an output audio device. AVCapture
            // negotiates Bluetooth/USB PCM independently and rebuilds conversion
            // from each buffer's actual format when the route changes.
            discard()
            let uid = device.uid
            let microphone = uid.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: uid)
            guard let microphone else { throw VoiceInputError.selectedInputUnavailable }
            let capture = VoiceMicrophoneCapture(device: microphone, destination: format, continuation: continuation,
                onLevel: onLevel, onFormat: { _ in }, onFirstBuffer: onFirstBuffer, onSpectrum: onSpectrum)
            directCapture = capture; running = true
            do {
                try await capture.start()
                try Task.checkCancellation()
                return Started(engineID: ObjectIdentifier(capture), processingStatus: inputHealth.description + " · Standard microphone input",
                               microphoneName: inputHealth.name, reusedEngine: false)
            } catch {
                await capture.stop()
                directCapture = nil; running = false
                throw error
            }
        }
        let (engine, voiceProcessing, reused) = try configured(reduceBackgroundNoise: reduceBackgroundNoise, device: device)
        let input = engine.inputNode
        var installedTap = false, started = false
        defer {
            if !started {
                engine.stop()
                if installedTap { input.removeTap(onBus: 0) }
                running = false
                discard()
            }
        }
        try Task.checkCancellation()
        // Bluetooth may switch from high-rate stereo playback to mono headset
        // input only when I/O starts. A pre-start tap pins the old format and
        // makes that transition fail with kAudioUnitErr_FormatNotSupported.
        try engine.start()
        try Task.checkCancellation()
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate.isFinite, source.sampleRate > 0, source.channelCount > 0 else {
            throw FlowError("No microphone is available. Connect one and try again.")
        }
        let pipe = try VoiceAudioBridge(source: source, destination: format, continuation: continuation, onLevel: onLevel)
        let spectrum = onSpectrum.map { DictationSpectrumTap(sampleRate: source.sampleRate, deliver: $0) }
        // Do not force a cached output format onto hardware that may have just
        // changed routes. The error-returning API also closes the race between
        // reading the format and installing the tap; Swift cannot catch NSException.
        try input.__installTap(onBus: 0, bufferSize: 1024, format: nil, error: (),
            block: DictationSpectrumTap.combined(pipe.tap, spectrum, firstBuffer: FirstBufferSignal(onFirstBuffer)))
        installedTap = true
        running = true; stream = continuation
        try Task.checkCancellation()
        started = true
        return Started(engineID: ObjectIdentifier(engine), processingStatus: inputHealth.description + " · " + (voiceProcessing
            ? "Apple voice processing active"
            : "Standard microphone input") + (device.note.map { " · " + $0 } ?? ""), microphoneName: inputHealth.name, reusedEngine: reused)
    }

    /// Stops capture and releases the microphone; the configured engine stays for the next dictation.
    func stop() async {
        if let capture = directCapture {
            await capture.stop()
            directCapture = nil; running = false; stream = nil
            return
        }
        guard let engine, running else { return }
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        running = false; stream = nil
    }
}

/// Reports the first captured buffer once, with the time it arrived on the audio thread.
final class FirstBufferSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let report: @Sendable (Date) -> Void
    init(_ report: @escaping @Sendable (Date) -> Void) { self.report = report }
    func fire() {
        let first = lock.withLock { () -> Bool in defer { fired = true }; return !fired }
        if first { report(Date()) }
    }
}

/// Runs the pill's voice spectrum on the tap's serial audio callbacks (never the
/// main thread) and hands at most ~60 snapshots per second onward. Created on
/// the capture actor, outside MainActor; its tap closure is explicitly Sendable.
final class DictationSpectrumTap: @unchecked Sendable {
    private let spectrum: VoiceSpectrum
    private let deliver: @Sendable ([Float], [Float]) -> Void
    private var lastDelivery: UInt64 = 0
    private static let interval: UInt64 = 16_000_000

    init(sampleRate: Double, deliver: @escaping @Sendable ([Float], [Float]) -> Void) {
        spectrum = VoiceSpectrum(sampleRate: sampleRate)
        self.deliver = deliver
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        assert(!Thread.isMainThread, "The spectrum must run on the audio callback, not the main thread")
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
        spectrum.process(channel, count: Int(buffer.frameLength))
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastDelivery >= Self.interval else { return }
        lastDelivery = now
        let snapshot = spectrum.snapshot()
        deliver(snapshot.bands, snapshot.peaks)
    }

    /// Built outside any actor so the audio callback never inherits isolation.
    static func combined(_ bridge: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
                         _ spectrum: DictationSpectrumTap?, firstBuffer: FirstBufferSignal? = nil) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, time in
            firstBuffer?.fire()
            bridge(buffer, time)
            spectrum?.process(buffer)
        }
    }
}

/// Start-up milestones of one dictation, for the start-latency timeline.
enum DictationStartStage: Sendable {
    /// The engine is running; `reused` when the warm engine was used.
    case captureRunning(reused: Bool)
    case firstBuffer
    case analyzerReady
}

/// Mac adapter: owns the microphone (chosen-device binding, voice processing, level and
/// spectrum taps) and feeds the portable `DictationRecognizer`. The microphone opens
/// first and buffers; the analyzer prepares in parallel and reads from the beginning.
@MainActor
final class SpeechService {
    private let audio = DictationAudioCapture()
    private var capturing = false
    private var captureTask: Task<DictationAudioCapture.Started, Error>?
    private var engineID: ObjectIdentifier?
    private var cleanupTask: Task<Void, Never>?
    private let recognizer = DictationRecognizer()
    private var generation = UUID()
    var locale: Locale { recognizer.locale }
    var isPrepared: Bool { recognizer.isPrepared }
    var text: String { recognizer.text }
    private(set) var voiceProcessingStatus = "Not recording"
    private(set) var microphoneName = "the system microphone"
    private(set) var lastAudioAt: Date?
    private(set) var heardSound = false

    static func contextualStrings(vocabulary: String) -> [String] { DictationRecognizer.contextualStrings(vocabulary: vocabulary) }

    func prepare(locale: Locale, download: Bool) async throws {
        try await recognizer.prepare(locale: locale, download: download)
    }

    /// Configure the engine (and voice processing, the slow part) ahead of the next
    /// dictation, without opening the microphone.
    func prewarm(reduceBackgroundNoise: Bool) {
        guard !capturing, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let audio = audio, plan = DictationInputDevice.plan()
        Task.detached(priority: .userInitiated) { await audio.warm(reduceBackgroundNoise: reduceBackgroundNoise, device: plan) }
    }

    func start(reduceBackgroundNoise: Bool = true, vocabulary: String = "", onText: @escaping @MainActor (String) -> Void, onLevel: @escaping @MainActor (Double) -> Void,
               onSpectrum: (@MainActor (_ bands: [Float], _ peaks: [Float]) -> Void)? = nil,
               onStage: (@MainActor (DictationStartStage, Date) -> Void)? = nil,
               onError: @escaping @MainActor (String) -> Void) async throws {
        guard isPrepared else { throw FlowError("Prepare a speech language in Setup first.") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw FlowError("Allow microphone access in Setup first.")
        }
        guard !capturing else { throw FlowError("A recording is already active.") }
        // Reserve startup before the first suspension so two callers cannot
        // prepare competing analyzer streams. Cancellation releases this reservation.
        capturing = true
        let token = UUID(); generation = token
        lastAudioAt = nil; heardSound = false
        var started = false
        // A failed or cancelled startup must release the microphone and analyzer.
        // A stale startup must never cancel a newer session.
        defer { if !started && generation == token { cancel() } }
        await cleanupTask?.value
        await VoiceCaptureRelease.shared.wait()
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        let input = try await recognizer.makeInput()
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        var deliverSpectrum: (@Sendable ([Float], [Float]) -> Void)?
        if let onSpectrum {
            deliverSpectrum = { [weak self] bands, peaks in
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    onSpectrum(bands, peaks)
                }
            }
        }
        let firstBuffer: @Sendable (Date) -> Void = { [weak self] at in
            Task { @MainActor [weak self] in
                guard let self, generation == token else { return }
                onStage?(.firstBuffer, at)
            }
        }
        let level: @Sendable (Double) -> Void = { [weak self] value in Task { @MainActor [weak self] in
            guard let self, generation == token else { return }
            lastAudioAt = .now
            if value > 0.05 { heardSound = true }
            onLevel(value)
        } }
        // Microphone first, on the capture actor; the analyzer prepares meanwhile.
        capturing = true
        let audio = audio, plan = DictationInputDevice.plan()
        let capture = Task<DictationAudioCapture.Started, Error>.detached(priority: .userInitiated) {
            try await audio.start(format: input.format, reduceBackgroundNoise: reduceBackgroundNoise, device: plan,
                                  continuation: input.continuation, onLevel: level, onFirstBuffer: firstBuffer, onSpectrum: deliverSpectrum)
        }
        captureTask = capture
        do {
            try await recognizer.startAnalyzer(vocabulary: vocabulary, onText: onText, onError: onError)
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            onStage?(.analyzerReady, .now)
        } catch {
            capture.cancel(); _ = try? await capture.value
            throw error
        }
        let ready = try await capture.value
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        engineID = ready.engineID; voiceProcessingStatus = ready.processingStatus
        microphoneName = ready.microphoneName
        onStage?(.captureRunning(reused: ready.reusedEngine), .now)
        started = true
    }

    func finish() async throws -> String {
        let token = generation
        if capturing { await audio.stop() }
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        capturing = false; engineID = nil; captureTask = nil
        return try await recognizer.finish()
    }
    func cancel() {
        generation = UUID()
        let wasCapturing = capturing, pendingCleanup = cleanupTask, audio = audio, pendingCapture = captureTask
        capturing = false; engineID = nil; captureTask = nil
        pendingCapture?.cancel()
        let releaseAnalyzer = recognizer.cancel()
        let cleanup = Task {
            await pendingCleanup?.value
            // A capture still starting must finish (or fail) before it is stopped.
            _ = try? await pendingCapture?.value
            if wasCapturing { await audio.stop() }
            await releaseAnalyzer()
        }
        cleanupTask = cleanup
        VoiceCaptureRelease.shared.enqueue { await cleanup.value }
    }
    func ownsEngine(_ identity: ObjectIdentifier?) -> Bool {
        guard let identity else { return false }
        return engineID == identity
    }
    func waitForCleanup() async { await cleanupTask?.value }
}
