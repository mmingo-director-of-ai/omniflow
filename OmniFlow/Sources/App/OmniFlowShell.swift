import AppKit
import Combine
import SwiftUI

/// One ordinary companion window; the optional island is only another presentation.
@MainActor
final class OmniFlowShellController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    static let shared = OmniFlowShellController()
    var isVisible: Bool { window?.isVisible == true && window?.isMiniaturized != true }
    var canPresentFeedback: Bool {
        !NSApp.isHidden && isVisible && window?.isOnActiveSpace == true && window?.occlusionState.contains(.visible) == true
    }

    private init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ section: WorkspaceSection = .dictation, activate: Bool = true) {
        IslandWorkspace.shared.section = section
        AppModel.shared.selectedPage = section.flowPage
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "OmniFlow"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 1040, height: 740)
            window.isReleasedWhenClosed = false
            let toolbar = NSToolbar(identifier: "OmniFlow.MainToolbar")
            toolbar.delegate = self; toolbar.displayMode = .iconOnly; window.toolbar = toolbar
            // Glass belongs to navigation and controls, not a sheet wrapped
            // around the entire opaque content canvas.
            let host = NSHostingView(rootView: OmniFlowShellView())
            let surface = NSView(), backdrop = NSVisualEffectView()
            backdrop.material = .underWindowBackground
            backdrop.blendingMode = .behindWindow; backdrop.state = .followsWindowActiveState
            for view in [backdrop, host] {
                view.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: surface.leadingAnchor), view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                    view.topAnchor.constraint(equalTo: surface.topAnchor), view.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
                ])
            }
            window.isOpaque = false; window.backgroundColor = .clear; window.contentView = surface
            let workArea = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 1000)
            window.setContentSize(NSSize(width: min(1180, workArea.width - 60), height: min(820, workArea.height - 60)))
            window.setFrameAutosaveName("OmniFlow.FreeFlow.v1")
            if !window.setFrameUsingName("OmniFlow.FreeFlow.v1") { window.center() }
            window.delegate = self
            self.window = window
        }
        if activate {
            NSApp.unhide(nil)
            if window?.isMiniaturized == true { window?.deminiaturize(nil) }
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if !NSApp.isHidden {
            window?.orderFrontRegardless()
        }
        OmniFlowActivityPill.shared.refresh()
    }

    func showFlowPage(_ page: String) {
        show(WorkspaceSection(rawValue: page) ?? (page == "Recent" ? .history : .dictation))
        AppModel.shared.selectedPage = page
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("sidebar"), .flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id.rawValue == "sidebar" else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Toggle Sidebar"; item.toolTip = "Show or hide sidebar"
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
        item.target = self; item.action = #selector(toggleSidebar); return item
    }
    @objc private func toggleSidebar() { AppModel.shared.sidebarVisible.toggle() }

    func windowWillClose(_ notification: Notification) {
        // Closing a surface does not own cancellation of voice or assistant work.
        Task { @MainActor in OmniFlowActivityPill.shared.refresh(shellIsClosing: true) }
    }
    func windowDidMiniaturize(_ notification: Notification) { OmniFlowActivityPill.shared.refresh() }
    func windowDidDeminiaturize(_ notification: Notification) { OmniFlowActivityPill.shared.refresh() }
}

/// Shared shell treatment; content forms remain on their ordinary surface.
struct OmniFlowNavigationGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 20

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

private struct OmniFlowShellView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var workspace = IslandWorkspace.shared
    var body: some View {
        HubView(model: model)
            .overlay { OmniFlowToastOverlay() }
            .allowsWindowActivationEvents()
            .tint(Color.flowInk)
            .onChange(of: workspace.section) { _, section in
                model.selectedPage = section.flowPage
            }
    }
}

struct OmniFlowAgentSessionsView: View {
    @ObservedObject private var state = AppState.shared

