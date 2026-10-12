import AppKit
import Combine
import UserNotifications

/// System notifications for ambient-rule events and agent permission requests.
/// It only observes published state, so the monitor and hook server stay unchanged.
/// Allow/Deny from a notification is an explicit click and is applied only if
/// that exact request is still pending.
@MainActor
final class OmniFlowNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OmniFlowNotifications()
    static let ambientKey = "omniflow.notify.ambient"
    static let approvalsKey = "omniflow.notify.approvals"
    private static let approvalCategory = "omniflow.approval"
    private static let ambientCategory = "omniflow.ambient"

    private var subscriptions = Set<AnyCancellable>()
    private var seenAmbient = Set<UUID>()
    private var postedApproval: UUID?

    var ambientEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.ambientKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.ambientKey); if newValue { requestAuthorization() } }
    }
    var approvalsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.approvalsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.approvalsKey); if newValue { requestAuthorization() } }
    }

    func start() {
        guard subscriptions.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive, .authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.ambientCategory, actions: [], intentIdentifiers: [])
        ])
        if ambientEnabled || approvalsEnabled { requestAuthorization() }

        // Events already present at launch are history, not news.
        seenAmbient = Set(AmbientMonitor.shared.events.map(\.id))
        AmbientMonitor.shared.$events.dropFirst().sink { [weak self] events in
            Task { @MainActor in self?.ambientChanged(events) }
        }.store(in: &subscriptions)
        AppState.shared.$pendingApproval.dropFirst().sink { [weak self] approval in
            Task { @MainActor in self?.approvalChanged(approval) }
        }.store(in: &subscriptions)
    }

    func stop() { subscriptions.removeAll() }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Sources

    private func ambientChanged(_ events: [AmbientEvent]) {
        let fresh = events.filter { !seenAmbient.contains($0.id) }
        seenAmbient.formUnion(events.map(\.id))
        guard ambientEnabled else { return }
        for event in fresh.prefix(3) {
            post(id: "ambient.\(event.id.uuidString)", title: event.title, body: event.detail, category: Self.ambientCategory)
        }
    }

    private func approvalChanged(_ approval: ApprovalInfo?) {
        if let previous = postedApproval, approval?.requestID != previous {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["approval.\(previous)"])
            postedApproval = nil
        }
        guard let approval, approvalsEnabled, postedApproval != approval.requestID else { return }
        postedApproval = approval.requestID
        let agent = AppState.shared.tasks.first { $0.id == approval.sessionId }?.name ?? "An agent"
        let completePreview = approval.command.count <= 180
        let detail = (approval.command.isEmpty ? approval.tool : String(approval.command.prefix(180)))
            + (completePreview ? "" : "… Open OmniFlow to review the full request.")
        post(id: "approval.\(approval.requestID)", title: "\(agent) needs permission",
             body: "\(approval.tool): \(detail)", category: approval.canApprove && completePreview ? Self.approvalCategory : Self.ambientCategory, sound: true,
             userInfo: ["request": approval.requestID.uuidString])
    }

    private func post(id: String, title: String, body: String, category: String, sound: Bool = false,
                      userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let request = response.notification.request.content.userInfo["request"] as? String
        await MainActor.run {
            guard let request, let requestID = UUID(uuidString: request) else { return }
            // Only answer the request this notification was about.
            guard AppState.shared.pendingApproval?.requestID == requestID else { return }
            switch action {
            case "allow": HookServer.shared.sendApprovalDecision("allow", requestID: requestID)
            case "deny": HookServer.shared.sendApprovalDecision("deny", requestID: requestID)
            default: NotificationCenter.default.post(name: .hookExpand, object: IslandView.approval)
            }
        }
    }
}
