import Testing
@testable import OmniFlowApp

@Test func holdRelease() {
    var m = ShortcutMachine()
    #expect(m.handle(.fnDown) == [.start])
    #expect(m.handle(.fnDown) == [])
    #expect(m.handle(.fnUp) == [.finish])
    #expect(m.handle(.fnDown) == [])
    #expect(m.state == .processing)
}
@Test func lockReleaseAndStop() {
    var m = ShortcutMachine()
    _ = m.handle(.fnDown)
    #expect(m.handle(.space) == [.lock])
    #expect(m.handle(.fnUp) == [])
    #expect(m.state == .locked)
    #expect(m.handle(.fnDown) == [])
    #expect(m.handle(.space) == [])
    #expect(m.handle(.fnUp) == [.finish])
}
@Test func escapeAndOtherShortcuts() {
    var m = ShortcutMachine()
    _ = m.handle(.fnDown)
    #expect(m.handle(.otherKey) == [.cancel])
    #expect(m.handle(.fnUp) == [])
    _ = m.handle(.fnDown)
    #expect(m.handle(.escape) == [.cancel])
    #expect(m.handle(.fnUp) == [])
    #expect(m.state == .idle)
}
@Test func lockedTypingDoesNotCancel() {
    var m = ShortcutMachine()
    _ = m.handle(.fnDown); _ = m.handle(.space); _ = m.handle(.fnUp)
    #expect(m.handle(.otherKey) == [])
    #expect(m.handle(.escape) == [.cancel])
}
@Test func cancelProcessingAndReset() {
    var m = ShortcutMachine()
    _ = m.handle(.fnDown); _ = m.handle(.fnUp)
    #expect(m.handle(.escape) == [.cancel])
    m.reset()
    #expect(m.handle(.fnDown) == [.start])
}
@Test func partialTranscriptsReplaceRatherThanDuplicate() {
    var b = TranscriptBuffer()
    b.receive("Hello", isFinal: false)
    b.receive("Hello world.", isFinal: true)
    b.receive(" How", isFinal: false)
    b.receive(" How are you?", isFinal: false)
    #expect(b.text == "Hello world. How are you?")
    b.receive(" How are you?", isFinal: true)
    #expect(b.text == "Hello world. How are you?")
}
@Test func cleanupRejectsLossAndInventedNumbers() {
    #expect(CleanupPolicy.accept(raw: "Send 42 items tomorrow", candidate: "Send 43 items tomorrow.") == nil)
    #expect(CleanupPolicy.accept(raw: "Send 42 items tomorrow", candidate: "") == nil)
    #expect(CleanupPolicy.accept(raw: "Please schedule a meeting with Sarah on Friday about the launch", candidate: "OK.") == nil)
    #expect(CleanupPolicy.accept(raw: "hello world", candidate: "Hello world.") == "Hello world.")
    #expect(CleanupPolicy.accept(raw: "hello world", candidate: "Here is the cleaned transcript: Hello world.") == nil)
}
@Test func focusValidationRejectsChanges() {
    let base = TargetFingerprint(pid: 10, value: "Draft", selection: "5:0")
    #expect(base.matches(TargetFingerprint(pid: 10, value: "Draft", selection: "5:0")))
    #expect(!base.matches(TargetFingerprint(pid: 11, value: "Draft", selection: "5:0")))
    #expect(!base.matches(TargetFingerprint(pid: 10, value: "Edited", selection: "5:0")))
    #expect(!base.matches(TargetFingerprint(pid: 10, value: "Draft", selection: "0:0")))
}

@Test func manualLockSurvivesReleaseAndPracticeCanCancel() {
    var m = ShortcutMachine()
    _ = m.handle(.fnDown)
    m.lock()
    #expect(m.handle(.fnUp) == [])
    #expect(m.handle(.fnDown) == [])
    #expect(m.handle(.fnUp) == [.finish])
    m.reset()
    m.lock()
    #expect(m.handle(.escape) == [.cancel])
}

