import AppIntents
import SwiftUI
import WidgetKit

// Desktop widgets for people who prefer the essentials without the notch:
// system resources, coding agents, and quick actions. Each reads the snapshot
// the OmniFlow app publishes to the shared App Group.

struct OmniFlowEntry: TimelineEntry {
    let date: Date
    let snapshot: OmniFlowWidgetSnapshot
}

struct OmniFlowProvider: TimelineProvider {
    func placeholder(in context: Context) -> OmniFlowEntry { .init(date: .now, snapshot: .preview) }
    func getSnapshot(in context: Context, completion: @escaping (OmniFlowEntry) -> Void) {
        completion(.init(date: .now, snapshot: context.isPreview ? .preview : OmniFlowWidgetStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<OmniFlowEntry>) -> Void) {
        // The app reloads timelines when it publishes; this is only a fallback refresh.
        completion(Timeline(entries: [.init(date: .now, snapshot: OmniFlowWidgetStore.read())],
                            policy: .after(.now.addingTimeInterval(5 * 60))))
    }
}

@main
struct OmniFlowWidgetBundle: WidgetBundle {
    var body: some Widget {
        OmniFlowSystemWidget()
        OmniFlowAgentsWidget()
        OmniFlowActionsWidget()
        OmniFlowDictateControl()
        OmniFlowAskControl()
        OmniFlowFocusControl()
        OmniFlowAgentsControl()
    }
}

// MARK: - Widgets

struct OmniFlowSystemWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OmniFlowWidgetStore.kinds.system, provider: OmniFlowProvider()) { entry in
            SystemWidgetView(entry: entry).containerBackground(for: .widget) { WidgetBackdrop(artwork: "PandaMonitoringWash") }
        }
        .configurationDisplayName("OmniFlow System")
        .description("CPU, memory, disk and network at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OmniFlowAgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OmniFlowWidgetStore.kinds.agents, provider: OmniFlowProvider()) { entry in
            AgentsWidgetView(entry: entry).containerBackground(for: .widget) { WidgetBackdrop(artwork: "PandaHistoryWash") }
        }
        .configurationDisplayName("OmniFlow Agents")
        .description("Your coding agent sessions and usage limits.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct OmniFlowActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OmniFlowWidgetStore.kinds.actions, provider: OmniFlowProvider()) { entry in
            ActionsWidgetView(entry: entry).containerBackground(for: .widget) { WidgetBackdrop(artwork: "PandaDictationWash") }
        }
        .configurationDisplayName("OmniFlow")
        .description("Dictate, ask, and toggle focus follows mouse.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Views

private let accent = Color(red: 0.44, green: 0.85, blue: 0.72)

struct WidgetBackdrop: View {
    let artwork: String
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.11), Color(red: 0.06, green: 0.08, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
            Image(artwork).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 150, height: 100)
                .offset(x: 18, y: 12)
                .opacity(0.22)
                .blendMode(.screen)
        }
    }
}

struct SystemWidgetView: View {
    let entry: OmniFlowEntry
    /// Set only when rendering previews outside WidgetKit.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        if let system = entry.snapshot.system {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "System", symbol: "cpu", updated: entry.snapshot.updated)
                if family == .systemSmall {
                    Text(percent(system.cpu)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("CPU").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    meterRow("Memory", fraction: fraction(system.memoryUsed, system.memoryTotal))
                    meterRow("Disk", fraction: fraction(system.diskUsed, system.diskTotal))
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(percent(system.cpu)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("CPU · thermal \(system.thermal)").font(.caption2).foregroundStyle(.secondary)
                            WidgetSparkline(values: system.cpuHistory).frame(height: 26).padding(.top, 4)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            meterRow("Memory", fraction: fraction(system.memoryUsed, system.memoryTotal),
                                     detail: bytes(system.memoryUsed) + " of " + bytes(system.memoryTotal))
                            meterRow("Disk", fraction: fraction(system.diskUsed, system.diskTotal),
                                     detail: bytes(system.diskUsed) + " of " + bytes(system.diskTotal))
                            HStack(spacing: 10) {
                                Label(rate(system.downRate), systemImage: "arrow.down")
                                Label(rate(system.upRate), systemImage: "arrow.up")
                            }.font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(.white)
        } else {
            WidgetEmpty(monitoring: entry.snapshot.monitoringEnabled, what: "system resources")
        }
    }

    private func meterRow(_ title: String, fraction: Double?, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption2.weight(.medium))
                Spacer()
                Text(detail ?? percent(fraction)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            WidgetMeter(fraction: fraction)
        }
    }
}

