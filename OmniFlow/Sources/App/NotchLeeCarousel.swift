import AppKit
import SwiftUI
import os

private let carouselLog = Logger(subsystem: "com.mengohlabs.NotchLee", category: "carousel")

/// The expanded island overview as a carousel: sessions first, then one
/// monitoring panel per page. Swipe left/right on the trackpad (the page follows
/// the fingers and springs into place), turn the mouse wheel, or click the dots.
/// Long-form details and settings stay on the OmniFlow Monitoring page.
struct NotchLeeCarousel: View {
    @ObservedObject var state: AppState
    @ObservedObject private var monitor = OmniFlowMonitoringCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    @State private var holdsMonitor = false
    /// While a book is open the Reader card replaces Music (one media card).
    @State private var readerActive = ReaderController.shared.isActive

    private var pages: [NotchLeePanel] { NotchLeePanel.pages(for: monitor, reader: readerActive) }
    private var index: Int { NotchLeePanel.index(of: state.carouselPanel, page: state.carouselPage, in: pages) }
    private var showsMonitoring: Bool { pages.indices.contains(index) && pages[index].isMonitoring }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width + IslandSessionLayout.spacing
            HStack(spacing: IslandSessionLayout.spacing) {
                ForEach(Array(pages.enumerated()), id: \.element) { position, panel in
                    // Only the current page and its neighbours (reachable by a drag) are built.
                    if abs(position - index) <= 1 {
                        page(panel, progress: (CGFloat(position) * width - (CGFloat(index) * width - dragOffset)) / width)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        Color.clear.frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            .offset(x: -CGFloat(index) * width + dragOffset)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .background(NotchLeeSwipeReader(onDrag: { drag($0, width: width) },
                                            onEnd: { settle(width: width) },
                                            onStep: { step($0) }))
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
        // Sessions and media pages need no samples: sample only while a monitoring page shows.
        .onAppear { holdMonitor(showsMonitoring) }
        .onChange(of: showsMonitoring) { _, showing in holdMonitor(showing) }
        .onDisappear { holdMonitor(false) }
        .onReceive(ReaderController.shared.engine.$status.receive(on: RunLoop.main).map { _ in ReaderController.shared.isActive }.removeDuplicates()) {
            readerActive = $0
        }
    }

    private func holdMonitor(_ hold: Bool) {
        guard hold != holdsMonitor else { return }
        holdsMonitor = hold
        hold ? monitor.acquire() : monitor.release()
    }

    @ViewBuilder private func page(_ panel: NotchLeePanel, progress: CGFloat) -> some View {
        switch panel {
        case .home:
            NotchLeeHomePanel(active: pages.indices.contains(index) && pages[index] == panel)
        case .sessions:
            if state.view == .empty || state.tasks.isEmpty { EmptyStateView(state: state) } else { OverviewView(state: state) }
        case .reader:
            ReaderIslandPanel()
        case .music, .weather, .news:
            // Neighbouring pages are built for the drag; only the visible one does work.
            NotchLeeMediaPanel(panel: panel, active: pages.indices.contains(index) && pages[index] == panel)
        default:
            NotchLeePanelCard(panel: panel, monitor: monitor, progress: progress)
        }
    }

    // MARK: Gesture

    private func drag(_ delta: CGFloat, width: CGFloat) {
        var next = dragOffset + delta
        // Rubber-band past the first and last page.
        if (index == 0 && next > 0) || (index == pages.count - 1 && next < 0) { next = dragOffset + delta * 0.3 }
        dragOffset = max(-width, min(width, next))
    }

    private func settle(width: CGFloat) {
        let threshold = width * 0.18
        let target = dragOffset < -threshold ? index + 1 : dragOffset > threshold ? index - 1 : index
        carouselLog.debug("settle offset=\(dragOffset, privacy: .public) index=\(index, privacy: .public) target=\(target, privacy: .public)")
        withAnimation(animation) {
            select(min(max(0, target), pages.count - 1))
            dragOffset = 0
        }
    }

    private func step(_ delta: Int) {
        let target = min(max(0, index + delta), pages.count - 1)
        withAnimation(animation) { select(target); dragOffset = 0 }
    }

    private func select(_ position: Int) {
        state.carouselPage = position
        state.carouselPanel = pages[position]
    }

    private var animation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86)
    }
}

