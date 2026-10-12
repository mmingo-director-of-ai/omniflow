// Copyright (c) 2026 Quandry Labs (MIT).
import CoreServices
import Darwin
import Foundation
import Synchronization

enum OmniFlowAgentHarness: String, CaseIterable, Sendable {
    case codex
    case claude
    case gemini
    case aider
    case openCode
    case cursor
    case copilot
    case amp

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .aider: "Aider"
        case .openCode: "OpenCode"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        case .amp: "Amp"
        }
    }

    init?(processName: String) {
        switch processName.lowercased() {
        case "codex": self = .codex
        case "claude": self = .claude
        case "gemini": self = .gemini
        case "aider": self = .aider
        case "opencode": self = .openCode
        case "cursor-agent", "cursoragent": self = .cursor
        case "copilot": self = .copilot
        case "amp": self = .amp
        default: return nil
        }
    }
}

struct OmniFlowAgentTokenUsage: Equatable, Sendable {
    var inputTokens: UInt64 = 0
    var cachedInputTokens: UInt64 = 0
    var outputTokens: UInt64 = 0
    var reasoningTokens: UInt64 = 0
    var totalTokens: UInt64 = 0

    static let zero = OmniFlowAgentTokenUsage()

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: sum(lhs.inputTokens, rhs.inputTokens),
            cachedInputTokens: sum(lhs.cachedInputTokens, rhs.cachedInputTokens),
            outputTokens: sum(lhs.outputTokens, rhs.outputTokens),
            reasoningTokens: sum(lhs.reasoningTokens, rhs.reasoningTokens),
            totalTokens: sum(lhs.totalTokens, rhs.totalTokens)
        )
    }
    static func sum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

struct OmniFlowAgentProcessSnapshot: Identifiable, Equatable, Sendable {
    let id: Int32
    let harness: OmniFlowAgentHarness
    let elapsed: TimeInterval
    let cpuPercent: Double
    let memoryPercent: Double
}

enum OmniFlowAgentSessionState: String, Equatable, Sendable {
    case running
    case waiting
    case idle
}

struct OmniFlowAgentSessionSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let harness: OmniFlowAgentHarness
    let project: String
    let workingDirectory: String
    let taskLabel: String
    let branch: String?
    let model: String
    let effort: String?
    let lastActivity: Date
    let tokenUsage: OmniFlowAgentTokenUsage
    let contextFraction: Double?
    var contextWindowTokens: UInt64? = nil
    var contextIsEstimate = false
    let state: OmniFlowAgentSessionState
}

struct OmniFlowAgentQuotaSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let harness: OmniFlowAgentHarness
    let label: String
    let usedFraction: Double
    let resetDate: Date?
}

struct OmniFlowAgentSnapshot: Equatable, Sendable {
    var sampledAt: Date
    var processes: [OmniFlowAgentProcessSnapshot]
    var sessions: [OmniFlowAgentSessionSnapshot]
    var tokenUsage: OmniFlowAgentTokenUsage
    var quotas: [OmniFlowAgentQuotaSnapshot]
    var tokenRate: Double
    var tokenRateHistory: [Double]

    static let placeholder = OmniFlowAgentSnapshot(
        sampledAt: .now,
        processes: [],
        sessions: [],
        tokenUsage: .zero,
        quotas: [],
        tokenRate: 0,
        tokenRateHistory: Array(repeating: 0, count: 24)
    )
}

