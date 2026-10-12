import AVFoundation
import Foundation

@MainActor final class KokoroReplySpeaker: ReplySpeaker {
    static let selectionKey = "omniflow.assistant.kokoroVoice"
    var onFirstAudio: (@MainActor () -> Void)?
    var onFinished: (@MainActor () -> Void)?
    var onFailure: (@MainActor (Error) -> Void)?
    private let playback = SpeechPlayback()
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var queue: [(String, Double)] = []
    private var ended = false
    private var active = false
    private var voice = KokoroReadingVoice.resolve(nil)
    func prepare() {
        let voice = KokoroReadingVoice.resolve(UserDefaults.standard.string(forKey: Self.selectionKey))
        Task { await KokoroReader.shared.prepare(voice) }
    }
    func beginReply() {
        stop()
        active = true
        voice = KokoroReadingVoice.resolve(UserDefaults.standard.string(forKey: Self.selectionKey))
        let token = generation
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { active = false; onFailure?(error); return }
        #endif
        playback.reset(generation: token) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, self.active else { return }
                self.onFirstAudio?()
            }
        }
    }
    func enqueue(_ sentence: String, rate: Double, pitch: Double) {
        guard active, !sentence.isEmpty else { return }
        queue.append((sentence, rate)); pump()
    }
    func endReply() { ended = true; pump() }
    func stop() {
        generation &+= 1
        task?.cancel(); task = nil
        queue.removeAll(); ended = false; active = false
        playback.reset(generation: generation, onFirstAudio: nil)
    }
    func shutdown() { stop(); playback.shutdown() }
    private func pump() {
        guard active, task == nil else { return }
        let token = generation
        guard !queue.isEmpty else {
            if ended {
                playback.finishWhenDrained(generation: token) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.active else { return }
                        self.active = false
                        self.onFinished?()
                    }
                }
            }
            return
        }
        let (text, rate) = queue.removeFirst(), voice = voice
        task = Task { [weak self] in
            do {
                let samples = try await KokoroReader.shared.sentence(text, voice: voice, rate: rate)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                let pcm = samples.map { Int16(max(-32768, min(32767, ($0.isFinite ? $0 : 0) * 32767))).littleEndian }
                self.playback.schedule(pcm.withUnsafeBytes { Data($0) }, generation: token)
                self.task = nil
                self.pump()
            } catch {
                guard let self, self.generation == token else { return }
                self.stop()
                self.onFailure?(error)
            }
        }
    }
}
