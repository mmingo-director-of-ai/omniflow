import AppKit
import Combine
import SwiftUI

/// One collection owner shared by the app shell and the island carousel pages.
/// Nothing is collected, and no internet lookup happens, until monitoring is enabled.
@MainActor
final class OmniFlowMonitoringCoordinator: ObservableObject {
    static let shared = OmniFlowMonitoringCoordinator()
    @Published var enabled: Bool { didSet { save(enabled, "enabled") } }
    @Published var publicIPLookupEnabled: Bool { didSet { save(publicIPLookupEnabled, "publicIP") } }
    @Published var collectsSystem: Bool { didSet { save(collectsSystem, "system") } }
    @Published var collectsAgents: Bool { didSet { save(collectsAgents, "agents") } }
    @Published var showsNetwork: Bool { didSet { save(showsNetwork, "network") } }
    @Published var showsTaskDetails: Bool { didSet { save(showsTaskDetails, "taskDetails") } }
    @Published var systemInterval: Double { didSet { save(systemInterval, "systemInterval") } }
    @Published var agentInterval: Double { didSet { save(agentInterval, "agentInterval") } }
    @Published private(set) var system: OmniFlowSystemSnapshot?
    @Published private(set) var agents: OmniFlowAgentSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRunning = false
    private let defaults: UserDefaults
    private let systemSampler = OmniFlowSystemSampler()
    private let agentSampler: OmniFlowAgentSampler
    private var task: Task<Void, Never>?
    private var generation = 0

