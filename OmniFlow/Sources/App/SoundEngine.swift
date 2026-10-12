import AVFoundation
import AppKit

/// Original, softly synthesized OmniFlow cues. Generated locally and cached on first use.
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()
    var enabled = true
    var volume: Float = 0.12 { didSet { players.values.forEach { $0.volume = volume } } }
    private var players: [String: AVAudioPlayer] = [:]
    private var warm: AVAudioPlayer?
    private var coolDown: DispatchWorkItem?

    /// Synthesize cues off the main thread and prime their players, so the
    /// wake and end-of-speech cues start without a first-use delay.
    func preload(_ names: [String]) {
        let missing = names.filter { players[$0] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            let tones = missing.map { ($0, Self.tone($0)) }
            await MainActor.run {
                for (name, data) in tones where self.players[name] == nil {
                    guard let player = try? AVAudioPlayer(data: data) else { continue }
                    player.volume = self.volume
                    player.prepareToPlay()
                    self.players[name] = player
                }
            }
        }
    }

    func play(_ name: String) {
        guard enabled, AppState.shared.soundEnabled else { return }
        if players[name] == nil { players[name] = try? AVAudioPlayer(data: Self.tone(name)) }
        guard let player = players[name] else { return }
        player.volume = volume
        player.currentTime = 0
        player.play()
        // Keep the output device stable across short cue bursts, then release it.
        if warm == nil {
            warm = try? AVAudioPlayer(data: Self.wav([Int16](repeating: 0, count: 2400)))
            warm?.numberOfLoops = -1
            warm?.volume = 0
        }
        if warm?.isPlaying != true { warm?.play() }
        coolDown?.cancel()
        let stop = DispatchWorkItem { [weak self] in self?.warm?.stop() }
        coolDown = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: stop)
    }

    nonisolated private static func tone(_ name: String) -> Data {
        let notes: [Double]
        switch name {
        case "greet", "open": notes = [523.25, 659.25]
        case "finish", "approve", "proud": notes = [523.25, 659.25, 783.99]
        case "error", "rate", "annoyed": notes = [329.63, 293.66]
        case "approval", "question": notes = [440, 587.33]
        case "close", "sleep", "yawn": notes = [392, 329.63]
        case "wake": notes = [587.33, 880]
        case "heard": notes = [659.25]
        default: notes = [523.25]
        }
        var samples: [Int16] = []
        let duration = 0.105
        for frequency in notes {
            for frame in 0..<Int(duration * 24000) {
                let t = Double(frame) / 24000
                let attack = min(1, t / 0.008)
                let release = min(1, (duration - t) / 0.04)
                let envelope = attack * release * exp(-t * 14)
                let wave = sin(2 * .pi * frequency * t) + 0.12 * sin(4 * .pi * frequency * t)
                samples.append(Int16(max(-32767, min(32767, wave * envelope * 14000))))
            }
        }
        return wav(samples)
    }

    nonisolated private static func wav(_ samples: [Int16]) -> Data {
        var result = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        word(UInt32(samples.count * 2 + 36)); result.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(24000)); word(UInt32(48000))
        word(UInt16(2)); word(UInt16(16)); result.append(Data("data".utf8)); word(UInt32(samples.count * 2))
        for sample in samples { word(sample) }
        return result
    }
}
