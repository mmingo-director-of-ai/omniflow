import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandWindowController: NSWindowController {

    private var islandPanel: IslandPanel!
    private var state: AppState { AppState.shared }

    // State machine (replaces all hover/absence/auto-close timers)
    let fsm = IslandStateMachine()

    private var wasInIsland = false
    /// Pointer tracking is event-driven: no work while the mouse is still.
    private var pointerMonitors: [Any] = []
    private var pointerCheckQueued = false
    /// Display asleep or session switched away: no tracking, no animation.
    private var systemInactive = Set<String>()
    private var systemSubscriptions = Set<AnyCancellable>()
    private let presence = IslandPresence()
    private var keyMonitor: Any?
    private var viewSubscription: AnyCancellable?
    private var wakeSubscription: AnyCancellable?
    private var presentationSubscription: AnyCancellable?

    // Confused recovery timer (set by handleDizzy)
    private var confusedRecoveryTimer: DispatchWorkItem?

    // Finished-pin timer
    private var finishedPinTimer: DispatchWorkItem?

    // Bot-head hover (love emote — mirrors prototype botHover())
    private var hoverTimer: DispatchWorkItem?
    private var botHoverTimer: DispatchWorkItem?
    private var botHovering: Bool = false
    private var lastLoveTime: Double = 0
    private var botHoverStartPos: CGPoint = .zero

    // Island repositioning
    private var islandDragStart: NSPoint? = nil
    private var islandDragGrabPoint: CGPoint = .zero
    private var pendingIslandClick = false   // any island click → expand on mouseUp
    private var isRepositioning = false
    // Notch real dimensions (set on init)
    private var notchW: CGFloat = IslandConst.notchWidth
    private var notchH: CGFloat = IslandConst.notchHeight
    private var hasNotch = true

    convenience init() {
        let screen = Self.preferredScreen(for: AppState.shared)!
        let geometry = Self.screenGeometry(for: screen)
        let nW = geometry.width
        let nH = geometry.height

        let sf = screen.frame
        // Full-screen transparent panel lets the island move along any screen edge.
        // It stays click-through
        // except over the island itself (toggled in pollFrame).
        let panel = IslandPanel(
            contentRect: sf,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.notchWidth  = nW
        panel.notchHeight = nH

        self.init(window: panel)
        self.islandPanel = panel
        self.notchW = nW
        self.notchH = nH
        self.hasNotch = geometry.hasNotch
        setupPanel(screen: screen)
    }

    private func setupPanel(screen: NSScreen) {
        guard let panel = window as? IslandPanel else { return }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.canHide = false // The island remains available when the main window is hidden.
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        // Propagate real notch dimensions to AppState
        AppState.shared.notchWidth  = notchW
        AppState.shared.notchHeight = notchH
        AppState.shared.hasNotch = hasNotch
        state.islandDisplayID = Self.displayID(for: screen)

        let contentSize = panel.contentRect(forFrameRect: panel.frame).size

        // Apple-recommended pattern: put NSHostingView and drag destination as siblings
        // inside a common superview, rather than embedding one inside the other.
        let container = IslandTrackingView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]
        // While the panel accepts the mouse, moves go to this app and global
        // monitors are blind; the tracking area keeps hover/leave detection alive.
        container.onPointerMoved = { [weak self] in self?.pollFrame() }
        panel.acceptsMouseMovedEvents = true

        let hosting = NSHostingView(rootView: IslandHostView(presence: presence).environmentObject(AppState.shared))
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]

        // FileDropNSView sits below the hosting view (hitTest returns nil → no mouse interference).
        // AppKit routes NSDraggingDestination events to registered views independently of hitTest.
        let dropView = FileDropNSView(frame: NSRect(origin: .zero, size: contentSize))
        dropView.autoresizingMask = [.width, .height]
        dropView.onDragEntered = { [weak self] loc in
            Task { @MainActor in
                let iLoc = self?.windowToIsland(loc) ?? CGPoint(x: 320, y: 88)
                AppState.shared.fileDragOver = true
                // enterZone sets isActive=true BEFORE hookExpand triggers re-render,
                // so IslandContainer sees isActive=true when state.view becomes .upload.
                UploadSequenceEngine.shared.enterZone(x: iLoc.x, y: iLoc.y)
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.upload)
                NotificationCenter.default.post(name: .botMorphTo, object: CGFloat(1))
            }
        }
        dropView.onDragUpdated = { [weak self] loc in
            Task { @MainActor in
                let iLoc = self?.windowToIsland(loc) ?? CGPoint(x: 320, y: 88)
                UploadSequenceEngine.shared.updateCursor(x: iLoc.x, y: iLoc.y)
            }
        }
        dropView.onDragExited = {
            Task { @MainActor in
                AppState.shared.fileDragOver = false
                // Do NOT collapse — drag session still active; island stays open.
                NotificationCenter.default.post(name: .botMorphTo, object: CGFloat(0))
                UploadSequenceEngine.shared.exitZone()
            }
        }
        dropView.onFilesDropped = { urls in
            Task { @MainActor in
                await FileDropHandler.handle(urls: urls, state: AppState.shared)
            }
        }

        container.addSubview(hosting)    // z-bottom: SwiftUI + mouse events
        container.addSubview(dropView)   // z-top: drag only (hitTest→nil, transparent to mouse)
        panel.contentView = container

        startPolling()
        startKeyMonitor()
        observeSystemActivity()
        wireFSM()
        wakeSubscription = WakeListener.shared.$enabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.state.mode != .expanded else { return }
                self.setMode(self.baseMode())
            }

        presentationSubscription = state.$notchlyEnabled.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.window?.orderFrontRegardless()
                    self.startPolling()
                    self.fsm.launch()
                } else {
                    self.fsm.cancelTimers()
                    self.stopPolling()
                    self.hoverTimer?.cancel(); self.botHoverTimer?.cancel()
                    self.wasInIsland = false
                    self.islandPanel.ignoresMouseEvents = true
                    self.window?.orderOut(nil)
                    self.state.mode = .hidden
                }
                OmniFlowActivityPill.shared.refresh()
            }

        // View changes are presentation only. Clicking an editable control can
        // make the panel key; background updates and guide restoration cannot.
        viewSubscription = state.$view
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newView in
                guard let self, self.state.notchlyEnabled else { return }
                if newView == .voice || newView == .workspace {
                    self.fsm.expandedExternally()
                } else if self.fsm.state == .home && !self.wasInIsland {
                    self.fsm.mouseLeft()
                }
            }
    }

    // MARK: - FSM wiring

    private func wireFSM() {
        fsm.onTransition = { [weak self] from, to in
            guard let self else { return }
            switch to {
            case .hidden:
                self.setMode(.hidden)

            case .petit:
                if from == .coucou {
                    // Fire interrupt first so canvas collapse starts before mode change
                    NotificationCenter.default.post(name: .greetingInterrupt, object: nil)
                } else if from == .hidden {
                    SoundEngine.shared.play("peek")
                }
                // setMode BEFORE changing view: onChange(of: state.view) guards on .expanded,
                // so setting view while already compact won't trigger a spurious open animation.
                self.setMode(.compact)
                if from == .coucou { self.state.view = self.defaultView() }
                // Start 60s hide timer if mouse is not currently over the island
                if !self.wasInIsland { self.fsm.mouseLeft() }

            case .home:
                self.expand(to: self.defaultView())
                // Start collapse timer if mouse not currently hovering
                if !self.wasInIsland {
                    self.fsm.mouseLeft()
                }

            case .coucou:
                self.expand(to: .greeting)
            }
        }

        // FSM observes greetComplete notification
        NotificationCenter.default.addObserver(
            forName: .greetComplete, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fsm.greetComplete() }
        }
    }

    // MARK: - Pointer tracking (event-driven)

    /// Mouse-move monitors replace the former 60 Hz timer: a still pointer costs nothing.
    private func startPolling() {
        guard state.notchlyEnabled, systemInactive.isEmpty, pointerMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFrame() }
        }) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pollFrame() }
            return event
        }) { pointerMonitors.append(local) }
        pollFrame()
    }

    private func stopPolling() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
    }

    /// The island can grow or move under a still pointer; re-check once after layout.
    private func schedulePointerCheck() {
        guard !pointerCheckQueued, !pointerMonitors.isEmpty else { return }
        pointerCheckQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pointerCheckQueued = false
                self.pollFrame()
            }
        }
    }

    private func observeSystemActivity() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (pause, resume, reason) in [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")
        ] {
            workspace.publisher(for: pause).receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.systemInactive.insert(reason)
                self.stopPolling()
                self.updatePresence()
            }.store(in: &systemSubscriptions)
            workspace.publisher(for: resume).receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.systemInactive.remove(reason)
                self.updatePresence()
                self.startPolling()
            }.store(in: &systemSubscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedulePointerCheck() }
            .store(in: &systemSubscriptions)
        Publishers.MergeMany(
            state.$mode.map { _ in () }.eraseToAnyPublisher(),
            state.$view.map { _ in () }.eraseToAnyPublisher(),
            state.$islandEdge.map { _ in () }.eraseToAnyPublisher(),
            state.$islandXOffset.map { _ in () }.eraseToAnyPublisher(),
            state.$tasks.map(\.count).removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in self?.schedulePointerCheck() }
        .store(in: &systemSubscriptions)
        updatePresence()
    }

    /// Occlusion state is not used: a clear, click-through full-screen panel can
    /// report itself occluded while its island is drawn, which would freeze it.
    private func updatePresence() {
        let paused = !systemInactive.isEmpty
        if presence.animationsPaused != paused { presence.animationsPaused = paused }
    }

    private func pollFrame() {
        guard state.notchlyEnabled, let panel = window as? IslandPanel else { return }

        let mouse = NSEvent.mouseLocation

        // Convert mouse to panel-local coords (macOS: origin bottom-left)
        let pf = panel.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)

        // Island rect in panel coords
        let islandRect = panel.currentIslandFrame(nw: notchW, nh: notchH)
        // On a screen without a notch, the resting bar must not intercept clicks
        // in the app window immediately below the menu bar.
        let hoverRect = !hasNotch && state.mode != .expanded
            ? islandRect : islandRect.insetBy(dx: -6, dy: -6)
        let inIsland = hoverRect.contains(local)

        // Toggle click-through
        let shouldAcceptMouse = inIsland || isRepositioning || islandDragStart != nil
        if panel.ignoresMouseEvents == shouldAcceptMouse {
            panel.ignoresMouseEvents = !shouldAcceptMouse
            if shouldAcceptMouse, let cv = panel.contentView {
                panel.invalidateCursorRects(for: cv)
            }
        }

        // Mouse in screen coords (Y flipped, origin top-left) for Bot look-at
        let screenH = panel.screen?.frame.height ?? NSScreen.main!.frame.height
        let newPos = CGPoint(x: mouse.x - (panel.screen?.frame.minX ?? 0),
                             y: (panel.screen?.frame.maxY ?? screenH) - mouse.y)
        let cur = AppState.shared.mousePosition
        if abs(newPos.x - cur.x) > 1 || abs(newPos.y - cur.y) > 1 {
            AppState.shared.mousePosition = newPos
        }

        // AppState can hide the island by itself (last task ended): keep the FSM in step.
        if state.mode == .hidden && fsm.state == .petit { fsm.hiddenExternally() }

        // Feed FSM hover enter/leave
        if inIsland && !wasInIsland {
            guard !isRepositioning else { wasInIsland = inIsland; return }
            // If in coucou: tell greeting to stay open (tc → infinity)
            if fsm.state == .coucou {
                NotificationCenter.default.post(name: .greetingHover, object: nil)
            }
            fsm.mouseEntered()
            // Option: expand fully on hover instead of just peeking, except
            // when the pointer arrives on a control (the Reading badge).
            let onControl = IslandControlZones.contains(local, windowHeight: panel.contentView?.bounds.height ?? panel.frame.height)
            if state.expandOnHover, !onControl, fsm.state != .coucou, state.mode != .expanded {
                fsm.click()
            }
        }
        if !inIsland && wasInIsland {
            if state.view == .voice || state.view == .workspace { fsm.cancelTimers() }
            else { fsm.mouseLeft() }
        }
        wasInIsland = inIsland

        // Bot-head hover (love emote)
        let overBot = state.mode == .expanded && state.stateOverride == nil && isBotHit(local)
        if overBot && !botHovering { botHoverIn(mousePos: NSEvent.mouseLocation) }
        if !overBot && botHovering { botHoverOut() }
        botHovering = overBot
        if botHovering {
            let m = NSEvent.mouseLocation
            let dist = hypot(m.x - botHoverStartPos.x, m.y - botHoverStartPos.y)
            if dist > 40 {
                botHoverStartPos = m
                botHoverTimer?.cancel()
                scheduleLoveTimer()
            }
        }

    }

    private var lastMouse: CGPoint = .zero

    // MARK: - Bot-head hover (love emote — mirrors prototype botHover())

    private func botHoverIn(mousePos: CGPoint) {
        guard state.mode == .expanded, state.stateOverride == nil else { return }
        guard CACurrentMediaTime() - lastLoveTime > 6 else { return }
        botHoverStartPos = mousePos
        NotificationCenter.default.post(name: .botBlink, object: nil)
        NotificationCenter.default.post(name: .botSetTgEs, object: CGFloat(1.08))
        SoundEngine.shared.play("hover")
        scheduleLoveTimer()
    }

    private func botHoverOut() {
        botHoverTimer?.cancel()
        NotificationCenter.default.post(name: .botSetTgEs, object: CGFloat(1))
    }

    private func scheduleLoveTimer() {
        botHoverTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.botHovering, self.state.stateOverride == nil else { return }
            guard CACurrentMediaTime() - self.lastLoveTime > 6 else { return }
            self.lastLoveTime = CACurrentMediaTime()
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.love)
            SoundEngine.shared.play("love")
        }
        botHoverTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: item)
    }

    private func scheduleHover(after delay: TimeInterval, action: @escaping () -> Void) {
        hoverTimer?.cancel()
        let item = DispatchWorkItem(block: action)
        hoverTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Mode transitions

    private func modeLevel(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }

    func setMode(_ mode: IslandMode) {
        guard state.notchlyEnabled else { state.mode = .hidden; return }
        let mode = mode == .hidden && state.isPresent && WakeListener.shared.enabled ? IslandMode.compact : mode
        let prev = state.mode
        guard mode != prev else { return }
        let shrinking = modeLevel(mode) < modeLevel(prev)
        let anim: Animation = shrinking
            ? .timingCurve(0.45, 0, 0.2, 1, duration: 0.34)
            : .spring(response: 0.5, dampingFraction: 0.72)
        withAnimation(anim) { state.mode = mode }
        if mode == .expanded { SoundEngine.shared.play("open") }
        if prev == .expanded { SoundEngine.shared.play("close"); state.isPinned = false }
    }

    func expand(to view: IslandView) {
        state.view = view
        guard state.notchlyEnabled else {
            let section: WorkspaceSection
            switch view {
            case .voice: section = .assistant
            case .workspace: section = IslandWorkspace.shared.section
            case .settings: section = .settings
            default: section = .sessions
            }
            OmniFlowShellController.shared.show(section, activate: false)
            return
        }
        if state.mode == .expanded {
            // Already expanded — just switch view
        } else {
            setMode(.expanded)
        }
        state.lastActivity = .now
    }

    func collapse() {
        state.isPinned = false
        finishedPinTimer?.cancel()
        // Keep the FSM in step with what is on screen (home/coucou → petit now).
        fsm.collapse()
        setMode(.compact)
        window?.resignKey()
    }

    // MARK: - Continuous edge placement

    /// Stay attached to the nearest edge and follow the pointer without preset stop positions.
    private func dragIslandTo(cursor mouse: NSPoint) {
        guard let panel = window as? IslandPanel,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? panel.screen else { return }
        if panel.frame != screen.frame {
            let geometry = Self.screenGeometry(for: screen)
            notchW = geometry.width
            notchH = geometry.height
            hasNotch = geometry.hasNotch
            panel.notchWidth = notchW
            panel.notchHeight = notchH
            state.notchWidth = notchW
            state.notchHeight = notchH
            state.hasNotch = hasNotch
            panel.setFrame(screen.frame, display: true)
        }
        let displayID = Self.displayID(for: screen)
        if state.islandDisplayID != displayID { state.islandDisplayID = displayID }
        let cursor = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
        let edge = IslandEdge.nearest(to: cursor, in: screen.frame.size)
        let (width, height) = islandSize(mode: state.mode, view: state.view,
                                         nw: notchW, nh: notchH,
                                         vertical: edge.isVertical, agentCount: state.tasks.count)
        let layout = IslandDockLayout(panelSize: screen.frame.size,
                                      islandSize: CGSize(width: width, height: height),
                                      edge: edge, offset: state.islandXOffset)
        state.islandEdge = edge
        state.islandXOffset = layout.dragOffset(cursor: cursor, grabPoint: islandDragGrabPoint)
    }

    // MARK: - Keyboard (Escape closes)

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                if event.keyCode == 53 { // Escape
                    if self.state.mode == .expanded && !self.state.isPinned {
                        self.collapse()
                    }
                }
            }
        }

        // Hook server expand requests (alerts only)
        NotificationCenter.default.addObserver(forName: .hookExpand, object: nil, queue: .main) { [weak self] note in
            let view = note.object as? IslandView
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.expand(to: view)
            }
        }

        // Hook server compact reveal (non-alert work events: session start, tool use, etc.)
        NotificationCenter.default.addObserver(forName: .hookReveal, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.notchlyEnabled else { return }
                self.fsm.reveal()
            }
        }

        // Collapse requests from views (OK button, etc.)
        NotificationCenter.default.addObserver(forName: .islandCollapse, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }

        // .botDizzy — posted by BotEngine.slap() on 3rd hit; show confused view + recover after 3.3s
        NotificationCenter.default.addObserver(forName: .botDizzy, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDizzy() }
        }

        // Drag the island along its attached surface.
        // Uses MainActor.assumeIsolated (synchronous) to avoid race with pollFrame().
        // Global mouseUp is the reliable fallback when cursor is outside our panel frame.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                // Hover state may be stale if the island changed under a still pointer.
                self.pollFrame()
                guard self.wasInIsland else { return }
                // A click on a control inside the island (the Reading badge) is not an open request.
                if let window = event.window,
                   IslandControlZones.contains(event.locationInWindow, windowHeight: window.contentView?.bounds.height ?? window.frame.height) { return }
                self.pendingIslandClick = true
                self.hoverTimer?.cancel()
                self.botHoverTimer?.cancel()
                self.botHovering = false
                // Drag can start anywhere on the island: press-and-move repositions it,
                // press-and-release (no move) is still a click/open.
                self.islandDragStart = NSEvent.mouseLocation
                if let panel = self.window as? IslandPanel {
                    let frame = panel.currentIslandFrame(nw: self.notchW, nh: self.notchH)
                    self.islandDragGrabPoint = CGPoint(
                        x: min(1, max(0, (event.locationInWindow.x - frame.minX) / frame.width)),
                        y: min(1, max(0, (frame.maxY - event.locationInWindow.y) / frame.height))
                    )
                }
                // Poking the bot head (expanded) still slaps.
                if self.state.mode == .expanded, self.isBotHit(event.locationInWindow) {
                    NotificationCenter.default.post(name: .triggerSlap, object: nil)
                }
            }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard let start = self.islandDragStart else { return }
                let m = NSEvent.mouseLocation
                if !self.isRepositioning {
                    guard hypot(m.x - start.x, m.y - start.y) > 3 else { return }
                    self.isRepositioning = true
                    NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.love)
                }
                // Follow the edge continuously; orientation follows the attached surface.
                self.dragIslandTo(cursor: m)
            }
            return event
        }

        // mouseUp — local (cursor still in panel) + global (cursor moved outside panel frame)
        let finishDrag: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRepositioning else { return }
                self.isRepositioning = false
                self.islandDragStart = nil
                self.state.stateOverride = nil
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let hadPendingClick = self.pendingIslandClick
                let wasDragging     = self.isRepositioning
                self.pendingIslandClick = false
                if wasDragging {
                    finishDrag()
                } else {
                    self.islandDragStart = nil
                    if hadPendingClick && self.state.mode != .expanded {
                        if self.fsm.state == .home {
                            // FSM already thinks it's open (e.g. the view folded it): just reopen.
                            self.expand(to: self.defaultView())
                        } else {
                            self.fsm.click()   // FSM petit/hidden→home; onTransition calls expand(to:)
                        }
                    }
                }
            }
            return event
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            finishDrag()
        }

        // Global hotkey to show island
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self, self.state.hotkeyEnabled else { return }
                let pressed = event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue
                guard pressed == self.state.hotkeyFlags, event.keyCode == self.state.hotkeyCode else { return }
                if self.state.mode == .hidden || self.state.mode == .compact {
                    self.expand(to: .overview)
                }
            }
        }

        // Track last external app for window context capture
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, app.bundleIdentifier != ourBundle else { return }
                self.state.lastExternalApp = app
            }
        }
    }

    // MARK: - Coordinate conversion: window (AppKit, y-up) → island coords (y-down, 0,0 = island top-left)

    func windowToIsland(_ loc: CGPoint) -> CGPoint {
        guard let panel = window as? IslandPanel else { return .zero }
        let frame = panel.currentIslandFrame(nw: notchW, nh: notchH)
        return CGPoint(x: loc.x - frame.minX, y: frame.maxY - loc.y)
    }

    // MARK: - Helpers

    func defaultView() -> IslandView {
        state.tasks.isEmpty ? .empty : .overview
    }

    func baseMode() -> IslandMode {
        guard state.isPresent else { return .hidden }
        return state.tasks.isEmpty && !WakeListener.shared.enabled ? .hidden : .compact
    }

    // MARK: - Activity reset (call on any user interaction in island)

    func resetActivity() {
        state.lastActivity = .now
    }

    // MARK: - Finished task pin (5.2s)

    func pinForFinished(taskId: String) {
        state.isPinned = true
        finishedPinTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.removeTask(id: taskId)
            self.state.isPinned = false
            self.collapse()
        }
        finishedPinTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2, execute: item)
    }

    // MARK: - Dizzy recovery (triggered by BotEngine.slap via .botDizzy)

    private func handleDizzy() {
        let prevView = state.view
        state.stateOverride = .dizzy
        expand(to: .confused)
        confusedRecoveryTimer?.cancel()
        let recovery = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.stateOverride = nil
            if self.state.view == .confused {
                let fallback = self.state.tasks.isEmpty ? IslandView.empty : .overview
                self.state.view = (prevView == .confused) ? fallback : prevView
            }
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        }
        confusedRecoveryTimer = recovery
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3, execute: recovery)
    }

    // MARK: - Bot hit test (for slap trigger)

    private func isBotHit(_ windowPoint: CGPoint) -> Bool {
        guard let panel = window as? IslandPanel else { return false }
        let frame = panel.currentIslandFrame(nw: notchW, nh: notchH)
        let (cx, cy, diameter, opacity) = botPosition(mode: state.mode, view: state.view,
            islandW: frame.width, islandH: frame.height,
            uploadProgress: state.uploadProgress, hasNotch: state.hasNotch,
            vertical: state.islandEdge.isVertical)
        guard opacity > 0 else { return false }
        let radius = (diameter / 0.6) / 2
        let dx = windowPoint.x - (frame.minX + cx)
        let dy = windowPoint.y - (frame.maxY - cy)
        return dx * dx + dy * dy <= radius * radius
    }

    // MARK: - Notch detection (static)

    static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func preferredScreen(for state: AppState) -> NSScreen? {
        if let id = state.islandDisplayID,
           let screen = NSScreen.screens.first(where: { displayID(for: $0) == id }) {
            return screen
        }
        return notchScreen() ?? NSScreen.main
    }

    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    static func screenGeometry(for screen: NSScreen) -> IslandScreenGeometry {
        let visibleMenuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        // visibleFrame includes the menu bar only while it is visible. Keep a
        // small resting bar when menus auto-hide or the app is in full screen.
        let menuBarHeight = visibleMenuBarHeight > 0
            ? visibleMenuBarHeight : NSStatusBar.system.thickness
        return IslandScreenGeometry(
            screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: menuBarHeight
        )
    }

    nonisolated func cleanup() {
        // Called explicitly before release if needed
    }
}

