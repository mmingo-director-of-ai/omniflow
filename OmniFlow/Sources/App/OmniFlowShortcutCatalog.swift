// Copyright (c) 2026 Quandry Labs (MIT).
import Foundation

struct OmniFlowShortcutGuideItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let keys: [String]

    init(_ id: String, _ title: String, keys: [String]) {
        self.id = id
        self.title = title
        self.keys = keys
    }
}

struct OmniFlowShortcutGuideGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let shortcuts: [OmniFlowShortcutGuideItem]
}

struct OmniFlowShortcutGuidePage: Identifiable, Equatable, Sendable {
    let id: String
    let eyebrow: String
    let title: String
    let sourceDetail: String
    let groups: [OmniFlowShortcutGuideGroup]

    var shortcutCount: Int {
        groups.reduce(0) { $0 + $1.shortcuts.count }
    }
}

enum OmniFlowShortcutGuidePaginator {
    static let shortcutsPerGroup = 8
    static let groupsPerPage = 3

    static func pages(
        sourceID: String,
        eyebrow: String,
        title: String,
        sourceDetail: String,
        groups: [OmniFlowShortcutGuideGroup]
    ) -> [OmniFlowShortcutGuidePage] {
        let chunks = groups.flatMap { group -> [OmniFlowShortcutGuideGroup] in
            let shortcutChunks = group.shortcuts.chunked(into: shortcutsPerGroup)
            return shortcutChunks.enumerated().map { index, shortcuts in
                OmniFlowShortcutGuideGroup(
                    id: "\(sourceID)-\(group.id)-\(index)",
                    title: shortcutChunks.count == 1
                        ? group.title
                        : "\(group.title) · \(index + 1)",
                    symbol: group.symbol,
                    shortcuts: shortcuts
                )
            }
        }

        return chunks.chunked(into: groupsPerPage).enumerated().map { index, pageGroups in
            OmniFlowShortcutGuidePage(
                id: "\(sourceID)-page-\(index)",
                eyebrow: eyebrow,
                title: title,
                sourceDetail: sourceDetail,
                groups: pageGroups
            )
        }
    }
}

