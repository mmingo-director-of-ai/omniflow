// The private Swift interface is adapted from Max Romer's MIT-licensed siri-tts-cli.
// See SiriTTSInterface-LICENSE.txt. This helper is excluded from the App Store build.
import Foundation
import CoreAudioTypes
import AVFoundation
@preconcurrency import SiriTTSService

struct Voice: Codable {
    let id: String
    let name: String
    let language: String
}

/// Converts Siri's generated chunks to 48 kHz mono signed 16-bit PCM as they arrive.
/// Voice 6 renders at 48 kHz; other Siri voices render 22.05 kHz PCM and are resampled.
final class AudioStream: @unchecked Sendable {
    let lock = NSLock()
    private var failed = false
    private var produced = 0
    private var decoder: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private let sink: (Data) -> Bool

    /// `sink` returns false to reject further audio (for example, a size cap).
    init(sink: @escaping (Data) -> Bool) { self.sink = sink }

    var didFail: Bool { lock.withLock { failed } }
    var producedBytes: Int { lock.withLock { produced } }

    func append(_ audio: AudioData) {
        lock.withLock {
            guard !failed, !audio.audioData.isEmpty else { return }
            let f = audio.asbd
            // Siri returns PCM for fresh synthesis and Opus packets for cached speech.
            // Decode with the system codec, retaining the same Siri voice audio.
            if f.mFormatID == kAudioFormatOpus {
                appendOpus(audio)
                return
            }
            guard f.mFormatID == kAudioFormatLinearPCM, [16000, 22050, 24000, 44100, 48000].contains(f.mSampleRate),
                  f.mChannelsPerFrame == 1, f.mBitsPerChannel == 16, f.mBytesPerFrame == 2,
                  f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                  f.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0,
                  audio.audioData.count.isMultiple(of: 2), audio.audioData.count <= 4_000_000 else {
                failed = true; return
            }
            if f.mSampleRate == 48000 { emit(audio.audioData) } else { resample(audio.audioData, from: f.mSampleRate) }
        }
    }

    private func emit(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        guard sink(pcm) else { failed = true; return }
        produced += pcm.count
    }

    private func appendOpus(_ audio: AudioData) {
        var description = audio.asbd
        guard description.mSampleRate == 48000, description.mChannelsPerFrame == 1,
              (1...1024).contains(audio.packetCount), audio.audioData.count <= 1_000_000,
              let source = AVAudioFormat(streamDescription: &description),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)
        else { failed = true; return }
        if decoder == nil {
            decoder = AVAudioConverter(from: source, to: target)
            decoder?.primeMethod = .none
        }
        guard let decoder else { failed = true; return }
        let stride = MemoryLayout<AudioStreamPacketDescription>.stride
        var packets: [AudioStreamPacketDescription] = []
        if audio.packetDescriptions.count >= audio.packetCount * stride {
            packets = audio.packetDescriptions.withUnsafeBytes { bytes in
                (0..<audio.packetCount).map { bytes.loadUnaligned(fromByteOffset: $0 * stride, as: AudioStreamPacketDescription.self) }
            }
        } else if audio.packetCount == 1 {
            packets = [.init(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(audio.audioData.count))]
        }
        guard packets.count == audio.packetCount,
              packets.allSatisfy({ $0.mStartOffset >= 0 && $0.mStartOffset <= audio.audioData.count &&
                  $0.mDataByteSize > 0 && Int($0.mDataByteSize) <= audio.audioData.count - Int($0.mStartOffset) }),
              let maximum = packets.map({ Int($0.mDataByteSize) }).max(), maximum * packets.count <= 4_000_000
        else { failed = true; return }
        let compressed = AVAudioCompressedBuffer(format: source, packetCapacity: AVAudioPacketCount(packets.count), maximumPacketSize: maximum)
        guard audio.audioData.count <= compressed.byteCapacity else { failed = true; return }
        audio.audioData.copyBytes(to: compressed.data.assumingMemoryBound(to: UInt8.self), count: audio.audioData.count)
        compressed.byteLength = UInt32(audio.audioData.count)
        compressed.packetCount = AVAudioPacketCount(packets.count)
        if let descriptions = compressed.packetDescriptions {
            for (index, packet) in packets.enumerated() { descriptions[index] = packet }
        } else { failed = true; return }
        let frameCapacity = AVAudioFrameCount(min(500_000, max(5760, audio.packetCount * 5760)))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frameCapacity) else { failed = true; return }
        var supplied = false
        var error: NSError?
        let status = decoder.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, error == nil else { failed = true; return }
        appendPCM(output)
    }

    private func resample(_ pcm: Data, from rate: Double) {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)
        else { failed = true; return }
        if resampler == nil || resampler?.inputFormat.sampleRate != rate { resampler = AVAudioConverter(from: source, to: target) }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard let resampler, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames),
              let channel = input.int16ChannelData?[0],
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(frames) * 48000 / rate) + 256)
        else { failed = true; return }
        pcm.withUnsafeBytes { raw in channel.update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames)) }
        input.frameLength = frames
        var supplied = false
        var error: NSError?
        let status = resampler.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { failed = true; return }
        appendPCM(output)
    }

    private func appendPCM(_ output: AVAudioPCMBuffer) {
        let count = Int(output.frameLength) * 2
        if count > 0, let bytes = output.int16ChannelData?[0] { emit(Data(bytes: bytes, count: count)) }
    }

    func finish(error: Error?) {
        lock.withLock {
            if error != nil { failed = true }
            // Flush whichever converter holds buffered tail audio.
            for converter in [decoder, resampler].compactMap({ $0 }) {
                guard !failed, let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 5760) else { return }
                var convertError: NSError?
                let status = converter.convert(to: output, error: &convertError) { _, inputStatus in inputStatus.pointee = .endOfStream; return nil }
                if status == .error || convertError != nil { failed = true } else { appendPCM(output) }
            }
        }
    }
}

