import Foundation
import Testing
@testable import OmniFlowApp

@Test func metricsDoNotInventDurationsForImportedHistory() {
    let timed = DictationEntry(raw: "one two three four", text: "One two three four.", note: "", destination: "Notes", state: .delivered, durationSeconds: 6)
    let imported = DictationEntry(raw: "five six seven eight", text: "Five six seven eight.", note: "", destination: "Notes", state: .needsCopy)
    let cancelled = DictationEntry(raw: "ignore this", text: "", note: "", destination: "Notes", state: .cancelled, durationSeconds: 20)
    let metrics = UsageMetrics(entries: [timed, imported, cancelled], typingWPM: 20)
    #expect(metrics.words == 8)
    #expect(metrics.dictations == 2)
    #expect(metrics.seconds == 6)
    #expect(metrics.speakingWPM == 40)
    #expect(metrics.estimatedSavedSeconds == 6)
    #expect(UsageMetrics(entries: [imported]).speakingWPM == nil)
}