/// Page dots in the island header, one per carousel page.
struct NotchLeeCarouselDots: View {
    @ObservedObject var state: AppState
    @ObservedObject private var monitor = OmniFlowMonitoringCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pages = NotchLeePanel.pages(for: monitor, reader: ReaderController.shared.isActive)
        let current = NotchLeePanel.index(of: state.carouselPanel, page: state.carouselPage, in: pages)
        HStack(spacing: 6) {
            ForEach(Array(pages.enumerated()), id: \.element) { position, panel in
                Button {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86)) {
                        state.carouselPage = position
                        state.carouselPanel = panel
                    }
                } label: {
                    Capsule()
                        .fill(position == current ? Color.white : Color.white.opacity(0.3))
                        .frame(width: position == current ? 14 : 6, height: 6)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .help(panel.title)
                .accessibilityLabel(panel.title)
                .accessibilityAddTraits(position == current ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: current)
    }
}

enum NotchLeePanel: String, CaseIterable, Identifiable {
    case home, sessions, reader, music, weather, news, cpu, memory, disk, network, system, agents, quotas, monitoringOff

    var id: String { rawValue }

    /// The page showing `panel` when it is present, otherwise `page` clamped.
    static func index(of panel: NotchLeePanel?, page: Int, in pages: [NotchLeePanel]) -> Int {
        if let panel, let position = pages.firstIndex(of: panel) { return position }
        return min(max(0, page), pages.count - 1)
    }

    /// Pages that read the monitoring sampler; only these hold its demand.
    var isMonitoring: Bool { ![.home, .sessions, .reader, .music, .weather, .news].contains(self) }

    static let musicKey = "omniflow.island.music", weatherKey = "omniflow.island.weather", newsKey = "omniflow.island.news"

    /// Media pages the user hasn't switched off. Music needs the direct build's private bridge.
    static func mediaPages(defaults: UserDefaults = .standard) -> [NotchLeePanel] {
        func on(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        var result: [NotchLeePanel] = []
        #if !APPSTORE
        if on(musicKey) { result.append(.music) }
        #endif
        if on(weatherKey) { result.append(.weather) }
        if on(newsKey) { result.append(.news) }
        return result
    }

    @MainActor static func pages(for monitor: OmniFlowMonitoringCoordinator, defaults: UserDefaults = .standard, reader: Bool = false) -> [NotchLeePanel] {
        // While a book is open, Reading is the first page and replaces Music.
        let lead: [NotchLeePanel] = reader ? [.reader, .home, .sessions] : [.home, .sessions]
        let media = reader ? mediaPages(defaults: defaults).filter { $0 != .music } : mediaPages(defaults: defaults)
        guard monitor.enabled else { return lead + media + [.monitoringOff] }
        var result: [NotchLeePanel] = lead + media
        let before = result.count
        if monitor.collectsSystem { result += [.cpu, .memory, .disk] + (monitor.showsNetwork ? [.network] : []) + [.system] }
        if monitor.collectsAgents { result += [.agents, .quotas] }
        return result.count == before ? result + [.monitoringOff] : result
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .sessions: "Sessions"
        case .reader: "Reading"
        case .music: "Music"
        case .weather: "Weather"
        case .news: "News"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .system: "This Mac"
        case .agents: "Agents"
        case .quotas: "Usage limits"
        case .monitoringOff: "Monitoring"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .sessions: "rectangle.stack"
        case .reader: "book"
        case .music: "music.note"
        case .weather: "cloud.sun"
        case .news: "newspaper"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .system: "desktopcomputer"
        case .agents: "terminal"
        case .quotas: "chart.bar.fill"
        case .monitoringOff: "gauge.with.dots.needle.33percent"
        }
    }

    /// Rotates through the painted artwork so neighbouring pages differ.
    var artwork: OmniFlowPageArtwork {
        switch self {
        case .cpu, .system, .monitoringOff: .monitoring
        case .memory, .agents: .dictation
        default: .history
        }
    }
}

/// One monitoring panel: Mochi keeps its place on the left, the figures sit in
/// the middle and a watercolor tile on the right pans gently as pages move.
private struct NotchLeePanelCard: View {
    let panel: NotchLeePanel
    @ObservedObject var monitor: OmniFlowMonitoringCoordinator
    /// 0 when centred; ±1 one page away. Drives the artwork parallax.
    let progress: CGFloat

