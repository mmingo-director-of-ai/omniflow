import AppKit
import Foundation
import ApplicationServices

@MainActor
private final class MockFocus: OmniFlowFocusApplying {
    struct Call: Equatable { let window: OmniFlowFocusWindow; let point: CGPoint; let raise: Bool }
    var calls: [Call] = []
    var inputCalls = 0
    func focusInput(_ window: OmniFlowFocusWindow, at point: CGPoint, stillAllowed: @MainActor () -> Bool) -> Bool {
        guard stillAllowed() else { return false }; inputCalls += 1; return true
    }
    var beforeEffect: (() -> Void)?
    func focus(_ window: OmniFlowFocusWindow, at point: CGPoint, raise: Bool, stillAllowed: @MainActor () -> Bool) -> Bool {
        beforeEffect?()
        guard stillAllowed() else { return false }
        calls.append(.init(window: window, point: point, raise: raise))
        return true
    }
}

@MainActor
private final class FocusTestState {
    var permitted = true
    var replacement = false
}

@main
struct OmniFlowFocusChecks {
    @MainActor
    static func main() async throws {
        let suite = "OmniFlowFocusChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try settingsChecks(defaults)
        ownWindowOcclusionChecks()
        accessibilityWindowChecks()
        try await engineChecks(defaults)
        controllerChecks(defaults)
        attemptChecks()
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp] {
            precondition(OmniFlowFocusController.observedEventMask & (CGEventMask(1) << type.rawValue) == 0)
        }
        print("OmniFlow focus checks passed: settings round-trip, older records, ownership, nested capture leases, late focus/raise, exclusions, same-app/multidisplay coordinates, verified activation and passive input")
    }

    private static func attemptChecks() {
        typealias A = OmniFlowFocusAttempt
        precondition(A(selected: true, alreadyActive: true, frontmost: .success, activateReturned: false).requested,
                     "An already-active app needs no activation")
        precondition(A(selected: true, alreadyActive: false, frontmost: .success, activateReturned: false).requested,
                     "AXFrontmost alone is a valid activation request")
        precondition(A(selected: true, alreadyActive: false, frontmost: .cannotComplete, activateReturned: true).requested,
                     "activate() remains the fallback")
        let refused = A(selected: true, alreadyActive: false, frontmost: .cannotComplete, activateReturned: false)
        precondition(!refused.requested && refused.failure == "macOS refused to bring the app forward.")
        let unselected = A(selected: false, alreadyActive: true, frontmost: .success, activateReturned: true)
        precondition(!unselected.requested && unselected.failure != nil, "No selected window must not report success")
        precondition(A(selected: true, alreadyActive: true, frontmost: .success, activateReturned: true, raise: .cannotComplete).requested,
                     "A raise error is not fatal once the app is frontmost")
        precondition(A.verified(targetPID: 7, frontmostPID: 7) == "Last window focus succeeded")
        precondition(A.verified(targetPID: 7, frontmostPID: 8) != "Last window focus succeeded",
                     "An ignored activation must not be reported as success")
        precondition(A.verified(targetPID: 7, frontmostPID: nil) != "Last window focus succeeded")
    }

    private static func accessibilityWindowChecks() {
        struct Node {
            var pid: pid_t = 123
            var role: String = kAXGroupRole
            var subrole: String = ""
            var parent: Int?
            var window: Int?
        }
        var tree = [0: Node(parent: 1, window: 2), 1: Node(), 2: Node(role: kAXWindowRole)]
        func resolve() -> Int? {
            OmniFlowFocusWindow.resolveWindow(from: 0, expectedPID: 123,
                pid: { tree[$0]?.pid }, role: { tree[$0]?.role }, subrole: { tree[$0]?.subrole },
                window: { tree[$0]?.window }, parent: { tree[$0]?.parent }, equal: ==)
        }
        precondition(resolve() == 2, "An editor's AXWindow link must work without a complete parent chain")
        tree[1]?.subrole = kAXSecureTextFieldSubrole
        precondition(resolve() == nil, "AXWindow must not bypass a secure ancestor")
        tree[1]?.subrole = ""
        tree[1]?.role = kAXMenuItemRole
        precondition(resolve() == nil, "Menus must not trigger focus behind them")
        tree[1]?.role = kAXGroupRole
        tree[1]?.pid = 456
        precondition(resolve() == nil, "Cross-process ancestors must fail closed")
        tree[1]?.pid = 123
        tree[1]?.parent = 0
        precondition(resolve() == nil, "Cyclic AX ancestry must not hang or focus")
        tree[1]?.parent = nil
        tree[2]?.pid = 456
        precondition(resolve() == nil, "A foreign AXWindow link must be rejected")
        tree[2]?.pid = 123
        tree[1]?.parent = 2
        precondition(resolve() == 2, "Ordinary parent traversal must keep working")
    }

    @MainActor
    private static func ownWindowOcclusionChecks() {
        func entry(_ id: CGWindowID, pid: pid_t, layer: Int, rect: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: layer, kCGWindowAlpha as String: CGFloat(1),
             kCGWindowIsOnscreen as String: true,
             kCGWindowBounds as String: ["X": rect.minX, "Y": rect.minY, "Width": rect.width, "Height": rect.height]]
        }
        let screen = CGRect(x: -1200, y: -200, width: 1200, height: 900)
        let shell = entry(10, pid: 999, layer: 0, rect: screen)
        let overlay = entry(11, pid: 999, layer: 25, rect: screen)
        let app = entry(20, pid: 123, layer: 0, rect: screen)
        let point = CGPoint(x: -600, y: 100)
        let application: (pid_t) -> OmniFlowFocusWindow.Application? = { _ in
            .init(bundleID: "com.example.target", launchDate: Date(timeIntervalSince1970: 1), isRegular: true, isTerminated: false)
        }
        func pick(_ entries: [[String: Any]], ignoresMouse: Bool, visible: Bool = true) -> OmniFlowFocusWindow? {
            OmniFlowFocusWindow.select(at: point, excludingPID: 999, windows: entries,
                ownSurface: { _ in .init(isVisible: visible, ignoresMouseEvents: ignoresMouse, alpha: 1) }, application: application)
        }
        precondition(pick([shell, app], ignoresMouse: false) == nil, "Interactive shell focused the application behind it")
        precondition(pick([overlay, app], ignoresMouse: false) == nil, "Interactive floating controls failed to block underlying focus")
        precondition(pick([overlay, app], ignoresMouse: true)?.windowID == 20, "Full-screen click-through island blocked pointer focus")
        precondition(pick([overlay, shell, app], ignoresMouse: false) == nil)
        let emptyOwnMetadata = OmniFlowFocusWindow.select(at: point, excludingPID: 999, windows: [shell, app], ownSurface: { _ in nil }, application: application)
        precondition(emptyOwnMetadata == nil, "Unknown own normal window did not fail closed")
        // Other applications in front of the shell remain eligible.
        precondition(pick([app, shell], ignoresMouse: false)?.windowID == 20)
        let elsewhere = entry(12, pid: 999, layer: 0, rect: CGRect(x: 50, y: 50, width: 500, height: 500))
        precondition(pick([elsewhere, app], ignoresMouse: false)?.windowID == 20, "Own window on another display blocked this point")
        // Chrome after a self-relaunch has no LaunchServices launch date.
        let relaunched = OmniFlowFocusWindow.select(at: point, excludingPID: 999, windows: [app], ownSurface: { _ in nil }) { _ in
            .init(bundleID: "com.google.Chrome", launchDate: nil, isRegular: true, isTerminated: false)
        }
        precondition(relaunched?.windowID == 20, "An app without a launch date was skipped")
        let accessory = entry(30, pid: 456, layer: 0, rect: screen)
        let behind = OmniFlowFocusWindow.select(at: point, excludingPID: 999, windows: [accessory, app], ownSurface: { _ in nil }) { pid in
            .init(bundleID: "com.example.\(pid)", launchDate: nil, isRegular: pid == 123, isTerminated: false)
        }
        precondition(behind == nil, "An ineligible front window let focus fall through to the window behind it")
        // A Touch ID / system prompt floating over the app takes focus; other floating windows don't.
        let prompt = entry(40, pid: 777, layer: 1000, rect: CGRect(x: -700, y: 0, width: 260, height: 257))
        let promptPick = OmniFlowFocusWindow.select(at: point, excludingPID: 999, windows: [prompt, app], ownSurface: { _ in nil }) { pid in
            pid == 777 ? .init(bundleID: "com.apple.LocalAuthentication.UIAgent", launchDate: nil, isRegular: false, isTerminated: false)
                : .init(bundleID: "com.example.target", launchDate: nil, isRegular: true, isTerminated: false)
        }
        precondition(promptPick?.windowID == 40 && promptPick?.isSystemPrompt == true, "Hover did not pick the Touch ID prompt")
        let floater = OmniFlowFocusWindow.select(at: point, excludingPID: 999, windows: [prompt, app], ownSurface: { _ in nil }) { pid in
            pid == 777 ? .init(bundleID: "com.example.overlay", launchDate: nil, isRegular: false, isTerminated: false)
                : .init(bundleID: "com.example.target", launchDate: nil, isRegular: true, isTerminated: false)
        }
        precondition(floater?.windowID == 20 && floater?.isSystemPrompt == false, "A non-prompt floating window was focused or blocked the app")
    }

    @MainActor
    private static func settingsChecks(_ defaults: UserDefaults) throws {
        let settings = OmniFlowFocusSettings(defaults: defaults)
        precondition(!settings.enabled && settings.values.focusDelayMs == 200)
        precondition(!settings.values.focusInputOnHover)
        settings.values.focusInputOnHover = true
        settings.values.focusDelayMs = 5000
        precondition(settings.values.focusDelayMs == 1000, "Delays must be clamped")
        settings.values.excludedBundleIDs = ["com.example.excluded"]
        settings.enabled = true
        let restored = OmniFlowFocusSettings(defaults: defaults)
        precondition(restored.enabled && restored.values == settings.values, "Focus settings did not round-trip")

        // Records written before the HUD and import fields were removed must still load.
        let older = #"{"version":1,"enabled":true,"values":{"isEnabled":false,"focusDelayMs":10,"raiseWindow":true,"raiseDelayMs":10,"excludedBundleIDs":["com.apple.finder"],"showInDock":false,"isShortcutGuideEnabled":true,"isSystemHUDEnabled":true,"systemHUDOpacity":0.5,"agentHUDLayout":"stacked"},"legacySnapshot":{"date":0}}"#
        defaults.set(Data(older.utf8), forKey: OmniFlowFocusSettings.storageKey)
        let migrated = OmniFlowFocusSettings(defaults: defaults)
        precondition(!migrated.values.focusInputOnHover, "Old records must not enable field focus")
        precondition(migrated.storageError == nil && migrated.enabled && !migrated.values.isEnabled &&
                     migrated.values.focusDelayMs == 10 && migrated.values.excludedBundleIDs == ["com.apple.finder"],
                     "An existing focus record was lost")
        defaults.set(Data(#"{"version":1,"enabled":false,"values":{}}"#.utf8), forKey: OmniFlowFocusSettings.storageKey)
        precondition(OmniFlowFocusSettings(defaults: defaults).values == OmniFlowFocusValues(), "Missing keys must take defaults")
        defaults.removeObject(forKey: OmniFlowFocusSettings.storageKey)
    }

    @MainActor
    private static func engineChecks(_ defaults: UserDefaults) async throws {
        let settings = OmniFlowFocusSettings(defaults: defaults)
        settings.values = .init()
        settings.values.focusDelayMs = 0
        settings.values.raiseWindow = false
        settings.enabled = true
        let mock = MockFocus()
        let left = CGPoint(x: -1100, y: -200)
        let right = CGPoint(x: 400, y: 300)
        let first = OmniFlowFocusWindow(windowID: 1, ownerPID: 123, bundleID: "com.example.target", launchDate: Date(timeIntervalSince1970: 1), bounds: CGRect(x: -1200, y: -300, width: 800, height: 600))
        let second = OmniFlowFocusWindow(windowID: 2, ownerPID: 123, bundleID: "com.example.target", launchDate: first.launchDate, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let state = FocusTestState()
        var permissionProbes = 0
        let engine = OmniFlowFocusEngine(settings: settings, focuser: mock, lookup: { point, _ in
            state.replacement || point == right ? second : first
        }, ownPID: 999) { permissionProbes += 1; return state.permitted }
        defer { engine.cancelPending() }
        for _ in 0..<100 { engine.pointerEvent(.mouseMoved, at: right) }
        precondition(permissionProbes == 0, "Mouse callbacks must not run permission or app-inventory probes")
        engine.pointerEvent(.mouseMoved, at: left)
        try await waitUntil { mock.calls.count == 1 }
        engine.pointerEvent(.mouseMoved, at: right)
        try await waitUntil { mock.calls.count == 2 }
        precondition(mock.calls.map(\.window.windowID) == [1, 2] && mock.calls[0].point == left)

        // Another controller/capture begins after scheduling but before the deadline.
        engine.pointerEvent(.mouseMoved, at: left)
        state.permitted = false
        try await Task.sleep(for: .milliseconds(70))
        precondition(mock.calls.count == 2)
        state.permitted = true
        engine.pointerEvent(.mouseMoved, at: left)
        settings.enabled = false
        try await Task.sleep(for: .milliseconds(70))
        precondition(mock.calls.count == 2, "Disabled settings allowed a late focus")
        settings.enabled = true
        settings.values.excludedBundleIDs = [first.bundleID]
        engine.pointerEvent(.mouseMoved, at: left)
        try await Task.sleep(for: .milliseconds(70))
        precondition(mock.calls.count == 2)
        settings.values.excludedBundleIDs = []
        engine.pointerEvent(.mouseMoved, at: left)
        engine.pointerEvent(.leftMouseDragged, at: left)
        try await Task.sleep(for: .milliseconds(70))
        precondition(mock.calls.count == 2, "Dragging failed to cancel queued focus")

        // A lease can invalidate work even after window lookup, just before AX.
        mock.beforeEffect = { engine.cancelPending() }
        engine.pointerEvent(.mouseMoved, at: left)
        try await Task.sleep(for: .milliseconds(70))
        precondition(mock.calls.count == 2, "The late effect guard ignored an invalidated generation")
        mock.beforeEffect = nil
        settings.values.raiseWindow = true
        settings.values.raiseDelayMs = 100
        engine.pointerEvent(.mouseMoved, at: left)
        try await waitUntil { mock.calls.count == 3 }
        precondition(!mock.calls.last!.raise)
        engine.cancelPending()
        try await Task.sleep(for: .milliseconds(140))
        precondition(mock.calls.count == 3, "Capture suspension failed to cancel delayed raise")
        engine.pointerEvent(.mouseMoved, at: left)
        try await waitUntil { mock.calls.count == 4 }
        state.replacement = true
        try await Task.sleep(for: .milliseconds(140))
        precondition(mock.calls.count == 4, "Changed window identity received a delayed raise")
        state.replacement = false
        engine.pointerEvent(.mouseMoved, at: left)
        try await waitUntil { mock.calls.count == 6 }
        precondition(!mock.calls[4].raise && mock.calls[5].raise, "Delayed raise parity was lost")
        precondition(mock.inputCalls == 0, "Input focus must be opt-in")
        settings.values.raiseWindow = false
        settings.values.focusInputOnHover = true
        engine.pointerEvent(.mouseMoved, at: left)
        try await Task.sleep(for: .milliseconds(50))
        precondition(mock.inputCalls == 0, "Input focus must respect its minimum dwell")
        try await waitUntil { mock.inputCalls == 1 }
        engine.pointerEvent(.mouseMoved, at: right)
        engine.cancelPending()
        try await Task.sleep(for: .milliseconds(200))
        precondition(mock.inputCalls == 1, "Cancelled dwell must not focus an input")
    }

    @MainActor
    private static func controllerChecks(_ defaults: UserDefaults) {
        let settings = OmniFlowFocusSettings(defaults: defaults)
        settings.enabled = true
        // No live event tap or AX action: permission remains false.
        let first = OmniFlowFocusController(settings: settings, accessibilityProbe: { false })
        let second = OmniFlowFocusController(settings: settings, accessibilityProbe: { false })
        first.start()
        defer { first.stop(); second.stop() }
        precondition(!first.isActive && first.status.contains("Accessibility"))
        second.start()
        precondition(!second.isActive && second.status.contains("Another OmniFlow"))
        let voice = first.suspend(reason: "Voice capture")
        let cursor = first.suspend(reason: "Region capture")
        precondition(first.suspensionCount == 2)
        first.resume(voice)
        first.resume(voice)
        precondition(first.suspensionCount == 1)
        first.stop()
        first.start()
        precondition(first.suspensionCount == 1, "Restart discarded a live capture lease")
        first.refreshAvailability()
        precondition(!first.isActive && first.status == "Focus following is paused for: Region capture", "Status must name the live lease")
        first.resume(cursor)
        precondition(first.suspensionCount == 0 && !first.isActive && first.status.contains("Accessibility"))
    }

    @MainActor
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !predicate(), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        precondition(predicate(), "Timed out waiting for mock focus")
    }
}