actor OmniFlowAgentSampler {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private var cachedCodexLogs: [URL] = []
    private var cachedClaudeLogs: [URL] = []
    /// Known session logs and their last modification, kept current by FSEvents.
    private var knownLogs: [URL: (harness: OmniFlowAgentHarness, modified: Date)] = [:]
    private var logTails: [URL: CachedLogTail] = [:]
    private let logChanges = OmniFlowLogChangeCollector()
    private let logQueue = DispatchQueue(label: "com.mengohlabs.NotchLee.monitoring.logs", qos: .utility)
    private var logStream: FSEventStreamRef?
    private var previousCPU: [ProcessKey: (cpuTime: UInt64, sampledAt: UInt64)] = [:]
    private var previousTokenTotal: UInt64?
    private var previousSampleDate: Date?
    private var tokenRateHistory = Array(repeating: 0.0, count: 24)

    private static let knownLogLimit = 32

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    isolated deinit {
        if let logStream {
            FSEventStreamStop(logStream)
            FSEventStreamInvalidate(logStream)
            FSEventStreamRelease(logStream)
        }
    }

    private var codexRoot: URL { homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory) }
    private var claudeRoot: URL { homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory) }

    func sample(showTaskDetails: Bool) -> OmniFlowAgentSnapshot {
        let now = Date()
        guard !Task.isCancelled else { return .placeholder }
        refreshLogCandidates()

        let processes = scanProcesses()
        let runningHarnesses = Set(processes.map(\.harness))
        let reader = OmniFlowAgentSessionLogReader(fileManager: fileManager)

        var parsedSessions: [OmniFlowParsedAgentSession] = []
        parsedSessions.append(contentsOf: cachedCodexLogs.compactMap { cachedSession(at: $0, harness: .codex, reader: reader) })
        parsedSessions.append(contentsOf: cachedClaudeLogs.compactMap { cachedSession(at: $0, harness: .claude, reader: reader) })
        parsedSessions.sort { $0.session.lastActivity > $1.session.lastActivity }

        var selectedParsed: [OmniFlowParsedAgentSession] = []
        var selectedIDs = Set<String>()
        for harness in runningHarnesses.sorted(by: { $0.displayName < $1.displayName }) {
            if let representative = parsedSessions.first(where: { $0.session.harness == harness }) {
                selectedParsed.append(representative)
                selectedIDs.insert(representative.session.id)
            }
        }
        for parsed in parsedSessions where selectedParsed.count < 16 && !selectedIDs.contains(parsed.session.id) {
            selectedParsed.append(parsed)
            selectedIDs.insert(parsed.session.id)
        }

        let sessions = selectedParsed.map { parsed -> OmniFlowAgentSessionSnapshot in
            let session = parsed.session
            let age = now.timeIntervalSince(session.lastActivity)
            let state: OmniFlowAgentSessionState
            if runningHarnesses.contains(session.harness), age < 150 {
                state = .running
            } else if runningHarnesses.contains(session.harness), age < 1_200 {
                state = .waiting
            } else {
                state = .idle
            }

            return OmniFlowAgentSessionSnapshot(
                id: session.id,
                harness: session.harness,
                project: session.project,
                workingDirectory: session.workingDirectory,
                taskLabel: showTaskDetails ? session.taskLabel : "Task details hidden",
                branch: session.branch,
                model: session.model,
                effort: session.effort,
                lastActivity: session.lastActivity,
                tokenUsage: session.tokenUsage,
                contextFraction: session.contextFraction,
                contextWindowTokens: session.contextWindowTokens,
                contextIsEstimate: session.contextIsEstimate,
                state: state
            )
        }

        let tokenUsage = sessions.reduce(.zero) { $0 + $1.tokenUsage }
        let quotas = latestQuotas(from: selectedParsed)
        let tokenRate = updateTokenRate(total: tokenUsage.totalTokens, now: now)

        return OmniFlowAgentSnapshot(
            sampledAt: now,
            processes: processes,
            sessions: sessions,
            tokenUsage: tokenUsage,
            quotas: quotas,
            tokenRate: tokenRate,
            tokenRateHistory: tokenRateHistory
        )
    }

    /// Called when no surface shows monitoring: the FSEvents stream is not an
    /// always-on cost. The next sample rescans, since changes were not observed.
    func suspend() {
        stopLogStream()
        previousCPU = [:]
    }

    // MARK: Log discovery

    /// One directory walk when sampling starts (or FSEvents asks for a rescan);
    /// afterwards the candidate list follows the changed paths FSEvents reports.
    private func refreshLogCandidates() {
        if logStream == nil { startLogStream() }
        let changes = logChanges.drain()
        if changes.rescan {
            knownLogs = [:]
            for (url, modified) in recentLogs(below: codexRoot, limit: Self.knownLogLimit) { knownLogs[url] = (.codex, modified) }
            for (url, modified) in recentLogs(below: claudeRoot, limit: Self.knownLogLimit) { knownLogs[url] = (.claude, modified) }
        } else {
            let codexPrefix = codexRoot.standardizedFileURL.path + "/"
            let claudePrefix = claudeRoot.standardizedFileURL.path + "/"
            for path in changes.paths where path.hasSuffix(".jsonl") {
                let harness: OmniFlowAgentHarness
                if path.hasPrefix(codexPrefix) { harness = .codex }
                else if path.hasPrefix(claudePrefix) { harness = .claude }
                else { continue }
                let url = URL(fileURLWithPath: path)
                if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                   values.isRegularFile == true, let modified = values.contentModificationDate {
                    knownLogs[url] = (harness, modified)
                } else {
                    knownLogs[url] = nil
                }
            }
        }
        cachedCodexLogs = newestLogs(.codex, limit: 8)
        cachedClaudeLogs = newestLogs(.claude, limit: 8)
        let retained = Set(newestLogs(.codex, limit: Self.knownLogLimit) + newestLogs(.claude, limit: Self.knownLogLimit))
        knownLogs = knownLogs.filter { retained.contains($0.key) }
        let active = Set(cachedCodexLogs + cachedClaudeLogs)
        logTails = logTails.filter { active.contains($0.key) }
    }

    private func newestLogs(_ harness: OmniFlowAgentHarness, limit: Int) -> [URL] {
        knownLogs.filter { $0.value.harness == harness }
            .sorted { $0.value.modified > $1.value.modified }
            .prefix(limit)
            .map(\.key)
    }

    private func startLogStream() {
        logChanges.requestRescan()
        let paths = [codexRoot.standardizedFileURL.path, claudeRoot.standardizedFileURL.path] as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(logChanges).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let collector = Unmanaged<OmniFlowLogChangeCollector>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            let rescan = (0..<count).contains { flags[$0] & rescanFlags != 0 }
            collector.record(list, rescan: rescan)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        // 2 s latency coalesces the constant appends of a running agent.
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, logQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        logStream = stream
    }

    private func stopLogStream() {
        guard let logStream else { return }
        FSEventStreamStop(logStream)
        FSEventStreamInvalidate(logStream)
        FSEventStreamRelease(logStream)
        self.logStream = nil
    }

    private func cachedSession(
        at url: URL,
        harness: OmniFlowAgentHarness,
        reader: OmniFlowAgentSessionLogReader
    ) -> OmniFlowParsedAgentSession? {
        var cached = logTails[url] ?? CachedLogTail(tail: OmniFlowAgentLogTail(harness: harness), session: nil)
        // Unchanged files are not opened; changed ones are read from the last offset.
        guard reader.needsRead(cached.tail, url: url) || cached.session == nil else { return cached.session }
        cached.session = reader.update(&cached.tail, url: url)
        logTails[url] = cached
        return cached.session
    }

    private func recentLogs(below directory: URL, limit: Int) -> [(URL, Date)] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var candidates: [(url: URL, modified: Date)] = []
        var inspected = 0
        for case let url as URL in enumerator {
            inspected += 1
            if inspected > 20_000 || Task.isCancelled { break }
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            candidates.append((url.standardizedFileURL, modified))
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { ($0.url, $0.modified) }
    }

    // MARK: Processes

    private struct ProcessKey: Hashable {
        let pid: Int32
        let start: UInt64
    }

    /// Reads the process table through libproc instead of launching `/bin/ps`.
    /// Only processes whose name matches a harness get a task-info read.
    ///
    /// CPU% semantics differ from `ps`: `ps %cpu` is a decaying average over
    /// roughly the last minute, while this is the share of CPU time used since
    /// the previous sample (the first sample of a process reads 0). Like `ps`,
    /// it can exceed 100% for multithreaded processes.
    private func scanProcesses() -> [OmniFlowAgentProcessSnapshot] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }

        let now = mach_absolute_time()
        let wallNow = Date().timeIntervalSince1970
        let physicalMemory = Double(ProcessInfo.processInfo.physicalMemory)
        var name = [CChar](repeating: 0, count: 256)
        var seen: [ProcessKey: (cpuTime: UInt64, sampledAt: UInt64)] = [:]
        var result: [OmniFlowAgentProcessSnapshot] = []

        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0,
                  let harness = OmniFlowAgentHarness(processName: String(cString: name)) else { continue }
            var task = proc_taskinfo()
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
                    == Int32(MemoryLayout<proc_taskinfo>.size),
                  proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
                    == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }

            let key = ProcessKey(pid: pid, start: bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec)
            let cpuTime = task.pti_total_user &+ task.pti_total_system
            var cpuPercent = 0.0
            if let previous = previousCPU[key], cpuTime >= previous.cpuTime, now > previous.sampledAt {
                // pti_total_* and mach_absolute_time share one unit (mach ticks on Apple
                // silicon, nanoseconds on Intel), so the timebase cancels in the ratio.
                cpuPercent = Double(cpuTime - previous.cpuTime) / Double(now - previous.sampledAt) * 100
            }
            seen[key] = (cpuTime, now)
            let started = Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000
            result.append(OmniFlowAgentProcessSnapshot(
                id: pid,
                harness: harness,
                elapsed: max(0, wallNow - started),
                cpuPercent: max(0, cpuPercent),
                memoryPercent: physicalMemory > 0 ? Double(task.pti_resident_size) / physicalMemory * 100 : 0
            ))
        }
        previousCPU = seen

        return result.sorted { lhs, rhs in
            if lhs.harness.displayName == rhs.harness.displayName {
                return lhs.elapsed > rhs.elapsed
            }
            return lhs.harness.displayName < rhs.harness.displayName
        }
    }

    private func latestQuotas(from sessions: [OmniFlowParsedAgentSession]) -> [OmniFlowAgentQuotaSnapshot] {
        var quotasByID: [String: (date: Date, quota: OmniFlowAgentQuotaSnapshot)] = [:]
        for parsed in sessions {
            for quota in parsed.quotas {
                let existing = quotasByID[quota.id]
                if existing == nil || parsed.session.lastActivity > existing!.date {
                    quotasByID[quota.id] = (parsed.session.lastActivity, quota)
                }
            }
        }
        return quotasByID.values
            .map(\.quota)
            .sorted { $0.label < $1.label }
    }

    private func updateTokenRate(total: UInt64, now: Date) -> Double {
        var rate = 0.0
        if let previousTokenTotal, let previousSampleDate, total >= previousTokenTotal {
            let elapsed = max(0.1, now.timeIntervalSince(previousSampleDate))
            rate = min(Double(total - previousTokenTotal) / elapsed, 5_000_000)
        }

        previousTokenTotal = total
        previousSampleDate = now
        tokenRateHistory.append(rate)
        if tokenRateHistory.count > 30 {
            tokenRateHistory.removeFirst(tokenRateHistory.count - 30)
        }
        return rate
    }

    private struct CachedLogTail: Sendable {
        var tail: OmniFlowAgentLogTail
        var session: OmniFlowParsedAgentSession?
    }
}

