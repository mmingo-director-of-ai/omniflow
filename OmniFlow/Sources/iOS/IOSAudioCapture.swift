import AVFoundation
import Speech

/// The iOS microphone. One AVAudioEngine runs while anything needs it: a
/// dictation, or a keyboard session that keeps the microphone open so the app
/// stays alive in the background. Audio reaches a recognizer only while a
/// dictation is attached; otherwise buffers are dropped unread.
final class IOSMicrophone: @unchecked Sendable {
    static let shared = IOSMicrophone()

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false
    private var sink: Sink?
    /// Voice bands for the live visualizer; touched only on the audio thread and under `lock`.
    private var spectrum: VoiceSpectrum?
    private var latestLevel: Float = 0

    private struct Sink {
        let format: AVAudioFormat
        let converter: AVAudioConverter
        let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
        let onLevel: @Sendable (Float) -> Void
    }

    var isRunning: Bool { lock.withLock { running } }
    /// Set while a keyboard session holds the microphone open between dictations.
    @MainActor var heldForKeyboard = false

    /// Closes the microphone unless a keyboard session is holding it.
    @MainActor func releaseIfUnheld() {
        detach()
        if !heldForKeyboard { close() }
    }

    /// Opens the microphone. The audio session must already be active.
    func open() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            throw IOSCaptureError("No microphone input is available.")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: native) { @Sendable [weak self] buffer, _ in
            self?.deliver(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw IOSCaptureError("The microphone couldn't start: \(error.localizedDescription)")
        }
        lock.withLock { running = true }
    }

    func close() {
        guard lock.withLock({ let was = running; running = false; sink = nil; return was }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Starts sending converted audio to a recognizer.
    func attach(format: AVAudioFormat, continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
                onLevel: @escaping @Sendable (Float) -> Void) throws {
        let native = engine.inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: native, to: format) else {
            throw IOSCaptureError("The microphone's audio format isn't supported.")
        }
        lock.withLock { sink = Sink(format: format, converter: converter, continuation: continuation, onLevel: onLevel) }
    }

    func detach() { lock.withLock { sink = nil; latestLevel = 0; spectrum?.reset() } }

    #if DEBUG
    /// Synthetic voice for DemoDictationEngine.
    var demoActive = false
    #endif

    /// The current voice bands (0...1, 17 bands) and level, for drawing.
    func snapshot() -> (bands: [Float], peaks: [Float], level: Float) {
        #if DEBUG
        if demoActive {
            let t = Date.now.timeIntervalSinceReferenceDate
            let syllable = Float(max(0, sin(t * 9) * 0.5 + sin(t * 3.1) * 0.5))
            let bands = (0..<17).map { band -> Float in
                let formant = exp(-pow((Float(band) - 5 - 3 * Float(sin(t * 2.3))) / 3.2, 2))
                return min(1, syllable * (0.25 + 0.75 * formant))
            }
            return (bands, bands, syllable)
        }
        #endif
        return lock.withLock {
            guard let spectrum, sink != nil else { return ([], [], 0) }
            let shape = spectrum.snapshot()
            return (shape.bands, shape.peaks, latestLevel)
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let sink = lock.withLock({ sink }) else { return }
        let level = Self.level(of: buffer)
        if let samples = buffer.floatChannelData?[0] {
            lock.withLock {
                if spectrum?.sampleRate != buffer.format.sampleRate { spectrum = VoiceSpectrum(sampleRate: buffer.format.sampleRate) }
                spectrum?.process(samples, count: Int(buffer.frameLength))
                latestLevel = level
            }
        }
        sink.onLevel(level)
        if let converted = Self.convert(buffer, with: sink.converter, to: sink.format) {
            sink.continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // About -50 dB maps to 0, -10 dB to 1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 50) / 40))
    }
}

struct IOSCaptureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
