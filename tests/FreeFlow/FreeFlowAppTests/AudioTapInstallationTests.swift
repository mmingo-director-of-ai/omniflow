import AVFoundation
import Testing

@Test func duplicateAudioTapIsARecoverableError() throws {
    let engine = AVAudioEngine()
    let mixer = AVAudioMixerNode()
    engine.attach(mixer)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    try mixer.__installTap(onBus: 0, bufferSize: 1024, format: format, error: ()) { _, _ in }
    defer { mixer.removeTap(onBus: 0) }
    #expect(throws: (any Error).self) {
        try mixer.__installTap(onBus: 0, bufferSize: 1024, format: format, error: ()) { _, _ in }
    }
}
