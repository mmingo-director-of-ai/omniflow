import AVFoundation
import Speech
import Synchronization
import Testing
@testable import OmniFlowApp

/// Reproduce the Core Audio queue boundary with real PCM conversion, without
/// opening a microphone, changing permissions or loading a speech model.
@Test @MainActor func audioTapCreatedOnMainActorRunsOnAudioQueue() async throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let speechFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let pipe = try VoiceAudioBridge(source: format, destination: speechFormat, continuation: continuation)
    let callback = pipe.tap
    try await Task.detached {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let audio = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1_024))
        audio.frameLength = 1_024
        let samples = try #require(audio.floatChannelData?[0])
        for index in 0..<1_024 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.1 }
        for _ in 0..<4 { callback(audio, AVAudioTime(sampleTime: 0, atRate: 48_000)) }
    }.value
    continuation.finish()
    var received = 0
    for try await _ in stream { received += 1 }
    #expect(received > 0)
}

@Test func stereoAndIntegerMicrophonesKeepSpeechAndMeterActivity() async throws {
    let speechFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    for encoding: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
        for interleaved in [false, true] {
            let format = try #require(AVAudioFormat(commonFormat: encoding, sampleRate: 48_000, channels: 2, interleaved: interleaved))
            let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
            let meter = Mutex(0.0)
            let pipe = try VoiceAudioBridge(source: format, destination: speechFormat, continuation: continuation,
                onLevel: { level in meter.withLock { $0 = level } })
            let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
            audio.frameLength = 1_024
            let channels = UnsafeMutableAudioBufferListPointer(audio.mutableAudioBufferList)
            for channel in channels { memset(channel.mData!, 0, Int(channel.mDataByteSize)) }
            // A stereo USB microphone can carry sound in channel two only.
            let data = try #require(channels[interleaved ? 0 : 1].mData)
            for frame in 0..<1_024 {
                let i = interleaved ? frame * 2 + 1 : frame
                switch encoding {
                case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self)[i] = 0.5
                case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self)[i] = 0.5
                case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self)[i] = 16_384
                case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self)[i] = 1_073_741_824
                default: Issue.record("Unsupported test format")
                }
            }
            for _ in 0..<7 { pipe.tap(audio, AVAudioTime(sampleTime: 0, atRate: 48_000)) }
            continuation.finish()
            var frames = 0
            for try await input in stream {
                frames += Int(input.buffer.frameLength)
                #expect(VoiceAudioBridge.level(of: input.buffer) > 0.65)
            }
            #expect(frames > 2_000)
            #expect(meter.withLock { $0 } > 0.8)
        }
    }
}

@Test func audioBacklogFailsInsteadOfSilentlyDroppingSpeech() async throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let speechFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let pipe = try VoiceAudioBridge(source: format, destination: speechFormat, continuation: continuation)
    let audio = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
    audio.frameLength = 1_024
    audio.floatChannelData![0].initialize(repeating: 0, count: 1_024)
    for _ in 0..<4 { pipe.tap(audio, AVAudioTime(sampleTime: 0, atRate: 48_000)) }
    var received = 0
    do {
        for try await _ in stream { received += 1 }
        Issue.record("A full audio queue must report an error")
    } catch {
        #expect(error as? VoiceInputError == .audioBacklog)
    }
    #expect(received == 1)
}

private func captureSample(format: CMFormatDescription, frames: Int = 32) throws -> CMSampleBuffer {
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                   presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
        dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    #expect(status == noErr)
    return try #require(sample)
}

@Test func capturePCMRetainsNativeSamplesAcrossFormatChanges() throws {
    for encoding: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
        for interleaved in [false, true] {
            let format = try #require(AVAudioFormat(commonFormat: encoding, sampleRate: 48_000,
                                                  channels: 2, interleaved: interleaved))
            let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
            source.frameLength = 32
            for audio in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList) {
                memset(try #require(audio.mData), 0x21, Int(audio.mDataByteSize))
            }
            let sample = try captureSample(format: format.formatDescription)
            #expect(CMSampleBufferSetDataBufferFromAudioBufferList(sample,
                blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: source.audioBufferList) == noErr)
            let copied = try VoiceCapturePCM.copy(sample)
            #expect(copied.format == format)
            #expect(copied.frameLength == source.frameLength)
            let original = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
            let result = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
            #expect(original.count == result.count)
            for (a, b) in zip(original, result) {
                #expect(a.mDataByteSize == b.mDataByteSize)
                #expect(memcmp(try #require(a.mData), try #require(b.mData), Int(a.mDataByteSize)) == 0)
                #expect(a.mData != b.mData)
            }
        }
    }
}

@Test func capturePCMRejectsInvalidOrMissingAudio() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let missingData = try captureSample(format: format.formatDescription)
    #expect(throws: VoiceInputError.unavailableInput) { try VoiceCapturePCM.copy(missingData) }
    let invalid = try captureSample(format: format.formatDescription)
    CMSampleBufferInvalidate(invalid)
    #expect(throws: VoiceInputError.unavailableInput) { try VoiceCapturePCM.copy(invalid) }

    var compressed = AudioStreamBasicDescription(mSampleRate: 48_000,
        mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
        mFramesPerPacket: 1_024, mBytesPerFrame: 0, mChannelsPerFrame: 1,
        mBitsPerChannel: 0, mReserved: 0)
    var description: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &compressed,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &description) == noErr)
    let unsupported = try captureSample(format: #require(description))
    #expect(throws: VoiceInputError.unavailableInput) { try VoiceCapturePCM.copy(unsupported) }
}
