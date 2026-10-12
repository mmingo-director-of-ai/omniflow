import AppKit
import Foundation
import SQLite3

@main
enum CursorAmbientTests {
    @MainActor static func main() throws {
        OmniFlowInteractionLeaseChecks.run()
        cursorWindowOwnership()
        precondition(!CursorGesture.isEngaged([]), "Ordinary clicks must belong to the host app")
        precondition(!CursorGesture.isEngaged(.maskControl))
        precondition(CursorGesture.isEngaged(.maskCommand))
        precondition(!CursorGesture.isEngaged([.maskCommand, .maskAlternate]))
        precondition(CursorGesture.rectangle(from: .zero, to: CGPoint(x: 3, y: 3)) == nil, "Command-click must remain a click")
        precondition(CursorGesture.rectangle(from: CGPoint(x: 30, y: 40), to: CGPoint(x: -20, y: -10)) == CGRect(x: -20, y: -10, width: 50, height: 50))
        precondition(AmbientCapability.allCases.count == 10)
        precondition(Set(AmbientCapability.allCases.map(\.source)).count == 10)
        let legacy = Data("{\"id\":\"85BD8774-749C-45B5-907C-5414FA32366C\",\"name\":\"Existing mail watch\",\"source\":\"email\",\"enabled\":true,\"filter\":\"review\",\"sender\":\"\",\"conversation\":42,\"spoken\":false}".utf8)
        let decoded = try JSONDecoder().decode(AmbientRule.self, from: legacy)
        precondition(decoded.conversation == 42 && decoded.messageConversation == nil && decoded.threshold == nil)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notchlee-context-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let messages = folder.appendingPathComponent("messages.sqlite")
        try fixture(messages, sql: """
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, handle_id INTEGER, is_from_me INTEGER);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, display_name TEXT, chat_identifier TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            INSERT INTO handle VALUES(1,'person@example.invalid');
            INSERT INTO chat VALUES(10,'Release group','group-1'),(20,'Other group','group-2');
            INSERT INTO message VALUES(1,'Release review is ready',1,0),(2,'My reply',1,1),(3,'100% ready',1,0),(4,'Unrelated',1,0);
            INSERT INTO chat_message_join VALUES(10,1),(10,2),(10,3),(20,4);
            """)
        let before = try Data(contentsOf: messages)
        let found = try MessagesCacheReader.search("Release", at: messages)
        precondition(found.count == 1 && found[0].conversation == 10)
        let percent = try MessagesCacheReader.search("100%", at: messages)
        precondition(percent.count == 1 && percent[0].text == "100% ready")
        let injection = try MessagesCacheReader.search("' OR 1=1 --", at: messages)
        precondition(injection.isEmpty)
        let incoming = try MessagesCacheReader.messages(after: 1, at: messages)
        precondition(incoming.map(\.id) == [3,4], "Skip outgoing messages and honor the cursor")
        let short = try MessagesCacheReader.search("R", at: messages)
        precondition(short.isEmpty)
        let after = try Data(contentsOf: messages)
        precondition(after == before, "Searching must not modify the Messages cache")

        let mail = folder.appendingPathComponent("mail.sqlite")
        try fixture(mail, sql: """
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY,address TEXT,comment TEXT);
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY,subject TEXT);
            CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY,summary TEXT);
            CREATE TABLE messages (ROWID INTEGER PRIMARY KEY,sender INTEGER,subject INTEGER,summary INTEGER,conversation_id INTEGER,deleted INTEGER);
            INSERT INTO addresses VALUES(1,'person@example.invalid','Test Person');
            INSERT INTO subjects VALUES(1,'Release review');
            INSERT INTO summaries VALUES(1,'Ready for review');
            INSERT INTO messages VALUES(1,1,1,1,42,0),(2,1,1,1,42,0),(3,1,1,1,99,1);
            """)
        let mailFound = try MailCacheReader.search("review", at: mail)
        precondition(mailFound.count == 1 && mailFound[0].conversation == 42 && mailFound[0].id == 2)
        print("Cursor gesture isolation, 10 ambient abilities, saved-watch migration, and read-only conversation search: passed")
    }

    private static func cursorWindowOwnership() {
        func window(_ pid: Int, _ rect: CGRect, alpha: Double = 1, onScreen: Bool = true) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowBounds as String: rect.dictionaryRepresentation,
             kCGWindowAlpha as String: alpha, kCGWindowIsOnscreen as String: onScreen]
        }
        let own = window(123, CGRect(x: 50, y: 20, width: 200, height: 100))
        let external = window(456, CGRect(x: 0, y: 0, width: 900, height: 600))
        let point = CGPoint(x: 100, y: 60)
        precondition(CursorContext.windowOwner(at: point, windows: [own, external]) == 123,
            "An own-app overlay must be recognized before any accessibility hit test")
        precondition(CursorContext.windowOwner(at: point, windows: [external, own]) == 456,
            "Target the app under the cursor, respecting z-order rather than foreground identity")
        precondition(CursorContext.windowOwner(at: CGPoint(x: 500, y: 300), windows: [own, external]) == 456)
        precondition(CursorContext.windowOwner(at: point, windows: [
            window(123, CGRect(x: 0, y: 0, width: 900, height: 600), alpha: 0),
            window(123, CGRect(x: 0, y: 0, width: 900, height: 600), onScreen: false), external]) == 456)
        precondition(CursorContext.windowOwner(at: point, windows: [[kCGWindowOwnerPID as String: 123]]) == nil)
        precondition(CursorContext.windowOwner(at: point, windows: [window(0, CGRect(x: 0, y: 0, width: 900, height: 600)), external]) == nil,
            "An unknown owner must not cause a read of a window underneath it")
        precondition(MacScreenContext.focusedWindowTitle(pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: "com.mengohlabs.NotchLee") == nil, "Background title reads must reject our own process before AX")
        precondition(CursorContext.windowOwner(at: CGPoint(x: -20, y: -30), windows: [own, external]) == nil)
        precondition(CursorContext.windowOwner(at: CGPoint(x: -20, y: -30), windows: [
            window(789, CGRect(x: -400, y: -200, width: 400, height: 200))]) == 789,
            "Displays left of or above the main display must retain their coordinates")
        print("Cursor targeting recognizes own windows before AX, respects z-order, and supports negative display coordinates: passed")
    }
    private static func fixture(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}
