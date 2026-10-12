import AppKit
import Foundation

enum OmniFlowMonitoringChecks {
    @MainActor static func run() async throws {
        try parserChecks()
        let all = OmniFlowSystemShortcutCatalog.groups.flatMap(\.shortcuts)
        precondition(all.count == 226 && Set(all.map(\.id)).count == all.count,
                     "The complete shortcut catalog was lost or duplicated")
        let pages = OmniFlowShortcutGuideCoordinator.systemPages()
        precondition(pages.flatMap(\.groups).flatMap(\.shortcuts) == all,
                     "Pagination dropped or reordered shortcuts")
        precondition(pages.allSatisfy { $0.groups.count <= 3 && $0.groups.allSatisfy { $0.shortcuts.count <= 8 } })
        precondition(OmniFlowNativeShortcutKeyFormatter.keyCaps(commandCharacter: "x", virtualKey: nil, glyph: nil, modifiers: 1) == ["⇧", "⌘", "X"])
        for mask in 0..<16 {
            let allowed = OmniFlowMonitoringCoordinator.allowsPublicIP(enabled: mask & 1 != 0,
                collectsSystem: mask & 2 != 0, includesNetwork: mask & 4 != 0, consent: mask & 8 != 0)
            precondition(allowed == (mask == 15), "A public IP request escaped an explicit collection/consent gate")
        }
        let now = Date(timeIntervalSince1970: 1000)
        precondition(OmniFlowMonitoringCoordinator.nextSampleDelay(now: now,
            systemDeadline: now.addingTimeInterval(30), agentDeadline: now.addingTimeInterval(10)) == 10,
                     "The sampler woke before the earliest enabled category was due")
        precondition(OmniFlowMonitoringCoordinator.nextSampleDelay(now: now,
            systemDeadline: now.addingTimeInterval(30), agentDeadline: nil) == 30,
                     "A disabled category shortened the active sampling interval")
        precondition(OmniFlowMonitoringCoordinator.nextSampleDelay(now: now,
            systemDeadline: nil, agentDeadline: nil) == nil,
                     "The sampler kept waking with no collection enabled")
        precondition(OmniFlowMonitoringCoordinator.nextSampleDelay(now: now,
            systemDeadline: now.addingTimeInterval(-10), agentDeadline: nil) == 0.05,
                     "An overdue deadline could spin without yielding")
        precondition(OmniFlowMonitoringCoordinator.nextSampleDelay(now: now,
            systemDeadline: now.addingTimeInterval(3600), agentDeadline: nil) == 30,
                     "A wall-clock adjustment stalled monitoring beyond its maximum cadence")
        let name = "OmniFlowChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = OmniFlowFocusSettings(defaults: defaults)
        let monitor = OmniFlowMonitoringCoordinator(defaults: defaults)
        precondition(!monitor.enabled && !monitor.publicIPLookupEnabled)
        monitor.collectsSystem = false; monitor.collectsAgents = false
        monitor.start(); monitor.start()
        precondition(monitor.isRunning && monitor.system == nil && monitor.agents == nil && !monitor.isRefreshing,
                     "Starting a disabled coordinator collected data")
        precondition(monitor.lastUpdated == nil, "Starting without a sample fabricated a refresh timestamp")
        monitor.enabled = true
        precondition(monitor.system == nil && monitor.agents == nil,
                     "An enabled master ignored disabled collection categories")
        monitor.stop()
        precondition(!monitor.isRunning && !monitor.isRefreshing)
        monitor.collectsSystem = true; monitor.collectsAgents = true; monitor.showsNetwork = true
        let noMedia = UserDefaults(suiteName: "OmniFlowNoMedia.\(UUID().uuidString)")!
        for key in [NotchLeePanel.musicKey, NotchLeePanel.weatherKey, NotchLeePanel.newsKey] { noMedia.set(false, forKey: key) }
        precondition(NotchLeePanel.pages(for: monitor, defaults: noMedia) == [.home, .sessions, .cpu, .memory, .disk, .network, .system, .agents, .quotas],
                     "The carousel lost a monitoring panel")
        monitor.showsNetwork = false; monitor.collectsAgents = false
        precondition(NotchLeePanel.pages(for: monitor, defaults: noMedia) == [.home, .sessions, .cpu, .memory, .disk, .system],
                     "Disabled categories must not leave empty panels")
        monitor.collectsSystem = false
        precondition(NotchLeePanel.pages(for: monitor, defaults: noMedia) == [.home, .sessions, .monitoringOff], "No categories must offer the setup panel")
        monitor.enabled = false
        precondition(NotchLeePanel.pages(for: monitor, defaults: noMedia) == [.home, .sessions, .monitoringOff], "Disabled monitoring must offer the turn-on panel")
        monitor.stop()
        let widget = OmniFlowWidgetPublisher.snapshot(monitor: monitor, focusEnabled: true, dictation: .init(words: 3, dictations: 1, wordsPerMinute: nil))
        precondition(widget.system == nil && widget.agents == nil && widget.focusFollowsMouse && widget.dictation?.words == 3,
                     "The widget snapshot invented monitoring data")
        let encoded = try JSONEncoder().encode(widget)
        let decoded = try JSONDecoder().decode(OmniFlowWidgetSnapshot.self, from: encoded)
        precondition(decoded == widget, "Widget snapshot did not round-trip")
        let keys = String(decoding: try JSONEncoder().encode(OmniFlowWidgetSnapshot.Session(id: "s", project: "p", harness: "h", state: "idle", context: nil)), as: UTF8.self)
        precondition(!keys.contains("workingDirectory") && !keys.contains("taskLabel"), "Widgets must not receive paths or prompts")
        let entry = DictationEntry(raw: "um hello there", text: "Hello there.", note: "", destination: "Notes")
        let entity = DictationEntity(entry)
        precondition(entity.id == entry.id && entity.text == "Hello there." && entity.destination == "Notes",
                     "Shortcuts must see the polished text of the right dictation")
        precondition(DictationEntity(DictationEntry(raw: "raw only", text: "", note: "", destination: "x")).text == "raw only",
                     "A dictation without cleanup must expose its original text")
        precondition(BotState.approval.spokenStatus == "waiting for approval" && BotState.working.spokenStatus == "working")
        let lockDefaults = UserDefaults(suiteName: "OmniFlowLock.\(UUID().uuidString)")!
        let lock = OmniFlowAppLock(defaults: lockDefaults)
        precondition(!lock.enabled && !lock.isLocked, "The lock must be off until the user turns it on")
        lock.lock()
        precondition(!lock.isLocked, "A disabled lock must never hide content")
        lock.enabled = true; lock.idleMinutes = 5
        lock.checkIdle(now: Date().addingTimeInterval(4 * 60))
        precondition(!lock.isLocked, "Locked before the idle period ended")
        lock.checkIdle(now: Date().addingTimeInterval(6 * 60))
        precondition(lock.isLocked, "Idle period passed without locking")
        lock.enabled = false
        precondition(!lock.isLocked, "Turning the lock off must reveal content")
        lock.enabled = true; lock.idleMinutes = 0
        lock.checkIdle(now: Date().addingTimeInterval(24 * 3600))
        precondition(!lock.isLocked, "Sleep-only mode must not lock on idle")
        precondition(OmniFlowAppLock(defaults: lockDefaults).isLocked, "An enabled lock must start locked after relaunch")
        let resumed = OmniFlowAppLock(defaults: lockDefaults)
        let before = resumed.retryToken
        resumed.resumeAfterSystem()
        precondition(resumed.retryToken == before + 1, "Waking the Mac must restart the in-app Touch ID sensor")
        resumed.enabled = false
        let unlockedToken = resumed.retryToken
        resumed.resumeAfterSystem()
        precondition(resumed.retryToken == unlockedToken, "An unlocked app must not restart authentication")
        let mediaDefaults = UserDefaults(suiteName: "OmniFlowMedia.\(UUID().uuidString)")!
        let media = NotchLeePanel.mediaPages(defaults: mediaDefaults)
        precondition(media.contains(.weather) && media.contains(.news) && media.allSatisfy { !$0.isMonitoring },
                     "Media pages must never hold the monitoring sampler")
        mediaDefaults.set(false, forKey: NotchLeePanel.newsKey)
        precondition(!NotchLeePanel.mediaPages(defaults: mediaDefaults).contains(.news), "A switched-off page still showed")
        let nowPlaying = NowPlayingService.decode(Data(#"{"title":"Song","artist":"Artist","album":"Album","duration":200,"elapsed":50,"rate":1,"sampledAt":1000}"#.utf8))
        precondition(nowPlaying?.track?.title == "Song" && nowPlaying?.track?.isPlaying == true)
        precondition(nowPlaying?.track?.position(at: Date(timeIntervalSince1970: 1010)) == 60, "Elapsed time must be derived, not polled")
        precondition(nowPlaying?.track?.position(at: Date(timeIntervalSince1970: 5000)) == 200, "Position must stop at the track end")
        precondition(NowPlayingService.decode(Data(#"{"sampledAt":1}"#.utf8))?.track == nil, "No title means nothing is playing")
        precondition(NowPlayingService.decode(Data(#"{"unavailable":true}"#.utf8))?.unavailable == true)
        let rss = #"<rss><channel><title>Example News</title><item><title>First</title><link>https://example.org/1</link><pubDate>Sun, 04 Oct 2026 10:00:00 +0000</pubDate></item><item><title><![CDATA[Second & more]]></title><link>javascript:alert(1)</link></item></channel></rss>"#
        let items = FeedParser.headlines(from: Data(rss.utf8), fallbackSource: "x")
        precondition(items.count == 2 && items[0].source == "Example News" && items[0].link?.host == "example.org" && items[0].date != nil)
        precondition(items[1].title == "Second & more" && items[1].link == nil, "Only web links may open from headlines")
        let atom = #"<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom Site</title><entry><title>Atomic</title><link rel="alternate" href="https://example.com/a"/><updated>2026-10-04T09:00:00Z</updated></entry></feed>"#
        let entries = FeedParser.headlines(from: Data(atom.utf8), fallbackSource: "x")
        precondition(entries.first?.title == "Atomic" && entries.first?.link?.absoluteString == "https://example.com/a" && entries.first?.source == "Atom Site")
        monitor.acquire(); monitor.acquire(); monitor.release()
        precondition(monitor.isRunning, "Closing one surface stopped sampling for another visible one")
        monitor.release(); monitor.release()
        precondition(!monitor.isRunning, "Sampling continued with no visible monitoring surface")
        monitor.acquire()
        precondition(monitor.isRunning, "An extra release left the demand count unable to restart")
        monitor.release()

        let fixture = InputFixture()
        let guide = OmniFlowShortcutGuideCoordinator(settings: settings, defaults: defaults, provider: StubProvider(),
            showDelay: .milliseconds(15), focusController: nil, observeEvents: false)
        guide.onPresentationRequested = { fixture.presentationRequests += 1 }
        precondition(!guide.holdEnabled, "A second global guide owner was enabled by default")
        guide.start(); guide.holdEnabled = true
        guide.openForFrontmostApp()
        precondition(guide.isPresented && guide.pages.first?.eyebrow == "Fixture App", "Manual guide or native menu page is unavailable")
        precondition(fixture.presentationRequests == 0, "Manual refresh opened another surface")
        guide.dismiss(); guide.applySettings()
        guide.handleEvent(type: .flagsChanged, flags: .command)
        guide.handleEvent(type: .rightMouseDown, flags: .command)
        try await Task.sleep(for: .milliseconds(40))
        precondition(!guide.isPresented, "Command-right-click displayed the shortcut guide")
        guide.handleEvent(type: .flagsChanged, flags: [])
        guide.handleEvent(type: .flagsChanged, flags: .command)
        guide.handleEvent(type: .leftMouseDragged, flags: .command)
        try await Task.sleep(for: .milliseconds(40))
        precondition(!guide.isPresented, "Command-drag displayed the shortcut guide")
        guide.handleEvent(type: .flagsChanged, flags: [])
        guide.handleEvent(type: .flagsChanged, flags: [.command, .shift])
        guide.handleEvent(type: .flagsChanged, flags: .command)
        try await Task.sleep(for: .milliseconds(40))
        precondition(!guide.isPresented, "Removing another modifier armed a still-held Command")
        guide.handleEvent(type: .flagsChanged, flags: [])
        guide.handleEvent(type: .flagsChanged, flags: .command)
        try await Task.sleep(for: .milliseconds(40))
        precondition(guide.isPresented, "Holding Command alone did not show the shared guide")
        precondition(fixture.presentationRequests == 1, "Command hold failed to request the shared presentation")
        guide.handleEvent(type: .flagsChanged, flags: [])
        precondition(!guide.isPresented, "Releasing Command retained a hold-triggered guide")
        guide.handleEvent(type: .flagsChanged, flags: .command)
        guide.stop()
        try await Task.sleep(for: .milliseconds(40))
        precondition(!guide.isPresented && !guide.isMonitoring, "A delayed guide outlived stop")
        print("OmniFlow monitoring consent, log parsing, catalog completeness and guide lifecycle checks passed")
    }

    private static func parserChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omniflow-parser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex.jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"id":"fixture","cwd":"/tmp/fixture-project","source":{"subagent":{"thread_spawn":{"agent_path":"/root/check_parser","agent_nickname":"Fixture"}}}}}"#,
            #"{"type":"turn_context","payload":{"model":"fixture-model","cwd":"/tmp/fixture-project","effort":"high"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1200},"last_token_usage":{"input_tokens":800},"model_context_window":4000},"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1900000000}}}}"#
        ]
        try lines.joined(separator: "\n").write(to: codex, atomically: true, encoding: .utf8)
        let reader = OmniFlowAgentSessionLogReader()
        let parsed = reader.readCodexSession(codex)
        precondition(parsed?.session.project == "fixture-project" && parsed?.session.taskLabel == "Fixture · check parser")
        precondition(parsed?.session.tokenUsage.totalTokens == 1200 && parsed?.session.contextFraction == 0.2)
        precondition(parsed?.quotas.first?.usedFraction == 0.25)
        let claude = root.appendingPathComponent("claude.jsonl")
        try #"{"type":"assistant","sessionId":"fixture-claude","cwd":"/tmp/fixture-project","gitBranch":"test/parser","message":{"model":"fixture-model","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50}}}"#.write(to: claude, atomically: true, encoding: .utf8)
        let claudeResult = reader.readClaudeSession(claude)
        precondition(claudeResult?.session.tokenUsage.totalTokens == 650 && claudeResult?.session.tokenUsage.cachedInputTokens == 500)
        try #"{"type":"assistant","sessionId":"overflow","message":{"usage":{"input_tokens":1e100,"cache_read_input_tokens":1e100,"output_tokens":1e100}}}"#.write(to: claude, atomically: true, encoding: .utf8)
        precondition(reader.readClaudeSession(claude)?.session.tokenUsage.totalTokens == .max,
                     "Oversized external log numbers overflowed the parser")
        try "not JSON\n{}\n".write(to: codex, atomically: true, encoding: .utf8)
        precondition(reader.readCodexSession(codex) == nil, "Malformed data fabricated a session")
        try incrementalTailChecks(root: root, reader: reader)
    }

    /// Appended lines are folded exactly once; partial lines wait; rotation restarts.
    private static func incrementalTailChecks(root: URL, reader: OmniFlowAgentSessionLogReader) throws {
        let log = root.appendingPathComponent("incremental.jsonl")
        let line = #"{"type":"assistant","sessionId":"tail","cwd":"/tmp/tail","message":{"model":"m","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50}}}"#
        try (line + "\n").write(to: log, atomically: true, encoding: .utf8)
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
        }
        var tail = OmniFlowAgentLogTail(harness: .claude)
        precondition(reader.update(&tail, url: log)?.session.tokenUsage.totalTokens == 650)
        try append(line + "\n")
        precondition(reader.needsRead(tail, url: log), "An appended log was not seen as changed")
        precondition(reader.update(&tail, url: log)?.session.tokenUsage.totalTokens == 1300, "Appended usage was lost or double counted")
        precondition(!reader.needsRead(tail, url: log))
        precondition(reader.update(&tail, url: log)?.session.tokenUsage.totalTokens == 1300, "An unchanged log was counted again")
        let half = line.index(line.startIndex, offsetBy: line.count / 2)
        try append(String(line[..<half]))
        precondition(reader.update(&tail, url: log)?.session.tokenUsage.totalTokens == 1300, "A partial line was counted")
        try append(String(line[half...]) + "\n")
        precondition(reader.update(&tail, url: log)?.session.tokenUsage.totalTokens == 1950, "A completed line was lost")
        try (line + "\n").write(to: log, atomically: true, encoding: .utf8)
        precondition(reader.update(&tail, url: log)?.session.tokenUsage.totalTokens == 650, "A replaced log kept stale totals")
    }

    @MainActor private struct StubProvider: OmniFlowNativeShortcutProviding {
        func frontmostApplicationShortcuts() -> OmniFlowNativeShortcutSnapshot? {
            .init(applicationName: "Fixture App", bundleIdentifier: "test.fixture", groups: [
                .init(id: "fixture", title: "Edit", symbol: "pencil", shortcuts: [.init("copy", "Copy", keys: ["⌘", "C"])])
            ])
        }
    }
    @MainActor private final class InputFixture {
        var presentationRequests = 0
    }
}
