import Foundation

@main struct ChatWorkspaceChecks {
    static func main() async throws {
        try AssistantConversationChecks.run()
        let id = UUID()
        var row = ConversationRecord(question: "Original title", answer: "A reply", conversationID: id)
        row.conversationTitle = "Renamed chat"
        let encoded = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(ConversationRecord.self, from: encoded)
        precondition(ConversationThread.group([decoded]).first?.title == "Renamed chat")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "conversationTitle")
        let old = try JSONDecoder().decode(ConversationRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.conversationTitle == nil)
        precondition(ConversationThread.group([old]).first?.title == "Original title")
        // A stored question is bounded; one within the bound is kept as typed.
        precondition(ConversationHistory.boundedQuestion(String(repeating: "q", count: 40_000)).count == ConversationHistory.maximumQuestionCharacters)
        precondition(ConversationHistory.boundedQuestion("short question") == "short question")
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = JournalFile(root: root)
        try await journal.save([row])
        let sealed = try Data(contentsOf: root.appendingPathComponent("conversations.jsonl"))
        precondition(OmniFlowVault.isSealed(sealed))
        let restored = await journal.load()
        precondition(restored.count == 1 && restored[0].conversationTitle == "Renamed chat")
        var original = AssistantConversation()
        original.restore([.init(question: "First", answer: "One"), .init(question: "Second", answer: "Two")], scope: "p")
        var branch = AssistantConversation()
        branch.restore(Array(original.archive.prefix(1)), scope: "p")
        let request = branch.begin(question: "Edited second", scope: "p", fullContext: true)
        precondition(request.turns.count == 1 && original.archive.count == 2)
        branch.complete(request, answer: "Changed", succeeded: true)
        precondition(original.archive.last?.answer == "Two" && branch.archive.last?.answer == "Changed")
        print("Chat checks passed: legacy decoding, renamed threads, encrypted round-trip, and branch isolation")
    }
}