/// Whole-reply WAV rendering for the one-shot `speak` command.
final class AudioResult: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm = Data()
    private(set) lazy var stream = AudioStream { [unowned self] chunk in
        lock.withLock {
            guard pcm.count + chunk.count < 24_000_000 else { return false }
            pcm.append(chunk)
            return true
        }
    }

    func wav() -> Data? {
        guard !stream.didFail else { return nil }
        return lock.withLock {
            guard pcm.count > 9600,
                  pcm.withUnsafeBytes({ raw in raw.bindMemory(to: Int16.self).contains { abs(Int($0)) > 32 } }) else { return nil }
            var data = Data("RIFF".utf8)
            func word<T: FixedWidthInteger>(_ number: T) {
                var little = number.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            word(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8))
            word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
            word(UInt32(48000)); word(UInt32(96000)); word(UInt16(2)); word(UInt16(16))
            data.append(Data("data".utf8)); word(UInt32(pcm.count)); data.append(pcm)
            return data
        }
    }
}

/// Long-lived mode. One process per app session keeps the daemon connection and
/// the selected voice warm. Requests arrive as JSON lines on stdin; replies leave
/// stdout as frames: 1-byte kind, 4-byte request id and 4-byte length (both
/// little-endian), then the payload. Kinds: R ready, A 48 kHz mono Int16 PCM,
/// D request done, E request failed. Nothing else is ever written to stdout.
struct ServeRequest: Decodable {
    var id: UInt32?
    var text: String?
    var rate: Float?
    var pitch: Float?
    var cancel: UInt32?
    var prewarm: Bool?
}

final class FrameWriter: @unchecked Sendable {
    private let lock = NSLock()
    func send(_ kind: UInt8, id: UInt32, _ payload: Data = Data()) {
        var frame = Data([kind])
        func word(_ number: UInt32) {
            var little = number.littleEndian
            withUnsafeBytes(of: &little) { frame.append(contentsOf: $0) }
        }
        word(id); word(UInt32(payload.count)); frame.append(payload)
        lock.withLock { FileHandle.standardOutput.write(frame) }
    }
}

final class ServeState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = Set<UInt32>()
    private var current: (id: UInt32, request: SynthesisRequest)?

    func cancel(_ id: UInt32, session: DaemonSession) {
        let request: SynthesisRequest? = lock.withLock {
            cancelled.insert(id)
            if cancelled.count > 4096 { cancelled.removeAll(); cancelled.insert(id) }
            return current?.id == id ? current?.request : nil
        }
        if let request { session.cancel(request: request) }
    }

    /// Returns false when the request was cancelled before synthesis began.
    func begin(_ id: UInt32, _ request: SynthesisRequest) -> Bool {
        lock.withLock {
            guard !cancelled.contains(id) else { return false }
            current = (id, request)
            return true
        }
    }

    func end() { lock.withLock { current = nil } }
}

