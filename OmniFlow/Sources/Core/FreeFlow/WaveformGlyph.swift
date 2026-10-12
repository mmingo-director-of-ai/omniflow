import SwiftUI

/// OmniFlow's dictation mark: five rounded voice bars. `WaveformGlyph` animates
/// it in the app; widgets, controls and the Lock Screen use the same shape as
/// the custom symbol `omniflow.waveform` (Symbols.xcassets), drawn by
/// `scripts/render-waveform-symbol.py` from `restHeights` and `barWidth`.
enum OmniWaveform {
    /// Bar heights at rest, as fractions of the glyph's height.
    static let restHeights: [CGFloat] = [0.42, 0.78, 1.0, 0.6, 0.32]
    /// Bar width as a fraction of the glyph's width; the four gaps share the rest.
    static let barWidth: CGFloat = 0.13
    /// The custom symbol's asset name.
    static let symbolName = OmniFlowSymbol.dictate

    /// Bars centred vertically in `rect`, each `heights[i]` of its height (at least round).
    static func path(in rect: CGRect, heights: [CGFloat]) -> Path {
        let count = heights.count
        guard count > 0 else { return Path() }
        let width = rect.width * barWidth
        let gap = count > 1 ? (rect.width - width * CGFloat(count)) / CGFloat(count - 1) : 0
        var path = Path()
        for (index, fraction) in heights.enumerated() {
            let height = max(width, rect.height * min(1, fraction))
            let bar = CGRect(x: rect.minX + CGFloat(index) * (width + gap), y: rect.midY - height / 2,
                             width: width, height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: width / 2, height: width / 2), style: .continuous)
        }
        return path
    }

    /// Heights for one frame. At rest the bars breathe slowly; while listening
    /// they follow the voice level with a little per-bar movement.
    static func heights(at time: TimeInterval, level: Float?) -> [CGFloat] {
        restHeights.enumerated().map { index, rest in
            let phase = Double(index) * 0.9
            guard let level else { return rest * CGFloat(0.86 + 0.14 * sin(time * 2 * .pi / 3.2 + phase)) }
            let voice = CGFloat(pow(Double(min(1, max(0, level * 3))), 0.75))
            let wobble = CGFloat(0.75 + 0.25 * sin(time * 9 + Double(index) * 1.7))
            return rest * (0.3 + 0.7 * voice * wobble)
        }
    }
}

/// The dictation mark as a live glyph, tinted by the foreground style. Pass
/// `level` while listening to make the bars follow the voice; without it they
/// breathe slowly. Reduce Motion, or being off screen, holds the bars still.
struct WaveformGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat
    /// Read once per frame while listening.
    var level: (() -> Float)?
    @State private var onScreen = false

    init(size: CGFloat, level: (() -> Float)? = nil) {
        self.size = size
        self.level = level
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: level == nil ? 1.0 / 15 : 1.0 / 30, paused: reduceMotion || !onScreen)) { timeline in
            Canvas { context, canvas in
                let heights = reduceMotion ? OmniWaveform.restHeights
                    : OmniWaveform.heights(at: timeline.date.timeIntervalSinceReferenceDate, level: level?())
                // A square glyph inset like an SF Symbol, so it lines up with text and other icons.
                let side = min(canvas.width, canvas.height) * 0.86
                let rect = CGRect(x: (canvas.width - side) / 2, y: (canvas.height - side) / 2, width: side, height: side)
                context.fill(OmniWaveform.path(in: rect, heights: heights), with: .foreground)
            }
        }
        .frame(width: size, height: size)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .accessibilityHidden(true)
    }
}
