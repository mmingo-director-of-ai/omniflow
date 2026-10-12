import AppIntents
import SwiftUI
import WidgetKit

// Views for the iPhone/iPad widgets and Live Activity. They take plain values
// (layout, rendering mode, phase, dates) instead of WidgetKit or ActivityKit
// context, so the preview harness renders the same code to images. Nothing
// here sets a fixed widget size; layouts follow the space they are given.

/// The widget shapes OmniFlow draws, mapped from WidgetFamily on device.
enum OmniWidgetLayout: String, CaseIterable, Sendable {
    case small, medium, large, extraLarge, circular, rectangular, inline
}

/// The Freeflow palette (Resources/Brand/tokens.json), resolved per appearance.
/// Private to the widgets so it never collides with the app's own theme.
struct OmniWidgetPalette {
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }
    var paper: Color { hex(dark ? 0x16181B : 0xF5F5F5) }
    var surface: Color { hex(dark ? 0x1D2024 : 0xFFFFFF) }
    var ink: Color { hex(dark ? 0xE8E8E8 : 0x1F1F1F) }
    var muted: Color { hex(dark ? 0x9C9C9C : 0x787878) }
    var accent: Color { hex(dark ? 0x70D9B8 : 0x1F7A70) }
    var banner: Color { hex(dark ? 0x1B2E2E : 0xEBF2ED) }
    var line: Color { hex(dark ? 0x3B413E : 0xE5E6E0) }
    /// The Live Activity and Dynamic Island are always dark.
    static let island = OmniWidgetPalette(scheme: .dark)

    private func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

private func heading(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }

// MARK: - Background and panda

/// The container background: paper with a soft accent wash toward the corner.
struct OmniWidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = OmniWidgetPalette(scheme: scheme)
        ZStack {
            palette.surface
            RadialGradient(colors: [palette.banner, palette.surface.opacity(0)], center: .bottomTrailing,
                           startRadius: 0, endRadius: 220)
        }
    }
}

/// The red panda as a still drawing; widgets never animate it. In tinted and
/// clear modes the white fills become the visible shape so the system tint
/// reads as the panda instead of a solid block.
struct OmniWidgetPanda: View {
    var fullColor = true
    var cheerful = false

