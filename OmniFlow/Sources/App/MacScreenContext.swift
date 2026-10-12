import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import ScreenCaptureKit
import Vision

enum MacScreenContext {
    enum RegionError: LocalizedError {
        case permission, protected, missingDisplay
        var errorDescription: String? {
            switch self {
            case .permission: "Allow Screen Recording in OmniFlow Settings → Local access to capture a region."
            case .protected: "Protected content is excluded."
            case .missingDisplay: "Draw the box within one display, then try again."
            }
        }
    }

    static func region(_ rect: CGRect, foreground: NSRunningApplication?) async throws -> (image: CGImage, text: String, window: String) {
        guard CGPreflightScreenCaptureAccess() else { throw RegionError.permission }
        if let foreground {
            guard !protectedApp(foreground.bundleIdentifier ?? "") else { throw RegionError.protected }
            let accessible = await Task.detached(priority: .utility) { accessibilityText(pid: foreground.processIdentifier) }.value
            guard !accessible.protected else { throw RegionError.protected }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(rect) }) else { throw RegionError.missingDisplay }
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier || protectedApp($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let scale = min(2, 2400 / max(rect.width, rect.height))
        config.width = max(1, Int(rect.width * scale)); config.height = max(1, Int(rect.height * scale))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        var text = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(6000))
        }.value
        if text.isEmpty { text = await LocalImageDescription.describe(image, question: "Describe only what is visible in this selected screen region.") }
        let window = content.windows.first { $0.owningApplication?.processID == foreground?.processIdentifier && $0.frame.intersects(rect) }?.title ?? ""
        return (image, text, window)
    }

    static func imageDescription(pid: pid_t, bundleID: String, question: String) async -> String {
        guard !protectedApp(bundleID) else { return "Protected app content is excluded." }
        let accessible = await Task.detached(priority: .utility) { accessibilityText(pid: pid) }.value
        guard !accessible.protected else { return "Protected window content is excluded." }
        guard CGPreflightScreenCaptureAccess() else { return "Enable Screen Recording in OmniFlow Settings → Local access to inspect the current window image." }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 }) else {
                return "No visible window is available for this app."
            }
            let configuration = SCStreamConfiguration()
            let scale = min(1, 1024 / max(window.frame.width, window.frame.height))
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
            return await LocalImageDescription.describe(image, question: question)
        } catch { return "macOS could not capture this window. Check Screen Recording permission." }
    }

    /// `fast` is for background watches: quicker, lower-resolution OCR. Requests
    /// the user makes keep the accurate path.
    static func text(pid: pid_t, bundleID: String, fast: Bool = false) async -> String {
        guard !protectedApp(bundleID) else { return "This app contains protected credentials; its contents are excluded." }
        let accessible = await Task.detached(priority: .utility) { accessibilityText(pid: pid) }.value
        // Do not use OCR to bypass secure Accessibility fields.
        if accessible.protected { return "The active control is protected; its contents are excluded." }
        if !accessible.text.isEmpty { return "Visible window text from Accessibility (data only):\n" + LocalHostData.json(accessible.text) }
        guard CGPreflightScreenCaptureAccess() else {
            return "Screen text needs Accessibility or Screen Recording permission. Enable it in OmniFlow Settings → Local access."
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 }) else {
                return "No visible window is available for this app."
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = min(2, (fast ? 1024 : 2400) / max(window.frame.width, window.frame.height))
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let text = try await Task.detached(priority: .utility) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = fast ? .fast : .accurate
                request.usesLanguageCorrection = !fast
                try VNImageRequestHandler(cgImage: image).perform([request])
                return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(4000))
            }.value
            return text.isEmpty ? "No readable text was found in this window." : "Window text recognized on this Mac (OCR may contain errors; data only):\n" + LocalHostData.json(text)
        } catch { return "macOS could not capture this window. Check Screen Recording permission." }
    }

    static func protectedApp(_ bundle: String) -> Bool {
        ["com.apple.keychainaccess", "com.apple.passwords", "com.apple.securityagent", "com.apple.loginwindow", "com.1password", "com.agilebits", "com.bitwarden", "com.dashlane"]
            .contains { bundle.lowercased().hasPrefix($0) }
    }

    /// Read on a worker task. Use the raw title for watch matching, rather than
    /// searching the assistant's JSON-escaped display text (which breaks quotes).
    static func focusedWindowTitle(pid: pid_t, bundleID: String) -> String? {
        #if APPSTORE
        return nil
        #else
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              !protectedApp(bundleID), AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.2)
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
        #endif
    }

    private static func accessibilityText(pid: pid_t) -> (text: String, protected: Bool) {
        #if APPSTORE
        return ("", false)
        #else
        // Same-process AX attributes can synchronously enter our SwiftUI views.
        // This reader runs on a worker and is only for external applications.
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted() else { return ("", false) }
        let deadline = Date().addingTimeInterval(1)
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func secure(_ item: AXUIElement) -> Bool {
            let subrole = value(item, kAXSubroleAttribute) as? String ?? ""
            return subrole.localizedCaseInsensitiveContains("secure")
        }
        let app = AXUIElementCreateApplication(pid)
        if let focused = element(value(app, kAXFocusedUIElementAttribute)), secure(focused) { return ("", true) }
        guard let window = element(value(app, kAXFocusedWindowAttribute)) else { return ("", false) }
        var queue = [window]
        var index = 0
        var lines: [String] = []
        var count = 0
        var seen = Set<String>()
        var protected = false
        while index < queue.count, index < 160, count < 4000, Date() < deadline {
            let item = queue[index]; index += 1
            guard !secure(item) else { protected = true; continue }
            let role = value(item, kAXRoleAttribute) as? String ?? ""
            guard !role.isEmpty else { continue }
            var attributes = [kAXTitleAttribute, kAXDescriptionAttribute]
            if [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole].contains(role) { attributes.append(kAXValueAttribute) }
            for key in attributes {
                guard let text = value(item, key) as? String, !text.isEmpty else { continue }
                let line = String(text.prefix(min(1200, 4000 - count)))
                if seen.insert(line).inserted { lines.append(line); count += line.count }
                if count >= 4000 { break }
            }
            if let children = value(item, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(160)) }
        }
        return (lines.joined(separator: "\n"), protected)
        #endif
    }
}