    var body: some View {
        ZStack {
            CardBackground(wash: .soft)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: panel.symbol).font(.system(size: 10, weight: .semibold))
                        Text(panel.title).font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                        Spacer(minLength: 4)
                        Button { IslandWorkspace.shared.show(.system) } label: { Image(systemName: "arrow.up.forward") }
                            .buttonStyle(.press)
                            .help("Open Monitoring in OmniFlow")
                            .accessibilityLabel("Open Monitoring in OmniFlow")
                    }
                    .foregroundColor(Color(hex: "#9EA4AE"))
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                artwork
            }
            .padding(.leading, 118).padding(.trailing, 8).padding(.vertical, 8)
        }
    }

    private var artwork: some View {
        // Use the same canonical character and separate scene layers as the pages.
        OmniFlowNovaScene(artwork: panel.artwork)
            .frame(width: 210, height: 140)
            // Parallax: the painting drifts slower than the page it sits on.
            .offset(x: -32 - progress * 30, y: -6)
            .scaleEffect(1.04 - min(0.04, abs(progress) * 0.04))
            .frame(width: 112, height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .rotationEffect(.degrees(Double(progress) * -4))
            .opacity(1 - min(0.6, abs(Double(progress)) * 0.6))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch panel {
        case .cpu: cpu
        case .memory: memory
        case .disk: disk
        case .network: network
        case .system: system
        case .agents: agents
        case .quotas: quotas
        case .monitoringOff: off
        case .home, .sessions, .reader, .music, .weather, .news: EmptyView()
        }
    }

    // MARK: Panels

    @ViewBuilder private var cpu: some View {
        if let value = monitor.system {
            HStack(spacing: 14) {
                figure(percent(value.cpuUsage), caption: "\(value.perCoreCPUUsage.count) cores · thermal \(value.hardwareTelemetry.thermalCondition.rawValue)")
                VStack(spacing: 4) {
                    NotchLeeSparkline(values: value.cpuHistory, ceiling: 1).frame(height: 26)
                    if !value.perCoreCPUUsage.isEmpty {
                        HStack(alignment: .bottom, spacing: 2) {
                            ForEach(Array(value.perCoreCPUUsage.enumerated()), id: \.offset) { _, core in
                                RoundedRectangle(cornerRadius: 1.5).fill(NotchLeeTheme.accent.opacity(0.8))
                                    .frame(height: max(2, CGFloat(min(1, max(0, core))) * 14))
                            }
                        }
                        .frame(height: 14)
                        .animation(.easeOut(duration: 0.4), value: value.perCoreCPUUsage)
                    }
                }
            }
        } else { sampling }
    }

    @ViewBuilder private var memory: some View {
        if let value = monitor.system {
            let fraction = value.memoryUsed.map { Double($0) / Double(max(1, value.physicalMemory)) }
            HStack(spacing: 14) {
                figure(bytes(value.memoryUsed), caption: "of \(bytes(value.physicalMemory))")
                VStack(alignment: .leading, spacing: 6) {
                    NotchLeeMeter(fraction: fraction)
                    detail("\(percent(fraction)) in use")
                }
            }
        } else { sampling }
    }

    @ViewBuilder private var disk: some View {
        if let value = monitor.system, let total = value.diskTotal, let free = value.diskFree {
            let used = total &- min(free, total)
            HStack(spacing: 14) {
                figure(bytes(used), caption: "used of \(bytes(total))")
                VStack(alignment: .leading, spacing: 6) {
                    NotchLeeMeter(fraction: Double(used) / Double(max(1, total)))
                    detail("\(bytes(free)) free")
                    if let available = value.diskAvailable, available > free {
                        detail("\(bytes(available)) available incl. purgeable")
                    }
                }
            }
        } else if monitor.system != nil { message("Disk usage is unavailable") } else { sampling }
    }

    @ViewBuilder private var network: some View {
        if let value = monitor.system {
            HStack(spacing: 12) {
                rate("Down", symbol: "arrow.down", value: value.networkReceiveRate, history: value.networkReceiveHistory)
                rate("Up", symbol: "arrow.up", value: value.networkTransmitRate, history: value.networkTransmitHistory)
            }
        } else { sampling }
    }

    @ViewBuilder private var system: some View {
        if let value = monitor.system {
            HStack(spacing: 14) {
                figure(uptime(value.uptime), caption: "uptime")
                VStack(alignment: .leading, spacing: 3) {
                    Text(value.hostname).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    detail(value.operatingSystem)
                    detail("LAN " + (value.lanIPv4 ?? "—"))
                }
            }
        } else { sampling }
    }

    @ViewBuilder private var agents: some View {
        if let value = monitor.agents {
            HStack(alignment: .top, spacing: 14) {
                figure("\(value.processes.count)", caption: String(format: "agents · %.1f tok/s", value.tokenRate))
                VStack(alignment: .leading, spacing: 5) {
                    if value.sessions.isEmpty { detail("No recent sessions") }
                    ForEach(value.sessions.prefix(2)) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(session.project) · \(session.state.rawValue)")
                                .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            if let context = session.contextFraction { NotchLeeMeter(fraction: context, height: 3) }
                        }
                    }
                }
            }
        } else { sampling }
    }

    @ViewBuilder private var quotas: some View {
        if let value = monitor.agents {
            if value.quotas.isEmpty { message("No usage limits reported") } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(value.quotas.prefix(3)) { quota in
                        HStack(spacing: 8) {
                            Text("\(quota.harness.displayName) · \(quota.label)").font(.system(size: 10)).lineLimit(1)
                                .frame(width: 130, alignment: .leading)
                            NotchLeeMeter(fraction: quota.usedFraction, height: 4)
                            Text(percent(quota.usedFraction)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .lineLimit(1).fixedSize()
                        }
                    }
                }
            }
        } else { sampling }
    }

    private var off: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Monitoring is off").font(.system(size: 13, weight: .semibold))
                detail("See CPU, memory, disk, network and agents here.")
            }
            Spacer(minLength: 4)
            Button("Turn on") { monitor.enabled = true }.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    // MARK: Pieces

    private func figure(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(caption).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
        }
        .frame(width: 118, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func rate(_ title: String, symbol: String, value: Double?, history: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundColor(Color(hex: "#8E939C"))
                Text(rateText(value)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                    .contentTransition(.numericText())
            }
            NotchLeeSparkline(values: history, ceiling: nil).frame(height: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundColor(Color(hex: "#9398A1")).lineLimit(1).truncationMode(.middle)
    }
    private var sampling: some View { message("Collecting the first sample…") }
    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1"))
    }

    private func bytes(_ value: UInt64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
    private func rateText(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max).nextDown)), countStyle: .memory) + "/s"
    }
    private func uptime(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }
}

