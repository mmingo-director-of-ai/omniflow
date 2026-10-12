import Testing
import AppKit
@testable import OmniFlowApp

@MainActor
private func event(_ code: Int64, flags: CGEventFlags = [], repeatKey: Bool = false) -> CGEvent {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
    e.flags = flags
    e.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
    return e
}
@MainActor private func drainActions() async {
    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { resume.resume() }
    }
}

@Test @MainActor func eventTapDefersWorkAndPreservesChordOrdering() async {
    let service = HotkeyService()
    var actions: [ShortcutMachine.Action] = []
    service.onAction = { actions.append($0) }
    #expect(service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn)))
    #expect(actions.isEmpty) // No AX/app work in the synchronous callback.
    #expect(service.receive(.keyDown, event(49, flags: .maskSecondaryFn)))
    #expect(service.receive(.keyDown, event(49, flags: .maskSecondaryFn, repeatKey: true)))
    #expect(service.receive(.keyUp, event(49)))
    #expect(service.receive(.flagsChanged, event(63)))
    await drainActions()
    #expect(actions == [.start, .lock])
    #expect(service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn)))
    await drainActions()
    #expect(actions == [.start, .lock])
    #expect(service.receive(.flagsChanged, event(63)))
    await drainActions()
    #expect(actions == [.start, .lock, .finish])
}

@Test @MainActor func arrowFnFlagsAndOtherModifiersDoNotStartCapture() async {
    let service = HotkeyService()
    var actions: [ShortcutMachine.Action] = []
    service.onAction = { actions.append($0) }
    _ = service.receive(.keyDown, event(123, flags: .maskSecondaryFn))
    _ = service.receive(.flagsChanged, event(63, flags: [.maskSecondaryFn, .maskControl]))
    _ = service.receive(.flagsChanged, event(63))
    await drainActions()
    #expect(actions.isEmpty)
}

@Test @MainActor func unrelatedFnShortcutPassesThroughAndCancels() async {
    let service = HotkeyService()
    var actions: [ShortcutMachine.Action] = []
    service.onAction = { actions.append($0) }
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    #expect(!service.receive(.keyDown, event(123, flags: .maskSecondaryFn)))
    _ = service.receive(.flagsChanged, event(63))
    await drainActions()
    #expect(actions == [.start, .cancel])
}

@Test @MainActor func uiLockedPracticeRespondsToEscape() async {
    let service = HotkeyService()
    var actions: [ShortcutMachine.Action] = []
    service.onAction = { actions.append($0) }
    service.lock()
    #expect(service.receive(.keyDown, event(53)))
    #expect(service.receive(.keyUp, event(53)))
    await drainActions()
    #expect(actions == [.cancel])
}

@Test @MainActor func ownedFnIsConsumedSoGlobeActionCannotAlsoFire() {
    let service = HotkeyService()
    #expect(service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn)))
    #expect(service.receive(.flagsChanged, event(63)))
}

@Test @MainActor func dictationControlsDoNotInvalidateInsertion() async {
    let service = HotkeyService()
    var interactions = 0
    service.onUserInteraction = { _ in interactions += 1 }
    // Hold-to-talk and release.
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    _ = service.receive(.flagsChanged, event(63))
    await drainActions()
    #expect(interactions == 0)
    service.reset()
    // Hands-free chord, release, then Fn to finish.
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    _ = service.receive(.keyDown, event(49, flags: .maskSecondaryFn))
    _ = service.receive(.keyUp, event(49))
    _ = service.receive(.flagsChanged, event(63))
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    _ = service.receive(.flagsChanged, event(63))
    await drainActions()
    #expect(interactions == 0)
    // A real edit still invalidates the captured target.
    _ = service.receive(.keyDown, event(0))
    await drainActions()
    #expect(interactions == 1)
}

@Test @MainActor func finishingResetKeepsFnReleaseOwned() {
    let service = HotkeyService()
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    _ = service.receive(.keyDown, event(49, flags: .maskSecondaryFn))
    _ = service.receive(.keyUp, event(49))
    _ = service.receive(.flagsChanged, event(63))
    #expect(service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn)))
    service.reset() // Completion/cancellation can happen before physical release.
    #expect(service.receive(.flagsChanged, event(63)))
}

@Test @MainActor func repeatedUserKeysStillInvalidateUnverifiableDestinations() async {
    let service = HotkeyService()
    var interactions = 0
    service.onUserInteraction = { _ in interactions += 1 }
    #expect(!service.receive(.keyDown, event(0, repeatKey: true)))
    await drainActions()
    #expect(interactions == 1)
}

@Test @MainActor func spaceIsOnlyConsumedWhenItLocksRecording() async {
    let service = HotkeyService()
    var actions: [ShortcutMachine.Action] = []
    service.onAction = { actions.append($0) }
    service.processing()
    #expect(service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn)))
    #expect(!service.receive(.keyDown, event(49, flags: .maskSecondaryFn)))
    #expect(!service.receive(.keyUp, event(49)))
    _ = service.receive(.flagsChanged, event(63))
    await drainActions()
    #expect(actions.isEmpty)
}

@Test @MainActor func handsFreeFinishChordNeverTypesSpaceIntoDestination() async {
    let service = HotkeyService()
    var actions: [ShortcutMachine.Action] = []
    var edits = 0
    service.onAction = { actions.append($0) }
    service.onUserInteraction = { _ in edits += 1 }
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    _ = service.receive(.keyDown, event(49, flags: .maskSecondaryFn))
    _ = service.receive(.keyUp, event(49))
    _ = service.receive(.flagsChanged, event(63))
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    #expect(service.receive(.keyDown, event(49, flags: .maskSecondaryFn)))
    #expect(service.receive(.keyDown, event(49, flags: .maskSecondaryFn, repeatKey: true)))
    #expect(service.receive(.flagsChanged, event(63)))
    #expect(service.receive(.keyUp, event(49)))
    await drainActions()
    #expect(actions == [.start, .lock, .finish])
    #expect(edits == 0)
}

@Test @MainActor func keyboardRecoveryDoesNotKeepAStuckFnKey() async {
    let service = HotkeyService()
    var actions: [ShortcutMachine.Action] = []
    var failures = 0
    service.onAction = { actions.append($0) }
    service.onFailure = { failures += 1 }
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    await drainActions()
    _ = service.receive(.tapDisabledByTimeout, event(0))
    await drainActions()
    // The tap can miss Fn-up while disabled. The next physical press must work.
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    _ = service.receive(.flagsChanged, event(63))
    await drainActions()
    #expect(actions == [.start, .start, .finish])
    #expect(failures == 1)
}

@Test @MainActor func stoppingEventTapDiscardsQueuedStart() async {
    let service = HotkeyService()
    var actions: [ShortcutMachine.Action] = []
    service.onAction = { actions.append($0) }
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    service.stop()
    await drainActions()
    #expect(actions.isEmpty)
}

@Test @MainActor func disabledEventTapDiscardsQueuedStart() async {
    let service = HotkeyService()
    var actions: [ShortcutMachine.Action] = []
    var failures = 0
    service.onAction = { actions.append($0) }
    service.onFailure = { failures += 1 }
    _ = service.receive(.flagsChanged, event(63, flags: .maskSecondaryFn))
    _ = service.receive(.tapDisabledByTimeout, event(63))
    await drainActions()
    #expect(actions.isEmpty)
    #expect(failures == 1)
}
