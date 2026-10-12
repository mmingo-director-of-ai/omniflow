import AppKit
import ApplicationServices
import Combine

/// Services consume a copy of selected text. They never return a replacement synchronously.
@MainActor
final class SelectionActionService: NSObject, ObservableObject {
    enum Action: String, CaseIterable, Identifiable {
        case cleanup, translate, style
        var id: String { rawValue }
        var title: String {
            switch self { case .cleanup: "Clean up"; case .translate: "Translate"; case .style: "Change writing style" }
        }
    }
    @Published private(set) var original = ""
    @Published private(set) var result = ""
    @Published private(set) var note = "Select text in another app and choose an OmniFlow service."
    @Published private(set) var busy = false
    @Published var action: Action = .cleanup
    @Published var sourceIdentifier = "en"
    @Published var targetIdentifier = "ja"
    @Published var writingStyle: WritingStyle = .apa
    @Published var pastedText = ""
    @Published private(set) var languages: [TranslationLanguage] = []
    var canStart: (() -> Bool)?
    var vocabulary = ""
    var onPresent: (() -> Void)?
    private var target: SelectionTarget?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var canReplace: Bool { target != nil && !result.isEmpty && !busy && result != original }

    func registerServices() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }
    @objc func cleanSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(board, action: .cleanup, error: error)
    }
    @objc func translateSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(board, action: .translate, error: error)
    }
    @objc func styleSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(board, action: .style, error: error)
    }
    private func receive(_ board: NSPasteboard, action: Action, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard !busy, canStart?() ?? true else { error.pointee = "Finish dictation before opening a text action."; return }
        guard let text = board.string(forType: .string), !text.isEmpty else {
            error.pointee = "The service did not receive selected text."; return
        }
        present(text: text, action: action, target: SelectionTarget.capture(matching: text))
    }
    func openSelectedText(action: Action = .cleanup) {
        guard !busy, canStart?() ?? true else { note = "Finish dictation before opening a text action."; return }
        guard let captured = SelectionTarget.capture() else {
            cancel(); target = nil
            note = "Select text in an accessible text field, or use the app’s Services menu to send text for preview."
            onPresent?(); return
        }
        present(text: captured.snapshot.selectedText, action: action, target: captured)
    }
    /// Also supports an explicit pasted-text workflow; it has no replacement destination.
    func preview(text: String, action: Action = .cleanup) {
        present(text: text, action: action, target: nil)
    }
    private func present(text: String, action: Action, target: SelectionTarget?) {
        cancel(); original = text; result = text; self.action = action; self.target = target
        note = target == nil ? "Review text here, then copy the result. This selection cannot be safely replaced." : "Review the result before copying or replacing the original selection."
        onPresent?()
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        if busy { note = "Cancelled. The original and last completed preview are retained." }
        busy = false
    }
    func loadLanguages() async { languages = await TranslationService().supportedLanguages() }
    func run() {
        guard canStart?() ?? true else { note = "Finish dictation before starting a text action."; return }
        cancel()
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = generation, input = original, chosen = action
        let source = sourceIdentifier, destination = targetIdentifier, style = writingStyle, hints = vocabulary
        busy = true; note = "Working on your Mac…"
        task = Task { [weak self] in
            let output: String, detail: String
            if chosen == .translate {
                let translated = await TranslationService().translate(input, source: Locale.Language(identifier: source), target: Locale.Language(identifier: destination))
                output = translated.text; detail = translated.note
            } else {
                let cleaned = await CleanupService().clean(input, locale: Locale(identifier: source), vocabulary: hints, writingStyle: chosen == .style ? style : .faithful)
                output = cleaned.text; detail = cleaned.note
            }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.result = output; self.note = detail; self.busy = false; self.task = nil
        }
    }
    func copyResult() {
        guard !result.isEmpty else { return }
        guard OmniFlowClipboard.copy(result, confirmation: "Result copied") else { return }
        note = "Result copied. Original text remains available below."
    }
    func copyOriginal() {
        guard !original.isEmpty else { return }
        guard OmniFlowClipboard.copy(original, confirmation: "Original copied") else { return }
        note = "Original copied."
    }
    func replaceOriginal() {
        guard canStart?() ?? true else { note = "Finish dictation before replacing text."; return }
        guard canReplace, let destination = target else { return }
        let replacement = result, token = generation
        busy = true
        task = Task { [weak self] in
            let message = await destination.replace(with: replacement)
            guard let self, self.generation == token else { return }
            self.note = message; self.busy = false
            // A mutation is never retried, even if the editor failed to acknowledge it.
            self.target = nil; self.task = nil
        }
    }
}

/// Value/range comparison is deliberately strict: editors that omit either use Copy only.
struct SelectionSnapshot: Equatable {
    let value: String
    let range: NSRange
    var selectedText: String { (value as NSString).substring(with: range) }
    init?(value: String, range: NSRange) {
        guard value.utf16.count <= 100_000, range.location >= 0, range.length > 0,
              range.location <= value.utf16.count, range.length <= value.utf16.count - range.location,
              Range(range, in: value) != nil,
              (value as NSString).rangeOfComposedCharacterSequences(for: range) == range else { return nil }
        self.value = value; self.range = range
    }
    func replacing(with text: String) -> String { (value as NSString).replacingCharacters(in: range, with: text) }
}

@MainActor
private struct SelectionTarget {
    let element: AXUIElement
    let pid: pid_t
    let snapshot: SelectionSnapshot
    static func capture(matching: String? = nil) -> SelectionTarget? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focused(app.processIdentifier), let snapshot = read(element),
              matching == nil || snapshot.selectedText == matching else { return nil }
        var writable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success,
              writable.boolValue else { return nil }
        return .init(element: element, pid: app.processIdentifier, snapshot: snapshot)
    }
    func replace(with replacement: String) async -> String {
        guard !Task.isCancelled, let app = NSRunningApplication(processIdentifier: pid),
              let current = Self.focused(pid), CFEqual(current, element), Self.read(element) == snapshot else {
            return "Replacement paused: the original field or selection changed. Copy the result instead."
        }
        app.activate()
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = Self.focused(pid), CFEqual(focused, element), Self.read(element) == snapshot else {
            return "Replacement paused: the original selection could not be verified. Copy the result instead."
        }
        let outcome = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef)
        // Never retry or blind-paste after sending a mutation, even if AX reports failure.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
        }
        guard outcome == .success, Self.string(element, kAXValueAttribute) == snapshot.replacing(with: replacement) else {
            return "The editor did not confirm replacement. Check the destination before copying; the original is retained here."
        }
        return "Replaced the verified original selection. The original is retained here."
    }
    private static func focused(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private static func read(_ element: AXUIElement) -> SelectionSnapshot? {
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        guard !subrole.localizedCaseInsensitiveContains("secure"),
              let role = string(element, kAXRoleAttribute), [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              let value = string(element, kAXValueAttribute) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let ax = raw as! AXValue
        guard AXValueGetType(ax) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ax, .cfRange, &range),
              let snapshot = SelectionSnapshot(value: value, range: NSRange(location: range.location, length: range.length)),
              string(element, kAXSelectedTextAttribute) == snapshot.selectedText else { return nil }
        return snapshot
    }
}
