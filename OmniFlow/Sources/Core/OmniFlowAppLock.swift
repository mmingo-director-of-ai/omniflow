import Combine
import Foundation
import LocalAuthentication
import SwiftUI
import os

private let lockLog = Logger(subsystem: "com.mengohlabs.NotchLee", category: "lock")

// Portable (no AppKit): shared with the iOS target, where it uses Face ID.
// Platform triggers (sleep, screen lock, activity) live in OmniFlowAppLockTriggers.

/// Optional Touch ID / password lock over OmniFlow's private content: the main
/// window, the island's assistant, memory, transcript and dictation sections,
/// and Shortcuts actions that return dictation text. Agent sessions, monitoring
/// and dictation itself keep working while locked.
@MainActor
final class OmniFlowAppLock: ObservableObject {
    static let shared = OmniFlowAppLock()
    static let enabledKey = "omniflow.lock.enabled"
    static let timeoutKey = "omniflow.lock.idleMinutes"

    @Published private(set) var isLocked = false {
        didSet { lockLog.info("lock isLocked=\(self.isLocked, privacy: .public)") }
    }
    @Published private(set) var authenticating = false
    @Published private(set) var message: String?
    /// False when this Mac has no usable Touch ID or Watch; the password sheet is used instead.
    @Published private(set) var sensorAvailable = true
    /// Changes when a fresh in-app evaluation should start (after a failed touch).
    @Published private(set) var retryToken = 0
    private var activeContext: LAContext?
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            lockLog.info("lock enabled changed to \(self.enabled, privacy: .public)")
            if !enabled { isLocked = false }
            onEnabledChange?()
        }
    }
    /// 0 = only on sleep, screen lock and quit.
    @Published var idleMinutes: Int { didSet { defaults.set(idleMinutes, forKey: Self.timeoutKey) } }

    private let defaults: UserDefaults
    private var lastActivity = Date()
    /// Platform hook, e.g. to drop dictations from Spotlight while the lock is on.
    var onEnabledChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        idleMinutes = defaults.object(forKey: Self.timeoutKey) as? Int ?? 5
        isLocked = enabled
        lockLog.info("lock init enabled=\(self.enabled, privacy: .public)")
    }

    /// Whether this device can authenticate at all (Touch ID or the account password).
    var canAuthenticate: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return "your password"
        }
    }

    /// Called by platform input monitors while the user is using OmniFlow.
    func noteActivity(_ date: Date = Date()) { lastActivity = date }

    func lock() {
        guard enabled, !isLocked else { return }
        isLocked = true
        message = nil
        retryToken &+= 1
    }

    func checkIdle(now: Date = Date()) {
        guard enabled, !isLocked, idleMinutes > 0 else { return }
        if now.timeIntervalSince(lastActivity) >= Double(idleMinutes) * 60 { lock() }
    }

    /// Biometric (or Apple Watch) evaluation drawn by an in-app sensor view that
    /// owns `context`, so no system sheet appears. One evaluation runs at a time.
    func beginEmbeddedUnlock(with context: LAContext) {
        guard isLocked else { return }
        activeContext?.invalidate()
        activeContext = context
        message = nil
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometricsOrCompanion
        guard context.canEvaluatePolicy(policy, error: &error) else {
            sensorAvailable = false
            return
        }
        sensorAvailable = true
        let id = ObjectIdentifier(context)
        context.evaluatePolicy(policy, localizedReason: "unlock your OmniFlow history and assistant") { success, error in
            let failure = (error as? LAError)?.code
            Task { @MainActor in OmniFlowAppLock.shared.finish(contextID: id, success: success, failure: failure) }
        }
    }

    /// Called when the system hands Touch ID back (wake, screen unlock, session switch back).
    func resumeAfterSystem() {
        guard isLocked, activeContext == nil else { return }
        retryToken &+= 1
    }

    private var resumeTask: Task<Void, Never>?
    private func scheduleResume(after delay: Duration) {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.resumeAfterSystem()
        }
    }

    /// Cancels the in-app evaluation when its sensor view leaves the screen.
    func endEmbeddedUnlock(_ context: LAContext) {
        guard activeContext === context else { return }
        activeContext = nil
        context.invalidate()
    }

    /// Password fallback, and the path on Macs without Touch ID: the system sheet.
    func unlockWithPassword() {
        guard isLocked, !authenticating else { return }
        if let activeContext { activeContext.invalidate(); self.activeContext = nil }
        let context = LAContext()
        context.localizedCancelTitle = "Not now"
        authenticating = true
        message = nil
        let id = ObjectIdentifier(context)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your OmniFlow history and assistant") { success, error in
            let failure = (error as? LAError)?.code
            Task { @MainActor in
                OmniFlowAppLock.shared.authenticating = false
                OmniFlowAppLock.shared.finish(contextID: id, success: success, failure: failure)
            }
        }
    }

    private func finish(contextID: ObjectIdentifier, success: Bool, failure: LAError.Code?) {
        if let activeContext, ObjectIdentifier(activeContext) == contextID { self.activeContext = nil }
        if success {
            isLocked = false
            lastActivity = Date()
            retryToken &+= 1
        } else if failure == .systemCancel || failure == .appCancel {
            // macOS takes Touch ID for its own lock screen, sleep or another app's prompt
            // and cancels ours. Start a fresh in-app evaluation once it lets go.
            if activeContext == nil { scheduleResume(after: .seconds(1.5)) }
        } else if failure == .biometryLockout {
            message = "Touch ID is locked after too many attempts. Use your password."
        } else if failure != .userCancel && failure != .appCancel && failure != .systemCancel && failure != .invalidContext {
            message = "That didn't match. Try again."
            retryToken &+= 1
        }
    }

    /// Enabling requires proving who you are first, so a passer-by can't turn it on and lock you out.
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        guard value else { enabled = false; return }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "turn on the OmniFlow lock") { success, _ in
            Task { @MainActor in
                if success { OmniFlowAppLock.shared.enabled = true; OmniFlowAppLock.shared.lastActivity = Date() }
            }
        }
    }
}

enum OmniFlowLockError: LocalizedError {
    case locked
    var errorDescription: String? { "OmniFlow is locked. Unlock it to use your dictations." }
}