    private var notice: IslandView? {
        switch state.view {
        case .approval, .question, .error, .finished, .upload, .uploading, .choose, .note, .ambient: return state.view
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let notice {
                    IslandViewContent(view: notice, state: state)
                        .frame(minHeight: 180).clipShape(RoundedRectangle(cornerRadius: 18))
                }
                if state.tasks.isEmpty {
                    ContentUnavailableView("No active agent sessions", systemImage: "terminal",
                        description: Text("Connected coding agents appear here when their hooks report activity."))
                } else {
                    ForEach(state.tasks) { task in
                        SessionCard(task: task, focused: state.focusId == task.id) { state.setFocus(task.id) }
                            .frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }.padding(20)
        }
    }
}

@MainActor
private final class OmniFlowQuickControlsPresentation: ObservableObject {
    @Published var expanded = false
    @Published var showsStatus = false
    @Published var dictation = false
    @Published var bottom = false
}

private final class OmniFlowQuickControlsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A single nonactivating surface: idle tab, revealed controls, then live feedback.
/// All actions use the existing assistant and workspace; visibility never owns capture.
@MainActor
final class OmniFlowActivityPill {
    static let shared = OmniFlowActivityPill()
    private var panel: NSPanel?
    private let presentation = OmniFlowQuickControlsPresentation()
    private var subscriptions: Set<AnyCancellable> = []
    private var collapseTask: Task<Void, Never>?
    private var dismissed = false
    private var stripInteraction = false
    private var anchor: CGPoint?
    private var updatingFrame = false
    private var explicitlyRevealed = false
    private let docking = OmniFlowPillDocking()