    var body: some View {
        let art = Canvas { context, size in
            context.withCGContext { cg in
                RedPandaDrawing.draw(cg, in: CGRect(origin: .zero, size: size), cheerful: cheerful)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        if fullColor {
            art
        } else {
            // White fills become the shape, black ink the cut-outs, drawn in the system's color.
            Rectangle().fill(.primary).mask(art.luminanceToAlpha()).aspectRatio(1, contentMode: .fit).widgetAccentable()
        }
    }
}

// MARK: - Action widgets (no shared data)

struct OmniWidgetAction<Intent: AppIntent>: Sendable {
    let title: String
    let subtitle: String
    let symbol: String
    let intent: Intent
}

let dictateAction = OmniWidgetAction(title: "Dictate", subtitle: "Tap to start talking",
                                     symbol: OmniFlowSymbol.dictate, intent: OmniFlowDictateIntent())
let translateAction = OmniWidgetAction(title: "Translate", subtitle: "Speak, read it translated",
                                       symbol: "character.bubble.fill", intent: OmniFlowTranslateIntent())
let newNoteAction = OmniWidgetAction(title: "New note", subtitle: "Talk it into a fresh note",
                                     symbol: "square.and.pencil", intent: OmniFlowNewNoteIntent())

/// One action in every family: a tile on the Home Screen and in StandBy, a
/// glyph or line on the Lock Screen. The whole widget is the button.
struct OmniActionWidgetView<Intent: AppIntent>: View {
    let action: OmniWidgetAction<Intent>
    let layout: OmniWidgetLayout
    var fullColor = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = OmniWidgetPalette(scheme: scheme)
        Button(intent: action.intent) {
            switch layout {
            case .inline:
                Label("OmniFlow \(action.title)", symbol: action.symbol)
            case .circular:
                ZStack {
                    Circle().fill(.fill.tertiary)
                    VStack(spacing: 1) {
                        Image(symbol: action.symbol).font(.system(size: 17, weight: .semibold)).widgetAccentable()
                        Text(action.title).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(4)
                }
            case .rectangular:
                HStack(spacing: 8) {
                    OmniWidgetPanda(fullColor: false).frame(minWidth: 30, maxWidth: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Label(action.title, symbol: action.symbol).font(.headline).lineLimit(1)
                            .minimumScaleFactor(0.8).widgetAccentable()
                        Text(action.subtitle).font(.caption).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        OmniWidgetPanda(fullColor: fullColor).frame(maxWidth: 52)
                        Spacer(minLength: 4)
                        Image(symbol: action.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(fullColor ? Color.white : palette.ink)
                            .padding(11)
                            .background(fullColor ? palette.accent : palette.ink.opacity(0.15), in: Circle())
                            .widgetAccentable()
                    }
                    Spacer(minLength: 0)
                    Text(action.title).font(heading(20)).foregroundStyle(palette.ink).lineLimit(1).minimumScaleFactor(0.7)
                    Text(action.subtitle).font(.caption).foregroundStyle(palette.muted).lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("OmniFlow \(action.title)")
    }
}

/// The Home Screen launcher: Dictate first and largest, then Translate and New
/// note. Medium is one row; large and iPad extra large add a greeting.
struct OmniQuickActionsView: View {
    let layout: OmniWidgetLayout
    var fullColor = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = OmniWidgetPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OmniWidgetPanda(fullColor: fullColor).frame(maxWidth: layout == .medium ? 30 : 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text("OmniFlow").font(heading(layout == .medium ? 15 : 19)).foregroundStyle(palette.ink)
                    if layout != .medium {
                        Text("Talk, translate or jot. It all stays on this device.")
                            .font(.caption).foregroundStyle(palette.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            if layout == .large {
                VStack(spacing: 8) {
                    tile(dictateAction, primary: true, palette: palette)
                    HStack(spacing: 8) {
                        tile(translateAction, primary: false, palette: palette)
                        tile(newNoteAction, primary: false, palette: palette)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    tile(dictateAction, primary: true, palette: palette)
                    tile(translateAction, primary: false, palette: palette)
                    tile(newNoteAction, primary: false, palette: palette)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tile<Intent: AppIntent>(_ action: OmniWidgetAction<Intent>, primary: Bool,
                                         palette: OmniWidgetPalette) -> some View {
        let roomy = layout != .medium
        let fill = primary && fullColor ? palette.accent : palette.ink.opacity(0.07)
        let foreground = primary && fullColor ? Color.white : palette.ink
        return Button(intent: action.intent) {
            VStack(alignment: .leading, spacing: 4) {
                Image(symbol: action.symbol).font(.system(size: roomy ? 20 : 17, weight: .semibold)).widgetAccentable()
                Spacer(minLength: 0)
                Text(action.title).font(.system(size: roomy ? 15 : 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                if roomy {
                    Text(action.subtitle).font(.caption2).opacity(0.75).lineLimit(2)
                }
            }
            .foregroundStyle(foreground)
            .padding(roomy ? 12 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("OmniFlow \(action.title)")
    }
}

// MARK: - Live Activity and Dynamic Island

/// Recording time: live while listening, frozen once recording stops.
struct OmniElapsedText: View {
    let startedAt: Date
    let stoppedAt: Date?
    var body: some View {
        Group {
            if let stoppedAt {
                Text(Duration.seconds(max(0, stoppedAt.timeIntervalSince(startedAt))),
                     format: .time(pattern: .minuteSecond))
            } else {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
            }
        }
        .monospacedDigit()
    }
}

struct OmniStopButton: View {
    var compact = false
    var body: some View {
        Button(intent: OmniFlowStopRecordingIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 6 : 9)
                .frame(maxWidth: compact ? nil : .infinity)
                .foregroundStyle(OmniWidgetPalette.island.paper)
                .background(OmniWidgetPalette.island.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }
}

private func phaseSymbol(_ mode: OmniFlowRecordingMode, _ phase: OmniFlowRecordingPhase) -> String {
    switch phase {
    case .listening: mode.symbol
    case .cleaning: "wand.and.sparkles"
    case .translating: "character.bubble.fill"
    case .done: "checkmark.circle.fill"
    case .ready: "keyboard"
    }
}

private func doneSummary(_ mode: OmniFlowRecordingMode, words: Int?) -> String {
    let what = mode == .dictate ? "Dictation" : "Translation"
    guard let words else { return "\(what) ready in OmniFlow" }
    return "\(what) ready · \(words.formatted()) words"
}

/// Lock Screen and the banner on devices without a Dynamic Island.
struct OmniRecordingLockScreenView: View {
    let mode: OmniFlowRecordingMode
    let state: OmniFlowRecordingContent
    private let palette = OmniWidgetPalette.island

    var body: some View {
        HStack(spacing: 14) {
            OmniWidgetPanda(cheerful: state.phase == .done).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("OmniFlow \(mode.title)").font(.caption.weight(.semibold)).foregroundStyle(palette.muted)
                Label(state.phase.title, symbol: phaseSymbol(mode, state.phase))
                    .font(heading(19)).foregroundStyle(palette.ink)
                if state.phase == .done {
                    Text(doneSummary(mode, words: state.words)).font(.caption).foregroundStyle(palette.muted)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                OmniElapsedText(startedAt: state.startedAt, stoppedAt: state.stoppedAt)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(state.phase == .listening ? palette.accent : palette.ink)
                    .frame(maxWidth: 90, alignment: .trailing)
                if state.phase == .listening { OmniStopButton(compact: true) }
            }
        }
        .padding(16)
    }
}

struct OmniIslandCompactLeading: View {
    let mode: OmniFlowRecordingMode
    let phase: OmniFlowRecordingPhase
    var body: some View {
        Image(symbol: phaseSymbol(mode, phase))
            .foregroundStyle(OmniWidgetPalette.island.accent)
            .accessibilityLabel("OmniFlow \(phase.title)")
    }
}

struct OmniIslandCompactTrailing: View {
    let state: OmniFlowRecordingContent
    var body: some View {
        OmniElapsedText(startedAt: state.startedAt, stoppedAt: state.stoppedAt)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(OmniWidgetPalette.island.ink)
            .frame(maxWidth: 44, alignment: .trailing)
    }
}

struct OmniIslandMinimal: View {
    let mode: OmniFlowRecordingMode
    let phase: OmniFlowRecordingPhase
    var body: some View {
        Image(symbol: phase == .done ? "checkmark" : mode.symbol)
            .foregroundStyle(OmniWidgetPalette.island.accent)
    }
}

/// The expanded Dynamic Island, region by region.
enum OmniIslandExpanded {
    struct Leading: View {
        let mode: OmniFlowRecordingMode
        let phase: OmniFlowRecordingPhase
        var body: some View {
            HStack(spacing: 8) {
                OmniWidgetPanda(cheerful: phase == .done).frame(width: 36, height: 36)
                Text(mode == .dictate ? "Dictate" : "Translate")
                    .font(heading(16)).foregroundStyle(OmniWidgetPalette.island.ink).lineLimit(1)
            }
        }
    }

    struct Trailing: View {
        let state: OmniFlowRecordingContent
        var body: some View {
            OmniElapsedText(startedAt: state.startedAt, stoppedAt: state.stoppedAt)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(state.phase == .listening ? OmniWidgetPalette.island.accent : OmniWidgetPalette.island.ink)
                .frame(maxWidth: 80, alignment: .trailing)
        }
    }

    struct Bottom: View {
        let mode: OmniFlowRecordingMode
        let state: OmniFlowRecordingContent
        var body: some View {
            HStack(spacing: 10) {
                Label(state.phase == .done ? doneSummary(mode, words: state.words) : state.phase.title,
                      symbol: phaseSymbol(mode, state.phase))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OmniWidgetPalette.island.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if state.phase == .listening { OmniStopButton(compact: true) }
            }
        }
    }
}

// MARK: - Data widgets (need the paid team's App Group)

struct OmniTodayStatsView: View {
    let snapshot: OmniFlowMobileSnapshot
    let layout: OmniWidgetLayout
    var fullColor = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = OmniWidgetPalette(scheme: scheme)
        switch layout {
        case .inline:
            Label("\(snapshot.wordsToday.formatted()) words · \(snapshot.streakDays)-day streak", systemImage: "flame.fill")
        case .circular:
            ZStack {
                Circle().fill(.fill.tertiary)
                VStack(spacing: 0) {
                    Image(systemName: "flame.fill").font(.system(size: 12, weight: .semibold)).widgetAccentable()
                    Text("\(snapshot.streakDays)").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("days").font(.system(size: 8, weight: .medium))
                }
            }
        case .rectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("OmniFlow today", systemImage: "text.word.spacing").font(.caption.weight(.semibold)).widgetAccentable()
                Text("\(snapshot.wordsToday.formatted()) words").font(.headline)
                Text("\(snapshot.streakDays)-day streak").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Today").font(.caption.weight(.semibold)).tracking(0.8).textCase(.uppercase)
                        .foregroundStyle(palette.muted)
                    Spacer()
                    Label("\(snapshot.streakDays)", systemImage: "flame.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(palette.accent).widgetAccentable()
                }
                Text(snapshot.wordsToday.formatted()).font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.ink).minimumScaleFactor(0.6).lineLimit(1)
                Text("words dictated").font(.caption).foregroundStyle(palette.muted)
                Spacer(minLength: 0)
                OmniWeekBars(values: snapshot.wordsLastSevenDays, palette: palette, fullColor: fullColor)
                    .frame(maxHeight: layout == .small ? 26 : 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct OmniWeekBars: View {
    let values: [Int]
    let palette: OmniWidgetPalette
    var fullColor = true
    var body: some View {
        let top = max(1, values.max() ?? 1)
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index == values.count - 1 ? palette.accent : palette.ink.opacity(0.18))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, proxy.size.height * CGFloat(value) / CGFloat(top)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .widgetAccentable(!fullColor)
        .accessibilityHidden(true)
    }
}

struct OmniRecentDictationView: View {
    let snapshot: OmniFlowMobileSnapshot
    let layout: OmniWidgetLayout
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = OmniWidgetPalette(scheme: scheme)
        if let recent = snapshot.recent {
            Button(intent: OmniFlowDictateIntent()) {
                if layout == .rectangular {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(recent.date, style: .relative).font(.caption.weight(.semibold)).widgetAccentable()
                        Text(recent.preview).font(.caption).lineLimit(3).privacySensitive()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(symbol: recent.translated ? "character.bubble.fill" : OmniFlowSymbol.dictate)
                                .foregroundStyle(palette.accent).widgetAccentable()
                            Text(recent.translated ? "Last translation" : "Last dictation")
                                .font(.caption.weight(.semibold)).foregroundStyle(palette.muted)
                            Spacer()
                            Text(recent.date, style: .relative).font(.caption2).foregroundStyle(palette.muted)
                        }
                        Text(recent.preview).font(.system(size: 15, design: .serif)).foregroundStyle(palette.ink)
                            .lineLimit(layout == .large ? 8 : 3).privacySensitive()
                        Spacer(minLength: 0)
                        HStack {
                            Text("\(recent.words.formatted()) words").font(.caption2).foregroundStyle(palette.muted)
                            Spacer()
                            Label("Dictate", symbol: OmniFlowSymbol.dictate).font(.caption.weight(.semibold))
                                .foregroundStyle(palette.accent).widgetAccentable()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .buttonStyle(.plain)
        } else {
            OmniActionWidgetView(action: dictateAction, layout: layout == .rectangular ? .rectangular : .small)
        }
    }
}

extension OmniFlowMobileSnapshot {
    static let preview = OmniFlowMobileSnapshot(
        updated: .now, wordsToday: 1_284, streakDays: 6, wordsLastSevenDays: [420, 880, 310, 1_020, 760, 1_410, 1_284],
        recent: .init(date: .now.addingTimeInterval(-12 * 60), words: 46,
                      preview: "Remind the team that the design review moved to Thursday, and bring the widget screenshots.",
                      translated: false))
}
