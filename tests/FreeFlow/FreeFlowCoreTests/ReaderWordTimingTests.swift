import Foundation
import Testing
@testable import OmniFlowApp

@Test func readAlongWordFollowsProgress() throws {
    let sentence = "The model fits a line, then asks how well it predicts."
    let words = ReaderWordTiming.words(in: sentence)
    func word(_ progress: Double) -> String {
        let range = ReaderWordTiming.word(at: progress, in: words)!
        return (sentence as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }
    #expect(words.ranges.count == 11)
    #expect(word(0) == "The")
    #expect(word(1) == "predicts")
    #expect(word(0.999) == "predicts")
    // Words come in order as progress grows, never skipping backwards.
    let sequence = stride(from: 0.0, through: 1.0, by: 0.01).map { ReaderWordTiming.word(at: $0, in: words)!.lowerBound }
    #expect(sequence == sequence.sorted())
    #expect(Set(sequence).count == 11)
    // The comma's pause belongs to "line": it holds longer than its length alone would.
    let line = words.ranges.firstIndex { (sentence as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) == "line" }!
    let share = words.ends[line] - (line > 0 ? words.ends[line - 1] : 0)
    #expect(share == 4 + ReaderWordTiming.shortPause)
    #expect(ReaderWordTiming.word(at: 0.5, in: ReaderWordTiming.words(in: "  ")) == nil)
}