    func start() {
        guard subscriptions.isEmpty else { return }
        VoiceAssistant.shared.$phase.combineLatest(AppState.shared.$notchlyEnabled, AppState.shared.$quickControlsEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, _, _ in
                guard let self else { return }
                if [.preparing, .listening, .finishing, .thinking].contains(phase) { dismissed = false; presentation.dictation = false }
                refresh()
            }.store(in: &subscriptions)
        AppModel.shared.$phase.receive(on: DispatchQueue.main).sink { [weak self] phase in
            guard let self else { return }
            if phase != .idle { presentation.dictation = true; dismissed = false }
            refresh()
        }.store(in: &subscriptions)
        // "Prepare to paste again" leaves the phase idle, so it must switch the pill to
        // the dictation surface itself; otherwise the Paste saved text button never shows.
        AppModel.shared.$pendingRetry.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] retry in
            guard let self else { return }
            if retry != nil { presentation.dictation = true; presentation.expanded = true; dismissed = false; collapseTask?.cancel() }
            refresh()
        }.store(in: &subscriptions)
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.docking.cancel(); self?.refresh() }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                guard let window = notification.object as? NSWindow,
                      window === OmniFlowShellController.shared.window else { return }
                self?.refresh()
            }.store(in: &subscriptions)
        if let saved = UserDefaults.standard.array(forKey: "omniflow.quickControlsAnchor") as? [Double],
           saved.count == 2, saved.allSatisfy(\.isFinite) {
            anchor = CGPoint(x: saved[0], y: saved[1])
        }
        refresh()
    }

    func refresh(shellIsClosing: Bool = false) {
        let voice = VoiceAssistant.shared
        let active = voice.isBusy || voice.phase == .speaking || AppModel.shared.isActive
        let hasActivity = presentation.dictation ? AppModel.shared.phase != .idle : voice.phase != .idle || !voice.response.isEmpty
        presentation.showsStatus = !dismissed && hasActivity &&
            (!(OmniFlowShellController.shared.canPresentFeedback && IslandWorkspace.shared.section == (presentation.dictation ? .dictation : .assistant)) || shellIsClosing) &&
            (presentation.dictation || !AppState.shared.notchlyEnabled || stripInteraction)
        guard AppState.shared.quickControlsEnabled || presentation.showsStatus else {
            docking.cancel(); panel?.orderOut(nil); return
        }
        guard !docking.isDragging else { return }
        if active { collapseTask?.cancel(); presentation.expanded = true }
        if panel == nil {
            let panel = OmniFlowQuickControlsPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.canHide = false // Cmd-H hides the main window, not persistent controls.
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = false
            panel.contentView = NSHostingView(rootView: OmniFlowQuickControlsView(presentation: presentation))
            panel.setAccessibilityLabel("OmniFlow floating controls")
            self.panel = panel
            NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
                .sink { [weak self] _ in
                    guard let self, !updatingFrame, docking.isDragging else { return }
                    docking.update(at: NSEvent.mouseLocation)
                }.store(in: &subscriptions)
        }
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let first = screens.first else { panel?.orderOut(nil); return }
        if anchor == nil {
            let display = screens.first(where: { $0.contains(NSEvent.mouseLocation) }) ?? first
            anchor = OmniFlowQuickControlsGeometry.defaultAnchor(visibleFrame: display)
        }
        let placement = docking.placement()
        presentation.bottom = placement?.zone == .bottom
        let idle = presentation.bottom ? CGSize(width: 52, height: 14) : CGSize(width: 14, height: 52)
        let controls = presentation.bottom ? CGSize(width: 158, height: 52) : CGSize(width: 52, height: 158)
        let size: CGSize = presentation.dictation && (presentation.showsStatus || AppModel.shared.isActive || AppModel.shared.pendingRetry != nil) ? CGSize(width: 440, height: 250) : presentation.showsStatus ? CGSize(width: 380, height: 310) :
            (presentation.expanded ? controls : idle)
        let frame = placement.map { OmniFlowQuickControlsGeometry.dockedFrame(zone: $0.zone, size: size, visibleFrame: $0.screen.visibleFrame) } ??
            OmniFlowQuickControlsGeometry.frame(anchor: anchor!, size: size, visibleFrames: screens)
        updatingFrame = true
        panel?.setFrame(frame, display: true)
        updatingFrame = false
        panel?.orderFrontRegardless()
        if !active && !presentation.showsStatus { scheduleCollapse() }
    }

    private var hovering = false
    func hover(_ inside: Bool) {
        hovering = inside
        guard !docking.isDragging else { return }
        collapseTask?.cancel()
        if inside { presentation.expanded = true; refresh() }
        else { scheduleCollapse() }
    }

    func reveal() {
        explicitlyRevealed = true
        collapseTask?.cancel()
        presentation.expanded = true
        refresh()
    }

    func collapse() {
        guard !AppModel.shared.isActive, !VoiceAssistant.shared.isBusy, VoiceAssistant.shared.phase != .speaking else { return }
        explicitlyRevealed = false
        hovering = false
        dismiss()
    }

    private func scheduleCollapse(delay: Double = 0.8) {
        guard !docking.isDragging, !AppModel.shared.isActive, AppModel.shared.pendingRetry == nil, !explicitlyRevealed, !hovering, !presentation.showsStatus, !VoiceAssistant.shared.isBusy,
              VoiceAssistant.shared.phase != .speaking, presentation.expanded else { return }
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !docking.isDragging, !AppModel.shared.isActive, AppModel.shared.pendingRetry == nil, !explicitlyRevealed, !hovering, !presentation.showsStatus,
                  !VoiceAssistant.shared.isBusy, VoiceAssistant.shared.phase != .speaking else { return }
            presentation.expanded = false
            refresh()
        }
    }

    func microphone() {
        stripInteraction = true
        dismissed = false
        presentation.expanded = true
        presentation.dictation = true
        let dictation = AppModel.shared
        if dictation.phase == .recording { dictation.finish() }
        else if dictation.isActive { dictation.cancel() }
        else { dictation.toggleHandsFree() }
        refresh()
    }

    func dismiss() {
        guard !AppModel.shared.isActive, !VoiceAssistant.shared.isBusy, VoiceAssistant.shared.phase != .speaking else { return }
        dismissed = true; stripInteraction = false
        explicitlyRevealed = false
        presentation.expanded = false
        refresh()
    }

    func stop() {
        docking.cancel(); collapseTask?.cancel(); subscriptions.removeAll(); panel?.orderOut(nil); panel = nil
    }

    func beginDragging() {
        collapseTask?.cancel()
        docking.begin(at: NSEvent.mouseLocation)
    }

    func endDragging(moved: Bool) {
        docking.update(at: NSEvent.mouseLocation)
        docking.finish(moved: moved)
        refresh()
    }

    func dock(to zone: OmniFlowPillZone, on screen: NSScreen? = nil) {
        guard let screen = screen ?? panel?.screen ?? NSScreen.main else { return }
        docking.cancel(); docking.set(zone, on: screen)
        AppState.shared.quickControlsEnabled = true
        refresh()
    }
}

