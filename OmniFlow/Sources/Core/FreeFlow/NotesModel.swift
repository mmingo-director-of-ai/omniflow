import Combine
import Foundation

/// The notes list both apps show, backed by the vault-sealed NoteStore.
@MainActor
final class NotesModel: ObservableObject {
    static let shared = NotesModel()
    @Published private(set) var notes: [DictationNote] = []
    /// A note something outside the Notes screen (a widget) asked to open.
    @Published var requestedOpen: UUID?
    /// "N notes couldn't be opened", when some note files fail to decrypt.
    @Published private(set) var problem: String?
    private let store = NoteStore.standard
    private var saving: [UUID: Task<Void, Never>] = [:]

    init() { Task { await reload() } }

    func reload() async {
        do {
            let loaded = try await store.load()
            notes = loaded.notes
            problem = loaded.unreadableCount == 0 ? nil
                : "\(loaded.unreadableCount) \(loaded.unreadableCount == 1 ? "note" : "notes") couldn't be opened. They're kept on disk unchanged."
            if loaded.unreadableCount > 0 {
                let count = String(loaded.unreadableCount)
                Task { await LocalTelemetry.shared.span("notes.unreadable", start: .now, attributes: ["count": count]) }
            }
        } catch {
            problem = "Notes couldn't be loaded: " + error.localizedDescription
        }
    }

    func note(_ id: UUID) -> DictationNote? { notes.first { $0.id == id } }

    /// A new empty note, saved once it has text.
    func create() -> UUID {
        let note = DictationNote()
        notes.insert(note, at: 0)
        return note.id
    }

    func append(_ text: String, to id: UUID) {
        guard var note = note(id) else { return }
        note.append(text)
        update(note)
    }

    func setBody(_ body: String, of id: UUID) {
        guard var note = note(id), note.body != body else { return }
        note.body = body; note.updated = .now
        update(note)
    }

    func delete(_ ids: [UUID]) {
        notes.removeAll { ids.contains($0.id) }
        Task { for id in ids { try? await store.delete(id) } }
    }

    /// Drops a note that never got any text.
    func discardIfEmpty(_ id: UUID) {
        if let note = note(id), note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { delete([id]) }
    }

    private func update(_ note: DictationNote) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
        notes.sort { $0.updated > $1.updated }
        // Typing saves are coalesced; each note keeps its latest text.
        saving[note.id]?.cancel()
        saving[note.id] = Task { [store] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? await store.save(note)
        }
    }
}
