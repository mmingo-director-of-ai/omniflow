import AppKit
@preconcurrency import ApplicationServices
import Carbon
import SwiftUI
import Combine

struct CursorReference: Codable, Sendable {
    var app: String
    var bundleID: String
    var window: String
    var text: String
    var kind: String
    var capturedAt = Date()
    var modelData: String {
        var bounded = self
        bounded.app = String(app.prefix(100)); bounded.window = String(window.prefix(240))
        bounded.text = String(text.prefix(2400))
        return LocalHostData.json(bounded)
    }
}

/// Small, testable gesture contract. Only Command gestures belong to OmniFlow.
struct CursorGesture {
    static func isEngaged(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty
    }
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        return rect.width >= 8 && rect.height >= 8 ? rect : nil
    }
}

@MainActor
final class CursorActions: NSObject, ObservableObject {
    static let shared = CursorActions()
    @Published private(set) var reference: CursorReference?
    @Published private(set) var preview: NSImage?
    @Published private(set) var message = "Select text or draw a region to give OmniFlow a reference."
    @Published private(set) var loading = false
    @Published private(set) var gesturesAvailable = false
    @Published private(set) var shortcutAvailable = false
    private var panel: CursorActionPanel?
    private var outline: NSPanel?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private let inputDiagnostics = InputEventDiagnostics("cursor-session")
    private var pendingDown: CGEvent?
    private var dragStart: CGPoint?
    private var regionActive = false
    private var cancelledDrag = false
    private var rightClick = false
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private let gestureLease = OmniFlowInteractionLease(reason: "Cursor region gesture")
    private let captureLease = OmniFlowInteractionLease(reason: "Cursor reference capture")
    private let panelLease = OmniFlowInteractionLease(reason: "Cursor action panel")
    private var subscriptions: Set<AnyCancellable> = []

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.close() }.store(in: &subscriptions)
    }

    func start() {
        #if !APPSTORE
        if tap == nil, AXIsProcessTrusted() {
            let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: { proxy, type, event, _ in
                    let pass = MainActor.assumeIsolated { CursorActions.shared.handle(proxy: proxy, type: type, event: event) != nil }
                    return pass ? Unmanaged.passUnretained(event) : nil
                }, userInfo: nil)
            if let tap {
                tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                gesturesAvailable = true
            }
        }
        registerShortcut()
        #endif
    }

    func stop() {
        close()
        cancelRegion()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil; gesturesAvailable = false
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKey = nil; hotKeyHandler = nil; shortcutAvailable = false
    }

    private func registerShortcut() {
        guard hotKey == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x4E4C4358 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in CursorActions.shared.engage(at: NSEvent.mouseLocation) }
            return noErr
        }, 1, &event, nil, &hotKeyHandler) == noErr else { return }
        shortcutAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: 0x4E4C4358, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    // Main-run-loop tap: no Accessibility, screenshots or model work inside the callback.
    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let started = ProcessInfo.processInfo.systemUptime
        inputDiagnostics.observe(type, event)
        defer { inputDiagnostics.finished(since: started) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            inputDiagnostics.disabled()
            cancelRegion()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let point = event.location
        let appPoint = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == kVK_Escape,
           regionActive || panel?.isVisible == true || pendingDown != nil {
            close()
            return nil
        }
        if type == .rightMouseUp, rightClick { rightClick = false; return nil }
        if type == .leftMouseUp, let down = pendingDown {
            defer { cancelRegion() }
            if cancelledDrag { return nil }
            if let start = dragStart, let rect = CursorGesture.rectangle(from: start, to: point), regionActive {
                outline?.orderOut(nil); outline = nil
                // Establish capture/panel leases before releasing the gesture.
                // Screenshot/OCR work still starts asynchronously below.
                captureRegion(rect, anchor: appPoint)
                return nil
            }
            // A Command-click without a box is still the host app's normal click.
            down.tapPostEvent(proxy)
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDragged, pendingDown != nil {
            if !cancelledDrag, let start = dragStart, let rect = CursorGesture.rectangle(from: start, to: point) {
                regionActive = true; drawRegion(rect)
            }
            return nil
        }
        if let panel, panel.isVisible, panel.frame.contains(appPoint) { return Unmanaged.passUnretained(event) }
        if type == .leftMouseDown || type == .rightMouseDown { close() }
        guard CursorGesture.isEngaged(event.flags) else { return Unmanaged.passUnretained(event) }
        if type == .rightMouseDown {
            rightClick = true
            engage(at: appPoint)
            return nil
        }
        if type == .leftMouseDown {
            gestureLease.begin()
            pendingDown = event.copy(); dragStart = point; cancelledDrag = false
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    func engage(at point: CGPoint) {
        let capture = beginReferenceCapture()
        let token = UUID(); generation = token
        loading = true; message = "Reading your selection…"
        work = Task { [weak self] in
            defer { self?.captureLease.end(capture) }
            let snapshot = await AgentCursor.shared.snapshot(at: point) ?? AgentCursor.shared.context.flatMap {
                Date().timeIntervalSince($0.capturedAt) < 120 ? $0 : nil
            }
            guard let self, !Task.isCancelled, generation == token else { return }
            loading = false
            if let snapshot, !snapshot.protectedContent {
                reference = CursorReference(app: snapshot.app, bundleID: snapshot.bundleID, window: snapshot.window,
                    text: snapshot.selectedText.isEmpty ? snapshot.label : snapshot.selectedText,
                    kind: snapshot.selectedText.isEmpty ? "Pointed control" : "Selected text")
                message = snapshot.selectedText.isEmpty ? "This app didn't expose selected text. Command-drag a box to capture it." : "Your selection is ready."
            } else {
                if snapshot?.protectedContent == true { message = "Protected content is excluded." }
                else if !AXIsProcessTrusted() { message = "Allow Accessibility in OmniFlow Settings to read your selection." }
                else { message = "Select text in another app, then Command–right-click here. You can also Command-drag a region." }
            }
            show(at: point)
        }
    }

    @objc func useSelection(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let capture = beginReferenceCapture()
        defer { captureLease.end(capture) }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let app = MacContext.foregroundApp
        reference = CursorReference(app: app?.localizedName ?? "Selection", bundleID: app?.bundleIdentifier ?? "",
                                    window: "", text: String(text.prefix(6000)), kind: "Selected text")
        message = "Your selection is ready."
        show(at: NSEvent.mouseLocation)
    }

    func useClipboard() {
        // Clipboard reading can overlap an in-flight region capture. It owns
        // its own suspension instead of ending that capture's shared token.
        let clipboard = OmniFlowInteractionLease(reason: "Clipboard reference")
        clipboard.begin()
        defer { clipboard.end() }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { message = "Copy text in the source app first."; return }
        reference = CursorReference(app: "Clipboard", bundleID: "", window: "", text: String(text.prefix(6000)), kind: "Copied text")
        preview = nil; message = "Copied text is ready."
    }

    private func captureRegion(_ rect: CGRect, anchor: CGPoint) {
        let capture = beginReferenceCapture()
        let app = MacContext.foregroundApp
        let token = UUID(); generation = token
        loading = true; message = "Reading this region on your Mac…"
        show(at: anchor)
        work = Task { [weak self] in
            defer { self?.captureLease.end(capture) }
            do {
                let captured = try await MacScreenContext.region(rect, foreground: app)
                guard let self, !Task.isCancelled, generation == token else { return }
                reference = CursorReference(app: app?.localizedName ?? "Screen", bundleID: app?.bundleIdentifier ?? "",
                    window: captured.window, text: captured.text, kind: "Screen region")
                preview = NSImage(cgImage: captured.image, size: .zero)
                loading = false; message = "Region captured for your next question."
            } catch {
                guard let self, generation == token else { return }
                loading = false; message = error.localizedDescription
            }
        }
    }

    func ask(_ question: String) {
        guard let reference, !reference.text.isEmpty else { return }
        let data = reference.modelData
        close()
        VoiceAssistant.shared.ask(question, reference: data)
    }

    func watch() {
        guard let reference else { return }
        close()
        AmbientDraft.shared.reference = reference
        IslandWorkspace.shared.show(.ambient)
    }

    func close() {
        generation = UUID(); work?.cancel(); work = nil
        panel?.orderOut(nil); panel = nil
        reference = nil; preview = nil; loading = false
        captureLease.end()
        panelLease.end()
        cancelRegion(preserveSuppressedMouseUps: true)
    }

    private func beginReferenceCapture() -> UUID {
        // Clearing the previous panel/gesture must not briefly restore focus
        // following before this capture owns its own suspension.
        let handoff = OmniFlowFocusController.shared.suspend(reason: "Cursor capture handoff")
        defer { OmniFlowFocusController.shared.resume(handoff) }
        close()
        return captureLease.begin()
    }

    private func show(at point: CGPoint) {
        panelLease.begin()
        let panel = CursorActionPanel(contentRect: CGRect(x: 0, y: 0, width: 350, height: 390),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: CursorActionsView())
        let bounds = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame ?? NSScreen.main!.visibleFrame
        panel.setFrameOrigin(CGPoint(x: min(max(bounds.minX + 8, point.x + 12), bounds.maxX - 358),
                                     y: min(max(bounds.minY + 8, point.y - 402), bounds.maxY - 398)))
        self.panel = panel
        panel.orderFrontRegardless(); panel.makeKey()
    }

    private func drawRegion(_ rect: CGRect) {
        if outline == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = RegionOutlineView()
            outline = panel
        }
        let frame = CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - rect.maxY,
                           width: rect.width, height: rect.height)
        outline?.setFrame(frame, display: true)
        outline?.orderFrontRegardless()
    }

    private func cancelRegion(preserveSuppressedMouseUps: Bool = false) {
        outline?.orderOut(nil); outline = nil
        // If its down event was swallowed, a cancelled gesture must swallow
        // the matching up too, without retaining focus protection after cancel.
        if !preserveSuppressedMouseUps { pendingDown = nil; rightClick = false }
        dragStart = nil; regionActive = false; cancelledDrag = pendingDown != nil
        gestureLease.end()
    }
}