enum OmniFlowSystemShortcutCatalog {
    // Apple-documented macOS defaults. Some can be disabled or changed in
    // System Settings, so the UI identifies this source as the default catalog.
    static let groups: [OmniFlowShortcutGuideGroup] = [
        group("common", "COMMON", "command", [
            item("cut", "Cut", "⌘", "X"),
            item("copy", "Copy", "⌘", "C"),
            item("paste", "Paste", "⌘", "V"),
            item("undo", "Undo", "⌘", "Z"),
            item("redo", "Redo", "⇧", "⌘", "Z"),
            item("select-all", "Select all", "⌘", "A"),
            item("find", "Find", "⌘", "F"),
            item("find-next", "Find next", "⌘", "G"),
            item("find-previous", "Find previous", "⇧", "⌘", "G"),
            item("open", "Open", "⌘", "O"),
            item("print", "Print", "⌘", "P"),
            item("save", "Save", "⌘", "S"),
            item("new-tab", "New tab", "⌘", "T"),
            item("close-window", "Close window", "⌘", "W"),
            item("close-all", "Close all windows", "⌥", "⌘", "W"),
            item("settings", "App settings", "⌘", ","),
            item("quit", "Quit app", "⌘", "Q"),
            item("full-screen", "Toggle full screen", "⌃", "⌘", "F"),
            item("quick-look", "Quick Look", "Space"),
            item("hide-app", "Hide front app", "⌘", "H"),
            item("hide-others", "Hide other apps", "⌥", "⌘", "H"),
            item("minimize", "Minimize window", "⌘", "M"),
            item("minimize-all", "Minimize app windows", "⌥", "⌘", "M"),
        ]),
        group("navigation", "APPS & SPACES", "rectangle.3.group", [
            item("switch-apps", "Switch apps", "⌘", "Tab"),
            item("switch-apps-reverse", "Switch apps backward", "⇧", "⌘", "Tab"),
            item("next-window", "Next app window", "⌘", "`"),
            item("previous-window", "Previous app window", "⇧", "⌘", "`"),
            item("mission-control", "Mission Control", "⌃", "↑"),
            item("app-windows", "App windows", "⌃", "↓"),
            item("previous-space", "Previous Space", "⌃", "←"),
            item("next-space", "Next Space", "⌃", "→"),
            item("show-desktop-fn-h", "Show desktop", "fn", "H"),
            item("show-desktop-fn-f11", "Show desktop", "fn", "F11"),
            item("show-desktop-command-f3", "Show desktop", "⌘", "F3"),
            item("toggle-dock-command", "Show or hide Dock", "⌥", "⌘", "D"),
            item("force-quit", "Force Quit", "⌥", "⌘", "Esc"),
        ]),
        group("search-input", "SEARCH & INPUT", "magnifyingglass", [
            item("spotlight", "Spotlight", "⌘", "Space"),
            item("finder-spotlight", "Finder Spotlight search", "⌥", "⌘", "Space"),
            item("character-viewer", "Character Viewer", "⌃", "⌘", "Space"),
            item("character-viewer-fn-e", "Character Viewer", "fn", "E"),
            item("character-viewer-fn-fn", "Character Viewer", "fn", "fn"),
            item("quick-note", "Quick Note", "fn", "Q"),
            item("toggle-dock-fn", "Show or hide Dock", "fn", "A"),
            item("control-center", "Control Center", "fn", "C"),
            item("dictation", "Start or stop dictation", "fn", "D"),
            item("notification-center", "Notification Center", "fn", "N"),
            item("apps-launchpad", "Apps or Launchpad", "fn", "⇧", "A"),
            item("type-to-siri", "Type to Siri", "⌘", "⌘"),
            item("previous-input-source", "Previous input source", "⌃", "Space"),
            item("next-input-source", "Next input source", "⌃", "⌥", "Space"),
        ]),
        group("capture", "SCREEN CAPTURE", "viewfinder", [
            item("capture-screen", "Capture entire screen", "⇧", "⌘", "3"),
            item("capture-selection", "Capture selection", "⇧", "⌘", "4"),
            item("screenshot-tools", "Screenshot and recording tools", "⇧", "⌘", "5"),
            item("capture-screen-clipboard", "Copy screen to Clipboard", "⌃", "⇧", "⌘", "3"),
            item("capture-selection-clipboard", "Copy selection to Clipboard", "⌃", "⇧", "⌘", "4"),
            item("capture-touch-bar", "Capture Touch Bar", "⇧", "⌘", "6"),
            item("capture-touch-bar-clipboard", "Copy Touch Bar to Clipboard", "⌃", "⇧", "⌘", "6"),
        ]),
        group("session", "SESSION & POWER", "power", [
            item("lock-screen", "Lock screen", "⌃", "⌘", "Q"),
            item("log-out", "Log out with confirmation", "⇧", "⌘", "Q"),
            item("log-out-now", "Log out immediately", "⌥", "⇧", "⌘", "Q"),
            item("sleep", "Sleep", "⌥", "⌘", "Power"),
            item("display-sleep", "Put displays to sleep", "⌃", "⇧", "Power"),
            item("power-dialog", "Restart, sleep, or shut down", "⌃", "Power"),
            item("force-restart", "Force restart", "⌃", "⌘", "Power"),
            item("quit-and-shut-down", "Quit apps and shut down", "⌃", "⌥", "⌘", "Power"),
        ]),
        group("finder-locations", "FINDER LOCATIONS", "folder", [
            item("finder-computer", "Computer", "⇧", "⌘", "C"),
            item("finder-desktop", "Desktop", "⇧", "⌘", "D"),
            item("finder-recents", "Recents", "⇧", "⌘", "F"),
            item("finder-go-folder", "Go to Folder", "⇧", "⌘", "G"),
            item("finder-home", "Home", "⇧", "⌘", "H"),
            item("finder-icloud", "iCloud Drive", "⇧", "⌘", "I"),
            item("finder-network", "Network", "⇧", "⌘", "K"),
            item("finder-downloads", "Downloads", "⌥", "⌘", "L"),
            item("finder-documents", "Documents", "⇧", "⌘", "O"),
            item("finder-airdrop", "AirDrop", "⇧", "⌘", "R"),
            item("finder-utilities", "Utilities", "⇧", "⌘", "U"),
            item("finder-connect-server", "Connect to Server", "⌘", "K"),
        ]),
        group("finder-views", "FINDER WINDOWS", "macwindow", [
            item("finder-new-window", "New Finder window", "⌘", "N"),
            item("finder-new-folder", "New folder", "⇧", "⌘", "N"),
            item("finder-smart-folder", "New Smart Folder", "⌥", "⌘", "N"),
            item("finder-preview-pane", "Toggle Preview pane", "⇧", "⌘", "P"),
            item("finder-tab-bar", "Toggle tab bar", "⇧", "⌘", "T"),
            item("finder-toolbar", "Toggle toolbar", "⌥", "⌘", "T"),
            item("finder-path-bar", "Toggle path bar", "⌥", "⌘", "P"),
            item("finder-sidebar", "Toggle sidebar", "⌥", "⌘", "S"),
            item("finder-status-bar", "Toggle status bar", "⌘", "/"),
            item("finder-view-options", "View options", "⌘", "J"),
            item("finder-icons", "Icon view", "⌘", "1"),
            item("finder-list", "List view", "⌘", "2"),
            item("finder-columns", "Column view", "⌘", "3"),
            item("finder-gallery", "Gallery view", "⌘", "4"),
        ]),
        group("finder-actions", "FINDER ACTIONS", "doc.on.doc", [
            item("finder-duplicate", "Duplicate", "⌘", "D"),
            item("finder-eject", "Eject", "⌘", "E"),
            item("finder-info", "Get Info", "⌘", "I"),
            item("finder-original", "Show original or refresh", "⌘", "R"),
            item("finder-folder-selection", "Folder from selection", "⌃", "⌘", "N"),
            item("finder-add-dock", "Add item to Dock", "⌃", "⇧", "⌘", "T"),
            item("finder-add-sidebar", "Add item to sidebar", "⌃", "⌘", "T"),
            item("finder-alias", "Make alias", "⌃", "⌘", "A"),
            item("finder-move-paste", "Move Clipboard files here", "⌥", "⌘", "V"),
            item("finder-quick-look", "Quick Look", "⌘", "Y"),
            item("finder-quick-look-slideshow", "Quick Look slideshow", "⌥", "⌘", "Y"),
            item("finder-back", "Previous folder", "⌘", "["),
            item("finder-forward", "Next folder", "⌘", "]"),
            item("finder-parent", "Open parent folder", "⌘", "↑"),
            item("finder-parent-window", "Parent folder in new window", "⌃", "⌘", "↑"),
            item("finder-open-item", "Open selected item", "⌘", "↓"),
            item("finder-expand", "Open selected list folder", "→"),
            item("finder-collapse", "Close selected list folder", "←"),
            item("finder-trash", "Move to Trash", "⌘", "Delete"),
            item("finder-empty-trash", "Empty Trash", "⇧", "⌘", "Delete"),
            item("finder-empty-trash-now", "Empty Trash immediately", "⌥", "⇧", "⌘", "Delete"),
        ]),
        group("hardware", "HARDWARE CONTROLS", "keyboard", [
            item("mirror-displays", "Toggle display mirroring", "⌘", "Brightness−"),
            item("display-settings", "Open Displays settings", "⌥", "Brightness+"),
            item("external-brightness-up", "External display brighter", "⌃", "Brightness+"),
            item("external-brightness-down", "External display dimmer", "⌃", "Brightness−"),
            item("fine-brightness-up", "Fine brightness increase", "⌥", "⇧", "Brightness+"),
            item("fine-brightness-down", "Fine brightness decrease", "⌥", "⇧", "Brightness−"),
            item("mission-control-settings", "Open Mission Control settings", "⌥", "F3"),
            item("sound-settings", "Open Sound settings", "⌥", "Volume+"),
            item("fine-volume-up", "Fine volume increase", "⌥", "⇧", "Volume+"),
            item("fine-volume-down", "Fine volume decrease", "⌥", "⇧", "Volume−"),
            item("keyboard-settings", "Open Keyboard settings", "⌥", "Keyboard+"),
            item("fine-keyboard-up", "Fine keyboard brightness increase", "⌥", "⇧", "Keyboard+"),
            item("fine-keyboard-down", "Fine keyboard brightness decrease", "⌥", "⇧", "Keyboard−"),
        ]),
        group("text-format", "TEXT & FORMAT", "textformat", [
            item("text-bold", "Bold", "⌘", "B"),
            item("text-italic", "Italic", "⌘", "I"),
            item("text-link", "Add link", "⌘", "K"),
            item("text-underline", "Underline", "⌘", "U"),
            item("text-fonts", "Fonts window", "⌘", "T"),
            item("text-definition", "Show definition", "⌃", "⌘", "D"),
            item("text-spelling", "Spelling and Grammar", "⇧", "⌘", ":"),
            item("text-next-misspelling", "Next misspelling", "⌘", ";"),
            item("text-left-align", "Align left", "⌘", "{"),
            item("text-right-align", "Align right", "⌘", "}"),
            item("text-center-align", "Align center", "⇧", "⌘", "|"),
            item("text-search-field", "Go to search field", "⌥", "⌘", "F"),
            item("text-copy-style", "Copy style", "⌥", "⌘", "C"),
            item("text-paste-style", "Paste style", "⌥", "⌘", "V"),
            item("text-paste-match", "Paste and Match Style", "⌥", "⇧", "⌘", "V"),
            item("text-inspector", "Show inspector", "⌥", "⌘", "I"),
            item("text-page-setup", "Page setup", "⇧", "⌘", "P"),
            item("text-save-as", "Save As or duplicate", "⇧", "⌘", "S"),
            item("text-smaller", "Decrease size", "⇧", "⌘", "−"),
            item("text-larger", "Increase size", "⇧", "⌘", "+"),
            item("text-help", "Open Help menu", "⇧", "⌘", "?"),
        ]),
        group("text-edit", "TEXT EDITING", "character.cursor.ibeam", [
            item("delete-word", "Delete previous word", "⌥", "Delete"),
            item("delete-left", "Delete previous character", "⌃", "H"),
            item("delete-right", "Delete next character", "⌃", "D"),
            item("forward-delete", "Forward delete", "fn", "Delete"),
            item("kill-line", "Cut to end of line", "⌃", "K"),
            item("yank-line", "Paste killed text", "⌃", "Y"),
            item("page-up", "Page Up", "fn", "↑"),
            item("page-down", "Page Down", "fn", "↓"),
            item("home", "Home", "fn", "←"),
            item("end", "End", "fn", "→"),
            item("document-start", "Start of document", "⌘", "↑"),
            item("document-end", "End of document", "⌘", "↓"),
            item("line-start", "Start of line", "⌘", "←"),
            item("line-end", "End of line", "⌘", "→"),
            item("previous-word", "Previous word", "⌥", "←"),
            item("next-word", "Next word", "⌥", "→"),
            item("line-paragraph-start", "Start of line or paragraph", "⌃", "A"),
            item("line-paragraph-end", "End of line or paragraph", "⌃", "E"),
            item("character-forward", "Move one character forward", "⌃", "F"),
            item("character-back", "Move one character backward", "⌃", "B"),
            item("center-cursor", "Center cursor or selection", "⌃", "L"),
            item("line-up", "Move up one line", "⌃", "P"),
            item("line-down", "Move down one line", "⌃", "N"),
            item("new-line", "Insert new line", "⌃", "O"),
            item("transpose", "Transpose characters", "⌃", "T"),
        ]),
        group("selection", "TEXT SELECTION", "selection.pin.in.out", [
            item("select-document-start", "Select to document start", "⇧", "⌘", "↑"),
            item("select-document-end", "Select to document end", "⇧", "⌘", "↓"),
            item("select-line-start", "Select to line start", "⇧", "⌘", "←"),
            item("select-line-end", "Select to line end", "⇧", "⌘", "→"),
            item("select-line-up", "Extend selection up", "⇧", "↑"),
            item("select-line-down", "Extend selection down", "⇧", "↓"),
            item("select-left", "Extend selection left", "⇧", "←"),
            item("select-right", "Extend selection right", "⇧", "→"),
            item("select-paragraph-start", "Select to paragraph start", "⌥", "⇧", "↑"),
            item("select-paragraph-end", "Select to paragraph end", "⌥", "⇧", "↓"),
            item("select-word-left", "Select previous word", "⌥", "⇧", "←"),
            item("select-word-right", "Select next word", "⌥", "⇧", "→"),
        ]),
        group("keyboard-focus", "KEYBOARD FOCUS", "rectangle.and.hand.point.up.left", [
            item("focus-menu", "Focus menu bar", "⌃", "F2"),
            item("focus-menu-fn", "Focus menu bar", "fn", "⌃", "F2"),
            item("focus-dock", "Focus Dock", "⌃", "F3"),
            item("focus-dock-fn", "Focus Dock", "fn", "⌃", "F3"),
            item("focus-window", "Focus active or next window", "⌃", "F4"),
            item("focus-window-fn", "Focus active or next window", "fn", "⌃", "F4"),
            item("focus-toolbar", "Focus window toolbar", "⌃", "F5"),
            item("focus-toolbar-fn", "Focus window toolbar", "fn", "⌃", "F5"),
            item("focus-floating", "Focus floating window", "⌃", "F6"),
            item("focus-floating-fn", "Focus floating window", "fn", "⌃", "F6"),
            item("focus-previous-panel", "Focus previous panel", "⌃", "⇧", "F6"),
            item("focus-tab-mode", "Change Tab focus mode", "⌃", "F7"),
            item("focus-tab-mode-fn", "Change Tab focus mode", "fn", "⌃", "F7"),
            item("focus-status", "Focus status menus", "⌃", "F8"),
            item("focus-status-fn", "Focus status menus", "fn", "⌃", "F8"),
            item("focus-next-control", "Next control", "Tab"),
            item("focus-previous-control", "Previous control", "⇧", "Tab"),
            item("focus-next-text-control", "Next control from text field", "⌃", "Tab"),
            item("focus-previous-group", "Previous control group", "⌃", "⇧", "Tab"),
            item("focus-window-drawer", "Focus window drawer", "⌥", "⌘", "`"),
        ]),
        group("accessibility", "ACCESSIBILITY", "accessibility", [
            item("invert-colors", "Invert colors", "⌃", "⌥", "⌘", "8"),
            item("reduce-contrast", "Reduce contrast", "⌃", "⌥", "⌘", ","),
            item("increase-contrast", "Increase contrast", "⌃", "⌥", "⌘", "."),
            item("accessibility-panel", "Accessibility Shortcuts", "⌥", "⌘", "F5"),
            item("voiceover", "Toggle VoiceOver", "⌘", "F5"),
            item("zoom-toggle", "Toggle accessibility zoom", "⌥", "⌘", "8"),
            item("zoom-in", "Accessibility zoom in", "⌥", "⌘", "+"),
            item("zoom-out", "Accessibility zoom out", "⌥", "⌘", "−"),
        ]),
        group("tiling", "WINDOW TILING", "rectangle.split.2x1", [
            item("tile-fill", "Fill desktop", "fn", "⌃", "F"),
            item("tile-center", "Center window", "fn", "⌃", "C"),
            item("tile-left", "Move window left", "fn", "⌃", "←"),
            item("tile-right", "Move window right", "fn", "⌃", "→"),
            item("tile-top", "Move window top", "fn", "⌃", "↑"),
            item("tile-bottom", "Move window bottom", "fn", "⌃", "↓"),
            item("tile-restore", "Return to previous size", "fn", "⌃", "R"),
            item("tile-left-right", "Tile windows left and right", "fn", "⌃", "⇧", "←"),
            item("tile-right-left", "Tile windows right and left", "fn", "⌃", "⇧", "→"),
            item("tile-top-bottom", "Tile windows top and bottom", "fn", "⌃", "⇧", "↑"),
            item("tile-bottom-top", "Tile windows bottom and top", "fn", "⌃", "⇧", "↓"),
            item("tile-left-quarters", "Left and two quarters", "fn", "⌃", "⌥", "⇧", "←"),
            item("tile-right-quarters", "Right and two quarters", "fn", "⌃", "⌥", "⇧", "→"),
            item("tile-top-quarters", "Top and two quarters", "fn", "⌃", "⌥", "⇧", "↑"),
            item("tile-bottom-quarters", "Bottom and two quarters", "fn", "⌃", "⌥", "⇧", "↓"),
        ]),
    ]

    static var shortcutCount: Int {
        groups.reduce(0) { $0 + $1.shortcuts.count }
    }

    private static func item(_ id: String, _ title: String, _ keys: String...) -> OmniFlowShortcutGuideItem {
        OmniFlowShortcutGuideItem(id, title, keys: keys)
    }

    private static func group(
        _ id: String,
        _ title: String,
        _ symbol: String,
        _ shortcuts: [OmniFlowShortcutGuideItem]
    ) -> OmniFlowShortcutGuideGroup {
        OmniFlowShortcutGuideGroup(id: id, title: title, symbol: symbol, shortcuts: shortcuts)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
