import AppKit
import Combine

/// What's playing on this Mac, for the island's Music panel. Direct build only:
/// it runs the private-API Now Playing bridge inside Apple's /usr/bin/perl.
/// Event-driven; runs only while something on screen asks for it.
@MainActor
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    struct Track: Equatable, Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: Double?
        var elapsed: Double?
        var rate: Double
        var sampledAt: Date
        var isPlaying: Bool { rate > 0 }

        /// Elapsed time now, derived from the last sample rather than polled.
        func position(at date: Date = .now) -> Double? {
            guard let elapsed else { return nil }
            let value = elapsed + (isPlaying ? date.timeIntervalSince(sampledAt) * rate : 0)
            return duration.map { min($0, max(0, value)) } ?? max(0, value)
        }
    }

    enum Command: String { case toggle, play, pause, next, previous }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var unavailable = false

    private var demand = 0
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var subscriptions = Set<AnyCancellable>()

    init(observeWorkspace: Bool = true) {
        guard observeWorkspace else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            workspace.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.stopHelper() }.store(in: &subscriptions)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            workspace.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, demand > 0 else { return }
                startHelper()
            }.store(in: &subscriptions)
        }
    }

    func acquire() { demand += 1; if demand == 1 { startHelper() } }
    func release() { demand = max(0, demand - 1); if demand == 0 { stopHelper() } }

    func send(_ command: Command) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command.rawValue + "\n").utf8))
    }

    /// Resume the last player; if nothing starts, open Music and play there.
    func playOrOpenMusic() {
        send(.play)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, track?.isPlaying != true else { return }
            guard let music = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: music, configuration: configuration)
            try? await Task.sleep(for: .seconds(1.5))
            send(.play)
        }
    }

    static func decode(_ line: Data) -> (track: Track?, artwork: Data?, unavailable: Bool)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if object["unavailable"] as? Bool == true { return (nil, nil, true) }
        let artwork = (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        guard let title = object["title"] as? String, !title.isEmpty else { return (nil, artwork, false) }
        let track = Track(title: title, artist: object["artist"] as? String ?? "", album: object["album"] as? String ?? "",
                          duration: (object["duration"] as? NSNumber)?.doubleValue,
                          elapsed: (object["elapsed"] as? NSNumber)?.doubleValue,
                          rate: (object["rate"] as? NSNumber)?.doubleValue ?? 0,
                          sampledAt: Date(timeIntervalSince1970: (object["sampledAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970))
        return (track, artwork, false)
    }

    // MARK: Helper process

    private func startHelper() {
        #if APPSTORE
        unavailable = true
        #else
        guard process == nil else { return }
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        guard let script = Bundle.main.url(forResource: "OmniFlowNowPlaying", withExtension: "pl") else { unavailable = true; return }
        let library = helpers.appendingPathComponent("OmniFlowNowPlaying.dylib")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: library.path) else {
            unavailable = true; return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [script.path, library.path]
        let output = Pipe(), commands = Pipe()
        child.standardOutput = output
        child.standardInput = commands
        child.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = Self.pipeReader(owner: self, child: child)
        child.terminationHandler = Self.terminationHandler(owner: self)
        do {
            try child.run()
            adopt(child, input: commands.fileHandleForWriting)
            unavailable = false
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? commands.fileHandleForWriting.close()
            unavailable = true
        }
        #endif
    }

    private func stopHelper() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()          // the bridge exits when its stdin closes
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; buffer = Data()
    }

    // Bind callbacks to their producer. A terminated helper may report back
    // after sleep/wake or a visibility change has already started its replacement.
    func adopt(_ child: Process, input: FileHandle) {
        process = child
        self.input = input
        buffer = Data()
    }

    nonisolated static func pipeReader(owner: NowPlayingService, child: Process) -> @Sendable (FileHandle) -> Void {
        { [weak owner] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak owner] in owner?.receive(chunk, from: child) }
        }
    }

    nonisolated static func terminationHandler(owner: NowPlayingService) -> @Sendable (Process) -> Void {
        { [weak owner] child in
            let status = child.terminationStatus
            Task { @MainActor [weak owner] in owner?.helperEnded(child, status: status) }
        }
    }

    func receive(_ chunk: Data, from child: Process) {
        guard child === process, !chunk.isEmpty else { return }
        buffer.append(chunk)
        guard buffer.count < 8_000_000 else { buffer = Data(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let update = Self.decode(Data(line)) else { continue }
            if update.unavailable { unavailable = true; continue }
            if let data = update.artwork { artwork = NSImage(data: data) }
            if update.track == nil { artwork = nil }
            track = update.track
        }
    }

    func helperEnded(_ child: Process, status: Int32) {
        guard child === process else { return }
        (child.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        process = nil; input = nil; buffer = Data()
        // A macOS update can break the private bridge; say so instead of retrying forever.
        if status != 0 && status != 15 { unavailable = true }
    }
}
