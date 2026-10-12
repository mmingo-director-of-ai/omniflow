import Foundation
import CoreGraphics

@main
struct OmniFlowQuickControlsGeometryChecks {
    static func main() {
        let primary = rect(x: 0, y: 40, width: 1440, height: 836)
        let left = rect(x: -1920, y: -180, width: 1920, height: 1040)
        let above = rect(x: 100, y: 1000, width: 1280, height: 780)
        let idle = CGSize(width: 14, height: 52)
        let controls = CGSize(width: 48, height: 154)
        let activity = CGSize(width: 320, height: 154)

        let anchor = OmniFlowQuickControlsGeometry.defaultAnchor(visibleFrame: primary)
        precondition(anchor.x == 8 && anchor.y == 458)
        for size in [idle, controls, activity] {
            let frame = OmniFlowQuickControlsGeometry.frame(anchor: anchor, size: size, visibleFrames: [primary])
            precondition(frame.origin.x == anchor.x && frame.origin.y + frame.size.height / 2 == anchor.y && frame.size.width == size.width && frame.size.height == size.height,
                         "Expansion moved a fitting leading/midpoint anchor")
        }

        let leftAnchor = CGPoint(x: -1900, y: 100)
        let negative = OmniFlowQuickControlsGeometry.frame(anchor: leftAnchor, size: activity, visibleFrames: [primary, left, above])
        precondition(negative.origin.x == -1900 && negative.origin.y == 23 && contains(left, negative, margin: 8),
                     "A negative-origin display was treated as the primary display")

        // Containing display wins even when another display's center is nearer.
        let narrow = rect(x: 1440, y: 0, width: 100, height: 1800)
        let contained = OmniFlowQuickControlsGeometry.frame(anchor: CGPoint(x: 1450, y: 45), size: controls,
                                                           visibleFrames: [primary, narrow])
        precondition(contains(narrow, contained, margin: 8))

        // An unplugged display leaves a saved anchor: use distance to rectangles,
        // not to screen centers, then clamp onto the closest remaining work area.
        let unplugged = OmniFlowQuickControlsGeometry.frame(anchor: CGPoint(x: -1800, y: 160), size: activity,
                                                           visibleFrames: [above, primary])
        precondition(unplugged.origin.x == 8 && contains(primary, unplugged, margin: 8))
        let nearestUpper = OmniFlowQuickControlsGeometry.frame(anchor: CGPoint(x: 500, y: 950), size: controls,
                                                              visibleFrames: [primary, above])
        precondition(nearestUpper.origin.y == above.origin.y + 8, "Nearest display selection used the wrong work area")

        let edgeAnchor = CGPoint(x: primary.origin.x + primary.size.width - 16, y: primary.origin.y + primary.size.height - 4)
        let before = OmniFlowQuickControlsGeometry.frame(anchor: edgeAnchor, size: idle, visibleFrames: [primary])
        let expanded = OmniFlowQuickControlsGeometry.frame(anchor: edgeAnchor, size: activity, visibleFrames: [primary])
        let after = OmniFlowQuickControlsGeometry.frame(anchor: edgeAnchor, size: idle, visibleFrames: [primary])
        precondition(contains(primary, expanded, margin: 8))
        precondition(equal(before, after), "Expansion changed the persisted anchor or caused position drift")
        precondition(expanded.origin.x + expanded.size.width == primary.origin.x + primary.size.width - 8 && expanded.origin.y + expanded.size.height == primary.origin.y + primary.size.height - 8)

        let small = rect(x: -50, y: 25, width: 120, height: 80)
        let fitted = OmniFlowQuickControlsGeometry.frame(anchor: CGPoint(x: -42, y: 65), size: activity, visibleFrames: [small])
        precondition(equal(fitted, rect(x: -42, y: 33, width: 104, height: 64)), "Oversized expansion escaped a small work area")
        let tiny = rect(x: 20, y: 30, width: 10, height: 9)
        let tinyFrame = OmniFlowQuickControlsGeometry.frame(anchor: CGPoint(x: 0, y: 0), size: activity, visibleFrames: [tiny])
        precondition(tinyFrame.size.width > 0 && tinyFrame.size.height > 0 && contains(tiny, tinyFrame))

        let noDisplay = OmniFlowQuickControlsGeometry.frame(anchor: CGPoint(x: -5, y: 10), size: idle, visibleFrames: [])
        precondition(equal(noDisplay, rect(x: -5, y: -16, width: 14, height: 52)))
        let sanitized = OmniFlowQuickControlsGeometry.frame(anchor: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            size: CGSize(width: CGFloat.infinity, height: -1), visibleFrames: [rect(x: .infinity, y: 0, width: 0, height: 0), rect(x: 0, y: 0, width: 0, height: 0), primary])
        precondition(sanitized.size.width == 1 && sanitized.size.height == 1 && contains(primary, sanitized, margin: 8))
        for display in [primary, left, above, small, tiny] {
            for zone in OmniFlowPillZone.allCases {
                for size in [idle, controls, activity, CGSize(width: 440, height: 250)] {
                    let dock = OmniFlowQuickControlsGeometry.dockedFrame(zone: zone, size: size, visibleFrame: display)
                    precondition(contains(display, dock), "Dock escaped its display")
                    switch zone {
                    case .left: precondition(dock.midY == display.midY)
                    case .right: precondition(dock.midY == display.midY)
                    case .bottom: precondition(dock.midX == display.midX)
                    }
                }
            }
        }
        for display in [primary, left, above] {
            for zone in OmniFlowPillZone.allCases {
                let target = OmniFlowQuickControlsGeometry.zoneFrame(zone, visibleFrame: display)
                precondition(OmniFlowQuickControlsGeometry.nearestZone(to: CGPoint(x: target.midX, y: target.midY), visibleFrame: display) == zone)
                let compact = OmniFlowQuickControlsGeometry.dockedFrame(zone: zone, size: idle, visibleFrame: display)
                let recording = OmniFlowQuickControlsGeometry.dockedFrame(zone: zone, size: CGSize(width: 440, height: 250), visibleFrame: display)
                switch zone {
                case .left: precondition(compact.minX == recording.minX)
                case .right: precondition(compact.maxX == recording.maxX)
                case .bottom: precondition(compact.minY == recording.minY && compact.midX == recording.midX)
                }
            }
        }
        precondition(OmniFlowQuickControlsGeometry.nearestZone(to: CGPoint(x: CGFloat.nan, y: 0), visibleFrame: primary) == .left)
        print("OmniFlow quick-control geometry checks passed: anchors, three drop zones, edge-preserving expansion, negative displays, display recovery and small work areas")
    }

    private static func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    private static func equal(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.origin.x == rhs.origin.x && lhs.origin.y == rhs.origin.y &&
            lhs.size.width == rhs.size.width && lhs.size.height == rhs.size.height
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect, margin: CGFloat = 0) -> Bool {
        inner.origin.x >= outer.origin.x + margin && inner.origin.y >= outer.origin.y + margin &&
            inner.origin.x + inner.size.width <= outer.origin.x + outer.size.width - margin &&
            inner.origin.y + inner.size.height <= outer.origin.y + outer.size.height - margin
    }

}
