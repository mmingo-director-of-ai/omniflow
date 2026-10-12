import Testing
@testable import OmniFlowApp

@Test @MainActor func focusTrackerFollowsNewFieldAndNeverKeepsAnInvalidDestination() {
    var focused: String? = "Editor A"
    let tracker = FocusTracker { focused }
    tracker.start()
    #expect(tracker.current == "Editor A")
    focused = "Editor B"; tracker.sample()
    #expect(tracker.current == "Editor B")
    focused = nil; tracker.sample()
    #expect(tracker.current == nil) // No stale destination after focusing a password/non-editor.
    focused = "Editor C"
    #expect(tracker.freeze() == "Editor C") // Fresh synchronous reading at finish.
    focused = "Editor D"; tracker.sample()
    #expect(tracker.current == "Editor C") // No retargeting during delivery.
    tracker.stop()
    #expect(tracker.current == nil)
}
