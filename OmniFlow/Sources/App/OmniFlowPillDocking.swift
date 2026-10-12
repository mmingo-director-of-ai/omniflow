import AppKit
import ColorSync
import SwiftUI

/// Only the three drop targets have windows. They never intercept input, dim
/// the desktop, activate an application or survive the drag that owns them.
@MainActor
final class OmniFlowPillDocking {
    private var zones: [String: String]
    private var displayID: String?
    private var indicators: [OmniFlowPillZone: NSPanel] = [:]
    private var candidate: (screen: NSScreen, zone: OmniFlowPillZone)?
    private let defaults: UserDefaults
    private let lease = OmniFlowInteractionLease(reason: "Moving voice pill")
    private(set) var isDragging = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        zones = defaults.dictionary(forKey: "omniflow.pill.docks") as? [String: String] ?? [:]
        displayID = defaults.string(forKey: "omniflow.pill.display")
    }

    func placement() -> (screen: NSScreen, zone: OmniFlowPillZone)? {
        guard displayID != nil else { return nil } // Preserve the old position until the first explicit move.
        guard let screen = NSScreen.screens.first(where: { Self.id($0) == displayID }) ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        return (screen, OmniFlowPillZone(rawValue: zones[Self.id(screen)] ?? "") ?? .left)
    }

    func set(_ zone: OmniFlowPillZone, on screen: NSScreen) {
        let key = Self.id(screen)
        zones[key] = zone.rawValue; displayID = key
        defaults.set(zones, forKey: "omniflow.pill.docks")
        defaults.set(key, forKey: "omniflow.pill.display")
    }

    func begin(at point: CGPoint) {
        isDragging = true; lease.begin(); update(at: point)
    }

    func update(at point: CGPoint) {
        guard isDragging, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let zone = OmniFlowQuickControlsGeometry.nearestZone(to: point, visibleFrame: screen.visibleFrame)
        guard candidate?.screen !== screen || candidate?.zone != zone || indicators.isEmpty else { return }
        candidate = (screen, zone)
        for target in OmniFlowPillZone.allCases {
            let panel = indicators[target] ?? makeIndicator()
            indicators[target] = panel
            panel.contentView = NSHostingView(rootView: PillDropTarget(zone: target, selected: target == zone))
            panel.setFrame(OmniFlowQuickControlsGeometry.zoneFrame(target, visibleFrame: screen.visibleFrame), display: true)
            panel.orderFrontRegardless()
        }
    }

    func finish(moved: Bool) {
        if moved, let candidate { set(candidate.zone, on: candidate.screen) }
        cancel()
    }

    func cancel() {
        isDragging = false; candidate = nil
        for panel in indicators.values { panel.orderOut(nil) }
        indicators.removeAll(); lease.end()
    }

    private func makeIndicator() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityElement(false)
        return panel
    }

    private static func id(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display:\(screen.localizedName)" // Only used if macOS cannot supply its stable display UUID.
    }
}

private struct PillDropTarget: View {
    let zone: OmniFlowPillZone
    let selected: Bool
    var body: some View {
        Capsule().fill(selected ? Color.white.opacity(0.95) : Color.white.opacity(0.35))
            .overlay(Capsule().strokeBorder(selected ? Color.flowAccent : .white.opacity(0.3), lineWidth: selected ? 2 : 0.5))
            .padding(2).accessibilityHidden(true)
    }
}

/// Use AppKit's native window drag loop. No global mouse hook, polling timer,
/// full-screen overlay or second focus controller is needed.
struct OmniFlowPillDragHandle: NSViewRepresentable {
    var onClick: (() -> Void)?
    func makeNSView(context: Context) -> Handle { Handle(onClick: onClick) }
    func updateNSView(_ view: Handle, context: Context) { view.onClick = onClick }

    final class Handle: NSView {
        var onClick: (() -> Void)?
        init(onClick: (() -> Void)?) { self.onClick = onClick; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let origin = window.frame.origin
            OmniFlowActivityPill.shared.beginDragging()
            window.performDrag(with: event)
            let moved = hypot(window.frame.minX - origin.x, window.frame.minY - origin.y) > 3
            OmniFlowActivityPill.shared.endDragging(moved: moved)
            if !moved { onClick?() }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
