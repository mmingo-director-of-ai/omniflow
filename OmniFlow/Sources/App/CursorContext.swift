import Foundation
import CoreGraphics

/// Only the current context is retained. This is data for the local model, never executable instructions.
struct CursorContext: Codable, Equatable, Sendable {
    var capturedAt: Date
    var app: String
    var bundleID: String
    var window: String
    var role: String
    var label: String
    var selectedText: String
    var protectedContent: Bool = false

    var summary: String {
        if protectedContent { return "\(app) · protected field" }
        return [app, label.isEmpty ? window : label].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func modelData(now: Date = .now) -> String? {
        guard now.timeIntervalSince(capturedAt) < 120 else { return nil }
        var bounded = self
        bounded.app = String(app.prefix(100))
        bounded.window = String(window.prefix(240))
        bounded.label = String(label.prefix(400))
        bounded.selectedText = String(selectedText.prefix(1600))
        if protectedContent { bounded.window = ""; bounded.label = ""; bounded.selectedText = "" }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(bounded)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func accessibilityPoint(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// One on-screen window from the WindowServer list: bounds and owner (nil if invalid).
    struct WindowEntry: Sendable, Equatable {
        let bounds: CGRect
        let owner: pid_t?
    }

    /// Visible windows in front-to-back order, reduced to what hit testing needs.
    static func windowEntries(_ windows: [[String: Any]]) -> [WindowEntry] {
        windows.compactMap { window in
            guard (window[kCGWindowIsOnscreen as String] as? Bool) != false,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let owner = (window[kCGWindowOwnerPID as String] as? NSNumber).map(\.int32Value)
            return WindowEntry(bounds: rect, owner: owner.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// WindowServer supplies front-to-back bounds without invoking an app's
    /// accessibility implementation. Coordinates use the same origin as AX.
    static func windowOwner(at point: CGPoint, windows: [[String: Any]]) -> pid_t? {
        windowOwner(at: point, entries: windowEntries(windows))
    }

    static func windowOwner(at point: CGPoint, entries: [WindowEntry]) -> pid_t? {
        entries.first { $0.bounds.contains(point) }?.owner
    }

    /// Same content, ignoring when it was captured.
    func sameContent(as other: CursorContext?) -> Bool {
        guard var other else { return false }
        other.capturedAt = capturedAt
        return other == self
    }
}
