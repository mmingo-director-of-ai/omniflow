import Accelerate
import Foundation

/// A small log-spaced voice spectrum for the dictation pill. Hann-windowed real
/// FFT over a sliding window, mean power per band between `lowHz` and `highHz`,
/// dB relative to an adaptive per-band noise floor (room noise reads near zero,
/// speech stands out), fast-attack/slow-release smoothing and a gentle peak hold.
///
/// All buffers and the FFT setup are allocated once in `init`; `process` does no
/// allocation. Not thread-safe: confine an instance to one serial audio callback.
final class VoiceSpectrum: @unchecked Sendable {
    let bandCount: Int
    let sampleRate: Double
    /// Smoothed band energies, 0...1.
    private(set) var bands: [Float]
    /// Held peaks, 0...1, never below `bands`.
    private(set) var peaks: [Float]

    static let attack = 0.03, release = 0.15
    static let peakHold = 0.12, peakFallPerSecond: Float = 1.6
    /// dB above the floor at which a band reads as full.
    static let dynamicRange: Float = 40
    /// A band this many dB below the loudest band reads as empty, so the voice's
    /// spectral shape shows at any loudness instead of every band saturating.
    static let shapeRange: Float = 30
    /// Speech energy falls ~3 dB per octave; lift higher bands to keep them visible.
    static let tiltPerOctave: Float = 3
    /// dB above the floor before a band starts to rise; keeps noise flat.
    static let gate: Float = 5

