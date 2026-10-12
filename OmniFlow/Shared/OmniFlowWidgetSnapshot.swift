import Foundation

/// What the desktop widgets show. The app writes it to the shared App Group
/// container; the sandboxed widget extension only reads it. No transcripts,
/// prompts, paths or credentials are included.
struct OmniFlowWidgetSnapshot: Codable, Equatable, Sendable {
    struct System: Codable, Equatable, Sendable {
        var cpu: Double?
        var cpuHistory: [Double]
        var memoryUsed: UInt64?
        var memoryTotal: UInt64
        var diskUsed: UInt64?
        var diskTotal: UInt64?
        var downRate: Double?
        var upRate: Double?
        var thermal: String
    }
    struct Session: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var project: String
        var harness: String
        var state: String
        var context: Double?
    }
    struct Quota: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        var used: Double
        var resets: Date?
    }
    struct Agents: Codable, Equatable, Sendable {
        var processes: Int
        var tokenRate: Double
        var sessions: [Session]
        var quotas: [Quota]
    }
    struct Dictation: Codable, Equatable, Sendable {
        var words: Int
        var dictations: Int
        var wordsPerMinute: Int?
    }

    var updated: Date
    var monitoringEnabled: Bool
    var system: System?
    var agents: Agents?
    var dictation: Dictation?
    var focusFollowsMouse: Bool

    static let empty = OmniFlowWidgetSnapshot(updated: .distantPast, monitoringEnabled: false, system: nil,
                                              agents: nil, dictation: nil, focusFollowsMouse: false)
}

enum OmniFlowWidgetStore {
    /// The app and extension resolve the same build setting as their entitlements.
    /// Unsigned builds have no shared container; never guess a publisher's team.
    static let appGroup = configuredAppGroup(Bundle.main.object(forInfoDictionaryKey: "OmniFlowWidgetAppGroup"))

    static func configuredAppGroup(_ value: Any?) -> String? {
        guard let value = value as? String,
              value.range(of: #"^[A-Z0-9]{10}\.com\.mengohlabs\.omniflow\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    static let kinds = (system: "OmniFlowSystemWidget", agents: "OmniFlowAgentsWidget", actions: "OmniFlowActionsWidget")

    static var fileURL: URL? {
        guard let appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget-snapshot.json")
    }

    static func read() -> OmniFlowWidgetSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count < 512_000,
              let snapshot = try? JSONDecoder().decode(OmniFlowWidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    @discardableResult
    static func write(_ snapshot: OmniFlowWidgetSnapshot) -> Bool {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
