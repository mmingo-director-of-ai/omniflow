import AVFoundation
import Foundation

@MainActor
protocol ReplySpeaker: AnyObject {
    var onFirstAudio: (@MainActor () -> Void)? { get set }
    var onFinished: (@MainActor () -> Void)? { get set }
    var onFailure: (@MainActor (Error) -> Void)? { get set }
    func prepare()
    func beginReply()
    func enqueue(_ sentence: String, rate: Double, pitch: Double)
    func endReply()
    func stop()
    func shutdown()
}

/// Plays streamed 48 kHz mono PCM through an output-only engine. It never touches
/// `inputNode`, which would rebuild the input/output aggregate the capture path
/// avoids. Engine state and buffer accounting are confined to one serial queue.
final class SpeechPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "notchlee.speech.playback", qos: .userInteractive)
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var configurationObserver: NSObjectProtocol?
    private var generation: UInt64 = 0
    private var pending = 0
    private var reportedFirstAudio = false
    private var onFirstAudio: (@Sendable () -> Void)?
    private var onDrained: (@Sendable () -> Void)?
    private var idle: DispatchWorkItem?

    /// Drops everything scheduled for earlier generations.
    func reset(generation: UInt64, onFirstAudio: (@Sendable () -> Void)?) {
        queue.async { [self] in
            self.generation = generation
            player?.stop()
            pending = 0
            reportedFirstAudio = false
            self.onFirstAudio = onFirstAudio
            onDrained = nil
            scheduleIdleStop()
        }
    }

    func schedule(_ pcm: Data, generation: UInt64) {
        queue.async { [self] in
            guard generation == self.generation, let buffer = Self.buffer(pcm, format: format) else { return }
            guard let player = startIfNeeded() else { return }
            idle?.cancel(); idle = nil
            pending += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                self?.played(generation)
            }
            if !reportedFirstAudio {
                reportedFirstAudio = true
                onFirstAudio?()
            }
        }
    }

    func finishWhenDrained(generation: UInt64, _ handler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard generation == self.generation else { return }
            onDrained = handler
            drainIfIdle()
        }
    }

    func shutdown() {
        queue.async { [self] in
            generation &+= 1
            idle?.cancel(); idle = nil
            tearDown()
        }
    }

    private func played(_ generation: UInt64) {
        queue.async { [self] in
            guard generation == self.generation else { return }
            pending = max(0, pending - 1)
            drainIfIdle()
        }
    }

    private func drainIfIdle() {
        guard pending == 0 else { return }
        scheduleIdleStop()
        guard let onDrained else { return }
        self.onDrained = nil
        onDrained()
    }

    /// Release the output device a few seconds after the last sentence.
    private func scheduleIdleStop() {
        idle?.cancel()
        let stop = DispatchWorkItem { [weak self] in
            guard let self, pending == 0 else { return }
            tearDown()
        }
        idle = stop
        queue.asyncAfter(deadline: .now() + 6, execute: stop)
    }

    private func startIfNeeded() -> AVAudioPlayerNode? {
        if engine == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            self.engine = engine
            self.player = player
            // A route change stops the engine and discards scheduled audio.
            // Count it as played so a reply can never wait forever.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { @Sendable [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    // The stopped engine and player cannot be trusted; rebuild on the next buffer.
                    tearDown()
                    drainIfIdle()
                }
            }
        }
        guard let engine, let player else { return nil }
        if !engine.isRunning {
            do { try engine.start() } catch { tearDown(); return nil }
        }
        if !player.isPlaying { player.play() }
        return player
    }

    private func tearDown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        pending = 0
    }

    private static func buffer(_ pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for frame in 0..<frames {
                output[frame] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self))) / 32768
            }
        }
        return buffer
    }
}

