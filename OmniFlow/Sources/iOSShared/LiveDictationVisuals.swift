import SwiftUI

/// A slow, soft color field behind the live transcript that swells with the voice.
struct ListeningAura: View {
    var active: Bool
    var level: () -> Float

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let level = active ? Double(level()) : 0
            let drift = Float(sin(time * 0.45)) * 0.08, sway = Float(cos(time * 0.37)) * 0.08
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5 + drift, 0.55 + sway], [1, 0.5],
                [0, 1], [0.5 - drift, 1], [1, 1],
            ], colors: [
                Theme.paper, Theme.paper, Theme.paper,
                Theme.banner, Theme.accent.opacity(0.16 + 0.34 * level), Theme.banner,
                Theme.accent.opacity(0.30 + 0.40 * level), Theme.emerald.opacity(0.38 + 0.45 * level), Theme.accent.opacity(0.30 + 0.40 * level),
            ])
            .animation(.easeOut(duration: 0.25), value: level)
        }
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.6), value: active)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A small red dot that pulses while recording, with the elapsed time.
struct RecordingClock: View {
    let since: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.35]) { dot, value in dot.opacity(value) } animation: { _ in .easeInOut(duration: 0.8) }
            Text(since, style: .timer).monospacedDigit()
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording")
    }
}
