import Foundation
import CoreGraphics

@main
enum IslandScreenGeometryTests {
    static func main() {
        // Regression: absent auxiliary areas must never mean "screen-wide notch".
        for screenWidth: CGFloat in [1080, 1920, 2560, 3840] {
            let geometry = IslandScreenGeometry(
                screenWidth: screenWidth, safeAreaTop: 0,
                auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 30
            )
            precondition(!geometry.hasNotch)
            precondition(geometry.width == 80)
            precondition(geometry.height == 24)
        }

        // A shorter menu bar must also contain the resting island.
        let shortMenuBar = IslandScreenGeometry(
            screenWidth: 1920, safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 22
        )
        precondition(shortMenuBar.height == 22)

        // Real MacBook notch measurements retain their physical dimensions.
        let macBook = IslandScreenGeometry(
            screenWidth: 1512, safeAreaTop: 32,
            auxiliaryLeftWidth: 660, auxiliaryRightWidth: 660, menuBarHeight: 32
        )
        precondition(macBook.hasNotch)
        precondition(macBook.width == 192 && macBook.height == 32)

        // Incomplete or invalid measurements use the notch fallback, not the screen.
        for auxiliaryWidth: CGFloat? in [nil, 0, 1000] {
            let geometry = IslandScreenGeometry(
                screenWidth: 1512, safeAreaTop: 32,
                auxiliaryLeftWidth: auxiliaryWidth, auxiliaryRightWidth: auxiliaryWidth,
                menuBarHeight: 32
            )
            precondition(geometry.width == 184 && geometry.height == 32)
        }
        // Compact/greeting destinations share the measured resting height.
        for height: CGFloat in [22, 24, 32, 38] {
            let compact = IslandRestingLayout(width: 240, height: height)
            precondition(compact.botCenterY == height / 2)
            precondition(compact.botDiameter == min(20, height - 6))
            precondition(compact.botCenterY - compact.botDiameter / 2 >= 3)
            precondition(compact.botCenterY + compact.botDiameter / 2 <= height - 3)
            precondition(compact.miniGridCenterX == 200)
            precondition(compact.miniGridScale * 28 <= height - 4)
        }
        // Stacking must preserve the horizontal card dimensions and leave no empty slab.
        precondition(IslandSessionLayout.cardWidth * 2 + IslandSessionLayout.spacing
                     + IslandSessionLayout.padding * 2 == IslandSessionLayout.horizontalWidth)
        for (count, expectedHeight): (Int, CGFloat) in [(0, 160), (1, 160), (2, 268), (4, 484), (5, 484)] {
            let size = IslandSessionLayout.expandedSize(agentCount: count)
            precondition(size == CGSize(width: 325, height: expectedHeight))
            let firstCard = CGRect(x: 0, y: 0, width: IslandSessionLayout.cardWidth,
                                   height: IslandSessionLayout.cardHeight)
            let center = IslandSessionLayout.botCenter
            let radius = IslandSessionLayout.botDiameter / 0.6 / 2
            precondition(firstCard.contains(CGRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2)))
        }

        // Regressions: an offset valid while compact can hide an expanded island;
        // stale values from another display (including non-finite values) must stay visible.
        for panelSize in [CGSize(width: 1512, height: 982), CGSize(width: 6144, height: 3456)] {
            let bounds = CGRect(origin: .zero, size: panelSize)
            for edge in IslandEdge.allCases {
                let sizes = edge.isVertical
                    ? [IslandSessionLayout.restingSize(agentCount: 4, compact: true),
                       IslandSessionLayout.expandedSize(agentCount: 4),
                       CGSize(width: 640, height: 160)] // side-docked alert
                    : [CGSize(width: 240, height: 24), CGSize(width: 640, height: 160)]
                for size in sizes {
                    for offset: CGFloat in [-10_000, -2752, -700, 0, 700, 10_000, .nan, .infinity] {
                        let dock = IslandDockLayout(panelSize: panelSize, islandSize: size,
                                                    edge: edge, offset: offset)
                        let rect = dock.frame
                        precondition(bounds.contains(rect))
                        precondition(bounds.contains(dock.appKitFrame))
                        precondition(rect.minX == dock.appKitFrame.minX)
                        precondition(abs(rect.minY - (panelSize.height - dock.appKitFrame.maxY)) < 0.001)
                        switch edge {
                        case .top: precondition(rect.minY == 0)
                        case .bottom: precondition(rect.maxY == panelSize.height)
                        case .left: precondition(rect.minX == 0)
                        case .right: precondition(rect.maxX == panelSize.width)
                        }
                    }
                }
            }
        }

        // Arbitrary positions along every edge must survive press/drag/release unchanged.
        let panelSize = CGSize(width: 1280, height: 800)
        for edge in IslandEdge.allCases {
            let size = edge.isVertical ? IslandSessionLayout.expandedSize(agentCount: 2)
                                       : CGSize(width: 640, height: 160)
            let layout = IslandDockLayout(panelSize: panelSize, islandSize: size, edge: edge, offset: 137.25)
            let grabPoint = CGPoint(x: 0.27, y: 0.61)
            let cursor = CGPoint(x: layout.frame.minX + size.width * grabPoint.x,
                                 y: layout.frame.minY + size.height * grabPoint.y)
            precondition(abs(layout.dragOffset(cursor: cursor, grabPoint: grabPoint) - 137.25) < 0.001)
            let movedCursor = CGPoint(x: cursor.x + 13.75, y: cursor.y + 13.75)
            precondition(abs(layout.dragOffset(cursor: movedCursor, grabPoint: grabPoint) - 151) < 0.001)
        }
        for (point, edge): (CGPoint, IslandEdge) in [
            (CGPoint(x: 5, y: 377), .left), (CGPoint(x: 1275, y: 377), .right),
            (CGPoint(x: 823, y: 5), .top), (CGPoint(x: 823, y: 795), .bottom),
        ] {
            precondition(IslandEdge.nearest(to: point, in: panelSize) == edge)
        }
        print("Island screen, session card and docking geometry: passed")
    }
}
