import AppKit
@preconcurrency import ApplicationServices
import Combine
import Synchronization

@MainActor
final class AgentCursor: ObservableObject {
    static let shared = AgentCursor()
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "agentCursorEnabled")
            enabled ? start() : stop()
        }
    }
    /// Republished only when the content changes; a stationary pointer re-reading
    /// the same control does not invalidate observers once a second.
    @Published private var latestContext: CursorContext?
    /// When the current content was last confirmed. Not published: it only keeps
    /// `context.capturedAt` fresh for `CursorContext.modelData`'s age limit.
    private var contextConfirmedAt: Date?
    var context: CursorContext? {
        guard var context = latestContext else { return nil }
        if let contextConfirmedAt { context.capturedAt = contextConfirmedAt }
        return context
    }
    @Published private(set) var hasAccessibility = false
    @Published private(set) var pointerUnavailable = false
    @Published var pointerScale: Double {
        didSet {
            let normalized = AgentPointerAppearance(scale: pointerScale).scale
            guard pointerScale == normalized else { pointerScale = normalized; return }
            defaults.set(pointerScale, forKey: "agentPointerScale")
            updateAppearance()
        }
    }
    @Published var pointerColorHex: String {
        didSet {
            let normalized = AgentPointerAppearance(colorHex: pointerColorHex).colorHex
            guard pointerColorHex == normalized else { pointerColorHex = normalized; return }
            defaults.set(pointerColorHex, forKey: "agentPointerColor")
            updateAppearance()
        }
    }
    private let defaults: UserDefaults
    private let pointer = AgentPointer()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var capture: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private enum Suspension { case sleep, session, display }
    private var suspensions = Set<Suspension>()
    private var suspended: Bool { !suspensions.isEmpty }
    private var lastCapture = Date.distantPast
    private var lastPointerCheck = Date.distantPast
    private var lastPosition = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "agentCursorEnabled")
        let appearance = AgentPointerAppearance(scale: defaults.object(forKey: "agentPointerScale") as? Double ?? 1,
                                                colorHex: defaults.string(forKey: "agentPointerColor") ?? "FFFFFF")
        pointerScale = appearance.scale
        pointerColorHex = appearance.colorHex
    }

    var status: String {
        if pointerUnavailable { return pointer.failure ?? "System cursor replacement is unavailable" }
        guard enabled else { return "Agent cursor off" }
        guard hasAccessibility else { return "Enable Accessibility to read what you point at" }
        return context?.summary ?? "Point at a control or select text in another app"
    }

    func launch() {
        let notifications = NSWorkspace.shared.notificationCenter
        let transitions: [(Notification.Name, Notification.Name, Suspension)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .sleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .session),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .display)
        ]
        for (pause, resume, reason) in transitions {
            notifications.publisher(for: pause).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.suspensions.insert(reason)
                self?.stop()
            }.store(in: &subscriptions)
            notifications.publisher(for: resume).receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                suspensions.remove(reason)
                if enabled { start() }
            }.store(in: &subscriptions)
        }
        notifications.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .merge(with: notifications.publisher(for: NSWorkspace.activeSpaceDidChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, enabled, !suspended else { return }
                pointerUnavailable = !pointer.refresh()
                refresh()
            }.store(in: &subscriptions)
        if enabled { start() } else { pointerUnavailable = !pointer.recover() }
    }

    func requestAccessibility() {
        #if !APPSTORE
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
        #endif
    }

    func start() {
        guard enabled, !suspended, timer == nil else { return }
        #if !APPSTORE
        hasAccessibility = AXIsProcessTrusted()
        updateAppearance()
        pointerUnavailable = !pointer.start()
        CursorActions.shared.start()
        lastPointerCheck = .now
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                          .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            // These events only sample context. WindowServer moves the real cursor itself.
            MainActor.assumeIsolated { self?.moved() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.moved() }
            return event
        }
        // Stationary context reads at 1 Hz; slow registration checks recover from an OS reset.
        let heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.moved()
                if Date().timeIntervalSince(self.lastPointerCheck) >= 5 {
                    self.lastPointerCheck = .now
                    self.pointerUnavailable = !self.pointer.refresh()
                }
                if Date().timeIntervalSince(self.lastCapture) >= 1 { self.refresh() }
            }
        }
        heartbeat.tolerance = 0.2
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
        moved()
        #endif
    }

    func stop() {
        CursorActions.shared.stop()
        pointerUnavailable = !pointer.stop()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        timer?.invalidate(); timer = nil
        capture?.cancel(); capture = nil
        setContext(nil)
        lastPosition = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    }

    private func moved() {
        guard enabled, !suspended else { return }
        let point = NSEvent.mouseLocation
        if point != lastPosition {
            lastPosition = point
            if Date().timeIntervalSince(lastCapture) > 0.35 { refresh() }
        }
    }

    private func updateAppearance() {
        pointerUnavailable = !pointer.setAppearance(AgentPointerAppearance(scale: pointerScale, colorHex: pointerColorHex))
    }

    func resetAppearance() { pointerScale = 1; pointerColorHex = "FFFFFF" }

    func snapshot(at position: CGPoint) async -> CursorContext? {
        guard AXIsProcessTrusted(), let foreground = MacContext.foregroundApp else { return nil }
        let request = CursorCaptureRequest(
            point: CursorContext.accessibilityPoint(position, primaryHeight: NSScreen.screens.first?.frame.height ?? 0),
            foregroundPID: foreground.processIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier)
        let result = await Task.detached(priority: .userInitiated) { CursorContextReader.read(request) }.value
        if case .snapshot(let snapshot) = result { return snapshot }
        return nil
    }

    func refresh() {
        guard enabled, !suspended, capture == nil else { return }
        #if !APPSTORE
        lastCapture = .now
        let trusted = AXIsProcessTrusted()
        if hasAccessibility != trusted { hasAccessibility = trusted }
        guard hasAccessibility else { setContext(nil); return }
        CursorActions.shared.start()
        guard let foreground = NSWorkspace.shared.frontmostApplication,
              foreground.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let position = NSEvent.mouseLocation
        let point = CursorContext.accessibilityPoint(position, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        let request = CursorCaptureRequest(point: point, foregroundPID: foreground.processIdentifier,
                                          ownPID: ProcessInfo.processInfo.processIdentifier)
        capture = Task { [weak self] in
            let value = await Task.detached(priority: .utility) { CursorContextReader.read(request) }.value
            guard let self, !Task.isCancelled, enabled, !suspended else { return }
            capture = nil
            switch value {
            case .ownApp: return // Keep the external context while the user moves into OmniFlow.
            case .unavailable: setContext(nil)
            case .snapshot(let snapshot): setContext(snapshot)
            }
        }
        #endif
    }

    private func setContext(_ snapshot: CursorContext?) {
        contextConfirmedAt = snapshot?.capturedAt
        guard let snapshot else {
            if latestContext != nil { latestContext = nil }
            return
        }
        if !snapshot.sameContent(as: latestContext) { latestContext = snapshot }
    }
}

