// Sandboxed local MCP servers for the native Atlas runtime (macOS only).
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
//
// Port of the Go helper's stdio transport (mcp_transport.go) and the launch
// half of its broker (mcp_broker.go). A server is a user-selected local
// executable, never a model-selected shell command. It starts under
// sandbox-exec with no network, no Apple Events, no Mach lookups and writes
// only inside a disposable 0700 work directory, in its own process group so
// closing the transport kills the server and every worker it spawned.
#if os(macOS)
#if canImport(AtlasRuntime)
import AtlasRuntime
#endif
import Darwin
import Foundation
import Synchronization

public enum AtlasStdioTransport {
    /// The launcher to install as `AtlasRuntimeEnvironment.stdioLauncher`.
    /// The App Store build cannot launch local servers.
    public static var launcher: AtlasStdioLauncher? {
        #if APPSTORE
        return nil
        #else
        return { config, workdir in try AtlasStdioClient(command: config.command, arguments: config.arguments, workdir: workdir) }
        #endif
    }
}

public final class AtlasStdioClient: MCPClient {
    static let maxFrameBytes = 24 * 1024 * 1024

    private struct State {
        var pid: pid_t = 0
        var input: Int32 = -1
        var output: Int32 = -1
        var lines: [Result<[UInt8], AtlasStdioError>] = []
        var waiter: CheckedContinuation<Result<[UInt8], AtlasStdioError>, Never>?
        var finished = false
        var closed = false
        var exited = false
        var workdir = ""
    }

    struct AtlasStdioError: Error { let code: String }

    let command: String
    let arguments: [String]
    let requestedWorkdir: String
    private let state = Mutex(State())
    /// Backpressure: the reader holds at most one undelivered frame.
    private let space = DispatchSemaphore(value: 1)

    public var serializesExchanges: Bool { true }
    public var expired: Bool { false }
    public var processIdentifier: pid_t { state.withLock { $0.pid } }

    public init(command: String, arguments: [String], workdir: String) throws {
        self.command = command
        self.arguments = arguments
        self.requestedWorkdir = workdir
    }

    deinit {
        let (pid, input) = state.withLock { ($0.pid, $0.input) }
        if pid > 0 { kill(-pid, SIGKILL) }
        if input >= 0 { Darwin.close(input) }
    }

    public func connect() async throws {
        guard state.withLock({ $0.pid == 0 && !$0.closed }) else { throw AtlasRuntimeError("mcp_already_connected") }
        guard command.hasPrefix("/"), arguments.count <= 32 else { throw AtlasRuntimeError("local_executable_required") }
        var info = stat()
        guard stat(command, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0 else {
            throw AtlasRuntimeError("mcp_executable_unavailable")
        }
        guard mkdir(requestedWorkdir, 0o700) == 0 else { throw AtlasRuntimeError("mcp_workdir_unavailable") }
        // Seatbelt path filters compare canonical paths (/var is a symlink).
        guard let resolved = realpath(requestedWorkdir, nil) else { throw AtlasRuntimeError("mcp_workdir_unavailable") }
        let workdir = String(cString: resolved)
        free(resolved)
        try spawn(workdir: workdir)
    }

    static func profile(workdir: String) -> String {
        func quoted(_ path: String) -> String { AtlasJSON.string(path).goText }
        let parent = (workdir as NSString).deletingLastPathComponent
        return "(version 1) (allow default) (deny network*) (deny file-write*) (deny appleevent-send) (deny mach-lookup) " +
            "(deny file-read* (subpath " + quoted(parent) + ")) " +
            "(allow file-read* file-write* (subpath " + quoted(workdir) + ")) " +
            #"(deny file-read* (regex #"^/Users/[^/]+/(\\.ssh|\\.aws|\\.azure|\\.kube|\\.gnupg)(/|$)")) "# +
            #"(deny file-read* (regex #"^/Users/[^/]+/Library/(Keychains|Cookies)(/|$)"))"#
    }

    /// The canonical work directory, once connected.
    public var workdir: String { state.withLock { $0.workdir } }

    private func spawn(workdir workdirPath: String) throws {
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { throw AtlasRuntimeError("mcp_start_failed") }
        guard pipe(&fromChild) == 0 else { Darwin.close(toChild[0]); Darwin.close(toChild[1]); throw AtlasRuntimeError("mcp_start_failed") }
        // No other process the app spawns may inherit these pipes (EOF must mean exit).
        for descriptor in toChild + fromChild { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(toChild[1], F_SETNOSIGPIPE, 1)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir(&actions, workdirPath)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new process group, and no inherited descriptors beyond stdio.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ["sandbox-exec", "-p", Self.profile(workdir: workdirPath), command] + arguments
        let environment = ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG=en_US.UTF-8", "HOME=" + workdirPath,
                           "TMPDIR=" + workdirPath, "GOTRACEBACK=none"]
        var pid: pid_t = 0
        let status = withCStrings(argv) { cArguments in
            withCStrings(environment) { cEnvironment in
                posix_spawn(&pid, "/usr/bin/sandbox-exec", &actions, &attributes, cArguments, cEnvironment)
            }
        }
        Darwin.close(toChild[0]); Darwin.close(fromChild[1])
        guard status == 0 else {
            Darwin.close(toChild[1]); Darwin.close(fromChild[0])
            throw AtlasRuntimeError("mcp_start_failed")
        }
        state.withLock { $0.pid = pid; $0.input = toChild[1]; $0.output = fromChild[0]; $0.workdir = workdirPath }
        let output = fromChild[0]
        let child = pid
        Thread.detachNewThread { [self] in readLines(output) }
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            state.withLock { $0.exited = true }
        }
    }

