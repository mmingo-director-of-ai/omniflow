import SwiftUI

// Live dictation visuals shared by the Mac pill, the iOS app and the iOS
// keyboard: the voice ring and the word-by-word transcript arrival.

/// The record button's halo: the live voice spectrum drawn as radial bars,
/// mirrored left and right, so each band of the voice moves its own bars.
/// At rest it breathes slowly; while listening it follows the voice.
struct VoiceRing: View {
    /// Voice bands (0...1), their held peaks and the overall level.
    typealias Spectrum = (bands: [Float], peaks: [Float], level: Float)
    var listening: Bool
    var color: Color
    /// Read once per frame while listening.
    var spectrum: () -> Spectrum

    private static let barCount = 56

    private static func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval,
                             snapshot: (bands: [Float], peaks: [Float], level: Float), listening: Bool, color: Color) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let inner = min(size.width, size.height) / 2 * 0.5
        let room = min(size.width, size.height) / 2 - inner - 2
        let bands = snapshot.bands
        var glow = Path()
        var bars: [(Path, Double)] = []
        for index in 0..<barCount {
            let angle = Double(index) / Double(barCount) * 2 * .pi - .pi / 2
            // Mirror around the vertical axis: low bands at the bottom, high at the top.
            let around = abs(sin((angle + .pi / 2) / 2))
            var value: CGFloat = 0, peak: CGFloat = 0
            if bands.count > 1 {
                let band = min(bands.count - 1, Int((1 - around) * Double(bands.count - 1) + 0.5))
                value = CGFloat(bands[band])
                peak = CGFloat(snapshot.peaks.indices.contains(band) ? snapshot.peaks[band] : bands[band])
            }
            let breath = CGFloat(0.5 + 0.5 * sin(time * 1.6 + Double(index) * 0.35)) * (1 - min(1, value * 3))
            let length = 4 + breath * (listening ? 3 : 2) + room * CGFloat(pow(Double(value), 0.75))
            let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
            func spoke(_ length: CGFloat) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
                path.addLine(to: CGPoint(x: center.x + dx * (inner + length), y: center.y + dy * (inner + length)))
                return path.strokedPath(StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            bars.append((spoke(length), 0.35 + 0.65 * Double(value)))
            if peak > 0.45 { glow.addPath(spoke(3 + room * peak)) }
        }
        if !glow.isEmpty {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                layer.fill(glow, with: .color(color.opacity(0.55)))
            }
        }
        for (path, opacity) in bars { context.fill(path, with: .color(color.opacity(listening ? opacity : 0.22))) }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Redraws only while listening, and never with Reduce Motion (then the
        // ring is a still, even ring).
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !listening || reduceMotion)) { timeline in
            Canvas { context, size in
                Self.draw(in: &context, size: size, time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                          snapshot: listening && !reduceMotion ? spectrum() : ([], [], 0), listening: listening, color: color)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Marks the words that just arrived so the renderer can bring them in.
struct FreshWords: TextAttribute {}

/// New words rise, sharpen and fade in, one after another; settled text is drawn as is.
struct WordArrivalRenderer: TextRenderer, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard run[FreshWords.self] != nil else { context.draw(run); continue }
                let count = max(run.count, 1)
                for (index, glyph) in run.enumerated() {
                    let delay = Double(index) / Double(count) * 0.55
                    let t = min(1, max(0, (progress - delay) / 0.45))
                    let eased = 1 - pow(1 - t, 3)
                    var copy = context
                    copy.opacity = eased
                    copy.translateBy(x: 0, y: (1 - eased) * 8)
                    if eased < 1 { copy.addFilter(.blur(radius: (1 - eased) * 5)) }
                    copy.draw(glyph)
                }
            }
        }
    }
}

/// The running transcript, with each new stretch of words animating in.
struct LiveTranscript: View {
    let text: String
    var font: Font = .system(size: 28, design: .serif)
    @State private var settled = ""
    @State private var fresh = ""
    @State private var progress = 1.0

    var body: some View {
        Text("\(Text(settled))\(Text(fresh).customAttribute(FreshWords()))")
            .font(font)
            .lineSpacing(6)
            .textRenderer(WordArrivalRenderer(progress: progress))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: text, initial: true) { old, new in advance(from: settled + fresh, to: new) }
            .accessibilityLabel(text)
    }

    /// Keeps what's unchanged settled; only the changed tail animates. Recognition
    /// often revises its last words, so the split falls on a word boundary.
    private func advance(from old: String, to new: String) {
        var common = old.commonPrefix(with: new)
        if common.count < new.count, let space = common.lastIndex(where: \.isWhitespace) {
            common = String(common[...space])
        } else if common.count < new.count {
            common = ""
        }
        settled = common
        fresh = String(new.dropFirst(common.count))
        progress = 0
        withAnimation(.easeOut(duration: 0.7)) { progress = 1 }
    }
}
