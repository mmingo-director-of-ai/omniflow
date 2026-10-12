import Foundation

/// One focus request per settled pointer location. Never repeatedly steals focus
/// from keyboard navigation while the pointer remains parked over another field.
public struct PointerDwell {
    private var anchor: CGPoint?
    private var since: TimeInterval = 0
    private var fired = false
    public init() {}
    public mutating func suppress(at point: CGPoint) { anchor = point; fired = true }
    public mutating func reset() { anchor = nil; fired = false }
    public mutating func shouldFocus(at point: CGPoint, time: TimeInterval, eligible: Bool) -> Bool {
        guard eligible else { reset(); return false }
        guard let anchor else { self.anchor = point; since = time; return false }
        if hypot(point.x - anchor.x, point.y - anchor.y) > 4 {
            self.anchor = point; since = time; fired = false; return false
        }
        guard !fired, time - since >= 0.45 else { return false }
        fired = true
        return true
    }
}
