import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private(set) var islandController: IslandWindowController?
    private var telemetryTimer: Timer?
    private var dockPreference: AnyCancellable?
    private var guidePresentation: AnyCancellable?
    private var restoreGuideSurface: (() -> Void)?
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        OmniFlowSync.shared.start()
        NotificationCenter.default.addObserver(forName: OmniFlowSync.changed, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppModel.shared.reloadSyncedHistory() }
        }
        if AgentPreferences.shared.enabled { AtlasRunnerSelection.launch() }
        AtlasMetalAgent.shared.start()
        MCPOAuth.shared.presenter = MacOAuthPresenter()
        // Ignore SIGPIPE — prevents crash when nb-hook closes socket before we write response
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.accessory)
        dockPreference = OmniFlowFocusSettings.shared.$values.map(\.showInDock).removeDuplicates()
            .receive(on: DispatchQueue.main).sink { shown in
                NSApp.setActivationPolicy(shown ? .regular : .accessory)
            }
        setupMenuBarItem()
        setupIsland()
        let dictation = AppModel.shared
        dictation.onOpenHub = { OmniFlowShellController.shared.showFlowPage(AppModel.shared.selectedPage) }
        dictation.onOpenSettings = { IslandWorkspace.shared.show(.settings) }
        dictation.onOverlayVisibility = { visible in
            if AppState.shared.quickControlsEnabled != visible { AppState.shared.quickControlsEnabled = visible }
            OmniFlowActivityPill.shared.refresh()
        }
        dictation.selectionActions.onPresent = {
            OmniFlowShellController.shared.showFlowPage("Actions")
        }
        NSApp.servicesProvider = OmniFlowServices.shared
        NSUpdateDynamicServices()
        FreeFlowIntentBridge.register(model: dictation)
        dictation.launch()
        VoiceAssistant.shared.registerShortcut()
        ReaderShortcut.shared.register()
        AgentCursor.shared.launch()
        ConversationHistory.shared.launch()
        AmbientMonitor.shared.launch()
        WakeListener.shared.launch()
        OmniFlowFocusController.shared.start()
        OmniFlowShortcutGuideCoordinator.shared.onPresentationRequested = { [weak self] in
            self?.presentShortcutGuide()
        }
        guidePresentation = OmniFlowShortcutGuideCoordinator.shared.$isPresented.dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] presented in
                guard !presented, let self else { return }
                self.restoreGuideSurface?(); self.restoreGuideSurface = nil
            }
        OmniFlowShortcutGuideCoordinator.shared.start()
        OmniFlowActivityPill.shared.start()
        if AppModel.shared.openHubOnLaunch || OmniFlowFocusSettings.shared.values.showInDock || !UserDefaults.standard.bool(forKey: "omniflow.companionIntroduced") {
            IslandWorkspace.shared.show(.dictation)
            UserDefaults.standard.set(true, forKey: "omniflow.companionIntroduced")
        }
        Task { await LocalTelemetry.shared.event("app.launch", success: true) }
        let telemetry = Timer(timeInterval: 60, repeats: true) { _ in
            Task { await LocalTelemetry.shared.sampleProcess() }
        }
        telemetry.tolerance = 15
        RunLoop.main.add(telemetry, forMode: .common)
        telemetryTimer = telemetry
        NotchLeeShortcuts.updateAppShortcutParameters()
        OmniFlowWidgetPublisher.shared.start()
        OmniFlowNotifications.shared.start()
        OmniFlowSpotlight.shared.start()
        OmniFlowAppLockTriggers.shared.start()
        launched = true
        let queued = pendingURLs; pendingURLs.removeAll()
        handleURLs(queued)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs.append(contentsOf: urls.prefix(8)); return }
        handleURLs(urls)
    }

    private func handleURLs(_ urls: [URL]) {
        for url in urls.prefix(8) {
            guard let command = FreeFlowIntentCommand(url: url) else { continue }
            // Websites can open a URL scheme. An explicit local action owns the
            // microphone; URL/Shortcuts sessions never insert into another app.
            if command == .start {
                OmniFlowShellController.shared.showFlowPage("Home")
                let alert = NSAlert()
                alert.messageText = "Start local dictation?"
                alert.informativeText = "This link wants to turn on your microphone. The result stays in OmniFlow, using your history settings."
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Start dictation")
                guard alert.runModal() == .alertSecondButtonReturn else { continue }
            }
            do { try FreeFlowIntentBridge.shared.run(command) }
            catch { AppModel.shared.status = error.localizedDescription; OmniFlowShellController.shared.showFlowPage("Home") }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await AppModel.shared.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        OmniFlowWidgetPublisher.shared.stop()
        AppModel.shared.hotkey.stop()
        AppModel.shared.cancel()
        AtlasMetalAgent.shared.stop()
        AtlasRunnerSelection.shutdown()
        VoiceAssistant.shared.cancel()
        VoiceShortcut.shared.unregister()
        ReaderShortcut.shared.unregister()
        AgentCursor.shared.stop()
        WakeListener.shared.stop()
        AmbientMonitor.shared.stop()
        OmniFlowFocusController.shared.stop()
        OmniFlowMonitoringCoordinator.shared.stop()
        OmniFlowShortcutGuideCoordinator.shared.stop()
        OmniFlowActivityPill.shared.stop()
        telemetryTimer?.invalidate()
    }

    // MARK: - Menu bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "OmniFlow")
        button.image?.size = NSSize(width: 24, height: 18)
        button.image?.accessibilityDescription = "OmniFlow"
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Open OmniFlow", action: #selector(openIsland), keyEquivalent: "")
        menu.addItem(withTitle: "Start dictation · Fn", action: #selector(startDictation), keyEquivalent: "")
        menu.addItem(withTitle: "Show island", action: #selector(showIsland), keyEquivalent: "")
        menu.addItem(withTitle: "Focus & pointer…", action: #selector(openFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Monitoring…", action: #selector(openMonitoring), keyEquivalent: "")
        menu.addItem(withTitle: "Talk to OmniFlow…", action: #selector(openVoice), keyEquivalent: "")
        menu.addItem(withTitle: "Continue reading · ⌃⌥R", action: #selector(continueReading), keyEquivalent: "")
        menu.addItem(withTitle: "Reader…", action: #selector(openReader), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        let hideItem = menu.addItem(withTitle: "Hide OmniFlow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openIsland() {
        IslandWorkspace.shared.show()
    }

    @objc private func showIsland() {
        NSApp.unhide(nil)
        AppState.shared.notchlyEnabled = true
        islandController?.expand(to: .overview)
    }

    @objc private func openFocus() { IslandWorkspace.shared.show(.focus) }
    @objc private func openMonitoring() { IslandWorkspace.shared.show(.system) }
    @objc private func continueReading() { ReaderController.shared.continueReading() }
    @objc private func openReader() { IslandWorkspace.shared.show(.reader) }

    private func presentShortcutGuide() {
        guard restoreGuideSurface == nil else { return }
        let workspace = IslandWorkspace.shared
        let state = AppState.shared
        let previousSection = workspace.section
        // Informational Command hold must not interrupt a pending approval or activate this app.
        guard !state.isPinned else { OmniFlowShortcutGuideCoordinator.shared.dismiss(); return }
        if OmniFlowShellController.shared.isVisible {
            workspace.section = .shortcuts
            restoreGuideSurface = {
                if workspace.section == .shortcuts { workspace.section = previousSection }
            }
        } else if state.notchlyEnabled {
            let previousView = state.view, previousMode = state.mode
            workspace.showInNotch(.shortcuts)
            restoreGuideSurface = { [weak self] in
                guard state.view == .workspace, workspace.section == .shortcuts else { return }
                workspace.section = previousSection
                state.view = previousView
                if previousMode == .expanded { self?.islandController?.setMode(previousMode) }
                else { self?.islandController?.collapse(); self?.islandController?.setMode(previousMode) }
            }
        } else {
            OmniFlowShellController.shared.show(.shortcuts, activate: false)
            restoreGuideSurface = {
                guard workspace.section == .shortcuts else { return }
                OmniFlowShellController.shared.close()
                workspace.section = previousSection
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        IslandWorkspace.shared.show()
        return true
    }

    @objc private func startDictation() { AppModel.shared.toggleHandsFree() }

    @objc private func openVoice() {
        VoiceAssistant.shared.show()
    }

    @objc private func openSettings() {
        IslandWorkspace.shared.show(.settings)
    }

    // MARK: - Island setup

    private func setupIsland() {
        islandController = IslandWindowController()
        if AppState.shared.notchlyEnabled {
            islandController?.showWindow(nil)
            islandController?.fsm.launch()
        }
        HookServer.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: .openFullSettings, object: nil)
    }
}
