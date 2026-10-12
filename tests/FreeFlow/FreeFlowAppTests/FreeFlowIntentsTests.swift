import Foundation
import Testing
@testable import OmniFlowApp

@MainActor
private final class IntentTarget: FreeFlowIntentTarget {
    var phase: AppModel.Phase = .idle
    var busy = false
    var canRecord = true
    var isLocalDictationSession = true
    var pages: [String] = []
    var starts: [Bool] = []
    var finishes = 0
    var cancellations = 0
    func openIntentPage(_ page: String) { pages.append(page) }
    func begin(practice: Bool) { starts.append(practice) }
    func finish() { finishes += 1 }
    func cancel(message: String) { cancellations += 1 }
}

@Test @MainActor func shortcutNavigationNeverStartsRecording() throws {
    let target = IntentTarget(), bridge = FreeFlowIntentBridge()
    bridge.model = target
    try bridge.run(.open)
    try bridge.run(.history)
    #expect(target.pages == ["Home", "Recent"])
    #expect(target.starts.isEmpty)
}

@Test @MainActor func shortcutStartUsesLocalSessionAndChecksReadiness() throws {
    let target = IntentTarget(), bridge = FreeFlowIntentBridge()
    bridge.model = target
    target.canRecord = false
    #expect(throws: FreeFlowIntentError.self) { try bridge.run(.start) }
    #expect(target.starts.isEmpty)
    target.canRecord = true; target.busy = true
    #expect(throws: FreeFlowIntentError.self) { try bridge.run(.start) }
    #expect(target.starts.isEmpty)
    target.busy = false
    try bridge.run(.start)
    #expect(target.starts == [true])
}

@Test @MainActor func shortcutControlsRejectUnrelatedAndInactiveSessions() throws {
    let target = IntentTarget(), bridge = FreeFlowIntentBridge()
    bridge.model = target
    #expect(throws: FreeFlowIntentError.self) { try bridge.run(.finish) }
    #expect(throws: FreeFlowIntentError.self) { try bridge.run(.cancel) }
    target.phase = .starting
    #expect(throws: FreeFlowIntentError.self) { try bridge.run(.finish) }
    #expect(target.cancellations == 0)
    target.phase = .recording; target.isLocalDictationSession = false
    #expect(throws: FreeFlowIntentError.self) { try bridge.run(.finish) }
    #expect(throws: FreeFlowIntentError.self) { try bridge.run(.cancel) }
    #expect(target.finishes == 0 && target.cancellations == 0)
    target.isLocalDictationSession = true
    try bridge.run(.finish)
    target.phase = .processing
    try bridge.run(.cancel)
    #expect(target.finishes == 1 && target.cancellations == 1)
}

@Test @MainActor func shortcutRequiresLiveAppModel() {
    let bridge = FreeFlowIntentBridge()
    #expect(throws: FreeFlowIntentError.self) { try bridge.run(.open) }
}

@Test func shortcutURLsAcceptOnlyKnownParameterlessActions() throws {
    for (route, action) in [("open", FreeFlowIntentCommand.open), ("history", .history), ("start-local", .start), ("finish-local", .finish), ("cancel-local", .cancel)] {
        #expect(FreeFlowIntentCommand(url: try #require(URL(string: "freeflow://\(route)"))) == action)
        #expect(FreeFlowIntentCommand(url: try #require(URL(string: "omniflow://\(route)"))) == action)
    }
    for value in ["https://start-local", "freeflow://start", "freeflow://start-local?text=hello", "freeflow://open/extra", "freeflow://open#start-local", "freeflow://user@start-local", "freeflow://open:42"] {
        #expect(FreeFlowIntentCommand(url: try #require(URL(string: value))) == nil)
    }
}
