import Foundation

/// What the iPhone/iPad data widgets show: today's words, the daily streak and
/// a short preview of the latest dictation. Off by default — it needs an App
/// Group, which a free Apple team cannot provision on iOS. To turn it on with a
/// paid team: add `OMNIFLOW_IOS_APP_GROUP` to SWIFT_ACTIVE_COMPILATION_CONDITIONS
/// of OmniFlowiOS and OmniFlowiOSWidgets, give both targets an entitlements file
/// with `com.apple.security.application-groups = [group.com.mengohlabs.omniflow]`,
/// and have the app call `OmniFlowMobileWidgetStore.write` after each dictation.
struct OmniFlowMobileSnapshot: Codable, Equatable, Sendable {
    struct Recent: Codable, Equatable, Sendable {
        var date: Date
        var words: Int
        /// At most `previewLimit` characters; widgets mark it privacy-sensitive
        /// so it is redacted on a locked device.
        var preview: String
        var translated: Bool
    }

    static let previewLimit = 140

    var updated: Date
    var wordsToday: Int
    var streakDays: Int
    /// Oldest first, today last.
    var wordsLastSevenDays: [Int]
    var recent: Recent?

    static let empty = OmniFlowMobileSnapshot(updated: .distantPast, wordsToday: 0, streakDays: 0,
                                              wordsLastSevenDays: [], recent: nil)
}

enum OmniFlowMobileWidgetStore {
    /// iOS App Groups must be `group.`-prefixed and provisioned (paid team).
    static let appGroup = "group.com.mengohlabs.omniflow"
    static let kinds = (today: "OmniFlowTodayWidget", recent: "OmniFlowRecentDictationWidget")

    #if OMNIFLOW_IOS_APP_GROUP
    static var isAvailable: Bool { fileURL != nil }
    #else
    static let isAvailable = false
    #endif

    private static var fileURL: URL? {
        #if OMNIFLOW_IOS_APP_GROUP
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("mobile-widget-snapshot.json")
        #else
        nil
        #endif
    }

    static func read() -> OmniFlowMobileSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count < 64_000,
              let snapshot = try? JSONDecoder().decode(OmniFlowMobileSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    @discardableResult
    static func write(_ snapshot: OmniFlowMobileSnapshot) -> Bool {
        var snapshot = snapshot
        if let recent = snapshot.recent, recent.preview.count > OmniFlowMobileSnapshot.previewLimit {
            snapshot.recent?.preview = String(recent.preview.prefix(OmniFlowMobileSnapshot.previewLimit)) + "…"
        }
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return false }
        return (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }
}
