import AppKit
import Combine
import SwiftUI

@MainActor
final class OmniFlowShortcutGuideCoordinator: ObservableObject {
    static let shared = OmniFlowShortcutGuideCoordinator()
    @Published var holdEnabled: Bool { didSet { defaults.set(holdEnabled, forKey: "omniflow.shortcuts.commandHold"); applySettings() } }
    @Published private(set) var isPresented = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var pages: [OmniFlowShortcutGuidePage] = []
    @Published var currentPageIndex = 0
    @Published private(set) var status = "Open the guide manually, or enable Command hold."
    var onPresentationRequested: (@MainActor () -> Void)?
    let settings: OmniFlowFocusSettings
    private let defaults: UserDefaults
    private let provider: any OmniFlowNativeShortcutProviding
    private let showDelay: Duration
    private let focusController: OmniFlowFocusController?
    private let observeEvents: Bool
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    private var focusSubscription: AnyCancellable?
    private var presentationTask: Task<Void, Never>?
    private var running = false
    private var commandHeld = false
    private var blockedUntilRelease = false
    private var presentedByHold = false

    var currentPage: OmniFlowShortcutGuidePage? { pages.indices.contains(currentPageIndex) ? pages[currentPageIndex] : pages.first }

    init(settings: OmniFlowFocusSettings = .shared, defaults: UserDefaults = .standard,
         provider: any OmniFlowNativeShortcutProviding = OmniFlowNativeMenuShortcutProvider(),
         showDelay: Duration = .milliseconds(650),
         focusController: OmniFlowFocusController? = .shared,
         observeEvents: Bool = true) {
        self.settings = settings; self.defaults = defaults; self.provider = provider
        self.showDelay = showDelay
        self.focusController = focusController
        self.observeEvents = observeEvents
        holdEnabled = defaults.bool(forKey: "omniflow.shortcuts.commandHold")
        pages = Self.systemPages()
        subscription = settings.$values.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.applySettings() } }
        focusSubscription = focusController?.$suspensionCount.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        }
    }
    func start() {
        guard !running else { return }; running = true
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applySettings() }
            })
        }
        applySettings()
    }
    func stop() {
        running = false; removeMonitors(); cancelHold(); dismiss()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }
    func applySettings() {
        guard running, holdEnabled, settings.values.isShortcutGuideEnabled,
              (focusController?.suspensionCount ?? 0) == 0 else {
            removeMonitors(); cancelHold()
            if presentedByHold { dismiss() }
            status = "Open manually. Command hold is off."
            return
        }
        guard !isMonitoring else { return }
        guard observeEvents else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: Self.globalHandler(self))
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: Self.localHandler(self))
        isMonitoring = globalMonitor != nil && localMonitor != nil
        status = isMonitoring ? "Hold Command by itself for 650 ms. A key, another modifier, click or drag cancels the guide."
            : "Command monitoring is unavailable. You can still open the guide manually."
    }
    nonisolated private static func globalHandler(_ owner: OmniFlowShortcutGuideCoordinator) -> (NSEvent) -> Void {
        { [weak owner] event in
            let type = event.type, flags = event.modifierFlags
            Task { @MainActor in owner?.handleEvent(type: type, flags: flags) }
        }
    }
    nonisolated private static func localHandler(_ owner: OmniFlowShortcutGuideCoordinator) -> (NSEvent) -> NSEvent? {
        { [weak owner] event in
            let type = event.type, flags = event.modifierFlags
            Task { @MainActor in owner?.handleEvent(type: type, flags: flags) }
            return event
        }
    }
    /// Deterministic input state; events are observed and never swallowed.
    func handleEvent(type: NSEvent.EventType, flags: NSEvent.ModifierFlags) {
        guard running, holdEnabled, settings.values.isShortcutGuideEnabled,
              (focusController?.suspensionCount ?? 0) == 0 else { cancelHold(); return }
        if !flags.contains(.command) {
            commandHeld = false; blockedUntilRelease = false; cancelHold()
            if presentedByHold { dismiss() }
            return
        }
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
        guard type == .flagsChanged, flags.intersection(modifiers) == .command else {
            blockedUntilRelease = true; cancelHold()
            if presentedByHold { dismiss() }
            return
        }
        guard !commandHeld, !blockedUntilRelease else { return }
        commandHeld = true
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.showDelay) } catch { return }
            guard !Task.isCancelled, self.running, self.holdEnabled, self.commandHeld,
                  !self.blockedUntilRelease,
                  (self.focusController?.suspensionCount ?? 0) == 0 else { return }
            self.openForFrontmostApp(fromHold: true)
        }
    }
    func openForFrontmostApp() { openForFrontmostApp(fromHold: false) }
    private func openForFrontmostApp(fromHold: Bool) {
        var result = Self.systemPages()
        if let native = provider.frontmostApplicationShortcuts(), native.shortcutCount > 0 {
            result = OmniFlowShortcutGuidePaginator.pages(sourceID: "native-\(native.bundleIdentifier ?? native.applicationName)",
                eyebrow: native.applicationName, title: "App menu shortcuts",
                sourceDetail: "\(native.shortcutCount) shortcuts read from app menus; bounded scan may be partial.", groups: native.groups) + result
        }
        pages = result; currentPageIndex = 0; isPresented = true; presentedByHold = fromHold
        if fromHold { onPresentationRequested?() }
    }
    func dismiss() { isPresented = false; presentedByHold = false }
    func movePage(_ delta: Int) {
        guard !pages.isEmpty else { return }
        currentPageIndex = (currentPageIndex + delta % pages.count + pages.count) % pages.count
    }
    private func cancelHold() { presentationTask?.cancel(); presentationTask = nil }
    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        isMonitoring = false; commandHeld = false; blockedUntilRelease = false
    }
    static func systemPages() -> [OmniFlowShortcutGuidePage] {
        OmniFlowShortcutGuidePaginator.pages(sourceID: "macos", eyebrow: "macOS defaults", title: "System shortcuts",
            sourceDetail: "\(OmniFlowSystemShortcutCatalog.shortcutCount) default shortcuts; app support and System Settings can change them.",
            groups: OmniFlowSystemShortcutCatalog.groups)
    }
}

