import Foundation

/// A dictated note: text you build up by talking (and can edit), kept apart
/// from one-off dictations. Shared by the Mac and iOS apps.
public struct DictationNote: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let created: Date
    public var updated: Date
    public var body: String

    public init(id: UUID = UUID(), created: Date = .now, updated: Date = .now, body: String = "") {
        self.id = id; self.created = created; self.updated = updated; self.body = body
    }

    /// The first line, or a date when the note is empty.
    public var title: String {
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if first.isEmpty { return created.formatted(date: .abbreviated, time: .shortened) }
        return first.count > 80 ? String(first.prefix(79)) + "…" : first
    }

    /// The text after the first line, for list previews.
    public var preview: String {
        let lines = body.split(whereSeparator: \.isNewline)
        return lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    public var wordCount: Int { UsageMetrics.countWords(body) }

    /// Adds a dictation at the end: a new paragraph, or the start of an empty note.
    public mutating func append(_ dictation: String, at date: Date = .now) {
        let text = dictation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let existing = body.trimmingCharacters(in: .whitespacesAndNewlines)
        body = existing.isEmpty ? text : existing + "\n\n" + text
        updated = date
    }
}

/// Notes on disk, one vault-sealed JSON file per note, like HistoryStore.
public actor NoteStore {
    public nonisolated let directory: URL
    static let standard = NoteStore(directory: NotchLeeStorage.root.appendingPathComponent("Notes", isDirectory: true))

    public init(directory: URL) { self.directory = directory }

    public struct Loaded: Sendable {
        public let notes: [DictationNote]
        /// Note files that exist but couldn't be opened (wrong key, damage). They are
        /// left on disk untouched and reported, never silently dropped.
        public let unreadableCount: Int
    }

    public func load() throws -> Loaded {
        try ensureDirectory()
        var notes: [DictationNote] = []
        var unreadable = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            guard let stored = try? OmniFlowVault.read(url),
                  let note = try? JSONDecoder().decode(DictationNote.self, from: stored.plaintext),
                  url.deletingPathExtension().lastPathComponent == note.id.uuidString else { unreadable += 1; continue }
            notes.append(note)
        }
        return Loaded(notes: notes.sorted { $0.updated > $1.updated }, unreadableCount: unreadable)
    }

    public func save(_ note: DictationNote) throws {
        try ensureDirectory()
        try OmniFlowVault.write(try JSONEncoder().encode(note), to: file(for: note.id))
    }

    public func delete(_ id: UUID) throws {
        let url = file(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func file(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
