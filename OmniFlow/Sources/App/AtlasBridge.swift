import Foundation
import Darwin

@MainActor
final class AtlasBridge {
    typealias Handler = @MainActor (AtlasFrame) async throws -> AtlasFrame
    nonisolated static let maximumFrameBytes = AtlasLimits.maximumFrameBytes
    static let maximumSteps = AtlasLimits.maximumSteps
    static var helperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NotchLeeAtlas")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    static var buildIdentity: AtlasBuildIdentity? {
        guard let url = Bundle.main.url(forResource: "atlas-sdk.lock", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AtlasBuildIdentity.self, from: data)
    }
    static var status: String {
        guard helperURL != nil, let identity = buildIdentity else { return "Atlas helper unavailable" }
        return "Atlas \(identity.version) · Apple on-device model"
    }

    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var handler: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var callbackDeadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<AtlasRunResult, Error>?
    private var buffer = Data()
    private var started = false
    private var nextCallback = 1
    private let requestID = UUID().uuidString
    private var onModel: Handler?
    private var onTool: Handler?
    private var startFrame = AtlasFrame(type: "start")
    private var identity: AtlasBuildIdentity?
    private var storeDirectory: URL?
    private(set) var processID: Int32?

    static func catalog(server: MCPServerConfiguration, executable: URL? = helperURL,
                        identity: AtlasBuildIdentity? = buildIdentity) async throws -> MCPCatalog {
        let result = try await AtlasBridge().run(prompt: "Discover configured MCP tools for user review.", tools: [],
            servers: [server], mode: "catalog", executable: executable, identity: identity, timeout: 35, requireAuthentication: true,
            onModel: { _ in throw AtlasBridgeError.invalidFrame }, onTool: { _ in throw AtlasBridgeError.invalidFrame })
        return try JSONDecoder().decode(MCPCatalog.self, from: Data(result.text.utf8))
    }

    func run(prompt: String, tools: [AtlasToolDefinition], servers: [MCPServerConfiguration] = [], mode: String? = nil, question: String? = nil,
             discoveryQuery: String? = nil,
             executable: URL? = AtlasBridge.helperURL, identity: AtlasBuildIdentity? = AtlasBridge.buildIdentity,
             workspace: URL? = nil, resume: Bool = false,
             timeout: Double = 3605, requireAuthentication: Bool = false, onModel: @escaping Handler, onTool: @escaping Handler) async throws -> AtlasRunResult {
        guard let executable, let identity else { throw AtlasBridgeError.unavailable }
        guard continuation == nil, processID == nil, prompt.utf8.count <= 64000,
              (discoveryQuery?.utf8.count ?? 0) <= 8000 else { throw AtlasBridgeError.invalidFrame }
        self.identity = identity
        self.onModel = onModel
        self.onTool = onTool
        startFrame.prompt = prompt
        startFrame.question = question
        startFrame.discoveryQuery = discoveryQuery
        startFrame.tools = tools
        startFrame.servers = try await MCPAuthorization.configure(servers, requireAuthentication: requireAuthentication)
        try Task.checkCancellation()
        startFrame.broker = servers.contains(where: { !$0.isRemote }) ? LocalMCPLauncher.shared.endpoint : nil
        startFrame.mode = mode
        guard !resume || (workspace != nil && servers.isEmpty && mode == nil) else { throw AtlasBridgeError.invalidFrame }
        let directory = workspace ?? FileManager.default.temporaryDirectory.appendingPathComponent("notchlee-payloads-" + requestID, isDirectory: true)
        if workspace == nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            storeDirectory = directory
        }
        defer { if workspace == nil { try? FileManager.default.removeItem(at: directory) } }
        startFrame.storeDirectory = directory.path
        startFrame.persistent = workspace != nil
        startFrame.resume = resume
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { result in
                continuation = result
                let child = Process()
                let stdin = Pipe()
                let stdout = Pipe()
                child.executableURL = executable
                // Explicit environment prevents inherited API keys, proxies and debug logging.
                child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "GOTRACEBACK": "none"]
                child.standardInput = stdin
                child.standardOutput = stdout
                child.standardError = FileHandle.nullDevice
                input = stdin.fileHandleForWriting
                _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                process = child
                do {
                    try child.run()
                    processID = child.processIdentifier
                    // Parent copies of the child's pipe ends must close so crashes produce EOF.
                    try stdin.fileHandleForReading.close()
                    try stdout.fileHandleForWriting.close()
                    let output = stdout.fileHandleForReading
                    reader = Task.detached(priority: .userInitiated) { [weak self] in
                        defer { try? output.close() }
                        var bytes = [UInt8](repeating: 0, count: 8192)
                        while !Task.isCancelled {
                            // POSIX read returns the available pipe bytes immediately. A buffered
                            // read-to-length can wait for a full block and deadlock an RPC handshake.
                            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { break }
                            await self?.receive(Data(bytes.prefix(count)))
                        }
                        await self?.finish(.failure(AtlasBridgeError.failed))
                    }
                    deadline = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(timeout))
                        guard !Task.isCancelled else { return }
                        self?.finish(.failure(AtlasBridgeError.timedOut))
                    }
                } catch { finish(.failure(AtlasBridgeError.unavailable)) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func receive(_ data: Data) {
        guard continuation != nil else { return }
        buffer.append(data)
        do {
            while let newline = buffer.firstIndex(of: 10) {
                guard newline < Self.maximumFrameBytes else { throw AtlasBridgeError.invalidFrame }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                let frame = try JSONDecoder().decode(AtlasFrame.self, from: line)
                try receive(frame)
                if continuation == nil { return }
            }
            guard buffer.count < Self.maximumFrameBytes else { throw AtlasBridgeError.invalidFrame }
        } catch { finish(.failure(error is AtlasBridgeError ? error : AtlasBridgeError.invalidFrame)) }
    }

    private func receive(_ frame: AtlasFrame) throws {
        guard frame.version == 4 else { throw AtlasBridgeError.incompatible }
        if frame.type == "ready" {
            guard !started, frame.sdkVersion == identity?.version, frame.revision == identity?.revision else { throw AtlasBridgeError.incompatible }
            started = true
            try send(startFrame)
            return
        }
        if frame.type == "error" { throw AtlasBridgeError.remoteCode(frame.error) }
        guard started, frame.requestID == requestID else { throw AtlasBridgeError.invalidFrame }
        switch frame.type {
        case "model", "analysis", "tool":
            guard handler == nil, frame.id == String(nextCallback) else { throw AtlasBridgeError.invalidFrame }
            nextCallback += 1
            let callback = frame.type == "tool" ? onTool : onModel
            callbackDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(150))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(AtlasBridgeError.timedOut))
            }
            handler = Task { [weak self] in
                guard let self, let callback else { return }
                do {
                    var reply = try await callback(frame)
                    try Task.checkCancellation()
                    guard continuation != nil else { return }
                    reply.type = "reply"
                    reply.id = frame.id
                    callbackDeadline?.cancel(); callbackDeadline = nil
                    handler = nil
                    try send(reply)
                } catch { finish(.failure(error)) }
            }
        case "event":
            guard let tool = frame.tool, ["getMacContext", "inspectLocalFiles", "mcp", "payload", "memory", "recallSavedMemory"].contains(tool) else { throw AtlasBridgeError.invalidFrame }
            Task { await LocalTelemetry.shared.event("atlas.tool.\(tool)", success: frame.success == true) }
        case "done":
            guard handler == nil, frame.stopReason == "stop", let text = frame.content, !text.isEmpty,
                  let steps = frame.steps, (1...Self.maximumSteps).contains(steps), let count = frame.toolCount, (0..<Self.maximumSteps).contains(count) else {
                throw AtlasBridgeError.invalidFrame
            }
            finish(.success(AtlasRunResult(text: text, steps: steps, toolCount: count)))
        default: throw AtlasBridgeError.invalidFrame
        }
    }

    private func send(_ frame: AtlasFrame) throws {
        guard continuation != nil, let input else { throw CancellationError() }
        var frame = frame
        frame.version = 4
        frame.requestID = requestID
        var data = try JSONEncoder().encode(frame)
        guard data.count < Self.maximumFrameBytes else { throw AtlasBridgeError.invalidFrame }
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func finish(_ result: Result<AtlasRunResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        callbackDeadline?.cancel(); callbackDeadline = nil
        handler?.cancel(); handler = nil
        onModel = nil; onTool = nil
        if let process, process.isRunning {
            process.terminate()
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        try? input?.close(); input = nil
        reader?.cancel(); reader = nil
        buffer.removeAll()
        startFrame = AtlasFrame(type: "start")
        if let directory = storeDirectory { try? FileManager.default.removeItem(at: directory) }
        storeDirectory = nil
        continuation.resume(with: result)
    }
}
