import Foundation
import AVFoundation
import Speech

/// Optional integration check, using a synthesized file instead of opening a microphone.
@main
enum SpeechPipelineTests {
    @MainActor final class LiveResult { var text = "" }

    @MainActor static func main() async throws {
        try await checkAudioMeterFormats()
        let locale = Locale(identifier: "en-US")
        let module: any SpeechModule
        let live = LiveResult()
        let readResults: @MainActor () -> Task<String, Error>
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults], attributeOptions: [])
            module = transcriber
            readResults = {
                Task {
                    var transcript = VoiceTranscript()
                    for try await result in transcriber.results {
                            transcript.update(text: String(result.text.characters), start: result.range.start.seconds, end: result.range.end.seconds, isFinal: result.isFinal)
                            live.text = transcript.text
                    }
                    return transcript.text
                }
            }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = VoiceInput.makeDictationTranscriber(locale: supported)
            module = transcriber
            readResults = {
                Task {
                    var transcript = VoiceTranscript()
                    for try await result in transcriber.results {
                            transcript.update(text: String(result.text.characters), start: result.range.start.seconds, end: result.range.end.seconds, isFinal: result.isFinal)
                            live.text = transcript.text
                    }
                    return transcript.text
                }
            }
        } else {
            throw VoiceInputError.unsupportedLanguage
        }
        guard try await AssetInventory.assetInstallationRequest(supporting: [module]) == nil else {
            throw VoiceInputError.modelDownloadRequired
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let destination = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])!
        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
        let bridge = try VoiceAudioBridge(source: file.processingFormat, destination: destination, continuation: continuation)
        let analyzer = SpeechAnalyzer(modules: [module])
        try await VoiceInput.addWakeVocabulary(to: analyzer)
        let results = readResults()
        try await analyzer.prepareToAnalyze(in: destination)
        try await analyzer.start(inputSequence: stream)
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
            try file.read(into: buffer)
            bridge.tap(buffer, AVAudioTime(sampleTime: file.framePosition, atRate: file.processingFormat.sampleRate))
        }
        // Wake detection needs partial results while the input is still open.
        // A final-file-only test can pass even when hands-free activation cannot work.
        let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate / 20))!
        silence.frameLength = silence.frameCapacity
        for audio in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
        }
        for _ in 0..<100 {
            if WakePhrase.command(in: live.text)?.lowercased().contains("waiting") == true { break }
            bridge.tap(silence, AVAudioTime(sampleTime: 0, atRate: file.processingFormat.sampleRate))
            try await Task.sleep(for: .milliseconds(50))
        }
        let liveWake = WakePhrase.command(in: live.text)?.lowercased().contains("waiting") == true
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await results.value
        precondition(liveWake, "Wake phrase must be available before the audio stream closes")
        precondition(text.lowercased().contains("waiting"), "Unexpected transcript: \(text)")
        precondition(WakePhrase.command(in: text)?.lowercased().contains("waiting") == true, "Wake phrase not recognized: \(text)")
        precondition(text.lowercased().components(separatedBy: "waiting").count == 2, "Repeated final transcript: \(text)")
        print("Live and final speech pipeline passed (\(file.processingFormat.sampleRate) → \(destination.sampleRate) Hz): \(text)")
    }

    static func checkAudioMeterFormats() async throws {
        for encoding: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [true, false] {
                let format = AVAudioFormat(commonFormat: encoding, sampleRate: 48000, channels: 2, interleaved: interleaved)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                buffer.frameLength = 1024
                let audio = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for channel in audio { memset(channel.mData!, 0, Int(channel.mDataByteSize)) }
                precondition(VoiceAudioBridge.level(of: buffer) == 0)
                // Sound only in channel two: catch both incorrect pointer counts
                // for interleaved buffers and meters that ignore 32-bit input.
                let data = audio[interleaved ? 0 : 1].mData!
                let index = interleaved ? 1 : 0
                switch encoding {
                case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self)[index] = 0.5
                case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self)[index] = 0.5
                case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self)[index] = 16384
                case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self)[index] = 1073741824
                default: preconditionFailure()
                }
                precondition(abs(VoiceAudioBridge.level(of: buffer) - 0.8996567) < 0.001)
                // Exercise the stereo USB capture path, including interleaved
                // integer PCM that AVAudioFile's default decoder normalizes away.
                for frame in 0..<1024 {
                    let index = interleaved ? frame * 2 + 1 : frame
                    switch encoding {
                    case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self)[index] = 0.5
                    case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self)[index] = 0.5
                    case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self)[index] = 16384
                    case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self)[index] = 1073741824
                    default: preconditionFailure()
                    }
                }
                let destination = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
                let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
                let bridge = try VoiceAudioBridge(source: format, destination: destination, continuation: continuation)
                bridge.tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
                continuation.finish()
                var frames = 0
                for try await input in stream {
                    frames += Int(input.buffer.frameLength)
                    precondition(VoiceAudioBridge.level(of: input.buffer) > 0.65, "Stereo speech must survive conversion to mono")
                }
                precondition(frames > 250, "Conversion must produce speech input, not silently discard it")
            }
        }
        print("Input meter and stereo→mono conversion: 16/32-bit integer, 32/64-bit float, planar/interleaved passed")
    }
}