/// Collects changed paths from the FSEvents queue for the sampler actor.
final class OmniFlowLogChangeCollector: Sendable {
    private struct Pending: Sendable {
        var paths = Set<String>()
        var rescan = true
    }
    private let pending = Mutex(Pending())

    func record(_ paths: [String], rescan: Bool) {
        pending.withLock { state in
            state.paths.formUnion(paths)
            if rescan { state.rescan = true }
        }
    }

    func requestRescan() { pending.withLock { $0.rescan = true } }

    func drain() -> (paths: Set<String>, rescan: Bool) {
        pending.withLock { state in
            defer { state = Pending(); state.rescan = false }
            return (state.paths, state.rescan)
        }
    }
}

struct OmniFlowParsedAgentSession: Sendable {
    let session: OmniFlowAgentSessionSnapshot
    let quotas: [OmniFlowAgentQuotaSnapshot]
}

/// Per-file incremental reader state. Lines are folded into a small per-harness
/// summary, so a growing log is read from its last byte offset instead of
/// re-parsing its 640 KB tail each time it changes.
///
/// Totals semantics: the first read folds the last 640 KB (as before); later
/// reads add only appended lines. Claude token totals therefore cover
/// "since the log was first seen in this run" rather than "the last 640 KB",
/// and restart from the tail window when the app relaunches or the file is
/// rotated or truncated.
struct OmniFlowAgentLogTail: Sendable {
    let harness: OmniFlowAgentHarness
    fileprivate(set) var offset: UInt64 = 0
    fileprivate var fileID: UInt64?
    fileprivate var modified: Date?
    fileprivate var codex = CodexFold()
    fileprivate var claude = ClaudeFold()