func serve(session daemon: DaemonSession, voice selected: SynthesisVoice) -> Int32 {
    // The daemon session and voice are used only from the synthesis worker and
    // this reader; the private framework exposes no Sendable annotations.
    nonisolated(unsafe) let session = daemon
    nonisolated(unsafe) let voice = selected
    let writer = FrameWriter()
    let state = ServeState()
    // One synthesis at a time, in request order; stdin stays free for cancellations.
    let worker = DispatchQueue(label: "notchlee.speech.synthesis", qos: .userInitiated)
    session.keepActive = true
    writer.send(UInt8(ascii: "R"), id: 0)
    while let line = readLine(strippingNewline: true) {
        guard line.utf8.count <= 20_000,
              let request = try? JSONDecoder().decode(ServeRequest.self, from: Data(line.utf8)) else { continue }
        if let id = request.cancel {
            state.cancel(id, session: session)
            continue
        }
        if request.prewarm == true {
            worker.async {
                let warm = SynthesisRequest(text: "Hello.", voice: voice)
                let done = DispatchSemaphore(value: 0)
                session.prewarm(request: warm) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 10)
            }
            continue
        }
        guard let id = request.id, id != 0, let text = request.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_000,
              let rate = request.rate, (0.7...1.3).contains(rate),
              let pitch = request.pitch, (0.8...1.2).contains(pitch) else {
            if let id = request.id { writer.send(UInt8(ascii: "E"), id: id) }
            continue
        }
        worker.async {
            let synthesis = SynthesisRequest(text: text, voice: voice)
            guard state.begin(id, synthesis) else { return }
            defer { state.end() }
            synthesis.synthesisContext.rate = rate
            synthesis.synthesisContext.pitch = pitch
            synthesis.synthesisContext.volume = 1
            var sent = 0
            let audio = AudioStream { chunk in
                // Bound a single sentence the same way the one-shot WAV is bounded.
                guard sent + chunk.count < 24_000_000 else { return false }
                sent += chunk.count
                writer.send(UInt8(ascii: "A"), id: id, chunk)
                return true
            }
            synthesis.synthesisContext.didGenerateAudio = { audio.append($0) }
            let done = DispatchSemaphore(value: 0)
            session.synthesize(request: synthesis) { error in audio.finish(error: error); done.signal() }
            guard done.wait(timeout: .now() + 30) == .success else {
                session.cancel(request: synthesis)
                writer.send(UInt8(ascii: "E"), id: id)
                return
            }
            writer.send(UInt8(ascii: audio.didFail || audio.producedBytes == 0 ? "E" : "D"), id: id)
        }
    }
    // stdin closed: the app quit or released the helper.
    worker.sync {}
    return 0
}

func run() -> Int32 {
    let args = CommandLine.arguments
    guard args.count >= 2, ["voices", "speak", "serve"].contains(args[1]) else { return 2 }
    let session = DaemonSession()
    guard session.invokeDaemon() else { return 3 }
    let ready = DispatchSemaphore(value: 0)
    let voiceLock = NSLock()
    nonisolated(unsafe) var installed: [SynthesisVoice] = []
    session.downloadedVoices(matching: nil) { voices in
        voiceLock.withLock { installed = voices }
        ready.signal()
    }
    guard ready.wait(timeout: .now() + 8) == .success else { return 4 }
    // Siri neural voices only (Apple's fmvoice and natural assets); never system/AVSpeech voices.
    let voices = voiceLock.withLock { installed.filter { $0.assetKey.contains(":fmvoice:") || $0.assetKey.contains(":natural:") } }
    if args[1] == "voices" {
        guard let data = try? JSONEncoder().encode(voices.map { Voice(id: $0.assetKey, name: $0.name ?? $0.language, language: $0.language) }) else { return 5 }
        FileHandle.standardOutput.write(data)
        return 0
    }
    if args[1] == "serve" {
        guard args.count == 3, let voice = voices.first(where: { $0.assetKey == args[2] }) else { return 2 }
        return serve(session: session, voice: voice)
    }
    guard args.count == 6, let voice = voices.first(where: { $0.assetKey == args[2] }),
          let rate = Float(args[4]), (0.7...1.3).contains(rate),
          let pitch = Float(args[5]), (0.8...1.2).contains(pitch) else { return 2 }
    var input = Data()
    do {
        while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= 16_000 else { return 2 }
        }
    } catch { return 2 }
    guard let text = String(data: input, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 2 }
    let request = SynthesisRequest(text: text, voice: voice)
    request.synthesisContext.rate = rate
    request.synthesisContext.pitch = pitch
    request.synthesisContext.volume = 1
    let audio = AudioResult()
    request.synthesisContext.didGenerateAudio = { audio.stream.append($0) }
    let done = DispatchSemaphore(value: 0)
    session.synthesize(request: request) { error in audio.stream.finish(error: error); done.signal() }
    guard done.wait(timeout: .now() + 30) == .success else { session.cancel(request: request); return 6 }
    guard let wav = audio.wav() else { return 7 }
    do {
        try wav.write(to: URL(fileURLWithPath: args[3]), options: [.atomic])
        return 0
    } catch { return 8 }
}

exit(run())
