import Testing
@testable import OmniFlowApp

@Test func agentLayoutKeepsEveryWordAndGroupsByTopic() {
    let text = "The build fails on main. It started after the merge. Next, update the changelog. Then open a merge request."
    let base = AgentLayout.plan(text)
    #expect(base.sentences.count == 4 && base.groupStarts == [0])
    let planned = AgentLayout.applying([2], to: base)!
    let laidOut = AgentLayout.render(planned)
    #expect(laidOut == "The build fails on main.\nIt started after the merge.\n\nNext, update the changelog.\nThen open a merge request.")
    #expect(AgentLayout.isLayoutOnly(original: text, candidate: laidOut))
}

@Test func agentLayoutRejectsImpossibleTopicShifts() {
    let base = AgentLayout.plan("One. Two. Three.")
    #expect(AgentLayout.applying([0], to: base) == nil)
    #expect(AgentLayout.applying([3], to: base) == nil)
    #expect(AgentLayout.applying([-1], to: base) == nil)
    #expect(AgentLayout.applying([], to: base) == base)
    // Splitting every sentence into its own group is not a layout.
    let four = AgentLayout.plan("One. Two. Three. Four.")
    #expect(AgentLayout.applying([1, 2, 3], to: four) == nil)
    #expect(AgentLayout.applying([2], to: four) != nil)
}

@Test func agentLayoutKeepsTheSpeakersParagraphsWithoutTheModel() {
    let text = "Refactor the parser. Keep the tests green.\n\nThen update the docs. Ship it."
    #expect(AgentLayout.deterministic(text) == "Refactor the parser.\nKeep the tests green.\n\nThen update the docs.\nShip it.")
}

@Test func agentIsAValidPerAppOutputStyle() {
    let profile = ApplicationProfile(name: "Terminal", bundleID: "com.apple.Terminal", outputStyle: AgentLayout.outputStyle)
    let resolved = ResolvedDictationPreferences.resolve(bundleID: "com.apple.Terminal", profiles: [profile], defaultWritingStyle: .apa, defaultOutputStyle: "natural")
    #expect(resolved.outputStyle == "agent")
}

@Test @MainActor func agentLayoutDeadlineDoesNotWaitForUncooperativeModel() async {
    var release: CheckedContinuation<[Int]?, Never>?
    let result = await AgentLayout.boundedTopicShifts(timeout: .milliseconds(20)) {
        await withCheckedContinuation { release = $0 }
    }
    #expect(result == nil)
    release?.resume(returning: [2])
    #expect(await AgentLayout.boundedTopicShifts(timeout: .seconds(1)) { [1] } == [1])
}
