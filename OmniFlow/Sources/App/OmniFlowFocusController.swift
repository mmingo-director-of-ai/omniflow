import AppKit
@preconcurrency import ApplicationServices
import Combine
import Synchronization

/// One app-owned passive event tap.
@MainActor
final class OmniFlowFocusController: ObservableObject {
    static let shared = OmniFlowFocusController()
    private static weak var owner: OmniFlowFocusController?
    let settings: OmniFlowFocusSettings
    @Published private(set) var isActive = false
    @Published private(set) var status = "Focus following is off"
    @Published private(set) var hasAccessibility = false
    @Published private(set) var suspensionCount = 0
    @Published private(set) var lastFocusResult = ""
    var enabled: Bool {
        get { settings.enabled }
        set { settings.enabled = newValue }
    }

    /// Mouse buttons are not observed, suppressed or transformed.
    static let observedEvents: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    static var observedEventMask: CGEventMask {
        observedEvents.reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }
    }

    private var started = false
    private var suspensions: [UUID: String] = [:]
    private var systemSuspensions = Set<String>()
    private var tap: OmniFlowFocusTap?
    private var subscriptions = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private let accessibilityProbe: @MainActor () -> Bool
    private let focuser = OmniFlowFocusAX()
    private var verification: Task<Void, Never>?
    private lazy var engine = OmniFlowFocusEngine(settings: settings, focuser: focuser, onFocusResult: { [weak self] success in
        self?.focusResult(success)
    }) { [weak self] in
        self?.mayAct == true && NSEvent.pressedMouseButtons == 0 &&
            NSEvent.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty
    }

    init(settings: OmniFlowFocusSettings = .shared,
         accessibilityProbe: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() }) {
        self.settings = settings
        self.accessibilityProbe = accessibilityProbe
    }

    private func focusResult(_ success: Bool) {
        verification?.cancel()
        guard success, let pid = focuser.lastTargetPID else {
            let result = focuser.lastFailure ?? "Focus paused before the window changed"
            if lastFocusResult != result { lastFocusResult = result }
            return
        }
        // A request is not a result: macOS may ignore activation. Report what is frontmost.
        verification = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            omniFlowFocusLog.info("verify target=\(pid, privacy: .public) frontmost=\(front ?? 0, privacy: .public)")
            let result = OmniFlowFocusAttempt.verified(targetPID: pid, frontmostPID: front)
            if lastFocusResult != result { lastFocusResult = result }
        }
    }

    func start() {
        guard !started else { refreshAvailability(); return }
        guard Self.owner == nil || Self.owner === self else {
            status = "Another OmniFlow focus controller already owns focus"
            return
        }
        Self.owner = self
        started = true
        settings.didChange = { [weak self] in
            self?.engine.cancelPending()
            self?.refreshAvailability()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                             NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.publisher(for: notification).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.engine.cancelPending()
                self?.refreshAvailability()
            }.store(in: &subscriptions)
        }
        let transitions: [(Notification.Name, Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display")
        ]
        for (pause, resume, reason) in transitions {
            workspace.publisher(for: pause).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.systemSuspensions.insert(reason)
                self?.engine.cancelPending()
                self?.refreshAvailability()
            }.store(in: &subscriptions)
            workspace.publisher(for: resume).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.systemSuspensions.remove(reason)
                self?.refreshAvailability()
            }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.engine.cancelPending()
                self?.refreshAvailability()
            }.store(in: &subscriptions)
        refreshAvailability()
    }

    func stop() {
        started = false
        removeTap()
        permissionTimer?.invalidate()
        permissionTimer = nil
        subscriptions.removeAll()
        if Self.owner === self { Self.owner = nil; settings.didChange = nil }
        // Active voice/cursor leases survive a controller stop/restart.
        status = "Focus following is stopped"
    }

    @discardableResult
    func suspend(reason: String) -> UUID {
        let token = UUID()
        suspensions[token] = String(reason.prefix(120))
        suspensionCount = suspensions.count
        omniFlowFocusLog.info("suspend \(reason, privacy: .public) held=\(self.suspensions.count, privacy: .public)")
        engine.cancelPending()
        refreshAvailability()
        return token
    }

    func resume(_ token: UUID) {
        guard let reason = suspensions.removeValue(forKey: token) else { return }
        suspensionCount = suspensions.count
        omniFlowFocusLog.info("resume \(reason, privacy: .public) held=\(self.suspensions.count, privacy: .public)")
        refreshAvailability()
    }

    /// Typing/clicking takes priority over a pending hover-to-input action.
    func cancelPendingInputFocus() {
        if settings.values.focusInputOnHover { engine.cancelPending() }
    }

    func requestAccessibility() {
        #if !APPSTORE
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        #endif
        refreshAvailability()
    }

    /// Re-read ownership/permission at every action, not only when a notification arrives.
    private var mayAct: Bool {
        started && Self.owner === self && suspensions.isEmpty && systemSuspensions.isEmpty &&
            accessibilityProbe()
    }

    func refreshAvailability() {
        let accessible = accessibilityProbe()
        if hasAccessibility != accessible { hasAccessibility = accessible }
        let reason: String?
        if !started { reason = "Focus following is stopped" }
        else if Self.owner !== self { reason = "Another OmniFlow focus controller owns focus" }
        else if !settings.enabled { reason = "Focus following is off. Enable it here when you want OmniFlow to own focus." }
        else if !settings.values.isEnabled { reason = "Focus following is paused" }
        else if !systemSuspensions.isEmpty { reason = "Focus following is paused while your Mac is inactive" }
        else if !suspensions.isEmpty {
            reason = "Focus following is paused for: " + Set(suspensions.values).sorted().joined(separator: ", ")
        }
        else if !hasAccessibility { reason = "Allow Accessibility to enable focus following" }
        else { reason = nil }
        if let reason {
            removeTap()
            if status != reason { status = reason }
        } else if tap != nil || installTap() {
            if !isActive { isActive = true }
            if status != "Focus follows the pointer" { status = "Focus follows the pointer" }
        } else {
            isActive = false
            status = "Pointer monitoring is unavailable. Check Accessibility and Input Monitoring in System Settings."
        }
        // Poll only while enabled and not suspended, to catch permission changes.
        // Resuming calls refreshAvailability, which restarts the poll.
        let polls = started && settings.enabled && suspensions.isEmpty && systemSuspensions.isEmpty
        if polls && permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAvailability() }
            }
            permissionTimer?.tolerance = 0.5
        } else if !polls {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    private func installTap() -> Bool {
        guard mayAct else { return false }
        let newTap = OmniFlowFocusTap(mask: Self.observedEventMask, deliver: { [weak self] type, point in
            self?.engine.pointerEvent(type, at: point)
        }, disabled: { [weak self] in
            guard let self else { return }
            engine.cancelPending()
            if mayAct, let tap { tap.enable() } else { refreshAvailability() }
        })
        guard newTap.start() else { return false }
        tap = newTap
        return true
    }

    private func removeTap() {
        engine.cancelPending()
        verification?.cancel()
        tap?.stop()
        tap = nil
        if isActive { isActive = false }
    }
}

