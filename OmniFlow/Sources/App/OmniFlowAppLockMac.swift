import AppKit
import Combine
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// macOS triggers for the portable OmniFlowAppLock: sleep, screen lock,
/// session switch, and activity inside OmniFlow for the idle timeout.
@MainActor
final class OmniFlowAppLockTriggers {
    static let shared = OmniFlowAppLockTriggers()
    private var subscriptions = Set<AnyCancellable>()
    private var idleTimer: Timer?
    private var activityMonitor: Any?

    func start(lock: OmniFlowAppLock = .shared) {
        guard subscriptions.isEmpty else { return }
        lock.onEnabledChange = { OmniFlowSpotlight.shared.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { _ in lock.lock() }.store(in: &subscriptions)
        }
        DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))
            .receive(on: DispatchQueue.main).sink { _ in lock.lock() }.store(in: &subscriptions)
        // After wake or unlocking the Mac, Touch ID is free again: restart the in-app sensor.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { _ in lock.resumeAfterSystem() }.store(in: &subscriptions)
        }
        DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsUnlocked"))
            .receive(on: DispatchQueue.main).sink { _ in lock.resumeAfterSystem() }.store(in: &subscriptions)
        // Local events only: activity inside OmniFlow keeps it unlocked.
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            lock.noteActivity()
            return event
        }
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { lock.checkIdle() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func stop() {
        subscriptions.removeAll()
        idleTimer?.invalidate(); idleTimer = nil
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        activityMonitor = nil
    }
}

/// Covers private content while locked. The content stays mounted but hidden
/// and inert, so unlocking returns you to exactly where you were. Touch ID is
/// read in place by the embedded sensor; no system sheet appears.
struct OmniFlowLockGate<Content: View>: View {
    @ObservedObject private var lock = OmniFlowAppLock.shared
    var compact = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            content()
                .blur(radius: lock.isLocked ? 18 : 0)
                .opacity(lock.isLocked ? 0.25 : 1)
                .allowsHitTesting(!lock.isLocked)
                .accessibilityHidden(lock.isLocked)
            if lock.isLocked {
                VStack(spacing: compact ? 10 : 14) {
                    Text("OmniFlow is locked").font(compact ? .headline : .title2.weight(.semibold))
                    if lock.sensorAvailable {
                        OmniFlowTouchIDSensor(retry: lock.retryToken)
                            .frame(width: compact ? 44 : 64, height: compact ? 44 : 64)
                            .accessibilityLabel("Touch ID sensor")
                        Text("Place your finger on Touch ID to unlock.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        Image(systemName: "lock.fill").font(.system(size: compact ? 22 : 30, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text("Your history, memory and conversations are hidden.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let message = lock.message {
                        Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                    Button(lock.sensorAvailable ? "Use password" : "Unlock with password") { lock.unlockWithPassword() }
                        .buttonStyle(lock.sensorAvailable ? AnyPrimitiveButtonStyle(.link) : AnyPrimitiveButtonStyle(.borderedProminent))
                        .disabled(lock.authenticating)
                }
                .padding(compact ? 18 : 28)
                .frame(maxWidth: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: lock.isLocked)
        .animation(.easeInOut(duration: 0.2), value: lock.message)
    }
}

/// Type-erased primitive button style so the fallback can switch emphasis.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Apple's embedded Touch ID glyph. While it is in a visible window it runs one
/// evaluation through its own LAContext, so authentication happens in OmniFlow.
struct OmniFlowTouchIDSensor: NSViewRepresentable {
    /// A new value starts a fresh evaluation (e.g. after a failed touch).
    let retry: Int

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ host: Host, context: Context) { host.update(retry: retry) }
    static func dismantleNSView(_ host: Host, coordinator: ()) { host.stop() }

    @MainActor
    final class Host: NSView {
        private var authContext: LAContext?
        private var sensor: LAAuthenticationView?
        private var retry = -1

        func update(retry: Int) {
            guard retry != self.retry else { return }
            self.retry = retry
            restart()
        }

        private var visibilityObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
            visibilityObserver = nil
            guard let window else { stop(); return }
            // Windows are often attached before they are shown; follow visibility.
            visibilityObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
            restart()
        }

        private var isShowing: Bool {
            guard let window else { return false }
            return window.isVisible && window.occlusionState.contains(.visible)
        }

        private func visibilityChanged() {
            if isShowing { if authContext == nil { restart() } } else { stop() }
        }

        private func restart() {
            stop()
            // Hidden windows (closed shell, collapsed island) must not hold the sensor.
            guard isShowing else { return }
            let context = LAContext()
            let view = LAAuthenticationView(context: context)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            authContext = context
            sensor = view
            OmniFlowAppLock.shared.beginEmbeddedUnlock(with: context)
        }

        func stop() {
            if let authContext { OmniFlowAppLock.shared.endEmbeddedUnlock(authContext) }
            sensor?.removeFromSuperview()
            sensor = nil
            authContext = nil
        }
    }
}
