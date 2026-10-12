import Foundation

/// Listening positions, sealed with `OmniFlowVault`. Holds positions only (book
/// ID, title, sentence and its CFI), never book text.
struct ReaderPositionStore: Sendable {
    struct Entry: Codable, Sendable, Equatable {
        var title: String
        var position: ReaderPosition
    }
    struct Saved: Codable, Sendable, Equatable {
        var books: [String: Entry] = [:]
        var lastBookID: String?
    }

    let file: URL

    static let standard = ReaderPositionStore(file: NotchLeeStorage.root.appendingPathComponent("Reader/positions.json"))

    func load() -> Saved {
        var saved = Saved()
        if let stored = try? OmniFlowVault.read(file), let decoded = try? JSONDecoder().decode(Saved.self, from: stored.plaintext) { saved = decoded }
        if usesSync, let state = try? SyncJournal.shared.snapshot() {
            for value in state.values.values where value.kind == .position {
                guard let data = value.payload, let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
                if saved.books[value.key].map({ $0.position.updatedAt < entry.position.updatedAt }) ?? true { saved.books[value.key] = entry }
            }
        }
        return saved
    }

    private var usesSync: Bool { OmniFlowVault.isAppProcess && file == Self.standard.file }

    func save(_ saved: Saved) throws {
        try NotchLeeStorage.prepare(file.deletingLastPathComponent())
        try OmniFlowVault.write(JSONEncoder().encode(saved), to: file)
        if usesSync {
            for (key, entry) in saved.books where key.hasPrefix("book-v1-") {
                let value = SyncValue(kind: .position, key: key, modified: entry.position.updatedAt,
                                      nonce: "position", payload: try JSONEncoder().encode(entry))
                try SyncJournal.shared.put(value)
            }
        }
    }
}
