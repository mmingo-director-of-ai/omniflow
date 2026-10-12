// Pointer-focus window lookup and activation, using public macOS APIs.
// MIT License — Copyright (c) 2026 Quandry Labs
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import AppKit
@preconcurrency import ApplicationServices
import os

struct OmniFlowFocusWindow: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bundleID: String
    /// Nil for processes LaunchServices did not launch (Chrome after a self-relaunch).
    let launchDate: Date?
    let bounds: CGRect
    /// A system authentication or permission prompt (a floating window owned
    /// by a background agent), focused by activating its owner.
    var isSystemPrompt = false

    /// macOS agents that show prompts the user must answer: Touch ID / Face ID
    /// (LocalAuthentication, including requests from apps such as Secretive),
    /// password and authorization dialogs, Gatekeeper and file-open warnings,
    /// privacy and alert panels. Measured: the Touch ID sheet is owned by
    /// coreautha (com.apple.LocalAuthentication.UIAgent) at window layer 1000.
    static let systemPromptBundles: Set<String> = [
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent",
        "com.apple.UserNotificationCenter",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.CoreLocationAgent",
    ]

    struct Application {
        var bundleID: String?
        var launchDate: Date?
        var isRegular: Bool
        var isTerminated: Bool
    }

    struct OwnSurface {
        var isVisible: Bool
        var ignoresMouseEvents: Bool
        var alpha: CGFloat
    }

    /// AXWindow is the standard window link. Some
    /// editors stop their parent chain before the window. Check every exposed
    /// ancestor for secure/menu controls, then use the validated window link.
    static func resolveWindow<Node>(from hit: Node, expectedPID: pid_t,
        pid: (Node) -> pid_t?, role: (Node) -> String?, subrole: (Node) -> String?,
        window: (Node) -> Node?, parent: (Node) -> Node?, equal: (Node, Node) -> Bool) -> Node? {
        var element = hit, linkedWindow: Node?
        var visited: [Node] = []
        for _ in 0..<20 {
            guard !visited.contains(where: { equal($0, element) }), pid(element) == expectedPID else { return nil }
            visited.append(element)
            let elementRole = role(element) ?? "", elementSubrole = subrole(element) ?? ""
            if elementRole.localizedCaseInsensitiveContains("secure") || elementSubrole.localizedCaseInsensitiveContains("secure") { return nil }
            if [kAXMenuRole, kAXMenuBarRole, kAXMenuItemRole].contains(elementRole) { return nil }
            if elementRole == kAXWindowRole { return element }
            if linkedWindow == nil, let candidate = window(element), pid(candidate) == expectedPID,
               role(candidate) == kAXWindowRole { linkedWindow = candidate }
            guard let next = parent(element) else { return linkedWindow }
            element = next
        }
        return nil
    }

    @MainActor
    static func at(_ point: CGPoint, excludingPID: pid_t) -> Self? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return select(at: point, excludingPID: excludingPID, windows: windows, ownSurface: { id in
            guard let window = NSApp?.window(withWindowNumber: Int(id)) else { return nil }
            return .init(isVisible: window.isVisible, ignoresMouseEvents: window.ignoresMouseEvents, alpha: window.alphaValue)
        }, application: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return .init(bundleID: app.bundleIdentifier, launchDate: app.launchDate,
                         isRegular: app.activationPolicy == .regular, isTerminated: app.isTerminated)
        })
    }

    /// CG entries are front-to-back. An interactive own window occludes the
    /// applications below it, while the island's click-through panel does not.
    /// Injection lets regression checks exercise that traversal without live UI.
    @MainActor
    static func select(at point: CGPoint, excludingPID: pid_t, windows: [[String: Any]],
                       ownSurface: (CGWindowID) -> OwnSurface?,
                       application: (pid_t) -> Application?) -> Self? {
        for item in windows {
            guard let id = item[kCGWindowNumber as String] as? CGWindowID,
                  let pid = item[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  let layer = item[kCGWindowLayer as String] as? Int,
                  width > 1, height > 1 else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard rect.contains(point), (item[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.01,
                  item[kCGWindowIsOnscreen as String] as? Bool ?? true else { continue }
            if pid == excludingPID {
                if let surface = ownSurface(id) {
                    if surface.isVisible && !surface.ignoresMouseEvents && surface.alpha > 0.01 { return nil }
                } else if layer == 0 {
                    // A normal own window with unknown AppKit metadata fails closed.
                    return nil
                }
                continue
            }
            if layer > 0 {
                // Floating windows are skipped, except a system prompt the user must answer.
                guard let app = application(pid), let bundle = app.bundleID, !app.isTerminated,
                      systemPromptBundles.contains(bundle) else { continue }
                return .init(windowID: id, ownerPID: pid, bundleID: bundle, launchDate: app.launchDate,
                             bounds: rect, isSystemPrompt: true)
            }
            // The topmost normal window decides. An ineligible one must not let
            // focus fall through to a window hidden behind it.
            guard let app = application(pid) else { return nil }
            // Do not activate a thumbnail behind Stage Manager's interaction surface.
            if app.bundleID == "com.apple.WindowManager" { return nil }
            guard app.isRegular, !app.isTerminated, let bundle = app.bundleID else { return nil }
            return .init(windowID: id, ownerPID: pid, bundleID: bundle, launchDate: app.launchDate, bounds: rect)
        }
        return nil
    }
}

@MainActor
protocol OmniFlowFocusApplying: AnyObject {
    func focus(_ window: OmniFlowFocusWindow, at point: CGPoint, raise: Bool,
               stillAllowed: @MainActor () -> Bool) -> Bool
    func focusInput(_ window: OmniFlowFocusWindow, at point: CGPoint,
                    stillAllowed: @MainActor () -> Bool) -> Bool
}

extension OmniFlowFocusApplying {
    func focusInput(_ window: OmniFlowFocusWindow, at point: CGPoint,
                    stillAllowed: @MainActor () -> Bool) -> Bool { false }
}

/// What one focus attempt asked of the target app. Activation can still be
/// ignored afterwards (cooperative activation), so the controller verifies the
/// frontmost process before reporting success.
struct OmniFlowFocusAttempt: Equatable, Sendable {
    var selected: Bool
    var alreadyActive: Bool
    var frontmost: AXError
    var activateReturned: Bool
    var raise: AXError?

    var requested: Bool { selected && (alreadyActive || frontmost == .success || activateReturned) }

    var failure: String? {
        if !selected { return "The app would not select the window under the pointer." }
        if !requested { return "macOS refused to bring the app forward." }
        return nil
    }

    /// Raising is cosmetic once the right app is frontmost; a raise error is logged, not fatal.
    static func verified(targetPID: pid_t, frontmostPID: pid_t?) -> String {
        frontmostPID == targetPID ? "Last window focus succeeded"
            : "macOS kept another app in front. Focus did not change."
    }
}

let omniFlowFocusLog = Logger(subsystem: "com.mengohlabs.NotchLee", category: "focus")

@MainActor
final class OmniFlowFocusAX: OmniFlowFocusApplying {
    private(set) var lastFailure: String?
    private(set) var lastTargetPID: pid_t?
    /// Focus through AX only: no synthetic clicks, caret movement, or text changes.
    func focusInput(_ window: OmniFlowFocusWindow, at point: CGPoint,
                    stillAllowed: @MainActor () -> Bool) -> Bool {
        guard stillAllowed(), !window.isSystemPrompt,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.ownerPID,
              let app = NSRunningApplication(processIdentifier: window.ownerPID),
              app.bundleIdentifier == window.bundleID, app.launchDate == window.launchDate else { return false }
        let application = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success else { return false }
        var candidate = hit
        for _ in 0..<8 {
            guard let element = candidate, stillAllowed() else { return false }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == window.ownerPID else { return false }
            let role = string(kAXRoleAttribute, element) ?? ""
            let subrole = string(kAXSubroleAttribute, element) ?? ""
            if subrole.localizedCaseInsensitiveContains("secure") { return false }
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
                var editable: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable) == .success,
                      editable.boolValue else { return false }
                var focused: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focused) == .success,
                   (focused as? Bool) == true { return true }
                var settable: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success,
                      settable.boolValue, stillAllowed(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == window.ownerPID else { return false }
                return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            }
            if role == kAXWindowRole || role == kAXApplicationRole { return false }
            candidate = child(kAXParentAttribute, element)
        }
        return false
    }

    func focus(_ window: OmniFlowFocusWindow, at point: CGPoint, raise: Bool,
               stillAllowed: @MainActor () -> Bool) -> Bool {
        lastFailure = nil
        lastTargetPID = nil
        guard stillAllowed(), AXIsProcessTrusted(),
              let app = NSRunningApplication(processIdentifier: window.ownerPID), !app.isTerminated,
              window.isSystemPrompt || app.activationPolicy == .regular, app.bundleIdentifier == window.bundleID,
              app.launchDate == window.launchDate else { return false }
        if window.isSystemPrompt { return focusPrompt(window, app: app, stillAllowed: stillAllowed) }
        guard let target = accessibilityWindow(at: point, expectedPID: window.ownerPID) else {
            lastFailure = "The app did not provide a focusable window under the pointer."
            omniFlowFocusLog.info("no AX window: \(window.bundleID, privacy: .public) pid=\(window.ownerPID, privacy: .public)")
            return false
        }
        guard matchesBounds(target, expected: window.bounds) else {
            lastFailure = "The window moved before focus could change. Move the pointer and try again."
            return false
        }
        let application = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        // Each effect rechecks the suspension generation and competing owner.
        guard stillAllowed() else { return false }
        let focused = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, target)
        guard stillAllowed() else { return false }
        let main = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard stillAllowed() else { return false }
        let windowFocus = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard stillAllowed() else { return false }
        var attempt = OmniFlowFocusAttempt(selected: focused == .success || main == .success || windowFocus == .success,
                                           alreadyActive: app.isActive, frontmost: .success, activateReturned: true)
        if !attempt.alreadyActive {
            // A background agent's activate() is subject to cooperative activation
            // and may be ignored while still returning true. AXFrontmost asks the
            // target app to activate itself; activate() remains the fallback.
            attempt.frontmost = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            guard stillAllowed() else { return false }
            attempt.activateReturned = app.activate()
        }
        if raise {
            guard stillAllowed() else { return false }
            attempt.raise = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        }
        omniFlowFocusLog.info("""
            focus \(window.bundleID, privacy: .public) pid=\(window.ownerPID, privacy: .public) \
            focusedWindow=\(focused.rawValue, privacy: .public) main=\(main.rawValue, privacy: .public) \
            focused=\(windowFocus.rawValue, privacy: .public) wasActive=\(attempt.alreadyActive, privacy: .public) \
            frontmost=\(attempt.frontmost.rawValue, privacy: .public) activate=\(attempt.activateReturned, privacy: .public) \
            raise=\(attempt.raise?.rawValue ?? 0, privacy: .public)
            """)
        lastFailure = attempt.failure
        if attempt.requested { lastTargetPID = window.ownerPID }
        return attempt.requested
    }

    /// Prompts already float above everything; focusing makes them key, so Return,
    /// Escape and password typing reach them. The agent is activated directly
    /// (it has no AX window hierarchy to select a window through).
    private func focusPrompt(_ window: OmniFlowFocusWindow, app: NSRunningApplication,
                             stillAllowed: @MainActor () -> Bool) -> Bool {
        if app.isActive { lastTargetPID = window.ownerPID; return true }
        let application = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard stillAllowed() else { return false }
        let frontmost = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard stillAllowed() else { return false }
        let activated = app.activate()
        omniFlowFocusLog.info("focus prompt \(window.bundleID, privacy: .public) pid=\(window.ownerPID, privacy: .public) frontmost=\(frontmost.rawValue, privacy: .public) activate=\(activated, privacy: .public)")
        let requested = frontmost == .success || activated
        lastFailure = requested ? nil : "macOS refused to bring the prompt forward."
        if requested { lastTargetPID = window.ownerPID }
        return requested
    }

    private func accessibilityWindow(at point: CGPoint, expectedPID: pid_t) -> AXUIElement? {
        var hit: AXUIElement?
        // CG traversal has already selected the top eligible application and
        // rejected interactive own surfaces. System-wide AX hit testing can
        // otherwise hit the island's screen-sized, click-through panel instead.
        let application = AXUIElementCreateApplication(expectedPID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        return OmniFlowFocusWindow.resolveWindow(from: hit, expectedPID: expectedPID,
            pid: { element in
                AXUIElementSetMessagingTimeout(element, 0.15)
                var pid: pid_t = 0
                return AXUIElementGetPid(element, &pid) == .success ? pid : nil
            }, role: { self.string(kAXRoleAttribute, $0) }, subrole: { self.string(kAXSubroleAttribute, $0) },
            window: { self.child(kAXWindowAttribute, $0) }, parent: { self.child(kAXParentAttribute, $0) },
            equal: { CFEqual($0, $1) })
    }

    private func matchesBounds(_ window: AXUIElement, expected: CGRect) -> Bool {
        var pointValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pointValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let pointValue, CFGetTypeID(pointValue) == AXValueGetTypeID(),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return false }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(pointValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return false }
        return abs(point.x - expected.minX) <= 2 && abs(point.y - expected.minY) <= 2 &&
            abs(size.width - expected.width) <= 2 && abs(size.height - expected.height) <= 2
    }

    private func string(_ attribute: String, _ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func child(_ attribute: String, _ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
