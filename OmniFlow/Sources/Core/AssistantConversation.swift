import Foundation

/// Current-dialogue context only. These pairs are not a transcript archive and
/// are never restored from saved history or ambient notifications.
struct AssistantConversationTurn: Codable, Equatable, Sendable {
    let question: String
    let answer: String
}

struct AssistantConversation: Sendable {
    static let maximumTurns = 4
    static let maximumBytes = 12_000

    struct Request: Sendable {
        let id: UUID
        let question: String
        let scope: String
        let turns: [AssistantConversationTurn]
    }

    private(set) var archive: [AssistantConversationTurn] = []
    private(set) var turns: [AssistantConversationTurn] = []
    private(set) var scope = ""
    private var pending: UUID?

    mutating func begin(question: String, scope: String, fullContext: Bool = false) -> Request {
        selectScope(scope)
        let id = UUID()
        pending = id
        return Request(id: id, question: question, scope: self.scope, turns: fullContext ? archive : turns)
    }

    @discardableResult
    mutating func complete(_ request: Request, answer: String, succeeded: Bool) -> Bool {
        guard pending == request.id, scope == request.scope else { return false }
        pending = nil
        guard succeeded,
              !request.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let turn = AssistantConversationTurn(question: request.question, answer: answer)
        archive.append(turn)
        let bytes = Self.byteCount(turn)
        // Preserve complete pairs. A partial older answer must not masquerade
        // as the complete answer the user is referring to in a follow-up.
        guard bytes <= Self.maximumBytes else {
            // The visible answer is newer than every retained pair. Keeping
            // those pairs would make "expand that" refer to an older answer.
            turns = []
            return false
        }
        turns.append(turn)
        while turns.count > Self.maximumTurns || turns.reduce(0, { $0 + Self.byteCount($1) }) > Self.maximumBytes {
            turns.removeFirst()
        }
        return true
    }

    mutating func cancel() { pending = nil }

    mutating func reset(scope: String) {
        self.scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        turns = []
        archive = []
        pending = nil
    }

    @discardableResult
    mutating func selectScope(_ scope: String) -> Bool {
        let normalized = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != self.scope else { return false }
        reset(scope: normalized)
        return true
    }

    mutating func restore(_ saved: [AssistantConversationTurn], scope: String) {
        reset(scope: scope)
        for turn in saved {
            let request = begin(question: turn.question, scope: scope)
            complete(request, answer: turn.answer, succeeded: true)
        }
    }

    static func contextJSON(_ turns: [AssistantConversationTurn], omittedTurns: Int = 0) throws -> String {
        struct Context: Encodable {
            let turns: [AssistantConversationTurn]
            let omittedTurns: Int
        }
        return String(decoding: try JSONEncoder().encode(Context(turns: turns, omittedTurns: max(0, omittedTurns))), as: UTF8.self)
    }

    private static func byteCount(_ turn: AssistantConversationTurn) -> Int {
        turn.question.utf8.count + turn.answer.utf8.count
    }
}
