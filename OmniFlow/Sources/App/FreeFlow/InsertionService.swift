import AppKit
@preconcurrency import ApplicationServices
import Combine
import OSLog

@MainActor
final class InsertionService: ObservableObject {
    @Published private(set) var canRestoreClipboard = false
    private var clipboardBackup: [[NSPasteboard.PasteboardType: Data]]?
    private var ownedClipboardCount: Int?
    func restoreClipboard() {
        defer { clipboardBackup = nil; ownedClipboardCount = nil; canRestoreClipboard = false }
        guard let clipboardBackup, NSPasteboard.general.changeCount == ownedClipboardCount else { return }
        restore(clipboardBackup, to: .general)
    }

    struct Target {
        let element: AXUIElement
        let fingerprint: TargetFingerprint
        let appName: String
        let bundleID: String
        let interactionSerial: UInt64
        var dynamicContent: Bool { bundleID == "dev.warp.Warp-Stable" }
    }
    private var interactionSerial: UInt64 = 0
    private(set) var captureProblem = "No editable text field was focused."
    private var lastInteraction = "input"
    func userInteracted(_ kind: String) { interactionSerial &+= 1; lastInteraction = kind }
    private let inputLogger = Logger(subsystem: "com.mengohlabs.NotchLee", category: "input-events")
    private var pasteSequence: UInt64 = 0
    enum Outcome { case inserted, pasteSent }
    var isTrusted: Bool { AXIsProcessTrusted() }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func capture() -> Target? {
        captureProblem = "No editable text field was focused."
        guard isTrusted else { captureProblem = "Accessibility access is required for automatic paste."; return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            captureProblem = "Focus a text field in another app before holding fn."; return nil
        }
        guard let element = focusedElement() else { captureProblem = "\(app.localizedName ?? "This app") does not expose its focused field."; return nil }
        guard !isSecure(element) else { captureProblem = "Automatic paste is disabled in password fields."; return nil }
        guard let fingerprint = fingerprint(element, pid: app.processIdentifier) else {
            captureProblem = "The focused control is not an editable text field."; return nil
        }
        return Target(element: element, fingerprint: fingerprint, appName: app.localizedName ?? "your app", bundleID: app.bundleIdentifier ?? "", interactionSerial: interactionSerial)
    }
    func insert(_ text: String, into target: Target) async throws -> Outcome {
        guard !text.isEmpty else { throw FlowError("Nothing to insert.") }
        try Task.checkCancellation()
        if let reason = changeReason(target) { throw FlowError(reason) }
        if (target.bundleID.localizedCaseInsensitiveContains("terminal") || target.bundleID.localizedCaseInsensitiveContains("warp") || target.bundleID == "com.googlecode.iterm2"), text.contains(where: \.isNewline) {
            throw FlowError("Review multiline text before pasting into a terminal. Your transcript is available to copy.")
        }
        // Paste is the primary path: rich editors often report AX success without applying text.
        // The focused element, available text/selection, and intervening user input are all checked.
        let pasteboard = NSPasteboard.general
        let originalCount = pasteboard.changeCount
        let snapshot = try (clipboardBackup != nil && ownedClipboardCount == originalCount ? clipboardBackup! : snapshotClipboard(pasteboard))
        guard pasteboard.changeCount == originalCount else { throw FlowError("Clipboard changed. Copy your transcript manually.") }
        guard unchanged(target), !Task.isCancelled else { throw CancellationError() }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        guard pasteboard.changeCount == originalCount else { throw FlowError("Clipboard changed. Copy your transcript manually.") }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects([item]) else {
            restore(snapshot, to: pasteboard)
            throw FlowError("The clipboard could not be prepared. Copy your transcript below.")
        }
        let ownedCount = pasteboard.changeCount
        clipboardBackup = snapshot; ownedClipboardCount = ownedCount; canRestoreClipboard = true
        var dispatched = false, confirmed = false
        defer {
            // Before dispatch it is safe to restore. After dispatch, wait for actual
            // destination evidence or an explicit user action; a timer is not an acknowledgement.
            if !dispatched || confirmed { restoreClipboard() }
        }
        try await Task.sleep(for: .milliseconds(80))
        try Task.checkCancellation()
        if let reason = changeReason(target) { throw FlowError(reason) }
        guard pasteboard.changeCount == ownedCount else {
            throw FlowError("Paste paused: the clipboard changed before delivery.")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            throw FlowError("Could not send the paste shortcut.")
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        pasteSequence &+= 1
        inputLogger.notice("paste dispatched sequence=\(self.pasteSequence)")
        dispatched = true
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // Give the destination a chance to provide acknowledgement. Unverifiable
        // editors retain the clipboard until the user explicitly restores it.
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { resume.resume() }
        }
        if !target.dynamicContent, let before = target.fingerprint.value, let after = string(target.element, kAXValueAttribute) {
            if after == before && !before.contains(text) {
                throw FlowError("The destination did not accept the paste. The transcript is saved in history.")
            }
            if Self.verifiesPaste(before: before, selection: target.fingerprint.selection, after: after, text: text) { confirmed = true; return .inserted }
        }
        return .pasteSent
    }
    static func verifiesPaste(before: String, selection: String?, after: String, text: String) -> Bool {
        guard let parts = selection?.split(separator: ":"), parts.count == 2,
              let start = Int(parts[0]), let length = Int(parts[1]), start >= 0, length >= 0,
              start <= (before as NSString).length,
              length <= (before as NSString).length - start else { return false }
        return (before as NSString).replacingCharacters(in: NSRange(location: start, length: length), with: text) == after
    }
    func unchanged(_ target: Target) -> Bool { changeReason(target) == nil }
    /// Record only the reason, never the destination's text or keystrokes.
    private func changeReason(_ target: Target) -> String? {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.fingerprint.pid {
            return "Paste paused: the frontmost app changed from \(target.appName)."
        }
        guard let current = focusedElement() else { return "Paste paused: the app no longer exposes a focused field." }
        if !CFEqual(current, target.element) { return "Paste paused: the app replaced or changed its focused accessibility field." }
        if isSecure(current) { return "Paste paused: the field is protected." }
        guard let now = fingerprint(current, pid: target.fingerprint.pid) else { return "Paste paused: the control no longer reports an editable text role." }
        if target.dynamicContent {
            return target.fingerprint.allowsInsertion(current: now, inputOccurred: interactionSerial != target.interactionSerial, dynamicContent: true)
                ? nil : "Paste paused: \(lastInteraction) after the destination was captured."
        }
        if target.fingerprint.value != now.value { return "Paste paused: the field's reported text changed during dictation." }
        if target.fingerprint.selection != now.selection { return "Paste paused: the field's reported cursor or selection changed during dictation." }
        if !target.fingerprint.allowsInsertion(current: now, inputOccurred: interactionSerial != target.interactionSerial) {
            return "Paste paused: \(lastInteraction); this editor cannot verify the draft."
        }
        return nil
    }
    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private func isSecure(_ element: AXUIElement) -> Bool {
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        return subrole == kAXSecureTextFieldSubrole || subrole.localizedCaseInsensitiveContains("secure")
    }
    private func fingerprint(_ element: AXUIElement, pid: pid_t) -> TargetFingerprint? {
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid else { return nil }
        guard let role = string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }
        // Chromium/Electron and some custom editors omit value/range. Same-element identity
        // plus the input serial still prevents pasting after a user edit or caret change.
        let value = string(element, kAXValueAttribute)
        if let value, value.count > 100_000 { return nil }
        var selection: CFTypeRef?
        var rangeString: String?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
           let selection, CFGetTypeID(selection) == AXValueGetTypeID() {
            let ax = selection as! AXValue
            if AXValueGetType(ax) == .cfRange {
                var range = CFRange()
                if AXValueGetValue(ax, .cfRange, &range) { rangeString = "\(range.location):\(range.length)" }
            }
        }
        return .init(pid: pid, value: value, selection: rangeString)
    }
    private func snapshotClipboard(_ board: NSPasteboard) throws -> [[NSPasteboard.PasteboardType: Data]] {
        var bytes = 0
        return try (board.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard !type.rawValue.localizedCaseInsensitiveContains("promise") else { throw FlowError("The clipboard contains deferred content. Use Copy when ready.") }
                guard let data = item.data(forType: type) else { throw FlowError("Clipboard content cannot be safely restored. Copy your transcript manually.") }
                bytes += data.count
                guard bytes < 16_000_000 else { throw FlowError("Clipboard contains a large item. Copy your transcript manually.") }
                types[type] = data
            }
            return types
        }
    }
    private func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        board.prepareForNewContents(with: .currentHostOnly)
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}

