import Foundation
import CoreGraphics

enum IslandEdge: String, CaseIterable {
    case top, bottom, left, right

    var isVertical: Bool { self == .left || self == .right }

    static func nearest(to point: CGPoint, in size: CGSize) -> IslandEdge {
        let distances: [(IslandEdge, CGFloat)] = [
            (.left, point.x), (.right, size.width - point.x),
            (.top, point.y), (.bottom, size.height - point.y),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .top
    }
}

/// Shared dimensions for the same session cards in either orientation.
enum IslandSessionLayout {
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 10
    static let headerHeight: CGFloat = 34
    static let headerTopPadding: CGFloat = 8
    static let headerExtent = headerTopPadding + headerHeight
    static let cardHeight: CGFloat = 98
    static let horizontalWidth: CGFloat = 640
    static let cardWidth = (horizontalWidth - padding * 2 - spacing) / 2
    static let verticalWidth = cardWidth + padding * 2
    static let botCenter = CGPoint(x: 58, y: cardHeight / 2)
    static let botDiameter: CGFloat = 58
    static let maxVisibleSessions = 4

    static func visibleCount(_ count: Int) -> Int {
        max(1, min(maxVisibleSessions, count))
    }

    static func expandedSize(agentCount: Int) -> CGSize {
        let count = CGFloat(visibleCount(agentCount))
        return CGSize(width: verticalWidth,
                      height: headerExtent + padding * 2 + count * cardHeight + (count - 1) * spacing)
    }

    static func restingSize(agentCount: Int, compact: Bool) -> CGSize {
        let count = CGFloat(visibleCount(agentCount))
        return CGSize(width: compact ? 60 : 48,
                      height: padding * 2 + count * 32 + (count - 1) * 8)
    }
}

/// Panel-local geometry in top-left coordinates, shared by SwiftUI and AppKit.
/// Clamp on every layout pass: an expansion or display change can invalidate a saved offset.
struct IslandDockLayout {
    let panelSize: CGSize
    let islandSize: CGSize
    let edge: IslandEdge
    let offset: CGFloat

    var maximumOffset: CGFloat {
        edge.isVertical
            ? max(0, (panelSize.height - islandSize.height) / 2)
            : max(0, (panelSize.width - islandSize.width) / 2)
    }

    var clampedOffset: CGFloat {
        offset.isFinite ? min(maximumOffset, max(-maximumOffset, offset)) : 0
    }

    var frame: CGRect {
        let centeredX = (panelSize.width - islandSize.width) / 2
        let centeredY = (panelSize.height - islandSize.height) / 2
        let origin: CGPoint
        switch edge {
        case .top: origin = CGPoint(x: centeredX + clampedOffset, y: 0)
        case .bottom: origin = CGPoint(x: centeredX + clampedOffset, y: panelSize.height - islandSize.height)
        case .left: origin = CGPoint(x: 0, y: centeredY + clampedOffset)
        case .right: origin = CGPoint(x: panelSize.width - islandSize.width, y: centeredY + clampedOffset)
        }
        return CGRect(origin: origin, size: islandSize)
    }

    /// Keep the pointer at the same relative grab point as the island changes orientation.
    func dragOffset(cursor: CGPoint, grabPoint: CGPoint) -> CGFloat {
        let proposed = edge.isVertical
            ? cursor.y + (0.5 - grabPoint.y) * islandSize.height - panelSize.height / 2
            : cursor.x + (0.5 - grabPoint.x) * islandSize.width - panelSize.width / 2
        return min(maximumOffset, max(-maximumOffset, proposed))
    }

    var appKitFrame: CGRect {
        let rect = frame
        return CGRect(x: rect.minX, y: panelSize.height - rect.maxY,
                      width: rect.width, height: rect.height)
    }
}

/// Resting island dimensions, using a physical notch only when the screen has one.
struct IslandScreenGeometry {
    static let fallbackNotchWidth: CGFloat = 184
    private static let noNotchWidth: CGFloat = 80
    private static let noNotchHeight: CGFloat = 24

    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    init(screenWidth: CGFloat, safeAreaTop: CGFloat,
         auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?,
         menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
                let measuredWidth = screenWidth - left - right
                width = measuredWidth > 0 && measuredWidth < screenWidth
                    ? measuredWidth : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = min(Self.noNotchHeight, menuBarHeight)
        }
    }
}

/// Shared by the compact view and the greeting's collapse destination.
struct IslandRestingLayout {
    let width: CGFloat
    let height: CGFloat

    var botDiameter: CGFloat { min(20, max(0, height - 6)) }
    var botCenterY: CGFloat { height / 2 }
    var miniGridScale: CGFloat { min(1, max(0, height - 4) / 28) }
    var miniGridCenterX: CGFloat { width - 40 }
}
