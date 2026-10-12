import Foundation
import Testing
@testable import OmniFlowApp

private let rate = 48_000.0

/// Feeds `seconds` of a signal in 1024-frame buffers, as the microphone tap does.
private func feed(_ spectrum: VoiceSpectrum, seconds: Double, start: inout Int, _ sample: (Int) -> Float) {
    var buffer = [Float](repeating: 0, count: 1024)
    for _ in 0..<Int(seconds * rate / 1024) {
        for index in buffer.indices { buffer[index] = sample(start + index) }
        start += buffer.count
        buffer.withUnsafeBufferPointer { spectrum.process($0.baseAddress!, count: $0.count) }
    }
}

private func noise(_ index: Int) -> Float {
    // Deterministic low-level hiss (~-66 dBFS).
    var x = UInt32(truncatingIfNeeded: index &* 2_654_435_761)
    x ^= x >> 13; x &*= 0x5bd1e995; x ^= x >> 15
    return (Float(x & 0xFFFF) / 65_535 - 0.5) * 0.001
}

@Test func bandsAreLogSpacedAcrossVoiceRange() {
    let spectrum = VoiceSpectrum(sampleRate: rate)
    #expect(spectrum.bandCount == 17)
    #expect(spectrum.centerHz(of: 0) < 120 && spectrum.centerHz(of: 16) > 5_000)
    for band in 1..<17 { #expect(spectrum.centerHz(of: band) > spectrum.centerHz(of: band - 1)) }
}

@Test func sineLightsTheMatchingBandOnly() throws {
    for hz in [200.0, 1_000.0, 4_000.0] {
        let spectrum = VoiceSpectrum(sampleRate: rate)
        var t = 0
        feed(spectrum, seconds: 0.6, start: &t, noise)
        feed(spectrum, seconds: 0.4, start: &t) { noise($0) + 0.3 * Float(sin(2 * .pi * hz * Double($0) / rate)) }
        let target = try #require(spectrum.band(containing: hz))
        let bands = spectrum.bands
        #expect(bands[target] > 0.6, "\(hz) Hz should light band \(target): \(bands)")
        let loudest = bands.indices.max { bands[$0] < bands[$1] }!
        #expect(abs(loudest - target) <= 1)
        let far = bands.indices.filter { abs($0 - target) > 3 }
        #expect(far.allSatisfy { bands[$0] < 0.25 }, "\(hz) Hz leaked: \(bands)")
    }
}

@Test func roomNoiseAndSilenceStayLow() {
    let spectrum = VoiceSpectrum(sampleRate: rate)
    var t = 0
    feed(spectrum, seconds: 2, start: &t, noise)
    #expect(spectrum.bands.allSatisfy { $0 < 0.1 }, "noise: \(spectrum.bands)")
    feed(spectrum, seconds: 1, start: &t) { _ in 0 }
    #expect(spectrum.bands.allSatisfy { $0 < 0.1 })
}

@Test func bandsReleaseAfterSpeechAndPeaksHoldBriefly() throws {
    let spectrum = VoiceSpectrum(sampleRate: rate)
    var t = 0
    feed(spectrum, seconds: 0.6, start: &t, noise)
    feed(spectrum, seconds: 0.3, start: &t) { noise($0) + 0.3 * Float(sin(2 * .pi * 1_000 * Double($0) / rate)) }
    let band = try #require(spectrum.band(containing: 1_000))
    let lit = spectrum.bands[band]
    feed(spectrum, seconds: 0.05, start: &t, noise)
    // Shortly after the tone stops the band is falling but the peak still holds.
    #expect(spectrum.peaks[band] >= lit * 0.95)
    feed(spectrum, seconds: 0.6, start: &t, noise)
    #expect(spectrum.bands[band] < 0.1, "release: \(spectrum.bands)")
    #expect(spectrum.peaks[band] < lit && spectrum.peaks[band] >= spectrum.bands[band])
}
