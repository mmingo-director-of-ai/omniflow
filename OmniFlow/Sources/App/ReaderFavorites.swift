import Foundation
import Combine

/// Reader organization belongs to OmniFlow; Apple Books remains read-only.
@MainActor
final class ReaderFavorites: ObservableObject {
    @Published private(set) var ids: Set<String>
    @Published private(set) var collections: [String: Set<String>]
    struct Bookmark: Codable, Identifiable {
        var id: UUID
        var bookID: String
        var ref: ReaderSentenceRef
        var title: String
        var cfi: String? = nil
    }
    @Published private(set) var bookmarks: [Bookmark]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bookmarks = defaults.data(forKey: "omniflow.reader.bookmarks").flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
        ids = Set(defaults.stringArray(forKey: "omniflow.reader.favorites") ?? [])
        collections = (defaults.dictionary(forKey: "omniflow.reader.collections") as? [String: [String]] ?? [:]).mapValues { Set($0) }
    }
    func toggle(_ id: String) {
        if !ids.insert(id).inserted { ids.remove(id) }
        defaults.set(ids.sorted(), forKey: "omniflow.reader.favorites")
    }
    @discardableResult func create(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !collections.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        collections[name] = []; save()
        return true
    }
    func toggle(_ id: String, in collection: String) {
        guard var members = collections[collection] else { return }
        if !members.insert(id).inserted { members.remove(id) }
        collections[collection] = members; save()
    }
    func toggleBookmark(bookID: String, ref: ReaderSentenceRef, title: String, cfi: String? = nil) {
        if let i = bookmarks.firstIndex(where: { $0.bookID == bookID && $0.ref == ref }) { bookmarks.remove(at: i) }
        else { bookmarks.append(.init(id: UUID(), bookID: bookID, ref: ref, title: title, cfi: cfi)) }
        if let data = try? JSONEncoder().encode(bookmarks) { defaults.set(data, forKey: "omniflow.reader.bookmarks") }
    }
    func removeCollection(_ name: String) { collections.removeValue(forKey: name); save() }
    private func save() { defaults.set(collections.mapValues { $0.sorted() }, forKey: "omniflow.reader.collections") }
}
