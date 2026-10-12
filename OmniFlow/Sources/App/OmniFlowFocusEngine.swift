// Pointer-focus debounce and delayed raise.
// MIT, Copyright 2026 Quandry Labs; full notice in OmniFlowFocusWindow.swift.
import AppKit

/// Scheduling policy is isolated from event taps and AX so tests never move real windows.
@MainActor
final class OmniFlowFocusEngine {
    typealias Lookup = @MainActor (CGPoint, pid_t) -> OmniFlowFocusWindow?
    private let settings: OmniFlowFocusSettings
    private let focuser: any OmniFlowFocusApplying
    private let lookup: Lookup
    private let canAct: @MainActor () -> Bool
    private let onFocusResult: @MainActor (Bool) -> Void
    private let ownPID: pid_t
    private var generation: UInt64 = 0
    private var pointer: CGPoint?
    /// One reusable dwell timer, re-armed per mouse move instead of a new Task per event.
    private var dwellTimer: DispatchSourceTimer?
    private var raiseTask: Task<Void, Never>?

    init(settings: OmniFlowFocusSettings, focuser: any OmniFlowFocusApplying,
         lookup: @escaping Lookup = OmniFlowFocusWindow.at,
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
         onFocusResult: @escaping @MainActor (Bool) -> Void = { _ in },
         canAct: @escaping @MainActor () -> Bool) {
        self.settings = settings
        self.focuser = focuser
        self.lookup = lookup
        self.ownPID = ownPID
        self.canAct = canAct
        self.onFocusResult = onFocusResult
    }

    isolated deinit {
        dwellTimer?.cancel()
    }

    func cancelPending() {
        generation &+= 1
        dwellTimer?.schedule(deadline: .distantFuture)
        raiseTask?.cancel()
        raiseTask = nil
        pointer = nil
    }

    func pointerEvent(_ type: CGEventType, at point: CGPoint) {
        cancelPending()
        // Called from the synchronous event tap. No app inventory, permissions,
        // window enumeration or AX work is allowed until the dwell expires.
        guard type == .mouseMoved, settings.enabled, settings.values.isEnabled else { return }
        pointer = point
        let delay = max(settings.values.focusInputOnHover ? 150 : 16, settings.values.focusDelayMs)
        dwell().schedule(deadline: .now() + .milliseconds(delay), leeway: .milliseconds(4))
    }

    private func dwell() -> DispatchSourceTimer {
        if let dwellTimer { return dwellTimer }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.dwellElapsed() }
        }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        dwellTimer = timer
        return timer
    }

    private func dwellElapsed() {
        // Any later event or cancellation re-armed or cleared the dwell; the
        // generation and pointer still guard against a stale fire.
        guard let point = pointer, current(generation, point) else { return }
        focus(at: point, ticket: generation)
    }

    private var allowed: Bool { settings.enabled && settings.values.isEnabled && canAct() }

    private func current(_ ticket: UInt64, _ point: CGPoint) -> Bool {
        generation == ticket && pointer == point && !Task.isCancelled
    }

    private func valid(_ ticket: UInt64, _ point: CGPoint) -> Bool {
        current(ticket, point) && allowed
    }

    private func eligible(at point: CGPoint) -> OmniFlowFocusWindow? {
        guard let window = lookup(point, ownPID), window.ownerPID != ownPID,
              !settings.values.excludedBundleIDs.contains(window.bundleID) else { return nil }
        return window
    }

    private func focus(at point: CGPoint, ticket: UInt64) {
        // Own shell/controls are rejected before the comparatively expensive
        // live ownership check. Recheck permission before every external effect.
        guard current(ticket, point), let target = eligible(at: point), valid(ticket, point) else { return }
        let shouldRaise = settings.values.raiseWindow
        let raiseDelay = settings.values.raiseDelayMs
        let permit: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return valid(ticket, point) && !settings.values.excludedBundleIDs.contains(target.bundleID)
        }
        let focused = focuser.focus(target, at: point, raise: shouldRaise && raiseDelay == 0, stillAllowed: permit)
        if focused, settings.values.focusInputOnHover, permit() {
            _ = focuser.focusInput(target, at: point, stillAllowed: permit)
        }
        onFocusResult(focused)
        guard focused, shouldRaise, raiseDelay > 0, permit() else { return }
        raiseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(raiseDelay)) } catch { return }
            guard let self, valid(ticket, point), settings.values.raiseWindow,
                  let current = eligible(at: point), current == target else { return }
            onFocusResult(focuser.focus(current, at: point, raise: true, stillAllowed: permit))
        }
    }
}
