import Foundation
import SQLite3

struct LocalMailMessage: Sendable, Codable {
    let id: Int64
    let sender: String
    let senderName: String
    let subject: String
    let summary: String
    let conversation: Int64
}

/// Read only the Mail application's existing local index. Never launch Mail, sync an
/// account, download a body, mark a message read, or contact an email provider.
enum MailCacheReader {
    enum ReadError: LocalizedError {
        case noCache, permission, schema
        var errorDescription: String? {
            switch self {
            case .noCache: return "No Apple Mail cache found. Add an account in Apple Mail first."
            case .permission: return "Allow Full Disk Access for OmniFlow to read Apple Mail's local cache."
            case .schema: return "This Apple Mail cache version isn't supported yet."
            }
        }
    }

    static func databaseURL() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        let folders: [URL]
        do { folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch { throw ReadError.permission }
        guard let result = folders.filter({ $0.lastPathComponent.hasPrefix("V") })
            .sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending })
            .map({ $0.appendingPathComponent("MailData/Envelope Index") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw ReadError.noCache }
        return result
    }

    static func latestID(at url: URL? = nil) throws -> Int64 {
        try withDatabase(url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT coalesce(max(ROWID), 0) FROM messages", -1, &statement, nil) == SQLITE_OK else { throw ReadError.schema }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReadError.schema }
            return sqlite3_column_int64(statement, 0)
        }
    }

    static func messages(after id: Int64, at url: URL? = nil) throws -> [LocalMailMessage] {
        try withDatabase(url) { db in
            let sql = """
                SELECT m.ROWID, substr(coalesce(a.address,''),1,200), substr(coalesce(a.comment,''),1,100), substr(coalesce(s.subject,''),1,240),
                       substr(coalesce(z.summary,''),1,1600), coalesce(m.conversation_id,0)
                FROM messages m
                LEFT JOIN addresses a ON a.ROWID=m.sender
                LEFT JOIN subjects s ON s.ROWID=m.subject
                LEFT JOIN summaries z ON z.ROWID=m.summary
                WHERE m.ROWID>? AND m.deleted=0 ORDER BY m.ROWID ASC LIMIT 8
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.schema }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            var result: [LocalMailMessage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ column: Int32, limit: Int) -> String {
                    guard let value = sqlite3_column_text(statement, column) else { return "" }
                    return String(String(cString: value).prefix(limit))
                }
                result.append(LocalMailMessage(id: sqlite3_column_int64(statement, 0), sender: text(1, limit: 200),
                                               senderName: text(2, limit: 100), subject: text(3, limit: 240),
                                               summary: text(4, limit: 1600), conversation: sqlite3_column_int64(statement, 5)))
            }
            return result
        }
    }

    static func search(_ query: String, at url: URL? = nil) throws -> [LocalMailMessage] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return [] }
        return try withDatabase(url) { db in
            let sql = """
                SELECT m.ROWID, coalesce(a.address,''), coalesce(a.comment,''), coalesce(s.subject,''),
                       coalesce(z.summary,''), m.conversation_id
                FROM (SELECT ROWID AS ROWID,* FROM messages WHERE deleted=0 ORDER BY ROWID DESC LIMIT 1500) m
                LEFT JOIN addresses a ON a.ROWID=m.sender
                LEFT JOIN subjects s ON s.ROWID=m.subject
                LEFT JOIN summaries z ON z.ROWID=m.summary
                WHERE m.conversation_id>0 AND (a.address LIKE ?1 ESCAPE '\\' OR a.comment LIKE ?1 ESCAPE '\\'
                      OR s.subject LIKE ?1 ESCAPE '\\' OR z.summary LIKE ?1 ESCAPE '\\')
                GROUP BY m.conversation_id ORDER BY max(m.ROWID) DESC LIMIT 6
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.schema }
            defer { sqlite3_finalize(statement) }
            let term = "%" + String(query.prefix(200)).replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            _ = term.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            var result: [LocalMailMessage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ column: Int32, _ limit: Int) -> String { sqlite3_column_text(statement, column).map { String(String(cString: $0).prefix(limit)) } ?? "" }
                result.append(LocalMailMessage(id: sqlite3_column_int64(statement, 0), sender: text(1, 200), senderName: text(2, 100),
                    subject: text(3, 240), summary: text(4, 500), conversation: sqlite3_column_int64(statement, 5)))
            }
            return result
        }
    }

    private static func withDatabase<T>(_ requested: URL?, _ body: (OpaquePointer) throws -> T) throws -> T {
        let url = try requested ?? databaseURL()
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw ReadError.permission
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 150)
        return try body(connection)
    }
}
