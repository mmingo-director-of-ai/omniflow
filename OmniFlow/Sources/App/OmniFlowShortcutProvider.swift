// Copyright (c) 2026 Quandry Labs (MIT).
import AppKit
import ApplicationServices

struct OmniFlowNativeShortcutSnapshot: Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String?
    let groups: [OmniFlowShortcutGuideGroup]

    var shortcutCount: Int {
        groups.reduce(0) { $0 + $1.shortcuts.count }
    }
}

@MainActor
protocol OmniFlowNativeShortcutProviding {
    func frontmostApplicationShortcuts() -> OmniFlowNativeShortcutSnapshot?
}

@MainActor
final class OmniFlowNativeMenuShortcutProvider: OmniFlowNativeShortcutProviding {
    private let application: @MainActor () -> NSRunningApplication?
    private var deadline = Date.distantPast
    init(application: @escaping @MainActor () -> NSRunningApplication? = { MacContext.foregroundApp }) {
        self.application = application
    }
    func frontmostApplicationShortcuts() -> OmniFlowNativeShortcutSnapshot? {
        guard AXIsProcessTrusted(),
              let application = application(),
              !application.isTerminated, application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.15)
        deadline = Date().addingTimeInterval(2)
        guard let menuBar = copyElementAttribute(kAXMenuBarAttribute, from: applicationElement) else {
            return nil
        }

        let groups = copyElementArrayAttribute(kAXChildrenAttribute, from: menuBar)
            .enumerated()
            .compactMap { index, menuBarItem in
                menuGroup(from: menuBarItem, index: index)
            }

        guard !groups.isEmpty else { return nil }
        return OmniFlowNativeShortcutSnapshot(
            applicationName: application.localizedName ?? "Current App",
            bundleIdentifier: application.bundleIdentifier,
            groups: groups
        )
    }

    private func menuGroup(from menuBarItem: AXUIElement, index: Int) -> OmniFlowShortcutGuideGroup? {
        guard Date() < deadline else { return nil }
        let title = normalizedTitle(copyStringAttribute(kAXTitleAttribute, from: menuBarItem))
            ?? "MENU \(index + 1)"
        guard let menu = copyElementArrayAttribute(kAXChildrenAttribute, from: menuBarItem)
            .first(where: { copyStringAttribute(kAXRoleAttribute, from: $0) == kAXMenuRole })
        else {
            return nil
        }

        var itemIndex = 0
        var shortcuts = collectShortcuts(
            from: menu,
            path: [],
            groupID: "native-\(index)",
            itemIndex: &itemIndex,
            depth: 0
        )

        var seen = Set<String>()
        shortcuts = shortcuts.filter { shortcut in
            seen.insert("\(shortcut.title)\u{1f}\(shortcut.keys.joined())").inserted
        }
        guard !shortcuts.isEmpty else { return nil }

        return OmniFlowShortcutGuideGroup(
            id: "native-menu-\(index)",
            title: title.uppercased(),
            symbol: symbol(for: title),
            shortcuts: shortcuts
        )
    }

    private func collectShortcuts(
        from menu: AXUIElement,
        path: [String],
        groupID: String,
        itemIndex: inout Int,
        depth: Int
    ) -> [OmniFlowShortcutGuideItem] {
        guard depth < 12, itemIndex < 512, Date() < deadline else { return [] }
        var shortcuts: [OmniFlowShortcutGuideItem] = []

        for menuItem in copyElementArrayAttribute(kAXChildrenAttribute, from: menu).prefix(256) {
            guard itemIndex < 512, Date() < deadline else { break }
            guard copyStringAttribute(kAXRoleAttribute, from: menuItem) == kAXMenuItemRole else {
                continue
            }

            let itemTitle = normalizedTitle(copyStringAttribute(kAXTitleAttribute, from: menuItem))
            if let itemTitle,
               let keys = OmniFlowNativeShortcutKeyFormatter.keyCaps(
                   commandCharacter: copyStringAttribute(kAXMenuItemCmdCharAttribute, from: menuItem),
                   virtualKey: copyNumberAttribute(kAXMenuItemCmdVirtualKeyAttribute, from: menuItem)?.intValue,
                   glyph: copyNumberAttribute(kAXMenuItemCmdGlyphAttribute, from: menuItem)?.intValue,
                   modifiers: copyNumberAttribute(kAXMenuItemCmdModifiersAttribute, from: menuItem)?.uint32Value
               )
            {
                let qualifiedTitle = (path + [itemTitle]).joined(separator: " › ")
                shortcuts.append(
                    OmniFlowShortcutGuideItem(
                        "\(groupID)-\(itemIndex)",
                        qualifiedTitle,
                        keys: keys
                    )
                )
                itemIndex += 1
            }

            let submenuPath = itemTitle.map { path + [$0] } ?? path
            for submenu in copyElementArrayAttribute(kAXChildrenAttribute, from: menuItem)
            where copyStringAttribute(kAXRoleAttribute, from: submenu) == kAXMenuRole {
                shortcuts.append(
                    contentsOf: collectShortcuts(
                        from: submenu,
                        path: submenuPath,
                        groupID: groupID,
                        itemIndex: &itemIndex,
                        depth: depth + 1
                    )
                )
            }
        }

        return shortcuts
    }

    private func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = value
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func symbol(for menuTitle: String) -> String {
        switch menuTitle.lowercased() {
        case "file": "doc"
        case "edit": "pencil"
        case "view": "eye"
        case "window": "macwindow"
        case "help": "questionmark.circle"
        default: "menubar.rectangle"
        }
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyNumberAttribute(_ attribute: String, from element: AXUIElement) -> NSNumber? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? NSNumber
    }

    private func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyElementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let values = value as? [AnyObject]
        else {
            return []
        }

        return values.prefix(256).compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }
}