    init(defaults: UserDefaults = .standard,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "omniflow.monitoring." + key) as? Bool ?? fallback }
        func number(_ key: String, _ fallback: Double) -> Double {
            let value = defaults.object(forKey: "omniflow.monitoring." + key) as? Double ?? fallback
            return value.isFinite ? min(30, max(1, value)) : fallback
        }
        enabled = flag("enabled", false)
        publicIPLookupEnabled = flag("publicIP", false)
        collectsSystem = flag("system", true)
        collectsAgents = flag("agents", true)
        showsNetwork = flag("network", true)
        showsTaskDetails = flag("taskDetails", true)
        systemInterval = number("systemInterval", 2)
        agentInterval = number("agentInterval", 3)
        agentSampler = OmniFlowAgentSampler(homeDirectory: homeDirectory)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "omniflow.monitoring." + key)
        restart()
    }

    private var demand = 0

    /// Sampling follows visibility: each visible monitoring surface holds one demand.
    func acquire() { demand += 1; if demand == 1 { start() } }
    func release() { demand = max(0, demand - 1); if demand == 0 { stop() } }

    func start() { guard !isRunning else { return }; isRunning = true; restart() }
    func stop() { isRunning = false; restart(); Task { [agentSampler] in await agentSampler.suspend() } }
    func refresh() { guard enabled else { return }; if !isRunning { isRunning = true }; restart() }

    static func allowsPublicIP(enabled: Bool, collectsSystem: Bool, includesNetwork: Bool, consent: Bool) -> Bool {
        enabled && collectsSystem && includesNetwork && consent
    }

    /// Disabled categories have no deadline. A clock adjustment cannot create
    /// a busy loop or leave the sampler asleep indefinitely.
    static func nextSampleDelay(now: Date, systemDeadline: Date?, agentDeadline: Date?) -> TimeInterval? {
        guard let deadline = [systemDeadline, agentDeadline].compactMap({ $0 }).min() else { return nil }
        return min(30, max(0.05, deadline.timeIntervalSince(now)))
    }

    /// Everything a sampling tick produces. Published fields are assigned
    /// together at the end of a tick, and only when they changed, so a tick
    /// costs observers one render pass instead of one per field and await.
    private struct Snapshot: Equatable {
        var system: OmniFlowSystemSnapshot?
        var agents: OmniFlowAgentSnapshot?
        var isRefreshing = false
        var lastUpdated: Date?
    }

    private var snapshot: Snapshot {
        Snapshot(system: system, agents: agents, isRefreshing: isRefreshing, lastUpdated: lastUpdated)
    }

    private func publish(_ change: (inout Snapshot) -> Void) {
        var next = snapshot
        change(&next)
        if next.system != system { system = next.system }
        if next.agents != agents { agents = next.agents }
        if next.isRefreshing != isRefreshing { isRefreshing = next.isRefreshing }
        if next.lastUpdated != lastUpdated { lastUpdated = next.lastUpdated }
    }

    private func restart() {
        generation += 1; task?.cancel(); task = nil
        guard enabled else { publish { $0 = Snapshot() }; return }
        // Stopped surfaces keep the last snapshot so the next one paints instantly.
        guard isRunning else { publish { $0.isRefreshing = false }; return }
        publish { next in
            next.isRefreshing = false
            if !collectsSystem { next.system = nil }
            if !collectsAgents { next.agents = nil }
        }
        guard collectsSystem || collectsAgents else { return }
        let ticket = generation
        task = Task { @MainActor [weak self] in
            var nextSystem = Date.distantPast, nextAgents = Date.distantPast
            var firstTick = true
            while !Task.isCancelled {
                guard let self, self.generation == ticket, self.enabled, self.isRunning else { return }
                let now = Date()
                let systemDue = self.collectsSystem && now >= nextSystem
                let agentsDue = self.collectsAgents && now >= nextAgents
                // Only the first sample after a (re)start shows progress; periodic
                // ticks publish once, with their results.
                if firstTick && (systemDue || agentsDue) { self.publish { $0.isRefreshing = true } }
                firstTick = false
                var sampled = false
                var systemSample: OmniFlowSystemSnapshot?
                var agentSample: OmniFlowAgentSnapshot?
                if systemDue {
                    let network = self.showsNetwork
                    var sample = await self.systemSampler.sample(includeNetworkDetails: network,
                        allowPublicAddressLookup: Self.allowsPublicIP(enabled: self.enabled,
                            collectsSystem: self.collectsSystem, includesNetwork: network, consent: self.publicIPLookupEnabled))
                    guard !Task.isCancelled, self.generation == ticket else { return }
                    let previous = self.system
                    if network {
                        sample.networkReceiveHistory = Array(((previous?.networkReceiveHistory ?? []) + [sample.networkReceiveRate ?? 0]).suffix(24))
                        sample.networkTransmitHistory = Array(((previous?.networkTransmitHistory ?? []) + [sample.networkTransmitRate ?? 0]).suffix(24))
                    }
                    sample.cpuHistory = Array(((previous?.cpuHistory ?? []) + [sample.cpuUsage ?? 0]).suffix(24))
                    systemSample = sample
                    sampled = true
                    nextSystem = Date().addingTimeInterval(self.systemInterval)
                }
                if agentsDue {
                    let sample = await self.agentSampler.sample(showTaskDetails: self.showsTaskDetails)
                    guard !Task.isCancelled, self.generation == ticket else { return }
                    agentSample = sample
                    sampled = true
                    nextAgents = Date().addingTimeInterval(self.agentInterval)
                }
                if sampled {
                    self.publish { tick in
                        if let systemSample { tick.system = systemSample }
                        if let agentSample { tick.agents = agentSample }
                        tick.lastUpdated = Date()
                        tick.isRefreshing = false
                    }
                }
                guard let delay = Self.nextSampleDelay(now: Date(),
                    systemDeadline: self.collectsSystem ? nextSystem : nil,
                    agentDeadline: self.collectsAgents ? nextAgents : nil) else { return }
                // Monitoring is glanceable: let the system coalesce wakeups.
                do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(min(0.5, delay * 0.1))) } catch { return }
            }
        }
    }
}

struct OmniFlowMonitoringView: View {
    @ObservedObject var coordinator: OmniFlowMonitoringCoordinator

