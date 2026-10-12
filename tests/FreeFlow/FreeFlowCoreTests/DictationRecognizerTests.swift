import Foundation
import Testing
@testable import OmniFlowApp

@Test func dictationRecognizerContextKeepsUserTermsFirstAndDeduplicates() {
    let context = DictationRecognizer.contextualStrings(vocabulary: "Kyube\n  omniflow \n\n" + String(repeating: "x", count: 61))
    #expect(Array(context.prefix(2)) == ["Kyube", "omniflow"])
    #expect(!context.contains("OmniFlow"))
    #expect(context.contains("Claude Code"))
    #expect(!context.contains { $0.count > 60 })
}

@MainActor @Test func dictationRecognizerRefusesToStartBeforePreparation() async {
    let recognizer = DictationRecognizer()
    #expect(!recognizer.isPrepared)
    await #expect(throws: DictationRecognizerError.self) {
        _ = try await recognizer.start(onText: { _ in }, onError: { _ in })
    }
}