    init(harness: OmniFlowAgentHarness) { self.harness = harness }

    fileprivate struct CodexFold: Sendable {
        var hasMeta = false
        var metaID: String?
        var metaCwd: String?
        var taskLabel = "Interactive task"
        var hasTurn = false
        var turnCwd: String?
        var model: String?
        var effort: String?
        var usage = OmniFlowAgentTokenUsage.zero
        var contextFraction: Double?
        var contextWindow: Double?
        var quotas: [OmniFlowAgentQuotaSnapshot] = []
    }

    fileprivate struct ClaudeEntry: Sendable {
        var cwd: String?
        var sessionID: String?
        var model: String?
        var branch: String?
        var context: Double?
    }

    fileprivate struct ClaudeFold: Sendable {
        var usage = OmniFlowAgentTokenUsage.zero
        var latestAssistant: ClaudeEntry?
        var latestWithSession: ClaudeEntry?
    }
}

struct OmniFlowAgentSessionLogReader {
    private static let tailByteLimit = 640_000
    private static let headerByteLimit = 96_000

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func readCodexSession(_ url: URL) -> OmniFlowParsedAgentSession? {
        var tail = OmniFlowAgentLogTail(harness: .codex)
        return update(&tail, url: url)
    }

    func readClaudeSession(_ url: URL) -> OmniFlowParsedAgentSession? {
        var tail = OmniFlowAgentLogTail(harness: .claude)
        return update(&tail, url: url)
    }

