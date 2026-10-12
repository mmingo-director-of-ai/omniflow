import AppKit
import Testing
@testable import OmniFlowApp

@Test @MainActor func inputDiagnosticDistinguishesRepeatFromDuplicateIdentity() {
    let diagnostics = InputEventDiagnostics("test")
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    event.timestamp = 123
    #expect(!diagnostics.observe(.keyDown, event))
    #expect(diagnostics.observe(.keyDown, event.copy()!))
    event.timestamp = 124
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    #expect(!diagnostics.observe(.keyDown, event))
    #expect(!diagnostics.observe(.keyUp, event))
    diagnostics.disabled()
    #expect(!diagnostics.observe(.keyDown, event))
}

@Test @MainActor func inputDiagnosticsKeepsTapStagesIndependent() {
    let hid = InputEventDiagnostics("test-HID")
    let session = InputEventDiagnostics("test-session")
    let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                        mouseCursorPosition: .zero, mouseButton: .left)!
    event.timestamp = 55
    #expect(!hid.observe(.leftMouseDown, event))
    #expect(!session.observe(.leftMouseDown, event))
    #expect(hid.observe(.leftMouseDown, event))
}
