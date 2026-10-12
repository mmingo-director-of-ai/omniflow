import Foundation
import SQLite3

/// A title in Apple Books' library that the reader can open: the user's own
/// EPUB files (not Store purchases, which are protected).
struct ReaderBook: Identifiable, Hashable, Sendable {
    let id: String          // Books' asset ID
    let title: String
    let author: String
    let path: String
    let progress: Double
    let lastOpened: Date?
}

/// Where Books last left a book: its page-start location and when it was saved.
struct ReaderBooksLocation: Sendable {
    let cfi: String?
    let progress: Double
    let modified: Date?
}

/// Read-only access to Apple Books' library and reading positions.
///
/// Books owns these Core Data stores and syncs them through iCloud, so the
/// reader never opens them in place: it copies the database and its WAL to a
/// private temporary folder, queries the copy, and deletes it. Nothing is
/// ever written to Books' files.
enum ReaderLibrary {
    enum ReadError: LocalizedError {
        case permission, missing, schema
        var errorDescription: String? {
            switch self {
            case .permission: "Allow Full Disk Access for OmniFlow to read your Apple Books library."
            case .missing: "No Apple Books library was found on this Mac."
            case .schema: "This version of Apple Books stores its library differently; the reader can't read it yet."
            }
        }
    }

    private static var documents: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.apple.iBooksX/Data/Documents")
    }

    /// The user's own EPUB packages, most recently opened first.
    static func books() throws -> [ReaderBook] {
        try query(store: "BKLibrary", prefix: "BKLibrary-") { db in
            let sql = """
                SELECT ZASSETID, ZTITLE, ZAUTHOR, ZPATH, ZREADINGPROGRESS, ZLASTOPENDATE FROM ZBKLIBRARYASSET
                WHERE ZDATASOURCEIDENTIFIER = 'com.apple.ibooks.datasource.ubiquity' AND ZPATH LIKE '%.epub'
                ORDER BY ZLASTOPENDATE DESC
                """
            return try rows(db, sql) { s in
                // No file checks here: a book iCloud is syncing can block a stat
                // for minutes. Each row reads its details off the main thread.
                guard let id = text(s, 0), let path = text(s, 3) else { return nil }
                return ReaderBook(id: id, title: text(s, 1) ?? (path as NSString).lastPathComponent, author: text(s, 2) ?? "",
                                  path: path, progress: sqlite3_column_double(s, 4), lastOpened: date(s, 5))
            }
        }
    }

    /// Asks iCloud to download a book that isn't on this Mac yet. Runs off the
    /// main thread; iCloud may take a while.
    static func requestDownload(_ path: String) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: path))
    }

    /// Books' saved position for one book. Read-only.
    static func location(for assetID: String) throws -> ReaderBooksLocation? {
        let progress = try query(store: "BKLibrary", prefix: "BKLibrary-") { db in
            try rows(db, "SELECT ZREADINGPROGRESS FROM ZBKLIBRARYASSET WHERE ZASSETID = ?", bind: [assetID]) { sqlite3_column_double($0, 0) }.first
        } ?? 0
        let annotation = try query(store: "AEAnnotation", prefix: "AEAnnotation_") { db in
            try rows(db, """
                SELECT ZANNOTATIONLOCATION, ZANNOTATIONMODIFICATIONDATE FROM ZAEANNOTATION
                WHERE ZANNOTATIONTYPE = 3 AND ZANNOTATIONDELETED = 0 AND ZANNOTATIONASSETID = ?
                ORDER BY ZANNOTATIONMODIFICATIONDATE DESC LIMIT 1
                """, bind: [assetID]) { (text($0, 0), date($0, 1)) }.first
        }
        guard annotation != nil || progress > 0 else { return nil }
        return ReaderBooksLocation(cfi: annotation?.0, progress: progress, modified: annotation?.1)
    }

    // MARK: - Snapshot queries

    private static func query<T>(store: String, prefix: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let folder = documents.appendingPathComponent(store)
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) }
        catch let error as CocoaError where error.code == .fileReadNoPermission { throw ReadError.permission }
        catch { throw FileManager.default.fileExists(atPath: documents.path) ? ReadError.permission : ReadError.missing }
        guard let database = names.filter({ $0.hasPrefix(prefix) && $0.hasSuffix(".sqlite") && !$0.contains("_cloud") }).sorted().last
        else { throw ReadError.missing }
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("omniflow-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: snapshot) }
        // The WAL holds Books' most recent changes; without it the copy is stale.
        for suffix in ["", "-wal"] {
            let source = folder.appendingPathComponent(database + suffix)
            guard suffix.isEmpty || FileManager.default.fileExists(atPath: source.path) else { continue }
            do { try FileManager.default.copyItem(at: source, to: snapshot.appendingPathComponent(database + suffix)) }
            catch { throw ReadError.permission }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.appendingPathComponent(database).path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw ReadError.schema
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static func rows<T>(_ db: OpaquePointer, _ sql: String, bind: [String] = [], _ map: (OpaquePointer) -> T?) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ReadError.schema }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { if let row = map(statement) { result.append(row) } }
        return result
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Core Data dates count seconds from 2001-01-01.
    private static func date(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }
}