    private let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var history: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]
    private var binRanges: [Range<Int>]
    private var floors: [Float]
    private var peakAge: [Double]
    private var tilt: [Float]
    private var aboveFloor: [Float]
    /// Band level averaged over ~40 ms in dB (a single FFT frame is too noisy;
    /// averaging in dB rather than power keeps the release fast after loud sounds).
    private var averageDecibels: [Float]
    private var filled = 0
    private static let unsetFloor: Float = -999

    init(sampleRate: Double, bandCount: Int = 17, lowHz: Double = 80, highHz: Double = 8000, fftSize: Int = 2048) {
        precondition(fftSize > 0 && fftSize & (fftSize - 1) == 0 && bandCount > 0)
        self.sampleRate = sampleRate
        self.bandCount = bandCount
        self.fftSize = fftSize
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        history = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imaginary = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        bands = [Float](repeating: 0, count: bandCount)
        peaks = [Float](repeating: 0, count: bandCount)
        floors = [Float](repeating: Self.unsetFloor, count: bandCount)
        peakAge = [Double](repeating: 0, count: bandCount)
        aboveFloor = [Float](repeating: 0, count: bandCount)
        averageDecibels = [Float](repeating: Self.unsetFloor, count: bandCount)
        tilt = (0..<bandCount).map { Self.tiltPerOctave * Float(log2(pow(highHz / lowHz, Double($0) / Double(bandCount)))) }
        binRanges = Self.binRanges(bandCount: bandCount, lowHz: lowHz, highHz: min(highHz, sampleRate / 2),
                                   sampleRate: sampleRate, fftSize: fftSize)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Log-spaced band edges mapped to FFT bins; every band gets at least one bin.
    static func binRanges(bandCount: Int, lowHz: Double, highHz: Double, sampleRate: Double, fftSize: Int) -> [Range<Int>] {
        let binHz = sampleRate / Double(fftSize)
        let maximumBin = fftSize / 2 - 1
        var ranges: [Range<Int>] = []
        var previousEnd = max(1, Int((lowHz / binHz).rounded(.down)))
        for band in 0..<bandCount {
            let upperHz = lowHz * pow(highHz / lowHz, Double(band + 1) / Double(bandCount))
            let end = min(maximumBin + 1, max(previousEnd + 1, Int((upperHz / binHz).rounded())))
            let start = min(previousEnd, end - 1)
            ranges.append(start..<end)
            previousEnd = end
        }
        return ranges
    }

    /// Feed mono samples; `count` may be smaller or larger than the FFT size.
    func process(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let elapsed = Double(count) / sampleRate
        // Slide the analysis window by the new samples.
        let fresh = min(count, fftSize)
        history.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            if fresh < fftSize { memmove(base, base + fresh, (fftSize - fresh) * MemoryLayout<Float>.stride) }
            memcpy(base + (fftSize - fresh), samples + (count - fresh), fresh * MemoryLayout<Float>.stride)
        }
        filled = min(fftSize, filled + fresh)
        vDSP_vmul(history, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Nyquist is packed into imagp[0]; drop it so bin 0 is DC only.
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
            }
        }
        // zrip output is 2x the DFT; window coherent gain ~0.5. Normalize to full scale.
        let scale = 1 / Float(fftSize * fftSize)
        let attack = Float(1 - exp(-elapsed / Self.attack))
        let release = Float(1 - exp(-elapsed / Self.release))
        // The floor starts at the first full window's level, then tracks quiet quickly and
        // loud slowly (~8 s), so pauses between words keep speech above it.
        let floorDown = Float(1 - exp(-elapsed / 0.5)), floorUp = Float(1 - exp(-elapsed / 8))
        guard filled == fftSize else { return }
        let smoothing = Float(1 - exp(-elapsed / 0.04))
        var loudest: Float = 0
        for band in 0..<bandCount {
            let range = binRanges[band]
            var sum: Float = 0
            for bin in range { sum += power[bin] }
            let frameDecibels = 10 * log10(max(sum / Float(range.count) * scale, 1e-12))
            averageDecibels[band] = averageDecibels[band] == Self.unsetFloor ? frameDecibels
                : averageDecibels[band] + (frameDecibels - averageDecibels[band]) * smoothing
            let decibels = averageDecibels[band]
            if floors[band] == Self.unsetFloor { floors[band] = decibels }
            floors[band] += (decibels - floors[band]) * (decibels < floors[band] ? floorDown : floorUp)
            // Gate before tilting, so the high-band lift never raises room noise.
            let excess = decibels - floors[band] - Self.gate
            aboveFloor[band] = excess > 0 ? excess + tilt[band] : 0
            loudest = max(loudest, aboveFloor[band])
        }
        // Loudness of the frame times each band's share of it.
        let loudness = min(1, loudest / Self.dynamicRange)
        for band in 0..<bandCount {
            let shape = aboveFloor[band] > 0 ? min(1, max(0, 1 + (aboveFloor[band] - loudest) / Self.shapeRange)) : 0
            let target = loudness * shape
            bands[band] += (target - bands[band]) * (target > bands[band] ? attack : release)
            if bands[band] >= peaks[band] {
                peaks[band] = bands[band]; peakAge[band] = 0
            } else {
                peakAge[band] += elapsed
                if peakAge[band] > Self.peakHold {
                    peaks[band] = max(bands[band], peaks[band] - Self.peakFallPerSecond * Float(elapsed))
                }
            }
        }
    }

    /// Fresh copies for delivery to another thread. Copying through the raw
    /// buffers keeps the analysis storage uniquely owned, so `process` never
    /// triggers a copy-on-write allocation.
    func snapshot() -> (bands: [Float], peaks: [Float]) {
        (bands.withUnsafeBufferPointer { Array($0) }, peaks.withUnsafeBufferPointer { Array($0) })
    }

    func reset() {
        for index in history.indices { history[index] = 0 }
        for band in 0..<bandCount { bands[band] = 0; peaks[band] = 0; floors[band] = Self.unsetFloor; peakAge[band] = 0; averageDecibels[band] = Self.unsetFloor }
        filled = 0
    }

    /// Center frequency of a band, for tests and diagnostics.
    func centerHz(of band: Int) -> Double {
        let range = binRanges[band]
        return (Double(range.lowerBound) + Double(range.count) / 2) * sampleRate / Double(fftSize)
    }

    func band(containing hz: Double) -> Int? {
        let bin = Int((hz * Double(fftSize) / sampleRate).rounded())
        return binRanges.firstIndex { $0.contains(bin) }
    }
}
