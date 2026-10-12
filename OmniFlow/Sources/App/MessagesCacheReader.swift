import Foundation
import SQLite3

struct LocalMessage: Sendable, Identifiable, Codable {
    let id: Int64
    let conversation: Int64
    let name: String
    let sender: String
    let text: String
}

/// Only the existing Messages database, opened read-only. No sync, sends or mark-read operations.
enum MessagesCacheReader {
    enum ReadError: LocalizedError {
        case unavailable, schema
        var errorDescription: String? {
            switch self {
            case .unavailable: "Allow Full Disk Access for OmniFlow to search Apple Messages stored on this Mac."
            case .schema: "This Messages cache format isn't supported."
            }
        }
    }
    static func latestID(at url: URL? = nil) throws -> Int64 {
        try database(url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT coalesce(max(ROWID),0) FROM message", -1, &statement, nil) == SQLITE_OK else { throw ReadError.schema }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReadError.schema }
            return sqlite3_column_int64(statement, 0)
        }
    }
    static func messages(after id: Int64, at url: URL? = nil) throws -> [LocalMessage] {
        try query("WHERE m.ROWID>?1 AND m.is_from_me=0 ORDER BY m.ROWID ASC LIMIT 12", at: url) { sqlite3_bind_int64($0, 1, id) }
    }
    static func search(_ term: String, at url: URL? = nil) throws -> [LocalMessage] {
        guard term.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return [] }
        let text = "%" + String(term.prefix(200)).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        return try query("""
            WHERE m.ROWID IN (SELECT ROWID FROM message ORDER BY ROWID DESC LIMIT 2000)
              AND (m.text LIKE ?1 ESCAPE '\\' OR h.id LIKE ?1 ESCAPE '\\' OR c.display_name LIKE ?1 ESCAPE '\\' OR c.chat_identifier LIKE ?1 ESCAPE '\\')
            GROUP BY c.ROWID ORDER BY max(m.ROWID) DESC LIMIT 6
            """, at: url) { statement in
                _ = text.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            }
    }
    private static func query(_ suffix: String, at url: URL?, bind: (OpaquePointer?) -> Void) throws -> [LocalMessage] {
        try database(url) { db in
            var statement: OpaquePointer?
            let sql = """
                SELECT m.ROWID,c.ROWID,substr(coalesce(nullif(c.display_name,''),c.chat_identifier,''),1,160),
                       substr(coalesce(h.id,''),1,160),substr(coalesce(m.text,''),1,1600)
                FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID
                JOIN chat c ON c.ROWID=j.chat_id LEFT JOIN handle h ON h.ROWID=m.handle_id
                \(suffix)
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.schema }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            var result: [LocalMessage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
                result.append(LocalMessage(id: sqlite3_column_int64(statement, 0), conversation: sqlite3_column_int64(statement, 1),
                    name: text(2), sender: text(3), text: text(4)))
            }
            return result
        }
    }
    private static func database<T>(_ url: URL?, body: (OpaquePointer) throws -> T) throws -> T {
        let url = url ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw ReadError.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 150)
        return try body(db)
    }
}
