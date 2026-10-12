import Foundation
import os

/// How long dictation takes to become ready after Fn goes down: OSSignposter
/// intervals ("Fn → <stage>") for Instruments and one `dictation.start` span with
/// milliseconds per stage. Timing only, never audio or words.
@MainActor
final class DictationStartTimeline {
    enum Stage: String, CaseIterable {
        case pillShown = "pill_shown", captureRunning = "capture_running", firstBuffer = "first_buffer"
        case analyzerReady = "analyzer_ready", firstPartial = "first_partial"
    }

    private static let signposter = OSSignposter(subsystem: "com.mengohlabs.NotchLee", category: "DictationStart")
    private let hotkeyDown: Date
    private var marks: [Stage: Date] = [:]
    private var intervals: [Stage: OSSignpostIntervalState] = [:]
    var reusedEngine: Bool?

    init(hotkeyDown: Date) {
        self.hotkeyDown = hotkeyDown
        for stage in Stage.allCases {
            intervals[stage] = Self.signposter.beginInterval(Self.name(stage), id: Self.signposter.makeSignpostID())
        }
    }

    func mark(_ stage: Stage, at date: Date = .now) {
        guard marks[stage] == nil else { return }
        marks[stage] = date
        if let state = intervals.removeValue(forKey: stage) { Self.signposter.endInterval(Self.name(stage), state) }
    }

    /// Milliseconds from Fn down to each reached stage.
    var milliseconds: [Stage: Int] { marks.mapValues { Int(($0.timeIntervalSince(hotkeyDown) * 1000).rounded()) } }

    func send() {
        for (stage, state) in intervals { Self.signposter.endInterval(Self.name(stage), state) }
        intervals = [:]
        var attributes: [String: String] = [:]
        for (stage, ms) in milliseconds { attributes[stage.rawValue + ".ms"] = String(ms) }
        if let reusedEngine { attributes["engine.reused"] = String(reusedEngine) }
        let start = hotkeyDown
        Task { await LocalTelemetry.shared.span("dictation.start", start: start, attributes: attributes) }
    }

    private static func name(_ stage: Stage) -> StaticString {
        switch stage {
        case .pillShown: "Fn → pill shown"
        case .captureRunning: "Fn → capture running"
        case .firstBuffer: "Fn → first buffer"
        case .analyzerReady: "Fn → analyzer ready"
        case .firstPartial: "Fn → first partial"
        }
    }
}
