import AVFoundation
import Foundation

/// Plays book sentences back to back through one player node, so nothing
/// overlaps and the only silences are the pauses the reader inserts. Each
/// sentence's leading and trailing silence is trimmed first: Siri voices start
/// with 30–480 ms of silence depending on the voice, which would make pacing
/// uneven. Output only; it never touches the input node. All engine state lives
/// on one serial queue.
final class ReaderPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "omniflow.reader.playback", qos: .userInitiated)
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?
    private var generation: UInt64 = 0
    private var paused = false
    /// Called on the playback queue when a sentence (and its pause) has played.
    var onPlayed: (@Sendable (_ sentence: Int, _ generation: UInt64, _ seconds: Double) -> Void)?
    /// Loudness envelope of what is scheduled, for the island waveform: no
    /// audio tap, just 33 ms RMS windows computed once per sentence and
    /// looked up by the player's position.
    private var envelope: [Segment] = []
    /// One scheduled sentence (plus its pause): loudness windows and voice-ring frames.
    private typealias Segment = (start: Int64, levels: [Float], frames: [SpectrumFrame])
    struct SpectrumFrame: Sendable { let bands: [Float]; let peaks: [Float] }
    /// The pill's voice spectrum, run over each sentence as it is scheduled (no
    /// audio tap). One instance across sentences, so smoothing carries over.
    private var analyzer: VoiceSpectrum?
    /// Samples per voice-ring frame (~17 ms at 48 kHz, one per display frame at 60 Hz).
    private static let spectrumHop = 800
    private var scheduledFrames: Int64 = 0
    /// Envelope and player as seen by `level()`, which runs on the main thread.
    private let levelLock = NSLock()
    private var levelState: (envelope: [Segment], player: AVAudioPlayerNode?, paused: Bool) = ([], nil, true)
    private func publishLevelState() { let snapshot = (envelope, player, paused); levelLock.withLock { levelState = snapshot } }
    private static let window = 1600
    /// Silent output (the headless soak tests); timing is unchanged.
    var muted = false
    /// The output route changed; scheduled audio was lost.
    var onRouteChange: (@Sendable () -> Void)?

    /// Drops everything scheduled and starts a new generation.
    func flush(generation: UInt64) {
        queue.async { [self] in
            self.generation = generation
            player?.stop()
            envelope = []; scheduledFrames = 0
            publishLevelState()
            if !paused { try? player?.playAudio(at: nil) }
        }
    }

    /// Schedules one sentence (48 kHz mono Float32) and the pause after it.
    func schedule(_ samples: [Float], sentence: Int, pauseAfter: Double, generation: UInt64) {
        queue.async { [self] in
            guard generation == self.generation, let player = startIfNeeded() else { return }
            // A sentence with no usable audio (a failed request, or only a
            // number) still gets its pause, so it completes in order.
            let buffer = Self.trimmedBuffer(samples, format: format)
            // After a wait for speech the player's clock has run on: this audio starts now.
            if let now = Self.position(of: player), now > scheduledFrames { scheduledFrames = now }
            if let buffer {
                player.scheduleBuffer(buffer)
                envelope.append((scheduledFrames, Self.levels(buffer), spectrumFrames(buffer, pause: Int(max(1, pauseAfter * 48000)))))
                if envelope.count > 8 { envelope.removeFirst(envelope.count - 8) }
                scheduledFrames += Int64(buffer.frameLength)
            }
            scheduledFrames += Int64(max(1, pauseAfter * 48000))
            publishLevelState()
            let seconds = Double(buffer?.frameLength ?? 0) / 48000 + max(1, pauseAfter * 48000) / 48000
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, pauseAfter * 48000)))!
            silence.frameLength = silence.frameCapacity
            player.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                guard let self else { return }
                self.queue.async { if generation == self.generation { self.onPlayed?(sentence, generation, seconds) } }
            }
            if !paused && !player.isPlaying { try? player.playAudio(at: nil) }
        }
    }

    func setPaused(_ pause: Bool) {
        queue.async { [self] in
            paused = pause
            publishLevelState()
            guard let player else { return }
            if pause { player.pause() } else {
                if engine?.isRunning == false { try? engine?.start() }
                try? player.playAudio(at: nil)
            }
        }
    }

    /// Releases the audio device; the next scheduled sentence starts it again.
    func shutdown() {
        queue.async { [self] in tearDown() }
    }

    private func startIfNeeded() -> AVAudioPlayerNode? {
        if engine == nil {
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            engine.attach(player)
            do { try engine.connectNode(player, to: engine.mainMixerNode, format: format) } catch { return nil }
            if muted { engine.mainMixerNode.outputVolume = 0 }
            engine.prepare()
            self.engine = engine; self.player = player
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.tearDown()
                    self.onRouteChange?()
                }
            }
        }
        guard let engine, let player else { return nil }
        if !engine.isRunning { do { try engine.start() } catch { tearDown(); return nil } }
        return player
    }

    /// Current output loudness, 0…1 (0 when paused or silent). Thread-safe.
    func level() -> Float {
        let state = levelLock.withLock { levelState }
        guard !state.paused, let player = state.player, player.isPlaying, let now = Self.position(of: player),
              let segment = state.envelope.last(where: { $0.start <= now }) else { return 0 }
        // Interpolate between windows (each ~70 ms) so the bars glide instead of
        // stepping, then scale into WaveformGlyph's voice range (it expects mic-like
        // RMS up to ~0.33; the envelope sits at 0.3–1 and would pin every bar).
        let position = Double(now - segment.start) / Double(Self.window)
        let index = Int(position)
        guard segment.levels.indices.contains(index) else { return 0 }
        let next = segment.levels.indices.contains(index + 1) ? segment.levels[index + 1] : segment.levels[index]
        let blend = Float(position - Double(index))
        return (segment.levels[index] * (1 - blend) + next * blend) / Self.glyphScale
    }

    /// How far through the sentence now playing, 0…1 by its audio (the pause
    /// after it reads as 1), for read-along highlighting. Holds its value while
    /// paused; nil before anything is scheduled. Thread-safe.
    func sentenceProgress() -> Double? {
        let state = levelLock.withLock { levelState }
        guard let player = state.player, let now = Self.position(of: player),
              let segment = state.envelope.last(where: { $0.start <= now }), !segment.levels.isEmpty else { return nil }
        let length = Double(segment.levels.count * Self.window)
        return min(1, max(0, Double(now - segment.start) / length))
    }

    /// Divides the envelope (speech ≈ 0.3–1) down to WaveformGlyph's mic-level input.
    private static let glyphScale: Float = 4

    /// Current voice-ring frame (bands and held peaks), empty when paused or
    /// silent. Thread-safe; read by the island once per display frame.
    func spectrum() -> (bands: [Float], peaks: [Float]) {
        let state = levelLock.withLock { levelState }
        guard !state.paused, let player = state.player, player.isPlaying, let now = Self.position(of: player),
              let segment = state.envelope.last(where: { $0.start <= now }), let last = segment.frames.last else { return ([], []) }
        let index = Int((now - segment.start) / Int64(Self.spectrumHop))
        let frame = segment.frames.indices.contains(index) ? segment.frames[index] : last
        return (frame.bands, frame.peaks)
    }

    /// Runs the voice spectrum over a sentence, then over the pause after it so
    /// the ring falls back as it does when you stop talking. A faint noise floor
    /// (about -50 dBFS, measured to keep speech off the ceiling) stands in for a microphone's room noise: synthesized
    /// speech has true digital silence, which would sink the spectrum's adaptive
    /// floor and saturate every band.
    private func spectrumFrames(_ buffer: AVAudioPCMBuffer, pause: Int) -> [SpectrumFrame] {
        let analyzer = self.analyzer ?? VoiceSpectrum(sampleRate: format.sampleRate)
        self.analyzer = analyzer
        let hop = Self.spectrumHop
        var scratch = [Float](repeating: 0, count: hop)
        var frames: [SpectrumFrame] = []
        var noise: UInt32 = 0x9E3779B9
        func feed(_ samples: UnsafePointer<Float>?, count: Int) {
            for i in 0..<count {
                noise = noise &* 1_664_525 &+ 1_013_904_223
                scratch[i] = (samples?[i] ?? 0) + (Float(noise >> 8) / Float(1 << 24) - 0.5) * 1.2e-2
            }
            scratch.withUnsafeBufferPointer { analyzer.process($0.baseAddress!, count: count) }
            let snapshot = analyzer.snapshot()
            frames.append(SpectrumFrame(bands: snapshot.bands, peaks: snapshot.peaks))
        }
        let count = Int(buffer.frameLength)
        if let samples = buffer.floatChannelData?[0] {
            var start = 0
            while start < count { let n = min(hop, count - start); feed(samples + start, count: n); start += n }
        }
        // Half a second of the pause is enough for the ring to settle; later lookups hold the last frame.
        var left = min(pause, Int(format.sampleRate / 2))
        while left > 0 { let n = min(hop, left); feed(nil, count: n); left -= n }
        return frames
    }

    private static func position(of player: AVAudioPlayerNode) -> Int64? {
        guard let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return nil }
        return time.sampleTime
    }

    /// RMS per window, scaled so speech sits around 0.3–1.
    private static func levels(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        let count = Int(buffer.frameLength)
        return stride(from: 0, to: count, by: window).map { start in
            let end = min(count, start + window)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return min(1, (sum / Float(end - start)).squareRoot() * 6)
        }
    }

    private func tearDown() {
        envelope = []; scheduledFrames = 0
        if let observer { NotificationCenter.default.removeObserver(observer) }
        defer { publishLevelState() }
        observer = nil
        player?.stop(); engine?.stop()
        player = nil; engine = nil
    }

    /// The sentence without silence below −45 dBFS at either end (a 20 ms
    /// fade keeps the cut click-free).
    static func trimmedBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let threshold: Float = 0.0056
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else { return nil }
        let fade = 960
        let start = max(0, first - fade), end = min(samples.count, last + fade)
        let count = end - start
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count {
            var value = samples[start + i]
            if i < fade { value *= Float(i) / Float(fade) }
            if count - i < fade { value *= Float(count - i) / Float(fade) }
            out[i] = value
        }
        return buffer
    }
}
