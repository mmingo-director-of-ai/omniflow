import Foundation
import Combine

struct ConversationRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    let question: String
    let answer: String
    var source: String = "conversation"
    var conversationID: UUID? = nil
    var scope: String? = nil
    var feedback: Int? = nil
    var conversationTitle: String? = nil
}

enum NotchLeeStorage {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchLee/LocalData", isDirectory: true)

    static func prepare(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        var folder = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    static func append(_ data: Data, to url: URL) throws {
        try prepare(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([10]))
    }
}

actor JournalFile {
    private let root: URL
    init(root: URL = NotchLeeStorage.root) { self.root = root }
    private var file: URL { root.appendingPathComponent("conversations.jsonl") }

    func load(now: Date = .now) -> [ConversationRecord] {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000 else { return [] }
        let stored: (plaintext: Data, wasPlaintext: Bool)
        do { stored = try OmniFlowVault.read(file) } catch {
            // Encrypted but unreadable (e.g. the key is gone): keep it aside rather than
            // letting the next save replace it with only new conversations.
            let aside = root.appendingPathComponent("conversations.unreadable-\(Int(now.timeIntervalSince1970)).jsonl")
            try? FileManager.default.moveItem(at: file, to: aside)
            return []
        }
        let decoder = JSONDecoder()
        let records = stored.plaintext.split(separator: 10).compactMap { try? decoder.decode(ConversationRecord.self, from: Data($0)) }
            .filter { now.timeIntervalSince($0.date) < 30 * 86400 }.suffix(500).map { $0 }
        // Migration: a journal written before encryption is rewritten sealed.
        if stored.wasPlaintext && !records.isEmpty { try? save(records, now: now) }
        return records
    }

    func save(_ records: [ConversationRecord], now: Date = .now) throws {
        try NotchLeeStorage.prepare(root)
        let encoder = JSONEncoder()
        var rows: [Data] = []
        var size = 0
        for record in records.filter({ now.timeIntervalSince($0.date) < 30 * 86400 }).suffix(500).reversed() {
            let row = try encoder.encode(record)
            guard size + row.count + 1 <= 7_000_000 else { break }
            rows.append(row); size += row.count + 1
        }
        var data = Data()
        for row in rows.reversed() { data.append(row); data.append(10) }
        try OmniFlowVault.write(data, to: file)
    }
}

@MainActor
final class ConversationHistory: ObservableObject {
    static let shared = ConversationHistory()
    @Published var enabled = UserDefaults.standard.object(forKey: "keepLocalTranscripts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "keepLocalTranscripts") }
    }
    @Published private(set) var records: [ConversationRecord] = []
    @Published private(set) var error: String?
    private let file = JournalFile()
    private var loading: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loaded = false
    private var clearGeneration = 0

    func launch() {
        guard loading == nil else { return }
        let token = clearGeneration
        loading = Task {
            let stored = await file.load()
            if clearGeneration == token { records = stored + records }
            loaded = true
            persist() // Enforce retention even if no new conversation is recorded.
        }
    }

    var conversations: [ConversationThread] { ConversationThread.group(records) }

    nonisolated static let maximumQuestionCharacters = 32_000
    nonisolated static func boundedQuestion(_ question: String) -> String { String(question.prefix(maximumQuestionCharacters)) }

    func append(question: String, answer: String, source: String = "conversation", conversationID: UUID? = nil, scope: String? = nil) {
        guard enabled else { return }
        // Answers are kept whole: a cut-off answer must not pass for the full one, and the runtime
        // already caps an answer at 16,000 bytes. A question has no such cap upstream, so it gets one here.
        records.append(ConversationRecord(question: Self.boundedQuestion(question), answer: answer, source: source, conversationID: conversationID, scope: scope))
        if records.count > 500 { records.removeFirst(records.count - 500) }
        persist()
    }

    func feedback(_ id: UUID, useful: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].feedback = useful ? 1 : -1
        persist()
    }

    func rename(_ id: UUID, title: String) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        for index in records.indices where (records[index].conversationID ?? records[index].id) == id {
            records[index].conversationTitle = title.isEmpty ? nil : title
        }
        persist()
    }

    func deleteConversation(_ id: UUID) {
        records.removeAll { ($0.conversationID ?? $0.id) == id }
        persist()
    }

    func clear() { clearGeneration += 1; records = []; persist() }

    private func persist() {
        guard loaded else { return }
        let snapshot = records
        let prior = saveTask
        saveTask = Task {
            await prior?.value
            do { try await file.save(snapshot); error = nil }
            catch { self.error = "Local history could not be saved." }
        }
    }
}

struct ConversationThread: Identifiable {
    let id: UUID
    let records: [ConversationRecord]
    var date: Date { records.last?.date ?? .distantPast }
    var title: String { records.first?.conversationTitle ?? records.first?.question ?? "Conversation" }
    var scope: String { records.first?.scope ?? "" }
    static func group(_ records: [ConversationRecord]) -> [Self] {
        let grouped = Dictionary(grouping: records.filter { $0.source == "conversation" }) { $0.conversationID ?? $0.id }
        return grouped.map { Self(id: $0.key, records: $0.value.sorted { $0.date < $1.date }) }.sorted { $0.date > $1.date }
    }
}
