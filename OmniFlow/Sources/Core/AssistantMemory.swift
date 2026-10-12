import Foundation
import Combine
import FoundationModels

struct SavedAssistantNote: Codable, Identifiable, Sendable {
    var id = UUID()
    var scope: String // Empty is personal; other values are explicit project names.
    var text: String
    var updatedAt = Date()
    var sourceTask: UUID?
    var sourceNote: String?
}

struct SavedAssistantTask: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, interrupted, complete }
    var id = UUID()
    let question: String
    let scope: String
    var updatedAt = Date()
    var status: Status = .running
    var answer = ""
    var findings: [AtlasMemoryRecord] = []
    var progress: AtlasAnalysisProgress?
}

struct AssistantMemoryDocument: Codable, Sendable {
    var version = 1
    var revision = 0
    var notes: [SavedAssistantNote] = []
    var tasks: [SavedAssistantTask] = []
}

struct SavedMemoryHit: Codable, Identifiable, Sendable {
    let id: String
    let scope: String
    let text: String
    let updatedAt: Date
    let derived: Bool
    var sourceTask: UUID?
    var sourceNote: String?
}

struct AssistantMemoryLease: Sendable {
    let task: SavedAssistantTask
    let directory: URL
    let resuming: Bool
}

enum AssistantMemoryError: LocalizedError {
    case damaged, limit, busy, missing, invalidNote, noCheckpoint
    var errorDescription: String? {
        switch self {
        case .damaged: "Saved memory could not be read. Its files have been left intact."
        case .limit: "Memory storage is full. Forget some saved tasks or notes to make room."
        case .busy: "This task is still running. Stop it before resuming or forgetting it."
        case .missing: "This saved memory is no longer available in the selected project."
        case .invalidNote: "Use a project name under 120 bytes and a note between 1 and 2,000 bytes."
        case .noCheckpoint: "This task has no saved source-analysis checkpoint to continue."
        }
    }
}