    private func readLines(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        var line: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            var start = 0
            for index in 0..<count where buffer[index] == 0x0A {
                line.append(contentsOf: buffer[start..<index])
                start = index + 1
                guard line.count <= Self.maxFrameBytes else { deliver(.failure(AtlasStdioError(code: "mcp_frame_limit_or_io_failure"))); return }
                deliver(.success(line))
                line.removeAll(keepingCapacity: true)
                if state.withLock({ $0.closed }) { return }
            }
            line.append(contentsOf: buffer[start..<count])
            if line.count > Self.maxFrameBytes { deliver(.failure(AtlasStdioError(code: "mcp_frame_limit_or_io_failure"))); return }
        }
        deliver(nil)
    }

    /// Hands one frame to the consumer, waiting while one is undelivered.
    private func deliver(_ item: Result<[UInt8], AtlasStdioError>?) {
        if item != nil { space.wait() }
        let resume = state.withLock { state -> (CheckedContinuation<Result<[UInt8], AtlasStdioError>, Never>, Result<[UInt8], AtlasStdioError>)? in
            let value = item ?? .failure(AtlasStdioError(code: "mcp_transport_closed_or_oversized"))
            if item == nil { state.finished = true }
            if let waiter = state.waiter {
                state.waiter = nil
                return (waiter, value)
            }
            if item != nil { state.lines.append(value) }
            return nil
        }
        if let (continuation, value) = resume { continuation.resume(returning: value) }
    }

    fileprivate func nextLine() async throws -> [UInt8] {
        let result: Result<[UInt8], AtlasStdioError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Result<[UInt8], AtlasStdioError>? in
                    if !state.lines.isEmpty { return state.lines.removeFirst() }
                    if state.finished || state.closed { return .failure(AtlasStdioError(code: "mcp_transport_closed_or_oversized")) }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            // Like the Go transport, a cancelled receive closes the server.
            self.terminate()
        }
        if Task.isCancelled { throw CancellationError() }
        switch result {
        case let .success(line):
            space.signal()
            return line
        case .failure:
            terminate()
            throw AtlasRuntimeError("mcp_transport_closed_or_oversized")
        }
    }

    public func post(_ body: [UInt8], expectsResponse: Bool, initialize: Bool) async throws -> (any MCPResponseReader)? {
        let input = state.withLock { $0.closed ? -1 : $0.input }
        guard input >= 0 else { throw AtlasRuntimeError("mcp_transport_closed_or_oversized") }
        guard body.count <= 32768 else { throw AtlasRuntimeError("mcp_request_limit") }
        let line = body + [0x0A]
        let written: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = line.withUnsafeBytes { buffer -> Bool in
                        var offset = 0
                        while offset < buffer.count {
                            let count = Darwin.write(input, buffer.baseAddress! + offset, buffer.count - offset)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { return false }
                            offset += count
                        }
                        return true
                    }
                    continuation.resume(returning: ok)
                }
            }
        } onCancel: { self.terminate() }
        try Task.checkCancellation()
        guard written else { throw AtlasRuntimeError("mcp_transport_closed_or_oversized") }
        return expectsResponse ? AtlasStdioReader(client: self) : nil
    }

    /// Kill the entire owned process group, including server workers.
    func terminate() {
        let (pid, input, waiter) = state.withLock { state -> (pid_t, Int32, CheckedContinuation<Result<[UInt8], AtlasStdioError>, Never>?) in
            guard !state.closed else { return (0, -1, nil) }
            state.closed = true
            let waiter = state.waiter
            state.waiter = nil
            let input = state.input
            state.input = -1
            return (state.pid, input, waiter)
        }
        if input >= 0 { Darwin.close(input) }
        if pid > 0 { kill(-pid, SIGKILL) }
        space.signal() // release a reader blocked on backpressure
        waiter?.resume(returning: .failure(AtlasStdioError(code: "mcp_transport_closed_or_oversized")))
    }

    public func close() async {
        terminate()
        // Wait (briefly) for the server to be reaped.
        for _ in 0..<200 where !state.withLock({ $0.exited || $0.pid == 0 }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct AtlasStdioReader: MCPResponseReader {
    let client: AtlasStdioClient
    func nextFrame() async throws -> [UInt8] { try await client.nextLine() }
}

private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return body(pointers)
}
#endif