    init(coordinator: OmniFlowMonitoringCoordinator = .shared) {
        self.coordinator = coordinator
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader
                monitoringControl
                if let system = coordinator.system { systemDetails(system) }
                if let agents = coordinator.agents { agentDetails(agents) }
                if !coordinator.enabled {
                    emptyState("Monitoring is paused", symbol: "pause.circle",
                               detail: "Turn it on when you want a live view of your Mac and coding agents.")
                } else if !coordinator.collectsSystem && !coordinator.collectsAgents {
                    emptyState("Choose what to monitor", symbol: "slider.horizontal.3",
                               detail: "Enable system resources or coding agents in Collection below.")
                } else if coordinator.system == nil && coordinator.agents == nil {
                    emptyState("Collecting the first sample", symbol: "waveform.path",
                               detail: "Your enabled categories will appear here as their samples arrive.")
                }
                collectionSettings
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .onAppear { coordinator.acquire() }
        .onDisappear { coordinator.release() }
    }

    private var pageHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) { heading; Spacer(minLength: 8); refreshButton }
            VStack(alignment: .leading, spacing: 14) { heading; refreshButton }
        }.padding(.vertical, 18).padding(.horizontal, 16)
            .background(OmniFlowWatercolor(artwork: .monitoring))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Monitoring").font(.system(size: 32, weight: .regular, design: .serif))
            Text("A clear view of your Mac and the agents at work.")
                .font(.body).foregroundStyle(.secondary)
        }
    }

    private var refreshButton: some View {
        Button { coordinator.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .controlSize(.large)
            .disabled(!coordinator.enabled || coordinator.isRefreshing)
    }

    private var monitoringControl: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $coordinator.enabled) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Enable monitoring").font(.headline)
                        Text("Collect only the categories you choose below.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }.toggleStyle(OmniFlowSwitchStyle())
                Divider()
                HStack(spacing: 7) {
                    Circle().fill(coordinator.enabled && coordinator.isRunning ? Color.accentColor : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(samplingStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var samplingStatus: String {
        guard coordinator.enabled else { return "Collection is off" }
        guard coordinator.collectsSystem || coordinator.collectsAgents else { return "No categories selected" }
        if coordinator.isRefreshing { return "Sampling enabled categories…" }
        if let updated = coordinator.lastUpdated { return "Last sampled at \(updated.formatted(date: .omitted, time: .standard))" }
        return "Waiting for the first sample"
    }

    private var collectionSettings: some View {
        card {
            VStack(alignment: .leading, spacing: 20) {
                sectionHeading("Collection", symbol: "slider.horizontal.3", detail: "You decide what appears here.")
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("System resources", isOn: $coordinator.collectsSystem)
                        .font(.headline)
                    Text("CPU, memory, storage and thermal state.").font(.subheadline).foregroundStyle(.secondary)
                    DisclosureGroup("Network & public IP") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Local network rates and addresses", isOn: $coordinator.showsNetwork)
                                .disabled(!coordinator.collectsSystem)
                            Toggle("Look up public IP addresses", isOn: $coordinator.publicIPLookupEnabled)
                                .disabled(!coordinator.collectsSystem || !coordinator.showsNetwork)
                            Text("Public IP lookup contacts ipify.org at most every five minutes while system and network monitoring are enabled.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Coding agents", isOn: $coordinator.collectsAgents).font(.headline)
                    Text("Supported agent processes and recent local session logs.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Toggle("Show task details", isOn: $coordinator.showsTaskDetails)
                        .disabled(!coordinator.collectsAgents)
                    DisclosureGroup("What agent monitoring reads") {
                        Text("Up to eight recent Codex and eight Claude session logs, with bounded log tails. Hiding task details changes display, not collection. Other supported harnesses show process data only.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                    }
                }
                Divider()
                DisclosureGroup("Refresh intervals") {
                    VStack(alignment: .leading, spacing: 16) {
                        cadence("System", value: $coordinator.systemInterval)
                        cadence("Agents", value: $coordinator.agentInterval)
                    }.padding(.top, 14)
                }
            }
        }
    }

    private func systemDetails(_ value: OmniFlowSystemSnapshot) -> some View {
        card {
            VStack(alignment: .leading, spacing: 20) {
                sectionHeading("This Mac", symbol: "desktopcomputer",
                               detail: value.operatingSystem + (value.operatingSystemBuild.map { " (\($0))" } ?? ""))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    metric("CPU", value: percent(value.cpuUsage), detail: "Current usage", symbol: "cpu")
                    metric("Memory", value: bytes(value.memoryUsed), detail: "of \(bytes(value.physicalMemory))", symbol: "memorychip")
                    metric("Disk free", value: bytes(value.diskFree), detail: "of \(bytes(value.diskTotal))", symbol: "internaldrive")
                    metric("Thermal state", value: value.hardwareTelemetry.thermalCondition.rawValue.capitalized,
                           detail: "Reported by macOS", symbol: "thermometer.medium")
                }
                if coordinator.showsNetwork { networkDetails(value) }
                Divider()
                DisclosureGroup("System details & availability") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Computer", value: value.hostname)
                        LabeledContent("User", value: "\(value.loggedInUser) (\(value.username))")
                        LabeledContent("Uptime", value: Duration.seconds(value.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                        if !value.perCoreCPUUsage.isEmpty {
                            Text("CPU by core: " + value.perCoreCPUUsage.map { percent($0) }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("Temperature, fan RPM and power draw are unavailable through the public telemetry used here.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") { NSWorkspace.shared.open(url) } }
                            label: { Label("Open Software Update", systemImage: "arrow.up.circle") }
                    }.padding(.top, 14)
                }
            }
        }
    }

    private func networkDetails(_ value: OmniFlowSystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text("Network").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Receive", systemImage: "arrow.down").font(.subheadline).foregroundStyle(.secondary)
                    Text(rate(value.networkReceiveRate)).font(.title3.weight(.semibold)).monospacedDigit()
                    history(value.networkReceiveHistory, title: "Receive · last 24 samples")
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 9) {
                    Label("Transmit", systemImage: "arrow.up").font(.subheadline).foregroundStyle(.secondary)
                    Text(rate(value.networkTransmitRate)).font(.title3.weight(.semibold)).monospacedDigit()
                    history(value.networkTransmitHistory, title: "Transmit · last 24 samples")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Network addresses") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("LAN", value: addresses([value.lanIPv4, value.lanIPv6]))
                    if let vpn = value.vpnInterface { LabeledContent("VPN interface", value: vpn + (value.vpnAddress.map { " · \($0)" } ?? "")) }
                    if coordinator.publicIPLookupEnabled { LabeledContent("Public IP", value: addresses([value.publicIPv4, value.publicIPv6])) }
                }.padding(.top, 12)
            }
        }
    }

    private func agentDetails(_ value: OmniFlowAgentSnapshot) -> some View {
        card {
            VStack(alignment: .leading, spacing: 20) {
                sectionHeading("Coding agents", symbol: "terminal", detail: "Activity from supported processes and recent local logs.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    metric("Processes", value: value.processes.count.formatted(), detail: "Currently detected", symbol: "terminal")
                    metric("Observed tokens", value: value.tokenUsage.totalTokens.formatted(), detail: "Selected recent sessions", symbol: "text.word.spacing")
                    metric("Token rate", value: String(format: "%.1f / s", value.tokenRate), detail: "Observed log activity", symbol: "waveform.path")
                }
                history(value.tokenRateHistory, title: "Token rate · last 24 samples")
                Text("Session status is inferred. Usage covers selected recent sessions, not every project or account.")
                    .font(.caption).foregroundStyle(.secondary)
                if !value.quotas.isEmpty { quotaDetails(value) }
                if value.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No recent sessions to show", systemImage: "text.page").font(.headline)
                        Text("No readable recent agent session was found. Detected processes are still listed in Process details.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Recent sessions").font(.headline)
                        ForEach(value.sessions) { session in sessionDetails(session) }
                    }
                }
                Divider()
                DisclosureGroup("Process details (\(value.processes.count))") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(value.processes) { process in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(process.harness.displayName) · PID \(process.id)").font(.subheadline.weight(.semibold))
                                Text(String(format: "CPU %.1f%% · memory %.1f%%", process.cpuPercent, process.memoryPercent)).monospacedDigit()
                                Text("Elapsed \(Duration.seconds(process.elapsed).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if value.processes.isEmpty { Text("No supported agent process is currently detected.").foregroundStyle(.secondary) }
                        Text("Process CPU can exceed 100% when several cores are active. Only harnesses with local session-log support have token and quota details.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 14)
                }
                DisclosureGroup("Coverage & source limits") {
                    Text("Session status is inferred from process presence and log modification time. Totals cover selected recent sessions. Codex uses the latest reported cumulative totals; Claude totals cover the sampled log tail only. A bounded header and the latest 640,000 log bytes are inspected. Missing fields remain unavailable; no cloud account API is queried.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                }
            }
        }
    }

    private func quotaDetails(_ value: OmniFlowAgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reported usage limits").font(.headline)
            ForEach(value.quotas) { quota in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("\(quota.harness.displayName) · \(quota.label)").font(.subheadline)
                        Spacer(minLength: 8)
                        Text(percent(quota.usedFraction)).font(.subheadline).monospacedDigit()
                    }
                    ProgressView(value: min(1, max(0, quota.usedFraction))).tint(.accentColor)
                    if let reset = quota.resetDate { Text("Resets \(reset.formatted())").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func sessionDetails(_ session: OmniFlowAgentSessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    sessionTitle(session); Spacer(minLength: 0); sessionStatus(session.state.rawValue)
                }
                VStack(alignment: .leading, spacing: 8) { sessionTitle(session); sessionStatus(session.state.rawValue) }
            }
            Text(session.taskLabel).font(.subheadline).lineLimit(3)
            let metadata = [session.model, session.branch, session.effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !metadata.isEmpty { Text(metadata).font(.caption).foregroundStyle(.secondary) }
            if let fraction = session.contextFraction {
                ProgressView("\(session.contextIsEstimate ? "Estimated context" : "Context") \(percent(fraction))", value: min(1, max(0, fraction)))
                    .font(.caption).tint(.accentColor)
            }
            Text("Last activity \(session.lastActivity.formatted()) · \(session.tokenUsage.totalTokens.formatted()) tokens")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Session details") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Session", value: session.id)
                    LabeledContent("Working directory", value: session.workingDirectory)
                    LabeledContent("Input tokens", value: session.tokenUsage.inputTokens.formatted())
                    LabeledContent("Cached input", value: session.tokenUsage.cachedInputTokens.formatted())
                    LabeledContent("Output", value: session.tokenUsage.outputTokens.formatted())
                    LabeledContent("Reasoning", value: session.tokenUsage.reasoningTokens.formatted())
                    if let window = session.contextWindowTokens {
                        LabeledContent(session.contextIsEstimate ? "Estimated context limit" : "Reported context limit", value: window.formatted())
                    }
                    if session.contextIsEstimate {
                        Text("Claude context percentage uses the inherited 200,000-token estimate, not a verified limit for this model. Its usage totals may be partial because only the latest 640,000 log bytes are read.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Only a bounded header and the latest 640,000 log bytes are inspected. Missing fields remain unavailable; no cloud account API is queried.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 12)
            }.font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sessionTitle(_ session: OmniFlowAgentSessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.harness.displayName).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(session.project).font(.headline)
        }
    }

    private func sessionStatus(_ status: String) -> some View {
        Text(status.capitalized).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private func sectionHeading(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, value: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
    }

    private func emptyState(_ title: String, symbol: String, detail: String) -> some View {
        card {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }

    private func cadence(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text("Every \(Int(value.wrappedValue)) s").foregroundStyle(.secondary).monospacedDigit() }
                .font(.subheadline)
            Slider(value: value, in: 1...30, step: 1) { Text("\(title) refresh interval") }
        }
    }

    private func bytes(_ value: UInt64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "Unavailable"
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "Sampling…" }
    private func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max).nextDown)), countStyle: .memory) + "/s"
    }
    private func addresses(_ values: [String?]) -> String {
        let available = values.compactMap { $0 }.filter { !$0.isEmpty }
        return available.isEmpty ? "Unavailable" : available.joined(separator: " · ")
    }

    private func history(_ values: [Double], title: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 3) {
                let ceiling = max(1, values.max() ?? 1)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.55))
                        .frame(height: max(2, min(32, CGFloat(value / ceiling) * 32)))
                }
            }.frame(height: 32)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(values.count) samples")
    }
}
