import AppKit
import OSLog
@preconcurrency import ApplicationServices

@MainActor
final class HotkeyService {
    var onAction: ((ShortcutMachine.Action) -> Void)?
    var onUserInteraction: ((String) -> Void)?
    var onFailure: (() -> Void)?
    private var machine = ShortcutMachine()
    private let inputDiagnostics = InputEventDiagnostics("hotkey-HID")
    private var deliveryGeneration: UInt64 = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnHeld = false
    private var finishingChord = false
    private var swallowed: Set<Int64> = []
    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let consume = MainActor.assumeIsolated {
                let service = Unmanaged<HotkeyService>.fromOpaque(info).takeUnretainedValue()
                return service.receive(type, event)
            }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); self.tap = nil; return false
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func lock() { machine.lock() }
    func processing() { machine.processing() }
    // Session completion must not relinquish an owned physical key before its release.
    func reset() { machine.reset() }
    func stop() {
        deliveryGeneration &+= 1
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; reset(); fnHeld = false; finishingChord = false; swallowed.removeAll()
    }
    private func send(_ event: ShortcutMachine.Event) {
        // Never perform AX calls or app work inside the synchronous event tap.
        // Main-queue FIFO preserves Fn-down / Space / Fn-up ordering.
        let token = deliveryGeneration
        for action in machine.handle(event) {
            DispatchQueue.main.async { [weak self] in
                guard let self, deliveryGeneration == token else { return }
                onAction?(action)
            }
        }
    }
    func receive(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        inputDiagnostics.observe(type, event)
        defer { inputDiagnostics.finished(since: started) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            inputDiagnostics.disabled()
            deliveryGeneration &+= 1
            reset(); fnHeld = false; finishingChord = false; swallowed.removeAll()
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            let point = event.location
            DispatchQueue.main.async { [weak self] in
                let appKitPoint = NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
                let onOverlay = NSApp.windows.contains { $0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible && $0.frame.contains(appKitPoint) }
                if !onOverlay { self?.onUserInteraction?("mouse click outside dictation bar") }
            }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged {
            // Only the physical Fn key; arrow keys may also carry maskSecondaryFn.
            if key == 63 {
                let down = event.flags.contains(.maskSecondaryFn)
                let owned = fnHeld || down
                if down != fnHeld {
                    let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                    if down && !event.flags.intersection(otherModifiers).isEmpty { return false }
                    finishingChord = down && machine.state == .locked
                    fnHeld = down; send(down ? .fnDown : .fnUp)
                }
                return owned
            }
            if fnHeld { send(.otherKey) }
            return false
        }
        if type == .keyUp { return swallowed.remove(key) != nil }
        guard type == .keyDown else { return false }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            if swallowed.contains(key) { return true }
            // Held keys still edit a destination after a fresh target capture.
            DispatchQueue.main.async { [weak self] in self?.onUserInteraction?("repeated key-down") }
            return false
        }
        // Fn-down immediately advances locked -> processing. Keep ownership of
        // that finish chord, but don't consume ordinary input during processing.
        if key == 49 && fnHeld && (machine.state == .holding || machine.state == .locked || finishingChord) {
            swallowed.insert(key); send(.space); return true
        }
        if key == 53 && machine.state != .idle {
            swallowed.insert(key); send(.escape); return true
        }
        if fnHeld { send(.otherKey) }
        let kind = key == 63 ? "Fn key-down" : key == 49 ? "Space key-down" : "other key-down"
        DispatchQueue.main.async { [weak self] in self?.onUserInteraction?(kind) }
        return false
    }
}

// Counts only event identities and timing; never logs characters, key codes,
// pointer coordinates, clipboard contents, or destination text.
@MainActor
final class InputEventDiagnostics {
    private let name: String
    private let logger = Logger(subsystem: "com.mengohlabs.NotchLee", category: "input-events")
    private var recent: [Identity] = []
    private var duplicates = 0
    private var slowCallbacks = 0
    private var pendingReport = false
    private struct Identity: Equatable {
        let type: CGEventType
        let timestamp: CGEventTimestamp
        let number: Int64
        let code: Int64
        let source: Int64
    }
    init(_ name: String) { self.name = name }
    @discardableResult
    func observe(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(type),
              event.timestamp != 0 else { return false }
        let keyboard = type == .keyDown || type == .keyUp
        let identity = Identity(type: type, timestamp: event.timestamp,
            number: keyboard ? 0 : event.getIntegerValueField(.mouseEventNumber),
            code: keyboard ? event.getIntegerValueField(.keyboardEventKeycode) : 0,
            source: event.getIntegerValueField(.eventSourceUnixProcessID))
        let duplicate = recent.contains(identity)
        if duplicate { duplicates += 1; reportLater() }
        recent.append(identity)
        if recent.count > 64 { recent.removeFirst() }
        return duplicate // Diagnostic only: never suppress real input.
    }
    func finished(since start: TimeInterval) {
        if ProcessInfo.processInfo.systemUptime - start > 0.02 {
            slowCallbacks += 1; reportLater()
        }
    }
    func disabled() {
        recent.removeAll()
        logger.error("tap disabled: \(self.name, privacy: .public)")
    }
    private func reportLater() {
        guard !pendingReport else { return }
        pendingReport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            logger.notice("tap=\(self.name, privacy: .public) duplicate-identities=\(self.duplicates) callbacks-over-20ms=\(self.slowCallbacks)")
            duplicates = 0; slowCallbacks = 0; pendingReport = false
        }
    }
}
