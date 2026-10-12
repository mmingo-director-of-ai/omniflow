import SwiftUI

/// The recording pill as an orb: a glass sphere wrapped in the live voice ring
/// (tap to finish), with cancel, lock and pause as their own glass circles.
/// Controls stay separated throughout microphone startup and recording,
/// including silence; the voice ring alone responds to audio levels.
struct DictationOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: AppModel.Phase
    let level: Double
    let locked: Bool
    /// Nil hides the pause circle (mouse-follow focus is off).
    let focusPaused: Bool?
    let spectrum: () -> VoiceRing.Spectrum
    let actions: Actions

    struct Actions {
        var finish: () -> Void
        var cancel: () -> Void
        var lock: () -> Void
        var togglePause: () -> Void
    }

    @Namespace private var glass
    @State private var hovering = false

    private var recording: Bool { phase == .recording }
    private var expanded: Bool { phase == .starting || recording || hovering || locked }

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: expanded ? 10 : -34) {
                satellite("xmark", help: "Cancel dictation", id: "cancel") { actions.cancel() }
                ZStack {
                    // A soft glow that swells with the voice, as behind the iPhone keyboard.
                    Circle()
                        .fill(RadialGradient(colors: [Color.flowAccent.opacity(recording ? 0.18 + 0.4 * min(1, level * 1.5) : 0.08), .clear],
                                             center: .center, startRadius: 20, endRadius: 64))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: level)
                    VoiceRing(listening: recording, color: .flowAccent, spectrum: spectrum)
                    .frame(width: 124, height: 124)
                    Button(action: actions.finish) {
                        ZStack {
                            if phase == .starting {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.flowAccent)
                                    .frame(width: 15, height: 15)
                            }
                        }
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: Circle())
                        .glassEffectID("orb", in: glass)
                    }
                    .buttonStyle(.plain)
                    .help("Finish dictation")
                    .accessibilityLabel("Finish dictation")
                }
                .frame(width: 124, height: 124)
                .zIndex(1)
                satellite(locked ? "lock.fill" : "lock.open", help: locked ? "Locked: hands-free" : "Lock recording",
                          id: "lock", highlighted: locked) { actions.lock() }
                if let focusPaused {
                    satellite(focusPaused ? "cursorarrow" : "pause.fill",
                              help: focusPaused ? "Resume mouse-follow focus" : "Pause mouse-follow focus",
                              id: "pause") { actions.togglePause() }
                }
            }
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72), value: expanded)
    }

    private func satellite(_ symbol: String, help: String, id: String, highlighted: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(highlighted ? Color.flowAccent : .white.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID(id, in: glass)
        }
        .buttonStyle(.plain)
        .opacity(expanded ? 1 : 0)
        .scaleEffect(expanded ? 1 : 0.5)
        .help(help)
        .accessibilityLabel(help)
        // Reachable by keyboard and VoiceOver even while collapsed.
        .accessibilityHidden(false)
    }


}

/// The orb outside recording: the same glass sphere with its controls as
/// separate circles, so the pill keeps one shape from start to finish.
/// Processing turns the voice ring into a slow sweep; a result shows a check;
/// an error turns the sphere's mark orange. The status line sits underneath.
struct DictationOrbStatus: View {
    enum Kind: Equatable { case idle, processing, result, error }

    struct Satellite: Identifiable {
        let id: String
        let symbol: String
        let help: String
        let action: () -> Void
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: Kind
    let message: String
    var leading: [Satellite] = []
    var trailing: [Satellite] = []
    /// Clicking the sphere (and the status line): open the Hub, settings, etc.
    let open: () -> Void
    @Namespace private var glass
    @State private var hovering = false
    @State private var appeared = false

    /// Idle tucks its controls away until you hover; every other state shows them.
    private var expanded: Bool { kind != .idle || hovering }

    var body: some View {
        VStack(spacing: 6) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: expanded ? 10 : -30) {
                    ForEach(leading) { satellite($0) }
                    ZStack {
                        if kind == .processing { sweep.frame(width: 76, height: 76) }
                        Button(action: open) {
                            center
                                .frame(width: 48, height: 48)
                                .contentShape(Circle())
                                .glassEffect(.regular.interactive(), in: Circle())
                                .glassEffectID("orb", in: glass)
                        }
                        .buttonStyle(.plain)
                        .help(message)
                        .accessibilityLabel(message)
                    }
                    .frame(width: 76, height: 76)
                    .zIndex(1)
                    ForEach(trailing) { satellite($0) }
                }
            }
            if kind != .idle || hovering {
                Button(action: open) {
                    Text(message).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85)).frame(maxWidth: 280)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .onAppear { appeared = true }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72), value: expanded)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72), value: kind)
    }

    @ViewBuilder private var center: some View {
        switch kind {
        case .idle:
            RedPandaView(paused: true).frame(width: 30, height: 30)
        case .processing:
            OmniFlowMascotActivity(phase: .processing).frame(width: 30, height: 30)
        case .result:
            Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.flowAccent)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.4)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.55), value: appeared)
        case .error:
            Image(systemName: "exclamationmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.orange)
        }
    }

    /// A slow accent sweep around the sphere while cleanup runs (still with Reduce Motion).
    private var sweep: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(AngularGradient(colors: [Color.flowAccent.opacity(0), Color.flowAccent], center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(angle))
                .padding(6)
        }
        .accessibilityHidden(true)
    }

    private func satellite(_ item: Satellite) -> some View {
        Button(action: item.action) {
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID(item.id, in: glass)
        }
        .buttonStyle(.plain)
        .opacity(expanded ? 1 : 0)
        .scaleEffect(expanded ? 1 : 0.5)
        .help(item.help)
        .accessibilityLabel(item.help)
    }
}
