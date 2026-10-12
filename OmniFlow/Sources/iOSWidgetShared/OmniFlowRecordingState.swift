import Foundation

// Plain values shared by the iPhone/iPad app, its widget extension and the
// Live Activity. No ActivityKit or UIKit here, so previews can render them.

enum OmniFlowRecordingMode: String, Codable, Hashable, Sendable {
    case dictate, translate

    var title: String { self == .dictate ? "Dictation" : "Translation" }
    var symbol: String { self == .dictate ? OmniFlowSymbol.dictate : "character.bubble.fill" }
}

enum OmniFlowRecordingPhase: String, Codable, Hashable, Sendable {
    case listening, cleaning, translating, done
    /// A keyboard session is on and waiting for the keyboard's mic.
    case ready

    var title: String {
        switch self {
        case .listening: "Listening"
        case .cleaning: "Cleaning up"
        case .translating: "Translating"
        case .done: "Done"
        case .ready: "Keyboard dictation on"
        }
    }
}

/// The Live Activity's changing state (ActivityAttributes.ContentState).
struct OmniFlowRecordingContent: Codable, Hashable, Sendable {
    var phase: OmniFlowRecordingPhase
    var startedAt: Date
    /// Set when recording stops, so the elapsed time freezes.
    var stoppedAt: Date?
    /// Only a count; transcripts never leave the app.
    var words: Int?
}