/// All mutations are serialized here. A corrupt file never becomes an empty
/// writable database. The UI and model use separate, bounded projections.
actor AssistantMemoryFile {
    let root: URL
    private var document: AssistantMemoryDocument?
    private var active: Set<UUID> = []
    private var file: URL { root.appendingPathComponent("memory.json") }
    private var tasksRoot: URL { root.appendingPathComponent("tasks", isDirectory: true) }
    init(root: URL) { self.root = root }

    func directory(_ id: UUID) -> URL { tasksRoot.appendingPathComponent(id.uuidString, isDirectory: true) }

    func load() throws -> AssistantMemoryDocument {
        if let document { return document }
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            let empty = AssistantMemoryDocument(); document = empty; return empty
        }
        // A sealed file that can't be opened (missing key) is damaged, never replaced with empty memory.
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_000_100,
              let stored = try? OmniFlowVault.read(file),
              var value = try? JSONDecoder().decode(AssistantMemoryDocument.self, from: stored.plaintext),
              value.version == 1, value.notes.count <= 1000, value.tasks.count <= 20,
              Set(value.notes.map(\.id)).count == value.notes.count, Set(value.tasks.map(\.id)).count == value.tasks.count,
              value.notes.allSatisfy({ !$0.text.isEmpty && $0.text.utf8.count <= 2000 && $0.scope.utf8.count <= 120 }),
              value.tasks.allSatisfy({ $0.question.utf8.count <= 8000 && $0.scope.utf8.count <= 120 }) else {
            throw AssistantMemoryError.damaged
        }
        for i in value.tasks.indices where value.tasks[i].status == .running { value.tasks[i].status = .interrupted }
        // Recover the latest committed progress, including cancellation or a
        // crash between the Go checkpoint and the next Swift model callback.
        for i in value.tasks.indices { recoverProgress(&value.tasks[i]) }
        // Migration: memory saved before encryption is rewritten sealed, unchanged.
        if stored.wasPlaintext { try? OmniFlowVault.write(stored.plaintext, to: file) }
        document = value
        return try prune(value, reserving: 0)
    }

    private func save(_ value: AssistantMemoryDocument) throws -> AssistantMemoryDocument {
        var value = value
        value.revision += 1
        let data = try JSONEncoder().encode(value)
        guard data.count <= 4_000_000 else { throw AssistantMemoryError.limit }
        try NotchLeeStorage.prepare(root)
        try OmniFlowVault.write(data, to: file)
        document = value
        return value
    }

    func put(_ note: SavedAssistantNote) throws -> AssistantMemoryDocument {
        guard !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              note.text.utf8.count <= 2000, note.scope.utf8.count <= 120 else { throw AssistantMemoryError.invalidNote }
        var value = try load()
        var note = note; note.updatedAt = .now
        if let i = value.notes.firstIndex(where: { $0.id == note.id }) { value.notes[i] = note }
        else {
            guard value.notes.count < 1000 else { throw AssistantMemoryError.limit }
            value.notes.append(note)
        }
        return try save(value)
    }

    func forgetNote(_ id: UUID) throws -> AssistantMemoryDocument {
        var value = try load(); value.notes.removeAll { $0.id == id }; return try save(value)
    }

    func forgetTask(_ id: UUID) throws -> AssistantMemoryDocument {
        guard !active.contains(id) else { throw AssistantMemoryError.busy }
        var value = try load()
        let folder = directory(id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        value.tasks.removeAll { $0.id == id }
        // Selected notes are independent copies and remain user-controlled.
        return try save(value)
    }

    func clear() throws -> AssistantMemoryDocument {
        guard active.isEmpty else { throw AssistantMemoryError.busy }
        var value = try load()
        if FileManager.default.fileExists(atPath: tasksRoot.path) { try FileManager.default.removeItem(at: tasksRoot) }
        value.notes = []; value.tasks = []
        return try save(value)
    }

    func begin(question: String, scope: String, resume: UUID?) throws -> (AssistantMemoryLease, AssistantMemoryDocument) {
        guard question.utf8.count <= 8000, scope.utf8.count <= 120 else { throw AssistantMemoryError.invalidNote }
        var value = try load()
        let task: SavedAssistantTask
        if let resume {
            guard !active.contains(resume) else { throw AssistantMemoryError.busy }
            guard var saved = value.tasks.first(where: { $0.id == resume && $0.scope == scope && $0.question == question }) else { throw AssistantMemoryError.missing }
            recoverProgress(&saved)
            guard saved.progress != nil else { throw AssistantMemoryError.noCheckpoint }
            saved.status = .running; saved.updatedAt = .now
            value.tasks[value.tasks.firstIndex(where: { $0.id == resume })!] = saved
            task = saved
        } else {
            value = try prune(value, reserving: 84 * 1024 * 1024)
            guard value.tasks.count < 20 else { throw AssistantMemoryError.limit }
            task = SavedAssistantTask(question: question, scope: scope)
            value.tasks.append(task)
            try NotchLeeStorage.prepare(directory(task.id))
        }
        value = try save(value)
        active.insert(task.id)
        return (AssistantMemoryLease(task: task, directory: directory(task.id), resuming: resume != nil), value)
    }

    func progress(_ id: UUID, view: AtlasMemoryView) throws -> AssistantMemoryDocument {
        var value = try load()
        guard active.contains(id), let i = value.tasks.firstIndex(where: { $0.id == id }) else { throw AssistantMemoryError.missing }
        value.tasks[i].findings = view.records
        value.tasks[i].progress = view.active
        value.tasks[i].updatedAt = .now
        return try save(value)
    }

    func finish(_ id: UUID, answer: String?) throws -> AssistantMemoryDocument {
        active.remove(id)
        var value = try load()
        guard let i = value.tasks.firstIndex(where: { $0.id == id }) else { throw AssistantMemoryError.missing }
        value.tasks[i].status = answer == nil ? .interrupted : .complete
        value.tasks[i].updatedAt = .now
        if let answer { value.tasks[i].answer = memoryTextPrefix(answer, bytes: 8000) }
        recoverProgress(&value.tasks[i])
        if value.tasks[i].progress?.complete == false { value.tasks[i].status = .interrupted }
        return try prune(save(value), reserving: 0)
    }

    private func recoverProgress(_ task: inout SavedAssistantTask) {
        let journal = directory(task.id).appendingPathComponent("task-memory.jsonl")
        guard let size = try? journal.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16*1024*1024,
              let data = try? Data(contentsOf: journal), let end = data.lastIndex(of: 10) else { return }
        struct Event: Decodable { var job: AtlasAnalysisProgress?; var record: AtlasMemoryRecord? }
        var records: [AtlasMemoryRecord] = []
        for line in data[...end].split(separator: 10) {
            guard let event = try? JSONDecoder().decode(Event.self, from: Data(line)) else { continue }
            if let job = event.job { task.progress = job }
            if let record = event.record { records.append(record); if records.count > 6 { records.removeFirst() } }
        }
        if !records.isEmpty { task.findings = records }
    }

    private func size(of folder: URL) -> Int {
        guard let paths = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total = 0
        for case let file as URL in paths {
            if let value = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), value.isRegularFile == true { total += value.fileSize ?? 0 }
        }
        return total
    }

    private func prune(_ original: AssistantMemoryDocument, reserving: Int) throws -> AssistantMemoryDocument {
        var value = original
        var bytes = size(of: tasksRoot)
        for task in value.tasks.sorted(by: { $0.updatedAt < $1.updatedAt }) where !active.contains(task.id) {
            guard Date().timeIntervalSince(task.updatedAt) > 30*86400 || bytes+reserving > 512*1024*1024 ||
                    (reserving > 0 && value.tasks.count >= 20) else { continue }
            let folder = directory(task.id); let removed = size(of: folder)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            value.tasks.removeAll { $0.id == task.id }; bytes -= removed
        }
        guard bytes+reserving <= 512*1024*1024 else { throw AssistantMemoryError.limit }
        return value.tasks.count != original.tasks.count ? try save(value) : value
    }

    func recall(query: String, scope: String, excluding: UUID? = nil) throws -> [SavedMemoryHit] {
        let value = try load()
        let terms = Self.terms(query)
        var ranked: [(Int, SavedMemoryHit)] = []
        for note in value.notes where note.scope.isEmpty || note.scope == scope {
            let matches = terms.intersection(Self.terms(note.text)).count
            ranked.append((matches*20 + (note.scope == scope ? 4 : 0) + 2,
                SavedMemoryHit(id: "note/"+note.id.uuidString, scope: note.scope, text: note.text,
                    updatedAt: note.updatedAt, derived: note.sourceTask != nil, sourceTask: note.sourceTask, sourceNote: note.sourceNote)))
        }
        for task in value.tasks where task.id != excluding && task.scope == scope && task.status != .running {
            let coverage = task.progress.map { "Source analysis: \($0.processedBytes)/\($0.totalBytes) bytes; \($0.complete ? "complete" : "incomplete")." } ?? "No whole-source analysis checkpoint."
            let text = "Saved task status: \(task.status.rawValue). \(coverage)\nRequest: \(task.question)\n\(task.answer.isEmpty ? task.findings.map(\.text).joined(separator: "\n") : task.answer)"
            let matches = terms.intersection(Self.terms(text)).count
            guard matches > 0 || terms.isEmpty else { continue }
            ranked.append((matches*20, SavedMemoryHit(id: "task/"+task.id.uuidString, scope: task.scope,
                text: text, updatedAt: task.updatedAt, derived: true, sourceTask: task.id)))
        }
        return ranked.sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            if $0.1.updatedAt != $1.1.updatedAt { return $0.1.updatedAt > $1.1.updatedAt }
            return $0.1.id < $1.1.id
        }.map(\.1)
    }

    private static func terms(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "that", "this", "with", "from", "what", "when", "where", "have", "does", "are", "was", "were", "you", "your", "please", "about", "can", "could", "would", "should", "use", "tell", "me", "is", "to", "of", "in", "it", "my", "we", "our"]
        return Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 && !stop.contains($0) })
    }
}