    /// True when the file changed since `tail` last read it.
    func needsRead(_ tail: OmniFlowAgentLogTail, url: URL) -> Bool {
        guard let info = fileInfo(url) else { return true }
        return info.id != tail.fileID || info.size != tail.offset || info.modified != tail.modified
    }

    /// Folds lines appended since the last call and returns the current session.
    func update(_ tail: inout OmniFlowAgentLogTail, url: URL) -> OmniFlowParsedAgentSession? {
        guard let info = fileInfo(url) else { return nil }
        if tail.fileID != info.id || info.size < tail.offset {
            // New, replaced or truncated file: start over from the tail window.
            tail = OmniFlowAgentLogTail(harness: tail.harness)
        }
        if tail.fileID == nil {
            tail.fileID = info.id
            if tail.harness == .codex {
                // Session metadata is written first and may precede the tail window.
                let header = data(from: url, start: 0, limit: Self.headerByteLimit)
                for object in jsonObjects(in: header, includeUnterminated: true).objects { fold(object, into: &tail) }
            }
            let start = info.size - min(info.size, UInt64(Self.tailByteLimit))
            consume(url: url, start: start, alignToLine: start > 0, size: info.size, tail: &tail)
        } else if info.size > tail.offset {
            // A burst larger than the window is skipped to its last 640 KB.
            let start = max(tail.offset, info.size - min(info.size, UInt64(Self.tailByteLimit)))
            consume(url: url, start: start, alignToLine: start > tail.offset, size: info.size, tail: &tail)
        }
        tail.modified = info.modified
        return session(from: tail, url: url, modified: info.modified)
    }

    private func consume(url: URL, start: UInt64, alignToLine: Bool, size: UInt64,
                         tail: inout OmniFlowAgentLogTail) {
        var chunk = data(from: url, start: start, limit: Int(size - start))
        var consumedStart = start
        if alignToLine {
            // No line boundary in the window: skip it (unparseable fragments are ignored anyway).
            guard let newline = chunk.firstIndex(of: 0x0A) else { tail.offset = size; return }
            consumedStart += UInt64(chunk.distance(from: chunk.startIndex, to: newline) + 1)
            chunk = chunk[chunk.index(after: newline)...]
        }
        let parsed = jsonObjects(in: chunk, includeUnterminated: true)
        for object in parsed.objects { fold(object, into: &tail) }
        tail.offset = consumedStart + UInt64(parsed.consumed)
    }

    private func fold(_ object: [String: Any], into tail: inout OmniFlowAgentLogTail) {
        switch tail.harness {
        case .codex: foldCodex(object, into: &tail.codex)
        case .claude: foldClaude(object, into: &tail.claude)
        default: break
        }
    }