extension InsertionService {
    @MainActor final class LiveSession {
        let target: Target
        var span: OwnedText
        var expectedSelection: String
        var conflicted = false
        init(target: Target, value: String, range: NSRange) {
            self.target = target; span = OwnedText(value: value, selection: range)
            expectedSelection = "\(range.location):\(range.length)"
        }
    }
    enum LiveOutcome { case written, unsupported, changed }
    func beginLive(_ target: Target) -> LiveSession? {
        // Initially opt in known native editors. Custom/web editors use the reliable
        // final-paste path even when they claim writable AX text attributes.
        guard ["com.apple.TextEdit", "com.apple.Notes", "com.apple.mail"].contains(target.bundleID),
              unchanged(target), let value = target.fingerprint.value,
              let range = parseRange(target.fingerprint.selection),
              range.location >= 0, range.length >= 0, range.location <= (value as NSString).length,
              range.length <= (value as NSString).length - range.location else { return nil }
        for attribute in [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(target.element, attribute as CFString, &settable) == .success, settable.boolValue else { return nil }
        }
        return LiveSession(target: target, value: value, range: range)
    }
    func updateLive(_ session: LiveSession, text: String) async -> LiveOutcome {
        guard !Task.isCancelled else { return .changed }
        guard liveUnchanged(session) else { session.conflicted = true; return .changed }
        if session.span.inserted == text { return .written }
        var range = CFRange(location: session.span.replacementRange.location, length: session.span.replacementRange.length)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(session.target.element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
            return session.span.inserted == nil ? .unsupported : .changed
        }
        // AX setters can report success without changing an editor's selection.
        // Verify the exact owned span before asking the app to replace any text.
        let replacementSelection = "\(range.location):\(range.length)"
        guard liveUnchanged(session, selection: replacementSelection) else {
            session.conflicted = true; return .changed
        }
        let expected = session.span.value(replacingWith: text)
        let result = AXUIElementSetAttributeValue(session.target.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        // Once mutation is requested, finish observing it even if cancellation arrives.
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { resume.resume() }
        }
        guard let current = fingerprint(session.target.element, pid: session.target.fingerprint.pid),
              current.value == expected, let selected = current.selection else {
            // A successful AX request can apply later. Never fall back to paste after
            // requesting a mutation whose outcome is ambiguous.
            session.conflicted = true; return .changed
        }
        let insertedLength = (text as NSString).length
        let caret = "\(session.span.originalRange.location + insertedLength):0"
        let selectedSpan = "\(session.span.originalRange.location):\(insertedLength)"
        guard result == .success, selected == caret || selected == selectedSpan,
              interactionSerial == session.target.interactionSerial,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == session.target.fingerprint.pid,
              let focused = focusedElement(), CFEqual(focused, session.target.element) else {
            session.conflicted = true; return .changed
        }
        session.span.commit(text); session.expectedSelection = selected
        return .written
    }
    func rollbackLive(_ session: LiveSession) async {
        guard session.span.inserted != nil, !session.conflicted, liveUnchanged(session) else { return }
        _ = await updateLive(session, text: session.span.originalSelection)
    }
    private func liveUnchanged(_ session: LiveSession, selection: String? = nil) -> Bool {
        guard !session.conflicted, interactionSerial == session.target.interactionSerial,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == session.target.fingerprint.pid,
              let focused = focusedElement(), CFEqual(focused, session.target.element), !isSecure(focused),
              let snapshot = fingerprint(focused, pid: session.target.fingerprint.pid) else { return false }
        return snapshot.value == session.span.expectedValue && snapshot.selection == (selection ?? session.expectedSelection)
    }
    private func parseRange(_ value: String?) -> NSRange? {
        guard let parts = value?.split(separator: ":"), parts.count == 2,
              let start = Int(parts[0]), let length = Int(parts[1]) else { return nil }
        return NSRange(location: start, length: length)
    }
}