struct AgentsWidgetView: View {
    let entry: OmniFlowEntry
    /// Set only when rendering previews outside WidgetKit.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        if let agents = entry.snapshot.agents {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "\(agents.processes) agents · \(String(format: "%.1f", agents.tokenRate)) tok/s",
                             symbol: "terminal", updated: entry.snapshot.updated)
                let limit = family == .systemLarge ? 6 : 2
                if agents.sessions.isEmpty {
                    Text("No recent sessions").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(agents.sessions.prefix(limit)) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(session.state == "running" ? accent : Color.gray).frame(width: 6, height: 6)
                            Text(session.project).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(session.harness + " · " + session.state).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let context = session.context { WidgetMeter(fraction: context, height: 3) }
                    }
                }
                if !agents.quotas.isEmpty {
                    Divider().overlay(Color.white.opacity(0.15))
                    ForEach(agents.quotas.prefix(family == .systemLarge ? 4 : 1)) { quota in
                        HStack(spacing: 8) {
                            Text(quota.label).font(.caption2).lineLimit(1)
                            WidgetMeter(fraction: quota.used, height: 4)
                            Text(percent(quota.used)).font(.caption2.weight(.semibold)).monospacedDigit().fixedSize()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
        } else {
            WidgetEmpty(monitoring: entry.snapshot.monitoringEnabled, what: "coding agents")
        }
    }
}

struct ActionsWidgetView: View {
    let entry: OmniFlowEntry
    /// Set only when rendering previews outside WidgetKit.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("OmniFlow").font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if let dictation = entry.snapshot.dictation, family == .systemMedium {
                    Text("\(dictation.words.formatted()) words").font(.caption2).foregroundStyle(.secondary)
                }
            }
            let columns = family == .systemSmall ? 2 : 4
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                action("Dictate", symbol: OmniFlowSymbol.dictate, intent: WidgetStartDictationIntent())
                action("Ask", symbol: "bubble.left.fill", intent: WidgetAskOmniFlowIntent())
                action("Monitor", symbol: "gauge.with.dots.needle.67percent", intent: WidgetOpenMonitoringIntent())
                action(entry.snapshot.focusFollowsMouse ? "Focus on" : "Focus off",
                       symbol: entry.snapshot.focusFollowsMouse ? "cursorarrow.motionlines" : "cursorarrow",
                       intent: WidgetToggleFocusIntent(), highlighted: entry.snapshot.focusFollowsMouse)
            }
            Spacer(minLength: 0)
            if family == .systemMedium, let dictation = entry.snapshot.dictation {
                HStack(spacing: 14) {
                    stat("\(dictation.dictations.formatted())", "dictations")
                    stat(dictation.wordsPerMinute.map { "\($0)" } ?? "—", "words / min")
                    Spacer()
                    if let system = entry.snapshot.system {
                        stat(percent(system.cpu), "CPU")
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func action<I: AppIntent>(_ title: String, symbol: String, intent: I, highlighted: Bool = false) -> some View {
        Button(intent: intent) {
            VStack(spacing: 4) {
                Image(symbol: symbol).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(highlighted ? accent.opacity(0.28) : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Pieces

struct WidgetHeader: View {
    let title: String
    let symbol: String
    let updated: Date
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption2.weight(.semibold)).foregroundStyle(accent)
            Text(title).font(.caption2.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 2)
            if Date.now.timeIntervalSince(updated) > 15 * 60 {
                Text("stale").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct WidgetEmpty: View {
    let monitoring: Bool
    let what: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.title3).foregroundStyle(accent)
            Text(monitoring ? "Waiting for OmniFlow" : "Monitoring is off").font(.caption.weight(.semibold))
            Text(monitoring ? "Open OmniFlow to start sampling \(what)." : "Turn on monitoring in OmniFlow to see \(what) here.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WidgetMeter: View {
    let fraction: Double?
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(accent).frame(width: proxy.size.width * CGFloat(min(1, max(0, fraction ?? 0))))
            }
        }
        .frame(height: height)
    }
}

struct WidgetSparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: proxy.size.width * CGFloat(index) / CGFloat(values.count - 1),
                                        y: proxy.size.height * (1 - CGFloat(min(1, max(0, value)))))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
private func fraction(_ used: UInt64?, _ total: UInt64?) -> Double? {
    guard let used, let total, total > 0 else { return nil }
    return Double(used) / Double(total)
}
private func bytes(_ value: UInt64?) -> String {
    value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
}
private func rate(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory) + "/s"
}

extension OmniFlowWidgetSnapshot {
    static let preview = OmniFlowWidgetSnapshot(
        updated: .now, monitoringEnabled: true,
        system: .init(cpu: 0.32, cpuHistory: [0.2, 0.28, 0.25, 0.4, 0.35, 0.32], memoryUsed: 22_000_000_000,
                      memoryTotal: 48_000_000_000, diskUsed: 610_000_000_000, diskTotal: 994_000_000_000,
                      downRate: 1_200_000, upRate: 80_000, thermal: "nominal"),
        agents: .init(processes: 3, tokenRate: 42, sessions: [
            .init(id: "1", project: "omniflow", harness: "Claude Code", state: "running", context: 0.42),
            .init(id: "2", project: "atlas", harness: "Codex", state: "idle", context: 0.18)],
            quotas: [.init(id: "q", label: "Codex · Weekly", used: 0.36, resets: nil)]),
        dictation: .init(words: 12_480, dictations: 214, wordsPerMinute: 148),
        focusFollowsMouse: true)
}
