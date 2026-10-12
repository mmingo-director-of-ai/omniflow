import AppKit
import Foundation
import SQLite3

@main
enum LocalAssistantTests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notchlee-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let dropView = FileDropNSView(frame: .zero)
        let passesBackgroundHit = await Task.detached { dropView.hitTest(.zero) == nil }.value
        precondition(passesBackgroundHit, "Background Accessibility hit testing must pass through without a MainActor trap")

        let suite = "notchlee-cursor-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let settings = AgentCursor(defaults: preferences)
        settings.pointerScale = 1.5
        settings.pointerColorHex = "#ff8800"
        let restored = AgentCursor(defaults: preferences)
        precondition(restored.pointerScale == 1.5 && restored.pointerColorHex == "FF8800")
        settings.pointerScale = .nan
        precondition(settings.pointerScale == 1)
        settings.pointerScale = 99
        precondition(settings.pointerScale == 3)
        settings.pointerColorHex = "invalid"
        precondition(settings.pointerColorHex == "FFFFFF")
        settings.resetAppearance()
        precondition(settings.pointerScale == 1 && settings.pointerColorHex == "FFFFFF")

        UserDefaults.standard.setVolatileDomain(["ambientEnabled": false, "localTelemetryEnabled": false], forName: UserDefaults.argumentDomain)
        let ambient = AmbientMonitor(file: folder.appendingPathComponent("ambient.json"))
        ambient.launch()
        await Task.detached {
            NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        }.value
        try await Task.sleep(for: .milliseconds(50))
        ambient.stop()
        print("Cursor settings save/restore and background thermal notification regression: passed")

        precondition(AgentPointerAppearance(scale: .nan, colorHex: "invalid").scale == 1)
        precondition(AgentPointerAppearance(scale: 99, colorHex: "#ff8800") == AgentPointerAppearance(scale: 3, colorHex: "FF8800"))
        precondition(AgentPointerAppearance(scale: -10).scale == 0.75)

        let other = SiriVoice(id: "en-US:fmvoice:other", name: "en-US-F", language: "en-US")
        let voice6 = SiriVoice(id: "en-US:fmvoice:female:en-US-G:premium:0", name: "en-US-G", language: "en-US")
        precondition(SiriVoice.voice6(in: [other]) == nil)
        precondition(SiriVoice.voice6(in: [other, voice6])?.id == voice6.id)
        precondition(SiriVoice.voice6(in: []) == nil)
        let systemPlan = DictationInputDevice.plan(uid: "")
        precondition(systemPlan.deviceID == nil && systemPlan.allowsVoiceProcessing && systemPlan.note == nil,
                     "System default must keep voice processing and bind nothing")
        let missing = DictationInputDevice.plan(uid: "no-such-microphone-\(UUID().uuidString)")
        precondition(missing.deviceID == nil && missing.allowsVoiceProcessing && missing.note != nil,
                     "An unplugged chosen microphone must fall back to the default, with a note")
        if let other = VoiceMicrophone.available().first(where: { $0.deviceID != VoiceMicrophone.defaultInputID() }) {
            let chosen = DictationInputDevice.plan(uid: other.id)
            precondition(chosen.deviceID == other.deviceID && !chosen.allowsVoiceProcessing,
                         "A chosen non-default microphone must be bound directly, without voice processing")
            precondition(DictationInputDevice.plan(uid: other.id).deviceID == other.deviceID, "Cached lookup changed device")
        }
        let context = SpeechService.contextualStrings(vocabulary: "Kwantly\n  pergamon \n\nomniflow\n" + String(repeating: "x", count: 80))
        precondition(context.first == "Kwantly" && context.contains("pergamon"), "User vocabulary must reach recognition first")
        precondition(context.filter { $0.lowercased() == "omniflow" }.count == 1, "Terms must not repeat")
        precondition(!context.contains { $0.isEmpty || $0.count > 60 }, "Blank or oversized lines must be dropped")
        precondition(SpeechService.contextualStrings(vocabulary: "").contains("Claude Code"))
        let aaron = SiriVoice(id: "en-US:fmvoice:male:aaron:premium:0", name: "aaron", language: "en-US")
        let martha = SiriVoice(id: "en-GB:fmvoice:female:martha:premium:0", name: "martha", language: "en-GB")
        let system = SiriVoice(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US")
        precondition(SiriVoice.preferred(in: [aaron, voice6], selectedID: aaron.id)?.id == aaron.id, "The chosen Siri voice was ignored")
        precondition(SiriVoice.preferred(in: [aaron, voice6], selectedID: "removed")?.id == voice6.id, "A missing choice must fall back to Voice 6")
        precondition(SiriVoice.preferred(in: [aaron], selectedID: nil)?.id == aaron.id)
        precondition(SiriVoice.sorted([martha, system, aaron], preferredLanguage: "en-US").map(\.id) == [aaron.id, martha.id],
                     "Only Siri voices may be offered, the user's language first")
        precondition(!system.isSiri && voice6.isSiri && voice6.displayName.hasPrefix("Siri Voice 6") && aaron.displayName.hasPrefix("Aaron") && aaron.gender == "male")
        // Spoken replies: only sentences followed by more text are queued while
        // streaming; a replaced draft stops the stream instead of mixing replies.
        var sentences = SpokenSentenceSplitter()
        precondition(sentences.sentences(in: "Your Mac has 42.5 GB free. Bat") == ["Your Mac has 42.5 GB free."])
        precondition(sentences.sentences(in: "Your Mac has 42.5 GB free. Battery is at 80%.") == [])
        precondition(sentences.remainder(of: "Your Mac has 42.5 GB free. Battery is at 80%. Done.") == ["Battery is at 80%.", "Done."])
        var replaced = SpokenSentenceSplitter()
        _ = replaced.sentences(in: "Let me check. Look")
        precondition(replaced.sentences(in: "Something else. More") == [] && replaced.remainder(of: "Final.") == nil)

        let processes = MacDiagnostics.parseProcesses("10 125.2 102400 /Applications/Code Helper\n20 2.0 2048 /usr/bin/test\nbad row")
        precondition(processes.count == 2 && processes[0].name == "Code Helper")
        precondition(processes[0].cpuPercent == 125.2 && processes[0].memoryMB == 100)
        precondition(!MacDiagnostics.memory().contains("unavailable"))
        let sample = folder.appendingPathComponent("notes.txt")
        try Data("Only the local test file.\nNo network required.".utf8).write(to: sample)
        let result = LocalFiles.inspect(.init(operation: .read, path: sample.path, query: nil, offset: 0))
        precondition(result.contains("Only the local test file"))
        precondition(LocalFiles.inspect(.init(operation: .read, path: "https://example.com", query: nil, offset: 0)).contains("local path"))
        precondition(LocalFiles.inspect(.init(operation: .search, path: folder.path, query: "notes", offset: nil)).contains("notes.txt"))
        let binary = folder.appendingPathComponent("binary.bin")
        try Data([0,1,2]).write(to: binary)
        precondition(LocalFiles.inspect(.init(operation: .read, path: binary.path, query: nil, offset: 0)).contains("binary"))

        let mail = folder.appendingPathComponent("mail.sqlite")
        var db: OpaquePointer?
        precondition(sqlite3_open(mail.path, &db) == SQLITE_OK)
        let schema = """
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
            CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, subject INTEGER, summary INTEGER, conversation_id INTEGER, deleted INTEGER);
            INSERT INTO addresses VALUES (1,'person@example.invalid','Test Person');
            INSERT INTO subjects VALUES (1,'Release review');
            INSERT INTO summaries VALUES (1,'Approved for review.');
            INSERT INTO messages VALUES (1,1,1,1,42,0);
            INSERT INTO messages VALUES (2,1,1,1,42,1);
            """
        precondition(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let latestMail = try MailCacheReader.latestID(at: mail)
        precondition(latestMail == 2)
        let messages = try MailCacheReader.messages(after: 0, at: mail)
        precondition(messages.count == 1 && messages[0].summary == "Approved for review.")
        precondition(AmbientRule(name: "Person", source: .email, sender: "PERSON@", conversation: 42).matchesMailHeaders(messages[0]))
        precondition(!AmbientRule(name: "Different thread", source: .email, conversation: 99).matchesMailHeaders(messages[0]))

        precondition(WakePhrase.command(in: "Hey Omni, what time is it?") == "what time is it?")
        precondition(WakePhrase.command(in: "HEY OMNI show my memory usage") == "show my memory usage")
        precondition(WakePhrase.command(in: "Omni, what time is it?") == "what time is it?")
        precondition(WakePhrase.command(in: "Omni show my memory usage") == "show my memory usage")
        precondition(WakePhrase.command(in: "They mentioned another assistant today") == nil)
        precondition(WakePhrase.command(in: "hey omnipresent") == nil)
        precondition(WakePhrase.command(in: "Hey, Omni, which agent is waiting for me?") == "which agent is waiting for me?")

        let journal = JournalFile(root: folder.appendingPathComponent("Journal"))
        let old = ConversationRecord(date: Date().addingTimeInterval(-31 * 86400), question: "Expired", answer: "Expired")
        let current = ConversationRecord(question: "Question", answer: "Answer")
        try await journal.save([old, current])
        let saved = await journal.load()
        precondition(saved.count == 1 && saved[0].id == current.id)
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("Journal/conversations.jsonl").path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        try await journal.save([])
        let cleared = await journal.load()
        precondition(cleared.isEmpty)

        let payload = LocalTelemetry.tracePayload(name: "test.operation", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 101), success: true, attributes: ["operation": "read"])
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let resources = decoded["resourceSpans"] as! [[String: Any]]
        let scopes = resources[0]["scopeSpans"] as! [[String: Any]]
        let spans = scopes[0]["spans"] as! [[String: Any]]
        precondition((spans[0]["traceId"] as! String).count == 32 && (spans[0]["spanId"] as! String).count == 16)
        precondition(spans[0]["kind"] as! Int == 1)
        precondition(spans[0]["startTimeUnixNano"] as! String == "100000000000")
        precondition(!String(decoding: data, as: UTF8.self).contains("Question"))
        print("Pointer appearance, Voice 6 restriction, host tools, read-only mail, wake phrase, local retention and OTLP encoding: passed")
    }
}