/// A passive event tap serviced by its own thread's run loop, so pointer
/// events never queue behind main-thread work. A burst of moves is merged into
/// a single main-thread hop that delivers only the latest event; the engine
/// cancels on every event anyway, so the outcome matches per-event delivery.
final class OmniFlowFocusTap: Sendable {
    private struct Shared: ~Copyable {
        var port: CFMachPort?
        var runLoop: CFRunLoop?
        var stopped = false
        var latest: (type: CGEventType, point: CGPoint)?
        var hopQueued = false
    }

    private let mask: CGEventMask
    private let deliver: @MainActor @Sendable (CGEventType, CGPoint) -> Void
    private let disabled: @MainActor @Sendable () -> Void
    private let shared = Mutex(Shared())

    init(mask: CGEventMask, deliver: @escaping @MainActor @Sendable (CGEventType, CGPoint) -> Void,
         disabled: @escaping @MainActor @Sendable () -> Void) {
        self.mask = mask
        self.deliver = deliver
        self.disabled = disabled
    }

    /// Creates the tap synchronously (so permission failures are reported), then
    /// hands it to a dedicated thread.
    @MainActor
    func start() -> Bool {
        let created = Mutex<Bool?>(nil)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let proceed = attachToCurrentThread()
            created.withLock { $0 = proceed }
            ready.signal()
            // Returns once stop() invalidates the port (its source leaves the loop).
            // The closure keeps `self` alive until then.
            if proceed { CFRunLoopRun() }
        }
        thread.name = "OmniFlow focus tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return created.withLock { $0 } ?? false
    }

    /// Tap thread. The port and run loop are created inside the lock so they belong to it.
    private func attachToCurrentThread() -> Bool {
        shared.withLock { state -> Bool in
            guard !state.stopped,
                  let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                      options: .listenOnly, eventsOfInterest: mask,
                      callback: { _, type, event, context in
                          if let context {
                              Unmanaged<OmniFlowFocusTap>.fromOpaque(context).takeUnretainedValue()
                                  .received(type, at: event.location)
                          }
                          return Unmanaged.passUnretained(event)
                      },
                      userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port)
                return false
            }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            state.port = port
            state.runLoop = runLoop
            return true
        }
    }

    func enable() {
        shared.withLock { state in
            if let port = state.port { CGEvent.tapEnable(tap: port, enable: true) }
        }
    }

    func stop() {
        shared.withLock { state in
            state.stopped = true
            if let port = state.port {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
            if let runLoop = state.runLoop { CFRunLoopStop(runLoop) }
            state.port = nil
            state.runLoop = nil
            state.latest = nil
        }
    }

    /// Tap thread.
    private func received(_ type: CGEventType, at point: CGPoint) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    guard !shared.withLock({ $0.stopped }) else { return }
                    disabled()
                }
            }
            return
        }
        let needsHop = shared.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.latest = (type, point)
            defer { state.hopQueued = true }
            return !state.hopQueued
        }
        guard needsHop else { return }
        DispatchQueue.main.async { [self] in
            guard let event = takeLatest() else { return }
            MainActor.assumeIsolated { deliver(event.type, event.point) }
        }
    }

    private func takeLatest() -> (type: CGEventType, point: CGPoint)? {
        shared.withLock { state in
            state.hopQueued = false
            defer { state.latest = nil }
            return state.stopped ? nil : state.latest
        }
    }
}
