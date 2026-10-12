import AVFoundation
import Testing
@testable import OmniFlowApp

@Test func missingMicrophonePermissionsHaveActionableDistinctFeedback() {
    #expect(OmniFlowMicrophonePermission(.authorized) == .allowed)
    let initial = OmniFlowMicrophonePermission(.notDetermined)
    #expect(initial == .notRequested)
    #expect(initial.actionTitle == "Allow microphone")
    let denied = OmniFlowMicrophonePermission(.denied)
    #expect(denied == .denied)
    #expect(denied.guidance.contains("Privacy & Security → Microphone"))
    #expect(denied.actionTitle == "Open microphone settings")
    let restricted = OmniFlowMicrophonePermission(.restricted)
    #expect(restricted == .restricted)
    #expect(restricted.guidance.contains("administrator"))
    #expect(OmniFlowMicrophonePermission.allowed.guidance.contains("Sound still needs"))
}

@Test func restartingDuringHighCPUDoesNotReplayAnAlert() {
    var watch = AmbientCPUWatchState()
    let startupEvents = (0..<20).map { _ in watch.observe(isHigh: true) }
    #expect(startupEvents.allSatisfy { !$0 })
    // A genuine recovery and later sustained rise still produces one event.
    let newEvents = [false, true, true, true].map { watch.observe(isHigh: $0) }
    #expect(newEvents == [false, false, true, false])
    // Relaunch / wake / enabling an existing watch must baseline again quietly.
    watch = AmbientCPUWatchState()
    let resumedEvents = (0..<3).map { _ in watch.observe(isHigh: true) }
    #expect(resumedEvents.allSatisfy { !$0 })
}

@Test func CPUWatchRequiresSustainedNewLoadAndRearmsAfterRecovery() {
    var watch = AmbientCPUWatchState()
    let events = [false, true, false, true, true, false, true, true]
        .map { watch.observe(isHigh: $0) }
    #expect(events == [false, false, false, false, true, false, false, true])
}
