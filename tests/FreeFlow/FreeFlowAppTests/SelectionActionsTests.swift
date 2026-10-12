import Foundation
import Testing
@testable import OmniFlowApp

@Test func selectionSnapshotUsesUTF16AndPreservesSurroundings() {
    let snapshot = SelectionSnapshot(value: "Hello 👋 world", range: NSRange(location: 6, length: 2))!
    #expect(snapshot.selectedText == "👋")
    #expect(snapshot.replacing(with: "friend") == "Hello friend world")
}
@Test func selectionRejectsInvalidOrEmptyRanges() {
    #expect(SelectionSnapshot(value: "abc", range: NSRange(location: 3, length: 1)) == nil)
    #expect(SelectionSnapshot(value: "abc", range: NSRange(location: 0, length: 0)) == nil)
    #expect(SelectionSnapshot(value: "👋", range: NSRange(location: 0, length: 1)) == nil)
    #expect(SelectionSnapshot(value: "abc", range: NSRange(location: Int.max, length: 2)) == nil)
}
@Test func selectionInvalidatesOnAnyTextOrRangeChange() {
    let initial = SelectionSnapshot(value: "one two", range: NSRange(location: 0, length: 3))
    #expect(initial != SelectionSnapshot(value: "one TWO", range: NSRange(location: 0, length: 3)))
    #expect(initial != SelectionSnapshot(value: "one two", range: NSRange(location: 4, length: 3)))
}
@Test @MainActor func pastedTextHasNoReplacementDestinationAndRetainsOriginal() {
    let service = SelectionActionService()
    service.preview(text: "keep this", action: .translate)
    #expect(service.original == "keep this")
    #expect(service.result == "keep this")
    #expect(!service.canReplace)
    service.cancel()
    #expect(service.original == "keep this")
}
@Test @MainActor func cancelledTranslationPreservesOriginalWithoutModelRequest() async {
    let task = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return await TranslationService().translate("Original", source: .init(identifier: "en"), target: .init(identifier: "ja"))
    }
    let result = await task.value
    #expect(result.text == "Original")
    #expect(!result.didTranslate)
}
@Test @MainActor func textActionsRespectDictationGate() {
    let service = SelectionActionService()
    service.canStart = { false }
    service.preview(text: "untouched", action: .cleanup)
    service.run()
    #expect(!service.busy)
    #expect(service.result == "untouched")
    #expect(service.note.contains("Finish dictation"))
}

@Test func translationPolicyProtectsCodeChartsAndInlineLiterals() {
    let protected = [
        "Keep `customer_id` exactly.",
        "Run this:\n```swift\nlet total = 42\n```",
        "```chart\n{\"title\":\"Sales\",\"values\":[42]}\n```",
        "~~~json\n{\"literal\":true}\n~~~",
        "Incomplete fence `do not change",
        "An unmatched ~~~ fence also remains intact"
    ]
    for text in protected { #expect(TranslationInputPolicy.preservationReason(for: text) != nil) }
    #expect(TranslationInputPolicy.preservationReason(for: "Hello, world. This is ordinary prose.") == nil)
    #expect(TranslationInputPolicy.preservationReason(for: "The estimate is ~5 minutes.") == nil)
}
@Test func translationPolicyCapsInputWithoutRejectingBoundary() {
    #expect(TranslationInputPolicy.preservationReason(for: String(repeating: "x", count: 5000)) == nil)
    #expect(TranslationInputPolicy.preservationReason(for: String(repeating: "x", count: 5001)) != nil)
    #expect(TranslationInputPolicy.preservationReason(for: "  \n") != nil)
}
@Test @MainActor func protectedTranslationReturnsExactOriginalWithoutModelRequest() async {
    let original = "Translate this explanation.\n```chart\n{\"name\":\"Revenue\",\"value\":123}\n```"
    let result = await TranslationService().translate(original, source: .init(identifier: "en"), target: .init(identifier: "ja"))
    #expect(result.text == original)
    #expect(!result.didTranslate)
    #expect(result.note.contains("protect exact content"))
}

@Test @MainActor func cleanupTimeoutStillRemovesFillersAndPreservesOriginalInput() {
    let original = "Close at, um, the pill options for Miter, Atlas, and Miter Defend."
    let fallback = CleanupService.fallback(original, locale: Locale(identifier: "en-US"), reason: "cleanup timed out")
    #expect(fallback.text == "Close at the pill options for Miter, Atlas, and Miter Defend.")
    #expect(fallback.note == "Basic cleanup · cleanup timed out")
    #expect(original.contains(", um,"))
    #expect(CleanupService.fallback("Wir fahren um acht.", locale: Locale(identifier: "de"), reason: "cleanup timed out").text == "Wir fahren um acht.")
}
