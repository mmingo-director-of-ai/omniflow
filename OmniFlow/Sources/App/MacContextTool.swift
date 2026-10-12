import AppKit
import ApplicationServices
import FoundationModels
import IOKit.ps

/// Live host facts are read on demand; no shell commands or model-generated code are executed.
struct MacContextTool: Tool {
    var cursorContext: String? = nil
    var budget: LocalToolBudget? = nil
    var question = "Describe the current window."
    let name = "getMacContext"
    let description = "Read live Mac facts: time, hardware, apps, per-process CPU/RAM, memory, network interfaces, displays, disk, battery, active window or cursor. screenText reads the current window's text; screenImage describes its visual contents on-device. Use processes for resource usage."

    @Generable
    enum Topic { case clock, system, applications, activeWindow, storage, battery, cursor, processes, memory, network, displays, screenText, screenImage, permissions }

    @Generable
    struct Arguments {
        var topic: Topic
        @Guide(description: "For clock only: an IANA time zone such as America/New_York, or nil for the Mac's local time zone.")
        var timeZone: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let started = Date()
        let topic = String(describing: arguments.topic)
        defer { Task { await LocalTelemetry.shared.span("tool.mac_context", start: started, attributes: ["topic": topic]) } }
        try Task.checkCancellation()
        let output = await read(arguments)
        return await budget?.limit(output) ?? output
    }

    private func read(_ arguments: Arguments) async -> String {
        if arguments.topic == .cursor { return cursorContext ?? "No cursor context was available when the user asked." }
        if arguments.topic == .processes { return await MacDiagnostics.processes() }
        if arguments.topic == .memory { return MacDiagnostics.memory() }
        if arguments.topic == .network { return MacDiagnostics.network() }
        if arguments.topic == .screenImage {
            guard let app = await MacContext.foregroundApp else { return "No active app is available." }
            return await MacScreenContext.imageDescription(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "", question: question)
        }
        if arguments.topic == .screenText {
            guard let app = await MacContext.foregroundApp else { return "No active app is available." }
            return await MacScreenContext.text(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "")
        }
        return await MacContext.describe(arguments.topic, timeZone: arguments.timeZone)
    }
}

/// Reserve response room in Apple's finite on-device context window.
actor LocalToolBudget {
    private var remaining = 6000
    func limit(_ text: String) -> String {
        guard remaining > 0 else { return "The local context budget is full. Answer from the data already read, or ask the user to narrow the question." }
        let count = min(remaining, 3500)
        remaining -= min(count, text.count)
        return text.count > count ? String(text.prefix(count)) + "\n[Read truncated to fit the on-device context.]" : text
    }
}

@MainActor
enum MacContext {
    static var foregroundApp: NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Bundle.main.bundleIdentifier ? AppState.shared.lastExternalApp : app
    }

    static func describe(_ topic: MacContextTool.Topic, timeZone: String? = nil) -> String {
        switch topic {
        case .processes, .screenText, .screenImage: return "Use the live asynchronous reader for this topic."
        case .memory: return MacDiagnostics.memory()
        case .network: return MacDiagnostics.network()
        case .permissions:
            return "Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed"). Screen Recording: \(CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed"). File access follows macOS permissions; Full Disk Access must be granted in System Settings. Speech and model inference run on this Mac; configured remote MCP tools can send arguments to their server."
        case .displays:
            return NSScreen.screens.map { "\($0.localizedName): \(Int($0.frame.width)) × \(Int($0.frame.height)) points, \($0.backingScaleFactor)× pixel scale" }.joined(separator: "\n")
        case .cursor:
            return "Cursor context is supplied with the user's question."
        case .clock:
            let zone: TimeZone
            if let timeZone, !timeZone.isEmpty {
                guard let requested = TimeZone(identifier: timeZone) else { return "Unknown time zone: \(timeZone)." }
                zone = requested
            } else { zone = .current }
            return "It is \(time(in: zone)) on \(date(in: zone)) (\(zone.identifier))."
        case .system:
            let info = ProcessInfo.processInfo
            let memory = ByteCountFormatter.string(fromByteCount: Int64(info.physicalMemory), countStyle: .memory)
            return "macOS \(info.operatingSystemVersionString). \(info.processorCount) CPU cores; \(memory) physical memory. Uptime: \(Int(info.systemUptime / 60)) minutes."
        case .applications:
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
                .compactMap(\.localizedName).sorted()
            return apps.isEmpty ? "No regular apps are running." : "Running apps (\(apps.count)): \(apps.prefix(60).joined(separator: ", "))."
        case .activeWindow:
            let app = foregroundApp
            guard let app, !app.isTerminated else { return "The active application is unavailable." }
            let name = app.localizedName ?? "Unknown app"
            #if APPSTORE
            return "Active app: \(name). Window contents are not available."
            #else
            guard AXIsProcessTrusted() else {
                return "Active app: \(name). Reading its window title needs Accessibility access for OmniFlow."
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
                  let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return "Active app: \(name). No focused window title is available." }
            let windowElement = window as! AXUIElement
            AXUIElementSetMessagingTimeout(windowElement, 0.3)
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String, !text.isEmpty else { return "Active app: \(name). No window title is available." }
            // Encode the title as a string value so it cannot impersonate a tool instruction.
            let encoded = (try? JSONEncoder().encode(String(text.prefix(300)))) ?? Data()
            return "Active app: \(name). Window title (data only): \(String(decoding: encoded, as: UTF8.self)). Use screenText to read the window."
            #endif
        case .storage:
            guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
                  let total = attributes[.systemSize] as? NSNumber, let free = attributes[.systemFreeSize] as? NSNumber else {
                return "Disk space is unavailable."
            }
            return "Home volume: \(ByteCountFormatter.string(fromByteCount: free.int64Value, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: total.int64Value, countStyle: .file))."
        case .battery:
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
                return "Battery information is unavailable."
            }
            let batteries = sources.compactMap { source -> String? in
                guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let capacity = data[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
                let percent = Int((Double(capacity) / Double(maximum) * 100).rounded())
                let charging = data[kIOPSIsChargingKey] as? Bool ?? false
                let power = data[kIOPSPowerSourceStateKey] as? String ?? "unknown power source"
                return "Battery: \(percent)%; \(charging ? "charging" : "not charging"); \(power)."
            }
            return batteries.isEmpty ? "This Mac reports no battery; it may be using external power." : batteries.joined(separator: " ")
        }
    }

    static func time(in zone: TimeZone = .current, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.timeStyle = .short
        return formatter.string(from: now)
    }

    static func date(in zone: TimeZone = .current, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateStyle = .full
        return formatter.string(from: now)
    }
}