struct OmniFlowShortcutGuideView: View {
    @ObservedObject var coordinator: OmniFlowShortcutGuideCoordinator

    init(coordinator: OmniFlowShortcutGuideCoordinator = .shared) { self.coordinator = coordinator }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader
                holdControl
                if let page = coordinator.currentPage {
                    sourceHeader(page)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16, alignment: .top)],
                              alignment: .leading, spacing: 16) {
                        ForEach(page.groups) { group in shortcutGroup(group) }
                    }
                } else {
                    card {
                        VStack(spacing: 12) {
                            Image(systemName: "keyboard").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                            Text("Your shortcuts belong here").font(.headline)
                            Text("Refresh to load available app-menu shortcuts and the macOS default guide.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            refreshButton
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { coordinator.start() }
    }

    private var pageHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) { heading; Spacer(minLength: 8); refreshButton }
            VStack(alignment: .leading, spacing: 14) { heading; refreshButton }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Shortcuts").font(.system(size: 30, weight: .semibold))
            Text("Useful keys for the app you're working in.")
                .font(.body).foregroundStyle(.secondary)
        }
    }

    private var refreshButton: some View {
        Button { coordinator.openForFrontmostApp() } label: {
            Label("Refresh app shortcuts", systemImage: "arrow.clockwise")
        }.controlSize(.large)
    }

    private var holdControl: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $coordinator.holdEnabled) {
                    HStack(alignment: .center, spacing: 12) {
                        keycap("⌘", prominent: true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Show when holding Command").font(.headline)
                            Text("Hold Command by itself for a moment to open the guide.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }.toggleStyle(OmniFlowSwitchStyle())
                Divider()
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: coordinator.isMonitoring ? "checkmark.circle" : "info.circle")
                        .foregroundStyle(coordinator.isMonitoring ? Color.accentColor : Color.secondary)
                    Text(coordinator.status).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
    }

    private func sourceHeader(_ page: OmniFlowShortcutGuidePage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 20) { sourceTitle(page); Spacer(minLength: 0); pagination }
                VStack(alignment: .leading, spacing: 14) { sourceTitle(page); pagination }
            }
            Text(page.sourceDetail).font(.subheadline).foregroundStyle(.secondary)
        }.padding(.top, 4)
    }

    private func sourceTitle(_ page: OmniFlowShortcutGuidePage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(page.eyebrow).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            Text(page.title).font(.title2.weight(.semibold))
        }
    }

    private var pagination: some View {
        HStack(spacing: 12) {
            Button { coordinator.movePage(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }.accessibilityLabel("Previous shortcuts").help("Previous page")
            Text("\(coordinator.currentPageIndex + 1) of \(coordinator.pages.count)")
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel("Page \(coordinator.currentPageIndex + 1) of \(coordinator.pages.count)")
            Button { coordinator.movePage(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }.accessibilityLabel("Next shortcuts").help("Next page")
        }.fixedSize()
    }

    private func shortcutGroup(_ group: OmniFlowShortcutGuideGroup) -> some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) {
                    Image(systemName: group.symbol).foregroundStyle(Color.accentColor)
                        .frame(width: 18).accessibilityHidden(true)
                    Text(group.title).font(.subheadline.weight(.semibold))
                }
                VStack(spacing: 0) {
                    ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, item in
                        shortcutRow(item).padding(.vertical, 10)
                        if index < group.shortcuts.count - 1 { Divider().opacity(0.55) }
                    }
                }
            }
        }
    }

    private func shortcutRow(_ item: OmniFlowShortcutGuideItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text(item.title).font(.subheadline).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                keys(item.keys)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.subheadline)
                keys(item.keys)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.keys.joined(separator: " "))
    }

    private func keys(_ values: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in keycap(value) }
        }
    }

    private func keycap(_ value: String, prominent: Bool = false) -> some View {
        Text(value)
            .font(.system(size: prominent ? 22 : 12, weight: .medium, design: .monospaced))
            .foregroundStyle(prominent ? Color.accentColor : Color.primary)
            .padding(.horizontal, prominent ? 12 : 7)
            .frame(minWidth: prominent ? 44 : 25, minHeight: prominent ? 44 : 27)
            .background(prominent ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: prominent ? 11 : 6))
            .overlay(RoundedRectangle(cornerRadius: prominent ? 11 : 6)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
            .fixedSize()
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
    }
}