@MainActor
final class AssistantMemory: ObservableObject {
    static let shared = AssistantMemory()
    @Published var enabled: Bool { didSet { defaults?.set(enabled, forKey: "assistantMemoryEnabled") } }
    @Published var project: String { didSet { defaults?.set(project, forKey: "assistantMemoryProject") } }
    @Published private(set) var document = AssistantMemoryDocument()
    @Published private(set) var error: String?
    @Published private(set) var busyTasks: Set<UUID> = []
    let file: AssistantMemoryFile
    private let defaults: UserDefaults?

    init(root: URL = NotchLeeStorage.root.appendingPathComponent("Memory", isDirectory: true), defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        enabled = defaults?.object(forKey: "assistantMemoryEnabled") as? Bool
            ?? defaults?.object(forKey: "keepLocalTranscripts") as? Bool ?? true
        project = defaults?.string(forKey: "assistantMemoryProject") ?? ""
        file = AssistantMemoryFile(root: root)
    }

    private func apply(_ value: AssistantMemoryDocument) { if value.revision >= document.revision { document = value }; error = nil }
    func load() async { do { apply(try await file.load()) } catch { self.error = error.localizedDescription } }
    func put(_ note: SavedAssistantNote) async { do { apply(try await file.put(note)) } catch { self.error = error.localizedDescription } }
    func forgetNote(_ id: UUID) async { do { apply(try await file.forgetNote(id)) } catch { self.error = error.localizedDescription } }
    func forgetTask(_ id: UUID) async { do { apply(try await file.forgetTask(id)) } catch { self.error = error.localizedDescription } }
    func clear() async { do { apply(try await file.clear()) } catch { self.error = error.localizedDescription } }

