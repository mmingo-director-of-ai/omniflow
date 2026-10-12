import AVFoundation
import Foundation
import Speech
import Testing
@testable import OmniFlowApp

/// Speech captured before the analyzer is ready must still be transcribed: the
/// microphone opens first and buffers. Uses macOS `say` to synthesize speech, so it
/// needs the en-US dictation assets (skips when they cannot be prepared).
@MainActor @Test func audioCapturedBeforeTheAnalyzerIsReadyIsNotLost() async throws {
    let recognizer = DictationRecognizer()
    do { try await recognizer.prepare(locale: Locale(identifier: "en-US"), download: true) }
    catch { return }   // no speech assets on this machine
    if SpeechTranscriber.isAvailable,
       await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) != nil {
        #expect(recognizer.backend == .speech, "Supported devices must use FreeFlow's SpeechTranscriber backend")
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("start-\(UUID().uuidString).aiff")
    defer { try? FileManager.default.removeItem(at: url) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "Pineapple sunrise. Ship the dashboard update on Thursday."]
    try say.run(); say.waitUntilExit()
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)

    let input = try await recognizer.makeInput()
    // Everything is "spoken" before the analyzer exists, as when the microphone wins the race.
    let bridge = try VoiceAudioBridge(source: file.processingFormat, destination: input.format, continuation: input.continuation)
    var offset: AVAudioFrameCount = 0
    while offset < buffer.frameLength {
        let count = min(1024, buffer.frameLength - offset)
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count))
        chunk.frameLength = count
        for channel in 0..<Int(buffer.format.channelCount) {
            chunk.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + Int(offset), count: Int(count))
        }
        bridge.tap(chunk, AVAudioTime(sampleTime: AVAudioFramePosition(offset), atRate: buffer.format.sampleRate))
        offset += count
    }
    try await recognizer.startAnalyzer(onText: { _ in }, onError: { _ in })
    let text = try await recognizer.finish().lowercased()
    #expect(text.contains("pineapple"), "first words lost: \(text)")
    #expect(text.contains("thursday"))
}