enum OmniFlowNativeShortcutKeyFormatter {
    private static let shiftMask: UInt32 = 1 << 0
    private static let optionMask: UInt32 = 1 << 1
    private static let controlMask: UInt32 = 1 << 2
    private static let noCommandMask: UInt32 = 1 << 3

    static func keyCaps(
        commandCharacter: String?,
        virtualKey: Int?,
        glyph: Int?,
        modifiers: UInt32?
    ) -> [String]? {
        let key = keyLabel(for: commandCharacter)
            ?? glyph.flatMap(glyphLabel)
            ?? virtualKey.flatMap(virtualKeyLabel)
        guard let key else { return nil }

        let modifiers = modifiers ?? 0
        var keys: [String] = []
        if modifiers & controlMask != 0 { keys.append("⌃") }
        if modifiers & optionMask != 0 { keys.append("⌥") }
        if modifiers & shiftMask != 0 { keys.append("⇧") }
        if modifiers & noCommandMask == 0 { keys.append("⌘") }
        keys.append(key)
        return keys
    }

    private static func keyLabel(for commandCharacter: String?) -> String? {
        guard let commandCharacter, !commandCharacter.isEmpty else { return nil }
        if commandCharacter == " " { return "Space" }
        if commandCharacter == "\t" { return "Tab" }
        if commandCharacter == "\r" || commandCharacter == "\n" { return "Return" }
        if commandCharacter == "\u{1b}" { return "Esc" }
        if commandCharacter == "\u{7f}" || commandCharacter == "\u{8}" { return "Delete" }

        guard let scalar = commandCharacter.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF71B: return "F\(scalar.value - 0xF703)"
        case 0xF727: return "Insert"
        case 0xF728: return "Delete"
        case 0xF729: return "Home"
        case 0xF72B: return "End"
        case 0xF72C: return "Page↑"
        case 0xF72D: return "Page↓"
        case 0xF746: return "Help"
        default:
            return commandCharacter.count == 1
                ? commandCharacter.uppercased()
                : commandCharacter
        }
    }

    private static func glyphLabel(_ glyph: Int) -> String? {
        switch glyph {
        case 0x02, 0x03: "Tab"
        case 0x04, 0x0B, 0x0C, 0x0D: "Return"
        case 0x09: "Space"
        case 0x0A: "Delete→"
        case 0x17: "Delete"
        case 0x1B: "Esc"
        case 0x1C: "Clear"
        case 0x62: "Page↑"
        case 0x63: "Caps"
        case 0x64: "←"
        case 0x65: "→"
        case 0x67: "Help"
        case 0x68: "↑"
        case 0x6A: "↓"
        case 0x6B: "Page↓"
        case 0x6E: "Power"
        case 0x6F...0x7A: "F\(glyph - 0x6E)"
        case 0x87...0x89: "F\(glyph - 0x87 + 13)"
        case 0x8C: "Eject"
        case 0x8D: "英数"
        case 0x8E: "かな"
        case 0x8F...0x92: "F\(glyph - 0x8F + 16)"
        default: nil
        }
    }

    private static func virtualKeyLabel(_ keyCode: Int) -> String? {
        switch keyCode {
        case 0x24: "Return"
        case 0x30: "Tab"
        case 0x31: "Space"
        case 0x33: "Delete"
        case 0x35: "Esc"
        case 0x40: "F17"
        case 0x4F: "F18"
        case 0x50: "F19"
        case 0x5A: "F20"
        case 0x60: "F5"
        case 0x61: "F6"
        case 0x62: "F7"
        case 0x63: "F3"
        case 0x64: "F8"
        case 0x65: "F9"
        case 0x67: "F11"
        case 0x69: "F13"
        case 0x6A: "F16"
        case 0x6B: "F14"
        case 0x6D: "F10"
        case 0x6F: "F12"
        case 0x71: "F15"
        case 0x72: "Help"
        case 0x73: "Home"
        case 0x74: "Page↑"
        case 0x75: "Delete→"
        case 0x76: "F4"
        case 0x77: "End"
        case 0x78: "F2"
        case 0x79: "Page↓"
        case 0x7A: "F1"
        case 0x7B: "←"
        case 0x7C: "→"
        case 0x7D: "↓"
        case 0x7E: "↑"
        default: nil
        }
    }
}