// MARK: - Presence

/// Whether the display is awake and the session active; drives the animation pause.
@MainActor
final class IslandPresence: ObservableObject {
    @Published var animationsPaused = false
}

private struct IslandHostView: View {
    @ObservedObject var presence: IslandPresence
    var body: some View {
        IslandRootView().environment(\.redPandaAnimationsPaused, presence.animationsPaused)
    }
}

/// Forwards mouse moves from an always-active tracking area. While the
/// click-through panel accepts the mouse, these moves never reach a global monitor.
final class IslandTrackingView: NSView {
    var onPointerMoved: (@MainActor () -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onPointerMoved?() }
    override func mouseEntered(with event: NSEvent) { onPointerMoved?() }
    override func mouseExited(with event: NSEvent) { onPointerMoved?() }
}

// MARK: - IslandPanel

final class IslandPanel: NSPanel {
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    /// Allow panel to sit in the menu bar / notch area — don't let macOS push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    func currentIslandFrame(nw: CGFloat, nh: CGFloat) -> CGRect {
        let s = AppState.shared
        let (width, height) = islandSize(mode: s.mode, view: s.view,
                                         progress: s.uploadProgress, nw: nw, nh: nh,
                                         vertical: s.islandEdge.isVertical, agentCount: s.tasks.count)
        return IslandDockLayout(panelSize: frame.size,
                                islandSize: CGSize(width: width, height: height),
                                edge: s.islandEdge, offset: s.islandXOffset).appKitFrame
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let triggerEmote     = Notification.Name("notchBuddy.triggerEmote")
    static let triggerSlap      = Notification.Name("notchBuddy.triggerSlap")
    static let botDizzy         = Notification.Name("notchBuddy.botDizzy")
    static let botGreet         = Notification.Name("notchBuddy.botGreet")
    static let botBlink         = Notification.Name("notchBuddy.botBlink")
    static let botSetTgEs       = Notification.Name("notchBuddy.botSetTgEs")
    static let botGulp          = Notification.Name("notchBuddy.botGulp")
    static let botMorphTo       = Notification.Name("notchBuddy.botMorphTo")
    static let islandAction     = Notification.Name("notchBuddy.islandAction")
    static let islandCollapse   = Notification.Name("notchBuddy.islandCollapse")
    static let openFullSettings = Notification.Name("notchBuddy.openFullSettings")
    static let hookReveal       = Notification.Name("notchBuddy.hookReveal")
    // Greeting ↔ IslandWindowController
    static let greetComplete    = Notification.Name("notchBuddy.greetComplete")
    static let greetingHover    = Notification.Name("notchBuddy.greetingHover")
    static let greetingInterrupt = Notification.Name("notchBuddy.greetingInterrupt")
}

// MARK: - islandSize (takes real notch dimensions)

/// Alerts, settings and upload flows retain their full controls when docked to a side.
func usesVerticalSessionLayout(mode: IslandMode, view: IslandView, vertical: Bool) -> Bool {
    vertical && (mode != .expanded || view == .overview)
}

func islandSize(mode: IslandMode, view: IslandView,
                progress: Double = 0,
                nw: CGFloat = IslandConst.notchWidth,
                nh: CGFloat = IslandConst.notchHeight,
                vertical: Bool = false,
                agentCount: Int = 1) -> (CGFloat, CGFloat) {
    if usesVerticalSessionLayout(mode: mode, view: view, vertical: vertical) {
        let size = mode == .expanded
            ? IslandSessionLayout.expandedSize(agentCount: agentCount)
            : IslandSessionLayout.restingSize(agentCount: agentCount, compact: mode == .compact)
        return (size.width, size.height)
    }
    switch mode {
    case .hidden: return (nw, nh)
    case .compact: return (nw + 160, nh)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        return (IslandConst.expandedWidth, view == .prompt ? 240 : layout.height)
    }
}