private struct CursorCaptureRequest: Sendable {
    let point: CGPoint
    let foregroundPID: pid_t
    let ownPID: pid_t
}

private enum CursorCaptureResult: Sendable {
    case ownApp, unavailable, snapshot(CursorContext)
}

/// Only queries other processes off the UI thread. System-wide AX hit testing
/// can synchronously enter our own SwiftUI views before returning their PID.
private enum CursorContextReader {
    /// The window list changes far less often than the 1 Hz context reads;
    /// reuse it for up to a second. A stale owner is caught by the AX PID check.
    private static let windowCache = Mutex<(takenAt: UInt64, entries: [CursorContext.WindowEntry])?>(nil)

    static func windowEntries() -> [CursorContext.WindowEntry] {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cached = windowCache.withLock({ $0 }), now &- cached.takenAt < 1_000_000_000 {
            return cached.entries
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let entries = CursorContext.windowEntries(windows)
        windowCache.withLock { $0 = (now, entries) }
        return entries
    }

    static func read(_ request: CursorCaptureRequest) -> CursorCaptureResult {
        #if APPSTORE
        return .unavailable
        #else
        let deadline = Date().addingTimeInterval(0.6)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.08)
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func text(_ target: AXUIElement, _ name: String, limit: Int = 400) -> String {
            guard let value = attribute(target, name) as? String else { return "" }
            return String(value.prefix(limit))
        }
        func isProtected(_ target: AXUIElement) -> Bool {
            let role = text(target, kAXRoleAttribute)
            let subrole = text(target, kAXSubroleAttribute)
            return role.isEmpty || role.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("secure")
        }
        guard let targetPID = CursorContext.windowOwner(at: request.point, entries: windowEntries()) else { return .unavailable }
        // Reject ourselves BEFORE any AX call. Checking the returned element's
        // PID is too late: the hit test may already have entered AppKit off-main.
        guard targetPID != request.ownPID else { return .ownApp }
        let axApp = AXUIElementCreateApplication(targetPID)
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        var hit: AXUIElement?
        // Scope the query to this external process, even if windows move while
        // reading. Never fall back to the system-wide accessibility object.
        guard AXUIElementCopyElementAtPosition(axApp, Float(request.point.x), Float(request.point.y), &hit) == .success,
              let hit else { return .unavailable }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success else { return .unavailable }
        if pid == request.ownPID { return .ownApp }
        guard pid == targetPID else { return .unavailable }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return .unavailable }
        let bundle = app.bundleIdentifier ?? ""
        let focused = pid == request.foregroundPID ? element(attribute(axApp, kAXFocusedUIElementAttribute)) : nil
        let protectedApp = MacScreenContext.protectedApp(bundle)
        var snapshot = CursorContext(capturedAt: .now, app: app.localizedName ?? "App", bundleID: bundle,
                                     window: "", role: "", label: "", selectedText: "")
        guard !protectedApp, !isProtected(hit), !(focused.map(isProtected) ?? false) else {
            snapshot.protectedContent = true
            return .snapshot(snapshot)
        }
        snapshot.role = text(hit, kAXRoleAttribute, limit: 80)
        // Only labels/static text and deliberate selections; never whole editable-field values.
        snapshot.label = text(hit, kAXTitleAttribute)
        if snapshot.label.isEmpty { snapshot.label = text(hit, kAXDescriptionAttribute) }
        if snapshot.label.isEmpty && snapshot.role == kAXStaticTextRole { snapshot.label = text(hit, kAXValueAttribute) }
        if let focused { snapshot.selectedText = text(focused, kAXSelectedTextAttribute, limit: 1600) }
        if snapshot.selectedText.isEmpty { snapshot.selectedText = text(hit, kAXSelectedTextAttribute, limit: 1600) }
        if let window = element(attribute(hit, kAXWindowAttribute)) ?? element(attribute(axApp, kAXFocusedWindowAttribute)) {
            snapshot.window = text(window, kAXTitleAttribute, limit: 240)
        }
        return .snapshot(snapshot)
        #endif
    }
}