private final class CursorActionPanel: NSPanel {
    nonisolated override var canBecomeKey: Bool { true }
    nonisolated override var canBecomeMain: Bool { false }
}

private final class RegionOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(NotchLeeTheme.accent).withAlphaComponent(0.1).setFill()
        bounds.fill()
        NSColor(NotchLeeTheme.accent).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2; border.stroke()
    }
}

private struct CursorActionsView: View {
    @ObservedObject private var actions = CursorActions.shared
    @State private var question = ""
    private let quick = [("Explain", "text.magnifyingglass", "Explain this reference clearly."),
                         ("Summarize", "text.alignleft", "Summarize this reference briefly."),
                         ("Rewrite", "pencil.line", "Rewrite this reference for clarity, preserving its meaning."),
                         ("Translate", "character.bubble", "Translate this reference into English.")]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RedPandaView(state: .idle).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OmniFlow").font(.headline)
                    Text(actions.reference?.app ?? "Cursor actions").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { actions.close() } label: { Image(systemName: "xmark") }.buttonStyle(.press).help("Close · Escape")
            }
            if actions.loading { ProgressView(actions.message).controlSize(.small) }
            else {
                HStack(alignment: .top, spacing: 8) {
                    if let image = actions.preview { Image(nsImage: image).resizable().scaledToFit().frame(width: 72, height: 52).clipShape(RoundedRectangle(cornerRadius: 6)) }
                    Text(actions.reference?.text.isEmpty == false ? String(actions.reference!.text.prefix(300)) : actions.message)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(10).frame(height: 74).background(NotchLeeTheme.card, in: RoundedRectangle(cornerRadius: 10))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(quick.enumerated()), id: \.offset) { index, item in
                    Button { actions.ask(item.2) } label: {
                        HStack { Image(systemName: item.1).foregroundStyle(NotchLeeTheme.accent); Text(item.0); Spacer(); Text("⌘\(index + 1)").foregroundStyle(.secondary) }
                            .font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.bordered).keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .disabled(actions.reference?.text.isEmpty != false || actions.loading)
                }
                Button { actions.watch() } label: { Label("Watch this", systemImage: "eye").frame(maxWidth: .infinity).padding(.vertical, 5) }
                    .buttonStyle(.bordered).keyboardShortcut("5", modifiers: .command).disabled(actions.reference?.bundleID.isEmpty != false)
                Button { actions.useClipboard() } label: { Label("Use copied text", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity).padding(.vertical, 5) }.buttonStyle(.bordered)
            }
            HStack {
                TextField("Ask about this…", text: $question).textFieldStyle(.plain).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.press)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || actions.reference?.text.isEmpty != false)
            }.padding(10).background(NotchLeeTheme.card, in: RoundedRectangle(cornerRadius: 10))
            Text("⌘ right-click · ⌘ drag a box · ⌃⌥C").font(.caption2).foregroundStyle(NotchLeeTheme.sage)
            Spacer(minLength: 0)
        }.padding(16).background(NotchLeeTheme.canvas, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(NotchLeeTheme.border))
            .foregroundStyle(NotchLeeTheme.paper).tint(NotchLeeTheme.accent)
            .preferredColorScheme(.dark).onExitCommand { actions.close() }
    }
    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { actions.ask(text) }
    }
}
