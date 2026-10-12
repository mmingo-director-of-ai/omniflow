import Combine
import Foundation
import WidgetKit

/// Publishes the desktop-widget snapshot. Sampling stays demand-driven: while at
/// least one OmniFlow widget is on the desktop, the publisher holds one
/// monitoring demand so the widgets have fresh data.
@MainActor
final class OmniFlowWidgetPublisher {
    static let shared = OmniFlowWidgetPublisher()
    private var subscriptions = Set<AnyCancellable>()
    private var lastReload = Date.distantPast
    private var pendingReload: Task<Void, Never>?
    private var holdsDemand = false
    private var configurationTimer: Timer?
    private let minimumReloadInterval: TimeInterval = 20

    func start() {
        guard subscriptions.isEmpty else { return }
        let monitor = OmniFlowMonitoringCoordinator.shared
        monitor.$system.dropFirst().sink { [weak self] _ in self?.publish() }.store(in: &subscriptions)
        monitor.$agents.dropFirst().sink { [weak self] _ in self?.publish() }.store(in: &subscriptions)
        monitor.$enabled.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.publish(force: true); self?.refreshDemand() }
        }.store(in: &subscriptions)
        AppModel.shared.$entries.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }.store(in: &subscriptions)
        OmniFlowFocusController.shared.settings.$enabled.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.publish(force: true) }
        }.store(in: &subscriptions)
        publish(force: true)
        refreshDemand()
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in OmniFlowWidgetPublisher.shared.refreshDemand() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        configurationTimer = timer
    }

    func stop() {
        subscriptions.removeAll()
        configurationTimer?.invalidate(); configurationTimer = nil
        pendingReload?.cancel()
        if holdsDemand { holdsDemand = false; OmniFlowMonitoringCoordinator.shared.release() }
    }

    func publish(force: Bool = false) {
        OmniFlowWidgetStore.write(Self.snapshot())
        let wait = minimumReloadInterval - Date().timeIntervalSince(lastReload)
        if force || wait <= 0 {
            pendingReload?.cancel(); pendingReload = nil
            reload()
        } else if pendingReload == nil {
            pendingReload = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                self?.pendingReload = nil
                self?.reload()
            }
        }
    }

    private func reload() {
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    /// Hold one sampling demand only while an OmniFlow widget is installed (checked every minute).
    func refreshDemand() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            let installed = (try? result.get())?.contains { $0.kind.hasPrefix("OmniFlow") } ?? false
            Task { @MainActor in
                let shared = OmniFlowWidgetPublisher.shared
                let wanted = installed && OmniFlowMonitoringCoordinator.shared.enabled
                if wanted && !shared.holdsDemand { shared.holdsDemand = true; OmniFlowMonitoringCoordinator.shared.acquire() }
                else if !wanted && shared.holdsDemand { shared.holdsDemand = false; OmniFlowMonitoringCoordinator.shared.release() }
            }
        }
    }

    static func snapshot(monitor: OmniFlowMonitoringCoordinator = .shared,
                         focusEnabled: Bool = OmniFlowFocusController.shared.enabled,
                         dictation: OmniFlowWidgetSnapshot.Dictation? = currentDictation()) -> OmniFlowWidgetSnapshot {
        let system = monitor.system.map { value in
            OmniFlowWidgetSnapshot.System(
                cpu: value.cpuUsage, cpuHistory: value.cpuHistory, memoryUsed: value.memoryUsed,
                memoryTotal: value.physicalMemory,
                diskUsed: value.diskTotal.flatMap { total in value.diskFree.map { total &- min($0, total) } },
                diskTotal: value.diskTotal, downRate: value.networkReceiveRate, upRate: value.networkTransmitRate,
                thermal: value.hardwareTelemetry.thermalCondition.rawValue)
        }
        let agents = monitor.agents.map { value in
            OmniFlowWidgetSnapshot.Agents(
                processes: value.processes.count, tokenRate: value.tokenRate,
                sessions: value.sessions.prefix(6).map {
                    .init(id: $0.id, project: $0.project, harness: $0.harness.displayName,
                          state: $0.state.rawValue, context: $0.contextFraction)
                },
                quotas: value.quotas.prefix(4).map {
                    .init(id: $0.id, label: "\($0.harness.displayName) · \($0.label)", used: $0.usedFraction, resets: $0.resetDate)
                })
        }
        return OmniFlowWidgetSnapshot(updated: Date(), monitoringEnabled: monitor.enabled, system: system,
                                      agents: agents, dictation: dictation, focusFollowsMouse: focusEnabled)
    }

    static func currentDictation() -> OmniFlowWidgetSnapshot.Dictation? {
        let model = AppModel.shared
        return .init(words: model.words, dictations: model.sessions, wordsPerMinute: model.metrics.speakingWPM)
    }
}