private struct OmniFlowQuickControlsView: View {
    @ObservedObject var presentation: OmniFlowQuickControlsPresentation
    @ObservedObject private var voice = VoiceAssistant.shared
    @ObservedObject private var dictation = AppModel.shared

    private var micTitle: String {
        if dictation.phase == .recording { return "Finish dictation" }
        if dictation.isActive { return "Cancel dictation" }
        return "Start dictation · Fn to talk"
    }
    private var micSymbol: String { dictation.isActive ? "stop.fill" : OmniFlowSymbol.dictate }
    private var phaseTitle: String {
        if presentation.dictation {
            switch dictation.phase {
            case .idle: return "Dictation"
            case .starting: return "Preparing microphone"
            case .recording: return "Listening"
            case .processing: return "Processing on your Mac"
            case .result: return "Transcript available"
            case .error: return "Recording needs attention"
            }
        }
        switch voice.phase {
        case .idle: return "Response available"
        case .preparing: return "Preparing microphone"
        case .listening: return "Listening"
        case .finishing: return "Finishing transcript"
        case .thinking: return "Working on it"
        case .speaking: return "Speaking"
        case .needsDownload: return "Speech setup needed"
        case .failed: return "Needs your attention"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if presentation.dictation && (presentation.showsStatus || dictation.isActive || dictation.pendingRetry != nil) {
                OverlayView(model: dictation)
            } else if presentation.expanded || presentation.showsStatus {
                if presentation.bottom && !presentation.showsStatus {
                    horizontalControls.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if geometry.size.height < 158 || geometry.size.width < 52 || (presentation.showsStatus && geometry.size.width < 334) {
                    compactControls(size: geometry.size)
                } else {
                    if presentation.showsStatus {
                        VStack(spacing: 10) {
                            FloatingChatReply()
                            HStack {
                                Image(systemName: "waveform")
                                    .font(.system(size: 25)).foregroundStyle(OmniFlowBrand.interactiveAccent)
                                    .symbolEffect(.variableColor.iterative, isActive: voice.isBusy || voice.phase == .speaking)
                                Text(phaseTitle).font(.callout)
                                Spacer()
                                Button("Open Chat") { IslandWorkspace.shared.show(.assistant) }
                                Button(voice.isBusy || voice.phase == .speaking || voice.voiceChatActive ? "Stop" : "Dismiss") {
                                    voice.cancel(); OmniFlowActivityPill.shared.dismiss()
                                }
                            }.controlSize(.small)
                        }.padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    } else {
                        controls.padding(4)
                    }
                }
            } else {
                ZStack {
                    OmniFlowPillTab(bottom: presentation.bottom)
                    OmniFlowPillDragHandle { OmniFlowActivityPill.shared.reveal() }
                }.accessibilityElement(children: .ignore).accessibilityLabel("OmniFlow voice pill")
                    .accessibilityAction(named: "Show controls") { OmniFlowActivityPill.shared.reveal() }
                    .help("OmniFlow · hover for controls · drag to an edge")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onHover { OmniFlowActivityPill.shared.hover($0) }
        .contextMenu {
            Button(micTitle) { OmniFlowActivityPill.shared.microphone() }
            Button("Open OmniFlow") { IslandWorkspace.shared.show(presentation.dictation ? .dictation : .assistant) }
            Button("Monitoring") { IslandWorkspace.shared.show(.system) }
            Button("Transcripts") { IslandWorkspace.shared.show(.history) }
            Divider()
            Menu("Move voice pill to") {
                ForEach(OmniFlowPillZone.allCases, id: \.self) { zone in
                    Button(zone.title, systemImage: zone.symbol) { OmniFlowActivityPill.shared.dock(to: zone) }
                }
            }
            Button("Collapse controls") { OmniFlowActivityPill.shared.collapse() }
                .disabled(dictation.isActive || voice.isBusy || voice.phase == .speaking)
            Button("Hide floating controls") { AppState.shared.quickControlsEnabled = false }
        }
        .preferredColorScheme(.dark)
    }

    private func compactControls(size: CGSize) -> some View {
        HStack(spacing: 4) {
            Button { OmniFlowActivityPill.shared.microphone() } label: {
                Image(symbol: micSymbol).font(.system(size: max(1, min(16, min(size.width, size.height) - 4))))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.accessibilityLabel(micTitle).help(micTitle)
            if size.width >= 76 {
                Button("Open OmniFlow", systemImage: "arrow.up.right") { IslandWorkspace.shared.show(presentation.dictation ? .dictation : .assistant) }
                    .labelStyle(.iconOnly).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.buttonStyle(.press).frame(width: size.width, height: size.height)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        VStack(spacing: 7) {
            Capsule().fill(.white.opacity(0.3)).frame(width: 16, height: 3)
                .frame(width: 34, height: 12).overlay(OmniFlowPillDragHandle())
                .help("Drag to the left, right or bottom edge")
            quickButton(micTitle, symbol: micSymbol, active: dictation.isActive) {
                OmniFlowActivityPill.shared.microphone()
            }
            quickButton("Open monitoring", symbol: "record.circle", active: false) { IslandWorkspace.shared.show(.system) }
            quickButton("Open transcripts", symbol: "text.bubble", active: false) { IslandWorkspace.shared.show(.history) }
        }.padding(.horizontal, 5).padding(.vertical, 7)
            .frame(width: 44, height: 150)
            .glassEffect(.regular, in: Capsule())
    }

    private var horizontalControls: some View {
        HStack(spacing: 6) {
            Capsule().fill(.white.opacity(0.3)).frame(width: 3, height: 16)
                .frame(width: 12, height: 34).overlay(OmniFlowPillDragHandle())
                .help("Drag to the left, right or bottom edge")
            quickButton(micTitle, symbol: micSymbol, active: dictation.isActive) { OmniFlowActivityPill.shared.microphone() }
            quickButton("Open monitoring", symbol: "record.circle", active: false) { IslandWorkspace.shared.show(.system) }
            quickButton("Open transcripts", symbol: "text.bubble", active: false) { IslandWorkspace.shared.show(.history) }
        }.padding(.horizontal, 7).padding(.vertical, 5)
            .frame(width: 150, height: 44).glassEffect(.regular, in: Capsule())
    }

    private func quickButton(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(symbol: symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(active ? OmniFlowBrand.onAccent : .white.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(active ? OmniFlowBrand.accent : .white.opacity(0.06), in: Circle())
        }.buttonStyle(.press).accessibilityLabel(title).help(title)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: voice.phase == .listening ? "waveform" : "waveform.circle")
                    .foregroundStyle(OmniFlowBrand.accent)
                Text(phaseTitle).font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if !dictation.isActive && !voice.isBusy && voice.phase != .speaking {
                    Button("Dismiss status", systemImage: "xmark") { OmniFlowActivityPill.shared.dismiss() }
                        .labelStyle(.iconOnly).buttonStyle(.press)
                }
            }
            Text(presentation.dictation ? dictation.message : voice.phase == .idle ? "Open OmniFlow to read your response." : voice.message)
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Button("Open OmniFlow") { IslandWorkspace.shared.show(presentation.dictation ? .dictation : .assistant) }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer(minLength: 0)
                if dictation.isActive || voice.isBusy || voice.phase == .speaking {
                    Button("Cancel") { if dictation.isActive { dictation.cancel() } else { voice.cancel() } }.buttonStyle(.borderless).font(.caption)
                }
            }
        }.padding(16).frame(width: 272, height: 150)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
    }
}

/// Layout the tab in its final orientation. Rotating a 12×48 view inside a
/// 52×14 panel leaves its layout vertical and clips the bottom-docked tab.
struct OmniFlowPillTab: View {
    var bottom: Bool
    var body: some View {
        Capsule().fill(.white.opacity(0.55))
            .frame(width: bottom ? 30 : 3, height: bottom ? 3 : 30)
            .frame(width: bottom ? 48 : 12, height: bottom ? 12 : 48)
            .background(.black.opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}