@Test func cleanupPreservesGreetingsAndNegations() {
    #expect(CleanupPolicy.accept(raw: "Um hello Sarah can we meet", candidate: "Sarah, can we meet?") == nil)
    #expect(CleanupPolicy.accept(raw: "Do not send the report", candidate: "Send the report.") == nil)
    #expect(CleanupPolicy.accept(raw: "I can't attend", candidate: "I cannot attend.") == "I cannot attend.")
}

@Test func structuredFormattingPreservesDataAndPermitsMarkdown() {
    let raw = "Development 2 servers. Production 8 servers."
    let table = "| Environment | Servers |\n| --- | --- |\n| Development | 2 |\n| Production | 8 |"
    #expect(CleanupPolicy.accept(raw: raw, candidate: table, structured: true) == table)
    #expect(CleanupPolicy.accept(raw: raw, candidate: "```markdown\n" + table + "\n```", structured: true) == table)
    #expect(CleanupPolicy.accept(raw: raw, candidate: table.replacingOccurrences(of: "8", with: "9"), structured: true) == nil)
}

@Test func cleanupRejectsEchoedPromptEnvelopes() {
    let raw = "We should paste the cleaned words into the focused field"
    let wrapped = "{\"vocabulary\":\"\",\"transcript\":\"We should paste the cleaned words into the focused field.\"}"
    #expect(CleanupPolicy.accept(raw: raw, candidate: wrapped, structured: true) == nil)
    #expect(CleanupPolicy.accept(raw: raw, candidate: "```json\n" + wrapped + "\n```", structured: true) == nil)
    #expect(CleanupPolicy.accept(raw: raw, candidate: "Transcript: " + raw, structured: true) == nil)
    #expect(CleanupPolicy.accept(raw: raw, candidate: "We should paste the cleaned words into the focused field.", structured: true) != nil)
    let code = "```json\n{\"enabled\":true}\n```"
    #expect(CleanupPolicy.accept(raw: "JSON code enabled true", candidate: code, structured: true) == code)
}

@Test func readableUnchangedTargetSurvivesNonEditingInput() {
    let original = TargetFingerprint(pid: 10, value: "draft", selection: "5:0")
    #expect(original.allowsInsertion(current: original, inputOccurred: true))
    #expect(!original.allowsInsertion(current: .init(pid: 10, value: "draft", selection: "0:0"), inputOccurred: true))
    #expect(!original.allowsInsertion(current: .init(pid: 10, value: "edited", selection: "5:0"), inputOccurred: false))
    #expect(!original.allowsInsertion(current: .init(pid: 11, value: "draft", selection: "5:0"), inputOccurred: false))
    let opaque = TargetFingerprint(pid: 10, value: nil, selection: nil)
    #expect(!opaque.allowsInsertion(current: opaque, inputOccurred: true))
    #expect(opaque.allowsInsertion(current: opaque, inputOccurred: false))
    let partial = TargetFingerprint(pid: 10, value: "draft", selection: nil)
    #expect(!partial.allowsInsertion(current: partial, inputOccurred: true))
}

@Test func dynamicTerminalRequiresUninterruptedInput() {
    let before = TargetFingerprint(pid: 10, value: "old output", selection: "10:0")
    let after = TargetFingerprint(pid: 10, value: "new terminal output", selection: "19:0")
    #expect(before.allowsInsertion(current: after, inputOccurred: false, dynamicContent: true))
    #expect(!before.allowsInsertion(current: after, inputOccurred: true, dynamicContent: true))
    #expect(!before.allowsInsertion(current: .init(pid: 11, value: nil, selection: nil), inputOccurred: false, dynamicContent: true))
    #expect(!before.allowsInsertion(current: after, inputOccurred: false))
}

@Test func handsFreeFinishWaitsForReleaseAndCannotFireAfterCancel() {
    var machine = ShortcutMachine()
    _ = machine.handle(.fnDown); _ = machine.handle(.space); _ = machine.handle(.fnUp)
    #expect(machine.handle(.fnDown) == [])
    #expect(machine.handle(.fnDown) == [])
    #expect(machine.handle(.escape) == [.cancel])
    #expect(machine.handle(.fnUp) == [])
    machine.reset(); machine.lock()
    #expect(machine.handle(.fnDown) == [])
    #expect(machine.handle(.fnUp) == [.finish])
    #expect(machine.handle(.fnUp) == [])
}