    func begin(question: String, resume: UUID?) async throws -> AssistantMemoryLease? {
        guard enabled else { if resume != nil { throw AssistantMemoryError.missing }; return nil }
        do {
            let (lease, state) = try await file.begin(question: question, scope: project.trimmingCharacters(in: .whitespacesAndNewlines), resume: resume)
            busyTasks.insert(lease.task.id); apply(state); return lease
        } catch { self.error = error.localizedDescription; throw error }
    }
    func update(_ id: UUID, view: AtlasMemoryView?) async {
        guard let view else { return }
        do { apply(try await file.progress(id, view: view)) } catch { self.error = error.localizedDescription }
    }
    func finish(_ id: UUID, answer: String?) async {
        busyTasks.remove(id)
        do { apply(try await file.finish(id, answer: answer)) } catch { self.error = error.localizedDescription }
    }
    func recalled(query: String, scope: String, excluding: UUID?, budget: Int = 3200) async throws -> [SavedMemoryHit] {
        guard enabled else { return [] }
        let hits = try await file.recall(query: query, scope: scope, excluding: excluding)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var result: [SavedMemoryHit] = []
        var bytes = 0
        for hit in hits.prefix(6) {
            let text = memoryTextPrefix(hit.text, bytes: 1000)
            let preview = SavedMemoryHit(id: hit.id, scope: hit.scope, text: text, updatedAt: hit.updatedAt, derived: hit.derived,
                sourceTask: hit.sourceTask, sourceNote: hit.sourceNote)
            let size = try encoder.encode(preview).count
            guard bytes+size <= budget else { continue }
            result.append(preview); bytes += size
        }
        return result
    }

    func retrieve(_ arguments: RecallSavedMemoryArguments, scope: String, excluding: UUID?) async throws -> String {
        guard enabled else { throw AssistantMemoryError.missing }
        let hits = try await file.recall(query: arguments.operation == .read ? "" : arguments.query ?? "", scope: scope, excluding: excluding)
        let selected: [SavedMemoryHit]
        let next: Int
        let total: Int
        if arguments.operation == .read {
            guard let found = hits.first(where: { $0.id == arguments.id }) else { throw AssistantMemoryError.missing }
            let data = Data(found.text.utf8)
            let offset = arguments.offset ?? 0
            guard offset >= 0, offset <= data.count, offset == data.count || data[offset] & 0xc0 != 0x80 else { throw AssistantMemoryError.missing }
            let chunk = memoryTextPrefix(String(decoding: data.dropFirst(offset), as: UTF8.self), bytes: 4000)
            selected = [SavedMemoryHit(id: found.id, scope: found.scope, text: chunk, updatedAt: found.updatedAt,
                derived: found.derived, sourceTask: found.sourceTask, sourceNote: found.sourceNote)]
            next = offset+chunk.utf8.count; total = data.count
        } else {
            let offset = arguments.offset ?? 0
            guard offset >= 0, offset <= hits.count else { throw AssistantMemoryError.missing }
            next = min(hits.count, offset+3)
            selected = hits[offset..<next].map { hit in
                SavedMemoryHit(id: hit.id, scope: hit.scope, text: memoryTextPrefix(hit.text, bytes: 1000), updatedAt: hit.updatedAt,
                    derived: hit.derived, sourceTask: hit.sourceTask, sourceNote: hit.sourceNote)
            }
            total = hits.count
        }
        struct Reply: Encodable {
            let trust = "untrusted_saved_data"
            let coverage = "Saved notes and past task summaries, not fresh observations. Task summaries may be incomplete. Open the saved task in Memory to inspect original evidence. Search returns previews. Read follows byte offsets until hasMore=false to recover a full saved entry."
            let records: [SavedMemoryHit]; let nextOffset: Int; let total: Int; let hasMore: Bool
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Reply(records: selected, nextOffset: next, total: total, hasMore: next < total))
        guard data.count <= 24000 else { throw AssistantMemoryError.limit }
        return String(decoding: data, as: UTF8.self)
    }
}

@Generable
struct RecallSavedMemoryArguments {
    @Generable enum Operation { case search, read }
    var operation: Operation
    @Guide(description: "search: words related to past work; empty lists recent entries. read: nil.")
    var query: String?
    @Guide(description: "read: exact returned saved id (note/UUID or task/UUID). search: nil. These are not current pN or mN handles.")
    var id: String?
    @Guide(description: "search: returned entry offset. read: returned byte offset within the saved text. Default 0; follow nextOffset while hasMore is true.")
    var offset: Int?
}

private func memoryTextPrefix(_ text: String, bytes: Int) -> String {
    let data = Data(text.utf8)
    var end = min(bytes, data.count)
    while end > 0 && end < data.count && data[end] & 0xc0 == 0x80 { end -= 1 }
    return String(decoding: data.prefix(end), as: UTF8.self)
}