    private func foldCodex(_ object: [String: Any], into fold: inout OmniFlowAgentLogTail.CodexFold) {
        let type = string(object["type"])
        let payload = dictionary(object["payload"])
        if type == "session_meta", !fold.hasMeta, let meta = payload {
            fold.hasMeta = true
            fold.metaID = string(meta["id"])
            fold.metaCwd = string(meta["cwd"])
            let source = dictionary(meta["source"])
            let subagent = dictionary(source?["subagent"])
            let spawn = dictionary(subagent?["thread_spawn"])
            if let agentPath = string(spawn?["agent_path"]) {
                let nickname = string(spawn?["agent_nickname"])
                let component = agentPath.split(separator: "/").last.map(String.init) ?? agentPath
                fold.taskLabel = nickname.map { "\($0) · \(component.replacingOccurrences(of: "_", with: " "))" }
                    ?? component.replacingOccurrences(of: "_", with: " ")
            }
        } else if type == "turn_context" {
            fold.hasTurn = payload != nil
            fold.turnCwd = string(payload?["cwd"])
            fold.model = string(payload?["model"])
            fold.effort = string(payload?["effort"])
        } else if type == "event_msg", string(payload?["type"]) == "token_count" {
            let info = dictionary(payload?["info"])
            let totalUsage = dictionary(info?["total_token_usage"])
            let lastUsage = dictionary(info?["last_token_usage"])
            let contextWindow = double(info?["model_context_window"])
            let contextInput = double(lastUsage?["input_tokens"])
            fold.contextWindow = contextWindow
            fold.contextFraction = contextWindow.flatMap { window in
                contextInput.map { min(1, max(0, $0 / max(1, window))) }
            }
            fold.usage = OmniFlowAgentTokenUsage(
                inputTokens: uint(totalUsage?["input_tokens"]),
                cachedInputTokens: uint(totalUsage?["cached_input_tokens"]),
                outputTokens: uint(totalUsage?["output_tokens"]),
                reasoningTokens: uint(totalUsage?["reasoning_output_tokens"]),
                totalTokens: uint(totalUsage?["total_tokens"])
            )
            let rateLimits = dictionary(payload?["rate_limits"])
            fold.quotas = ["primary", "secondary"].compactMap { key -> OmniFlowAgentQuotaSnapshot? in
                guard let window = dictionary(rateLimits?[key]),
                      let usedPercent = double(window["used_percent"])
                else { return nil }
                let windowMinutes = double(window["window_minutes"]) ?? 0
                let label: String
                if windowMinutes >= 10_000 {
                    label = "Weekly quota"
                } else if windowMinutes >= 240 {
                    label = "5-hour quota"
                } else if windowMinutes > 0 {
                    label = "\(Int(windowMinutes))-minute quota"
                } else {
                    label = "Usage quota"
                }
                let resetDate = double(window["resets_at"]).map(Date.init(timeIntervalSince1970:))
                return OmniFlowAgentQuotaSnapshot(
                    id: "codex-\(key)",
                    harness: .codex,
                    label: label,
                    usedFraction: min(1, max(0, usedPercent / 100)),
                    resetDate: resetDate
                )
            }
        }
    }

    private func foldClaude(_ object: [String: Any], into fold: inout OmniFlowAgentLogTail.ClaudeFold) {
        let isAssistant = string(object["type"]) == "assistant"
        guard isAssistant || string(object["sessionId"]) != nil else { return }
        let message = dictionary(object["message"])
        let rawUsage = dictionary(message?["usage"])
        let entry = OmniFlowAgentLogTail.ClaudeEntry(
            cwd: string(object["cwd"]),
            sessionID: string(object["sessionId"]),
            model: string(message?["model"]),
            branch: string(object["gitBranch"]).flatMap { $0 == "HEAD" ? nil : $0 },
            context: double(rawUsage?["input_tokens"])
                .map { $0 + (double(rawUsage?["cache_creation_input_tokens"]) ?? 0) + (double(rawUsage?["cache_read_input_tokens"]) ?? 0) }
        )
        if string(object["sessionId"]) != nil { fold.latestWithSession = entry }
        guard isAssistant else { return }
        fold.latestAssistant = entry
        let input = uint(rawUsage?["input_tokens"])
        let cacheCreation = uint(rawUsage?["cache_creation_input_tokens"])
        let cacheRead = uint(rawUsage?["cache_read_input_tokens"])
        let output = uint(rawUsage?["output_tokens"])
        fold.usage = fold.usage + OmniFlowAgentTokenUsage(
            inputTokens: input,
            cachedInputTokens: OmniFlowAgentTokenUsage.sum(cacheCreation, cacheRead),
            outputTokens: output,
            reasoningTokens: 0,
            totalTokens: [input, cacheCreation, cacheRead, output].reduce(0, OmniFlowAgentTokenUsage.sum)
        )
    }

