import Foundation
import Testing
@testable import OmniFlowApp

@Test @MainActor func cleanupDeadlineReturnsWhileModelIgnoresCancellation() async {
    let gate = CleanupDeadline<String>()
    var release: CheckedContinuation<String, Never>?
    var published = false
    let start = ContinuousClock.now
    let result = await gate.run(seconds: 0.02) {
        let text = await withCheckedContinuation { release = $0 }
        if gate.active { published = true }
        return text
    }
    #expect(result == nil)
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(!gate.active)
    release?.resume(returning: "late result")
    for _ in 0..<10 { await Task.yield() }
    #expect(!published)
}

@Test @MainActor func cleanupDeadlineKeepsEarlySuccess() async {
    let gate = CleanupDeadline<String>()
    let result = await gate.run(seconds: 10) { "finished" }
    #expect(result == "finished")
    #expect(!gate.active)
}

@Test @MainActor func cleanupDeadlineHonorsCallerCancellation() async {
    let gate = CleanupDeadline<String>()
    var release: CheckedContinuation<String, Never>?
    let task = Task { await gate.run(seconds: 10) {
        await withCheckedContinuation { release = $0 }
    } }
    while release == nil { await Task.yield() }
    task.cancel()
    let start = ContinuousClock.now
    #expect(await task.value == nil)
    #expect(start.duration(to: .now) < .seconds(2))
    release?.resume(returning: "cancelled result")
}