struct NotchLeeMeter: View {
    let fraction: Double?
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(LinearGradient(colors: [NotchLeeTheme.accent.opacity(0.75), NotchLeeTheme.accent],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, fraction ?? 0))))
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "Unavailable")
    }
}

struct NotchLeeSparkline: View {
    let values: [Double]
    /// Fixed upper bound (1 for a fraction), or nil to scale to the largest sample.
    let ceiling: Double?

    var body: some View {
        GeometryReader { proxy in
            let top = max(ceiling ?? (values.max() ?? 1), .leastNonzeroMagnitude)
            let points = values.enumerated().map { index, value in
                CGPoint(x: values.count < 2 ? 0 : proxy.size.width * CGFloat(index) / CGFloat(values.count - 1),
                        y: proxy.size.height * (1 - CGFloat(min(1, max(0, value / top)))))
            }
            ZStack {
                Path { path in
                    guard let first = points.first, let last = points.last else { return }
                    path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [NotchLeeTheme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(NotchLeeTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Reads scroll gestures that land on the carousel. A local monitor sees the
/// event before SwiftUI does, so it works over buttons and text too; it never
/// swallows events and ignores anything outside this view.
struct NotchLeeSwipeReader: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) {
        view.onDrag = onDrag; view.onEnd = onEnd; view.onStep = onStep
    }
    static func dismantleNSView(_ view: Reader, coordinator: ()) { view.removeMonitor() }

    final class Reader: NSView {
        var onDrag: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onStep: (Int) -> Void = { _ in }
        private var monitor: Any?
        private var tracking = false
        private var vertical: CGFloat = 0
        private var lastWheel = Date.distantPast

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard event.window === window else { return }
            carouselLog.debug("scroll phase=\(event.phase.rawValue, privacy: .public) momentum=\(event.momentumPhase.rawValue, privacy: .public) dx=\(event.scrollingDeltaX, privacy: .public) dy=\(event.scrollingDeltaY, privacy: .public)")
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if event.phase.isEmpty && event.momentumPhase.isEmpty {
                // Mouse wheel: one notch moves one page, either axis.
                guard inside else { return }
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                guard delta != 0, Date().timeIntervalSince(lastWheel) > 0.3 else { return }
                lastWheel = Date()
                onStep(delta < 0 ? 1 : -1)
                return
            }
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) {
                tracking = inside
                vertical = 0
            }
            guard tracking else { return }
            if event.phase.contains(.changed) || event.phase.contains(.began) {
                onDrag(event.scrollingDeltaX)
                vertical += event.scrollingDeltaY
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                tracking = false
                // A vertical two-finger scroll pages too, once it clearly dominates.
                if abs(vertical) > 40 { onStep(vertical < 0 ? 1 : -1) } else { onEnd() }
            }
        }
    }
}