    private func session(from tail: OmniFlowAgentLogTail, url: URL, modified: Date) -> OmniFlowParsedAgentSession? {
        switch tail.harness {
        case .codex: return codexSession(tail.codex, url: url, modified: modified)
        case .claude: return claudeSession(tail.claude, url: url, modified: modified)
        default: return nil
        }
    }

    private func codexSession(_ fold: OmniFlowAgentLogTail.CodexFold, url: URL, modified: Date) -> OmniFlowParsedAgentSession? {
        guard fold.hasMeta || fold.hasTurn else { return nil }
        let cwd = fold.turnCwd ?? fold.metaCwd ?? url.deletingLastPathComponent().path
        let project = URL(fileURLWithPath: cwd).lastPathComponent.nonempty ?? "Workspace"
        return OmniFlowParsedAgentSession(
            session: OmniFlowAgentSessionSnapshot(
                id: fold.metaID ?? url.deletingPathExtension().lastPathComponent,
                harness: .codex,
                project: project,
                workingDirectory: cwd,
                taskLabel: fold.taskLabel,
                branch: nil,
                model: fold.model ?? "Codex",
                effort: fold.effort,
                lastActivity: modified,
                tokenUsage: fold.usage,
                contextFraction: fold.contextFraction,
                contextWindowTokens: fold.contextWindow.flatMap { UInt64(exactly: $0) },
                state: .idle
            ),
            quotas: fold.quotas
        )
    }

    private func claudeSession(_ fold: OmniFlowAgentLogTail.ClaudeFold, url: URL, modified: Date) -> OmniFlowParsedAgentSession? {
        guard let latest = fold.latestAssistant ?? fold.latestWithSession else { return nil }
        let cwd = latest.cwd ?? url.deletingLastPathComponent().path
        let project = URL(fileURLWithPath: cwd).lastPathComponent.nonempty ?? "Workspace"
        return OmniFlowParsedAgentSession(
            session: OmniFlowAgentSessionSnapshot(
                id: latest.sessionID ?? url.deletingPathExtension().lastPathComponent,
                harness: .claude,
                project: project,
                workingDirectory: cwd,
                taskLabel: latest.branch.map { "Branch · \($0)" } ?? "Interactive task",
                branch: latest.branch,
                model: latest.model ?? "Claude",
                effort: nil,
                lastActivity: modified,
                tokenUsage: fold.usage,
                contextFraction: latest.context.map { min(1, max(0, $0 / 200_000)) },
                contextWindowTokens: 200_000,
                contextIsEstimate: true,
                state: .idle
            ),
            quotas: []
        )
    }

    private struct FileInfo {
        let id: UInt64
        let size: UInt64
        let modified: Date
    }

    private func fileInfo(_ url: URL) -> FileInfo? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileInfo(id: UInt64(info.st_ino), size: UInt64(max(0, info.st_size)), modified: modified)
    }

    private func data(from url: URL, start: UInt64, limit: Int) -> Data {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: limit) ?? Data()
        } catch {
            return Data()
        }
    }

    /// Complete lines, plus a final unterminated line only when it is already
    /// valid JSON. `consumed` is the byte count those lines cover, so a line
    /// still being written is re-read next time instead of being lost.
    private func jsonObjects(in data: Data, includeUnterminated: Bool) -> (objects: [[String: Any]], consumed: Int) {
        var objects: [[String: Any]] = []
        var consumed = 0
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            guard let newline = data[lineStart...].firstIndex(of: 0x0A) else {
                if includeUnterminated,
                   let object = try? JSONSerialization.jsonObject(with: Data(data[lineStart...])) as? [String: Any] {
                    objects.append(object)
                    consumed = data.distance(from: data.startIndex, to: data.endIndex)
                }
                break
            }
            if newline > lineStart,
               let object = try? JSONSerialization.jsonObject(with: Data(data[lineStart..<newline])) as? [String: Any] {
                objects.append(object)
            }
            lineStart = data.index(after: newline)
            consumed = data.distance(from: data.startIndex, to: lineStart)
        }
        return (objects, consumed)
    }

    private func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private func string(_ value: Any?) -> String? {
        (value as? String)?.nonempty
    }

    private func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func uint(_ value: Any?) -> UInt64 {
        guard let value = double(value), value.isFinite, value > 0 else { return 0 }
        return UInt64(exactly: value.rounded()) ?? .max
    }
}

private extension String {
    var nonempty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
