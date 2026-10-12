import Foundation
import CoreGraphics

enum OmniFlowPillZone: String, CaseIterable, Codable, Sendable {
    case left, right, bottom

    var title: String {
        switch self { case .left: "Left edge"; case .right: "Right edge"; case .bottom: "Bottom center" }
    }
    var symbol: String {
        switch self { case .left: "sidebar.left"; case .right: "sidebar.right"; case .bottom: "rectangle.bottomthird.inset.filled" }
    }
}

/// Shared geometry for the edge tab, control strip and active conversation pill.
/// Anchors use AppKit screen coordinates: leading X and vertical midpoint.
enum OmniFlowQuickControlsGeometry {
    private static let margin: CGFloat = 8

    static func defaultAnchor(visibleFrame: CGRect) -> CGPoint {
        guard usable(visibleFrame) else { return CGPoint(x: 0, y: 0) }
        return CGPoint(x: visibleFrame.origin.x + inset(for: visibleFrame.size.width),
                       y: visibleFrame.origin.y + visibleFrame.size.height / 2)
    }

    /// Recompute the origin for every presentation size; a right/bottom dock
    /// must not drift when the recording bar expands and collapses.
    static func dockedFrame(zone: OmniFlowPillZone, size: CGSize, visibleFrame: CGRect) -> CGRect {
        guard usable(visibleFrame) else { return frame(anchor: .zero, size: size, visibleFrames: []) }
        let fitted = frame(anchor: defaultAnchor(visibleFrame: visibleFrame), size: size, visibleFrames: [visibleFrame])
        let x: CGFloat, y: CGFloat
        switch zone {
        case .left:
            x = visibleFrame.minX + inset(for: visibleFrame.width)
            y = visibleFrame.midY - fitted.height / 2
        case .right:
            x = visibleFrame.maxX - inset(for: visibleFrame.width) - fitted.width
            y = visibleFrame.midY - fitted.height / 2
        case .bottom:
            x = visibleFrame.midX - fitted.width / 2
            y = visibleFrame.minY + inset(for: visibleFrame.height)
        }
        return CGRect(x: x, y: y, width: fitted.width, height: fitted.height)
    }

    static func zoneFrame(_ zone: OmniFlowPillZone, visibleFrame: CGRect) -> CGRect {
        dockedFrame(zone: zone, size: zone == .bottom ? CGSize(width: 52, height: 24) : CGSize(width: 24, height: 52),
                    visibleFrame: visibleFrame)
    }

    /// The highlighted target is always the actual drop destination, including
    /// when dropping between targets. There is no invisible dead zone.
    static func nearestZone(to point: CGPoint, visibleFrame: CGRect) -> OmniFlowPillZone {
        guard point.x.isFinite, point.y.isFinite, usable(visibleFrame) else { return .left }
        return OmniFlowPillZone.allCases.min {
            let a = zoneFrame($0, visibleFrame: visibleFrame), b = zoneFrame($1, visibleFrame: visibleFrame)
            return hypot(point.x - a.midX, point.y - a.midY) < hypot(point.x - b.midX, point.y - b.midY)
        } ?? .left
    }

    /// The saved anchor never changes when a larger presentation needs clamping.
    /// This avoids position drift when the control strip repeatedly expands.
    static func frame(anchor: CGPoint, size: CGSize, visibleFrames: [CGRect]) -> CGRect {
        let anchor = CGPoint(x: anchor.x.isFinite ? anchor.x : 0, y: anchor.y.isFinite ? anchor.y : 0)
        let requested = CGSize(width: size.width.isFinite ? max(1, size.width) : 1,
                               height: size.height.isFinite ? max(1, size.height) : 1)
        let frames = visibleFrames.filter(usable)
        let display = frames.first(where: { contains($0, anchor) }) ?? frames.min {
            distance(from: anchor, to: $0) < distance(from: anchor, to: $1)
        }
        // A headless/transient display list has no bounds to clamp against.
        guard let display else {
            return CGRect(origin: CGPoint(x: anchor.x, y: anchor.y - requested.height / 2), size: requested)
        }
        let dx = inset(for: display.size.width), dy = inset(for: display.size.height)
        let minX = display.origin.x + dx, minY = display.origin.y + dy
        let maxX = display.origin.x + display.size.width - dx, maxY = display.origin.y + display.size.height - dy
        let width = min(requested.width, maxX - minX)
        let height = min(requested.height, maxY - minY)
        return CGRect(origin: CGPoint(x: min(max(anchor.x, minX), maxX - width),
                                      y: min(max(anchor.y - height / 2, minY), maxY - height)),
                      size: CGSize(width: width, height: height))
    }

    /// Keep an 8pt margin normally; tiny work areas must still have visible area.
    private static func inset(for length: CGFloat) -> CGFloat {
        min(margin, max(0, (length - 1) / 2))
    }

    private static func usable(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.size.width.isFinite && frame.size.height.isFinite &&
            frame.size.width > 0 && frame.size.height > 0 &&
            (frame.origin.x + frame.size.width).isFinite && (frame.origin.y + frame.size.height).isFinite
    }

    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.origin.x && point.x <= rect.origin.x + rect.size.width &&
            point.y >= rect.origin.y && point.y <= rect.origin.y + rect.size.height
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.origin.x - point.x, 0, point.x - (rect.origin.x + rect.size.width))
        let dy = max(rect.origin.y - point.y, 0, point.y - (rect.origin.y + rect.size.height))
        return hypot(dx, dy)
    }
}
