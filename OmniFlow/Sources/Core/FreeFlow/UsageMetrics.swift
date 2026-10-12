import Foundation
import NaturalLanguage

public struct UsageMetrics {
    public struct Day: Identifiable {
        public let date: Date
        public let words: Int
        public var id: Date { date }
    }
    public let words: Int
    public let dictations: Int
    public let seconds: Double
    public let speakingWPM: Int?
    public let estimatedSavedSeconds: Double?
    public let streak: Int
    public let days: [Day]
    public init(entries: [DictationEntry], typingWPM: Double = 40, now: Date = .now, calendar: Calendar = .current) {
        let completed = entries.filter { $0.state == .delivered || $0.state == .pasteSent || $0.state == .needsCopy }
        let counted = completed.map { (entry: $0, words: Self.countWords($0.raw)) }
        words = counted.reduce(0) { $0 + $1.words }; dictations = completed.count
        let timed = counted.filter { ($0.entry.durationSeconds ?? 0) > 0 }
        seconds = timed.reduce(0) { $0 + ($1.entry.durationSeconds ?? 0) }
        let timedWords = timed.reduce(0) { $0 + $1.words }
        speakingWPM = seconds > 0 ? Int((Double(timedWords) / seconds * 60).rounded()) : nil
        estimatedSavedSeconds = seconds > 0 && typingWPM > 0 ? max(0, Double(timedWords) / typingWPM * 60 - seconds) : nil
        let today = calendar.startOfDay(for: now)
        days = (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            return Day(date: day, words: counted.filter { calendar.isDate($0.entry.date, inSameDayAs: day) }.reduce(0) { $0 + $1.words })
        }
        let activeDays = Set(completed.map { calendar.startOfDay(for: $0.date) })
        var cursor = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var count = 0
        while activeDays.contains(cursor) { count += 1; cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        streak = count
    }
    public static func countWords(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in count += 1; return true }
        return count
    }
}
