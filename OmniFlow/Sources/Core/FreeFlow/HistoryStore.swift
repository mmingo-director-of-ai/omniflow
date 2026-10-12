import Foundation

public struct DictationEntry: Identifiable, Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case recording, processing, ready, delivered, pasteSent, needsCopy, cancelled, failed }
    public let id: UUID
    public let date: Date
    public var raw: String
    public var text: String
    public var note: String
    public var destination: String
    public var state: State
    public var durationSeconds: Double?
    public var revision: Int
    /// What cleanup changed and refused, for History's "what changed". nil for
    /// entries saved before edits were recorded, which decode unchanged.
    public var edits: [CleanupEdit]?
    public var displayText: String { text.isEmpty ? raw : text }
    public var unfinished: Bool { state == .recording || state == .processing || state == .ready }
    public init(id: UUID = UUID(), date: Date = Date(), raw: String, text: String,
                note: String, destination: String, state: State = .needsCopy, revision: Int = 0, durationSeconds: Double? = nil,
                edits: [CleanupEdit]? = nil) {
        self.id = id; self.date = date; self.raw = raw; self.text = text
        self.note = note; self.destination = destination; self.state = state; self.revision = revision; self.durationSeconds = durationSeconds
        self.edits = edits
    }
}

public enum HistoryRetention: Int, CaseIterable, Codable, Sendable {
    case forever = 0, sevenDays = 7, thirtyDays = 30, ninetyDays = 90
    public static let `default`: Self = .thirtyDays
}

public actor HistoryStore {
    public struct RetentionResult: Sendable {
        public let trashedIDs: [UUID]
        public let failedIDs: [UUID]
    }
    public struct Loaded: Sendable { public let entries: [DictationEntry]; public let unreadableCount: Int }
    public nonisolated let directory: URL
    private var revisions: [UUID: Int] = [:]
    private var deleted: Set<UUID> = []
    private let trashItem: @Sendable (URL) throws -> Void
    public init(directory: URL, trashItem: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) {
        self.directory = directory; self.trashItem = trashItem
    }
    public func load() throws -> Loaded {
        try ensureDirectory()
        var records: [DictationEntry] = []
        var unreadable = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            do {
                let stored = try OmniFlowVault.read(url)
                let record = try JSONDecoder().decode(DictationEntry.self, from: stored.plaintext)
                guard url.deletingPathExtension().lastPathComponent == record.id.uuidString else { unreadable += 1; continue }
                records.append(record); revisions[record.id] = record.revision
                // Migration: entries saved before encryption are rewritten sealed.
                if stored.wasPlaintext { try? OmniFlowVault.write(stored.plaintext, to: url) }
            } catch { unreadable += 1 }
        }
        if usesSync {
            var merged = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            for value in try SyncJournal.shared.snapshot().values.values where value.kind == .transcript {
                guard let id = UUID(uuidString: value.key) else { continue }
                if let data = value.payload {
                    let entry = try JSONDecoder().decode(DictationEntry.self, from: data)
                    guard entry.id == id else { throw SyncFailure.malformed }
                    if merged[id]?.state != .recording && merged[id]?.state != .processing { merged[id] = entry }
                    revisions[id] = max(revisions[id] ?? 0, entry.revision)
                } else {
                    merged.removeValue(forKey: id); deleted.insert(id)
                    let local = file(for: id)
                    if FileManager.default.fileExists(atPath: local.path) { try trashItem(local) }
                }
            }
            records = Array(merged.values)
        }
        return Loaded(entries: records.sorted { $0.date > $1.date }, unreadableCount: unreadable)
    }
    public func save(_ entry: DictationEntry) throws {
        guard !deleted.contains(entry.id) else { return }
        try ensureDirectory()
        let url = file(for: entry.id)
        if revisions[entry.id] == nil, let stored = try? OmniFlowVault.read(url),
           let existing = try? JSONDecoder().decode(DictationEntry.self, from: stored.plaintext) {
            revisions[entry.id] = existing.revision
        }
        guard entry.revision >= (revisions[entry.id] ?? -1) else { return }
        let data = try JSONEncoder().encode(entry)
        try OmniFlowVault.write(data, to: url)
        revisions[entry.id] = entry.revision
        if usesSync, entry.state != .recording, entry.state != .processing {
            try SyncJournal.shared.put(.init(kind: .transcript, key: entry.id.uuidString, modified: .now, payload: data))
        }
    }
    public func moveToTrash(ids: [UUID]) throws {
        for id in ids {
            let url = file(for: id)
            if FileManager.default.fileExists(atPath: url.path) { try trashItem(url) }
            // Prevent delayed save tasks resurrecting records after explicit deletion.
            if usesSync { try SyncJournal.shared.put(.init(kind: .transcript, key: id.uuidString, modified: .now, payload: nil)) }
            deleted.insert(id); revisions.removeValue(forKey: id)
        }
    }
    /// Completed history expires by creation time. Recovery records and active retries stay.
    /// No suspension between selecting and trashing: saves serialize through this actor.
    public func applyRetention(_ policy: HistoryRetention, now: Date = .now,
                               excludingIDs: Set<UUID> = []) throws -> RetentionResult {
        guard policy != .forever else { return .init(trashedIDs: [], failedIDs: []) }
        let cutoff = now.addingTimeInterval(-Double(policy.rawValue) * 86400)
        let candidates = try load().entries.filter {
            ($0.state == .delivered || $0.state == .pasteSent) && $0.date < cutoff && !excludingIDs.contains($0.id)
        }
        var trashed: [UUID] = []
        var failed: [UUID] = []
        for entry in candidates {
            do { try moveToTrash(ids: [entry.id]); trashed.append(entry.id) }
            catch { failed.append(entry.id) }
        }
        return .init(trashedIDs: trashed, failedIDs: failed)
    }
    private var usesSync: Bool {
        OmniFlowVault.isAppProcess && directory.standardizedFileURL.path == NotchLeeStorage.root.appendingPathComponent("Dictations").standardizedFileURL.path
    }
    private func file(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

/// Calendar-day projection preserves individual timestamps, originals, edits and deletion/recovery semantics.
struct DictationDay {
    let date: Date
    let entries: [DictationEntry]
    static func group(_ entries: [DictationEntry], calendar: Calendar = .current) -> [Self] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
            .map { Self(date: $0.key, entries: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.date > $1.date }
    }
}
