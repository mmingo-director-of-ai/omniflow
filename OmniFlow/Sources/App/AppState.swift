import Foundation
import SwiftUI
import Combine

// Integration pills — always-present, never purged.
// This fork is a pure local-agent monitor: the only built-in pill is the
// Claude Code / VS Code one. Other coding agents (Codex, Gemini, …) appear
// dynamically as external-agent pills when their hook relay reports in.
extension AgentTask {
    /// No built-in/always-present pills: every pill is a live agent session, created
    /// when a session reports in and removed when it ends. See HookServer.upsertSession.
    static let integrationAgents: [AgentTask] = []

    /// IDs that can be toggled. None — pills are session-driven.
    static let toggleableIntegrationIds: [String] = []
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Island state
    @Published var mode: IslandMode = .hidden
    @Published var view: IslandView = .overview

    /// Presentation only. Capture, hooks and monitoring remain available in the app shell.
    @Published var notchlyEnabled: Bool = true {
        didSet { UserDefaults.standard.set(notchlyEnabled, forKey: "omniflow.notchlyEnabled") }
    }

    @Published var quickControlsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(quickControlsEnabled, forKey: "omniflow.quickControlsEnabled") }
    }

    // Tasks
    @Published var tasks: [AgentTask] = []
    @Published var focusId: String? = nil

    // Bot state override
    @Published var stateOverride: BotState? = nil

    // Real notch dimensions (set by IslandWindowController on launch)
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight
    var hasNotch = true

    // Last app active before OmniFlow (for window context capture)
    var lastExternalApp: NSRunningApplication? = nil

    // Bot drag-attach state (hides original bot while ghost follows cursor)
    @Published var isDraggingBot: Bool = false

    // Mouse tracking
    var mousePosition: CGPoint = .zero
    var lastMouseMove: Date = .now
    var lastActivity: Date = .now
    var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

    // Upload progress (0-1) — set to 1.0 only at completion; animation is time-based
    @Published var uploadProgress: Double = 0

    // Upload animation timing (non-published — TimelineViews read these directly)
    var uploadStartTime: Date?
    var uploadDuration: Double = 2.4

    // File drag-over state (mailbox morph glow + mouth spring)
    @Published var fileDragOver: Bool = false

    // Sound enabled — persisted
    @Published var soundEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    // Sound volume (0–0.2) — persisted, synced to SoundEngine
    @Published var soundVolume: Double = 0.12 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    // Context for prompt (window attach / file)
    @Published var promptContext: PromptContext? = nil

    // Dropped file (set during upload flow)
    @Published var droppedFile: DroppedFile? = nil

    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Auto-close delay — persisted
    @Published var autoCloseInterval: TimeInterval = 15 {
        didSet { UserDefaults.standard.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    // Absence interval — persisted
    var absenceInterval: TimeInterval = 3 * 60 {
        didSet { UserDefaults.standard.set(absenceInterval, forKey: "absenceInterval") }
    }

    // Greeting threshold — how long hidden before greeting on reappear (default 2 min)
    var greetThresholdSeconds: TimeInterval = 120 {
        didSet { UserDefaults.standard.set(greetThresholdSeconds, forKey: "greetThreshold") }
    }

    // Hotkey to show island (e.g. ⌘⇧N)
    @Published var hotkeyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { UserDefaults.standard.set(Int(hotkeyFlags), forKey: "hotkeyFlags") }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }

    // Expand the island on hover, not just peek — persisted
    @Published var expandOnHover: Bool = false {
        didSet { UserDefaults.standard.set(expandOnHover, forKey: "expandOnHover") }
    }

    // The attached screen edge also determines the layout orientation — persisted.
    /// Carousel page in the expanded overview: 0 is sessions, later pages are monitoring.
    @Published var carouselPage = 0 { didSet { carouselPanel = nil } }
    /// The selected carousel panel by identity, which wins over `carouselPage`
    /// while it exists, so pages appearing or leaving (the Reading card) never
    /// shift the selection, even while the island is compact.
    @Published var carouselPanel: NotchLeePanel?
    @Published var islandEdge: IslandEdge = .top {
        didSet { UserDefaults.standard.set(islandEdge.rawValue, forKey: "islandEdge") }
    }

    // Offset of the island along its docked edge, in points — persisted.
    // Top/bottom: horizontal offset from center. Left/right: vertical offset from center.
    @Published var islandXOffset: CGFloat = 0 {
        didSet { UserDefaults.standard.set(Double(islandXOffset), forKey: "islandXOffset") }
    }

    var islandDisplayID: UInt32? = nil {
        didSet { UserDefaults.standard.set(islandDisplayID.map { Int($0) }, forKey: "islandDisplayID") }
    }

    // Liquid Glass styling (macOS 26) instead of the opaque dark island — persisted
    @Published var liquidGlass: Bool = true {
        didSet { UserDefaults.standard.set(liquidGlass, forKey: "liquidGlass") }
    }

    // Pending approval request from a coding-agent hook (Claude Code / Codex / …)
    @Published var pendingApproval: ApprovalInfo? = nil

    // MARK: - Init (loads persisted settings)

    private init() {
        let ud = UserDefaults.standard

        if let value = ud.object(forKey: "omniflow.notchlyEnabled") as? Bool { notchlyEnabled = value }

        if let value = ud.object(forKey: "omniflow.quickControlsEnabled") as? Bool { quickControlsEnabled = value }

        if let v = ud.object(forKey: "soundEnabled") as? Bool   { soundEnabled = v }
        if let v = ud.object(forKey: "soundVolume")  as? Double { soundVolume  = v }
        // Migrate old 60s default → 15s
        if let v = ud.object(forKey: "autoCloseInterval") as? Double {
            autoCloseInterval = (v == 60) ? 15 : v
        }
        if let v = ud.object(forKey: "absenceInterval")   as? Double { absenceInterval   = v }
        if let v = ud.object(forKey: "greetThreshold")    as? Double { greetThresholdSeconds = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool  { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags")   as? Int   { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode")    as? Int   { hotkeyCode = UInt16(v) }
        if let v = ud.object(forKey: "expandOnHover") as? Bool  { expandOnHover = v }
        if let v = ud.string(forKey: "islandEdge"), let e = IslandEdge(rawValue: v) { islandEdge = e }
        if let v = ud.object(forKey: "islandXOffset") as? Double {
            // IslandDockLayout clamps to the current panel and orientation on every render.
            islandXOffset = v.isFinite ? CGFloat(v) : 0
        }
        if let v = ud.object(forKey: "islandDisplayID") as? Int {
            islandDisplayID = UInt32(exactly: v)
        }
        if let v = ud.object(forKey: "liquidGlass")   as? Bool  { liquidGlass = v }

        // Sync SoundEngine volume on launch
        SoundEngine.shared.volume = Float(soundVolume)

        // Always load the Claude Code pill
        loadIntegrationTasks()
    }

    // MARK: - Computed

    var focusTask: AgentTask? {
        tasks.first { $0.id == focusId } ?? tasks.first
    }

    var effectiveState: BotState {
        stateOverride ?? focusTask?.state ?? .idle
    }

    // MARK: - Task management

    func addTask(_ task: AgentTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        if focusId == nil { focusId = task.id }
        syncMode()
        syncView()
    }

    func removeTask(id: String) {
        tasks.removeAll { $0.id == id }
        if focusId == id { focusId = tasks.first?.id }
        syncMode()
        syncView()
    }

    /// Edits one task on a copy and publishes once, and only if something changed.
    /// Each in-place `tasks[idx].field = …` would otherwise re-render every observer.
    @discardableResult
    func mutateTask(id: String, _ change: (inout AgentTask) -> Void) -> Bool {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return false }
        var task = tasks[idx]
        change(&task)
        if task != tasks[idx] { tasks[idx] = task }
        return true
    }

    func updateTask(id: String, state: BotState) {
        guard let previous = tasks.first(where: { $0.id == id })?.state else { return }
        mutateTask(id: id) { task in
            task.state = state
            if state != .error { task.errorMessage = nil }
            if state != .question { task.questionMessage = nil }
        }
        if focusTask?.id == id,
           (view == .error && previous == .error && state != .error)
            || (view == .question && previous == .question && state != .question) {
            view = .overview
        }
    }

    func setFocus(_ id: String) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        if focusId != id { focusId = id }
        mutateTask(id: id) { $0.pillBadge = nil }  // clear badge when user brings task to focus
    }

    func syncMode() {
        // Keep the microphone indicator visible while hands-free is enabled.
        let needsCompact = !tasks.isEmpty || UserDefaults.standard.bool(forKey: "wakePhraseEnabled")
        if !needsCompact && mode == .compact {
            mode = .hidden
        } else if needsCompact && mode == .hidden && isPresent {
            mode = .compact
        }
    }

    func syncView() {
        guard mode == .expanded else { return }
        if view == .empty && !tasks.isEmpty { view = .overview }
        else if view == .overview && tasks.isEmpty { view = .empty }
    }

    /// No-op now that pills are session-driven (kept for call-site compatibility).
    func loadIntegrationTasks() {
        syncMode()
    }
}

// MARK: - Supporting types

enum PromptContext {
    case window(appName: String, title: String, url: String?)
    case file(name: String, fileURL: URL?)
}

struct DroppedFile {
    var url: URL
    var name: String
}
