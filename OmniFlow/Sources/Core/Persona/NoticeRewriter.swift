import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct NoticeRewriteRequest: Sendable, Equatable {
    let persona: Persona
    let kind: NoticeKind
    /// The Tier 1 line to rewrite. For critical notices this is the flavor only.
    let source: String
    /// Facts the rewrite must keep; empty for critical flavor lines.
    let facts: [String: String]
    /// Recently shown lines for this kind, which the rewrite must not reuse.
    let avoid: [String]
    let maxLength: Int
}

/// Produces a fresh line in a persona's voice. Implementations may be slow or refuse;
/// PhrasingEngine bounds the wait and validates the result.
protocol NoticeRewriter: Sendable {
    func rewrite(_ request: NoticeRewriteRequest) async throws -> String
}

/// Accepts a Tier 2 line only if it keeps the facts and adds none.
enum RewriteValidator {
    static func validate(_ raw: String, event: NoticeEvent, source: String, persona: Persona) -> String? {
        let critical = event.coreSentence != nil
        var line = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
            .trimmingCharacters(in: .whitespaces)
        while line.contains("  ") { line = line.replacingOccurrences(of: "  ", with: " ") }
        let limit = critical ? PhrasingEngine.maxFlavorLength : PhrasingEngine.maxLength
        guard !line.isEmpty, line.count <= limit else { return nil }
        // Every event number must appear; no number may appear that the event or source lacked.
        let required = critical ? [] : event.numbers
        let allowed = Set(required + numbers(in: source))
        var found = numbers(in: line)
        for number in required {
            guard let index = found.firstIndex(of: number) else { return nil }
            found.remove(at: index)
        }
        guard found.allSatisfy(allowed.contains) else { return nil }
        if !critical { guard event.names.allSatisfy(line.contains) else { return nil } }
        if !persona.explicitLanguage, ProfanityFilter.containsProfanity(line) { return nil }
        // Flavor must not steer a critical decision; the core sentence states the choice.
        if critical, ["allow", "deny", "approve", "reject"].contains(where: line.lowercased().contains) { return nil }
        return line
    }

    static func numbers(in text: String) -> [Int] {
        text.split { !$0.isNumber }.compactMap { Int($0) }
    }
}

#if canImport(FoundationModels)
/// Tier 2 on Apple's on-device model. No cloud fallback: unavailable, refused or
/// guardrail-blocked generations throw and the engine keeps the Tier 1 line.
actor FoundationModelsNoticeRewriter: NoticeRewriter {
    @Generable
    struct Rewrite {
        @Guide(description: "One short notice, one or two sentences, in the persona's voice. Keep every number and name exactly.")
        let line: String
    }

    struct Unavailable: Error {}

    private var prepared: (personaID: String, session: LanguageModelSession)?

    static func instructions(for persona: Persona) -> String {
        """
        You rewrite short system notices for OmniFlow, a Mac assistant, in a persona's voice. \
        Persona: \(persona.displayName). Tone: \(String(persona.toneInstructions.prefix(Persona.maxToneLength))) \
        Keep the meaning. Keep every number and name exactly as written. Add no new facts, numbers, advice or names. \
        Reply with the rewritten notice only. \(Persona.safetyRules)
        """
    }

    /// Prepares a session for the persona so the first rewrite skips model load.
    func prewarm(for persona: Persona) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        if prepared?.personaID == persona.id { return }
        let session = LanguageModelSession(instructions: Self.instructions(for: persona))
        session.prewarm()
        prepared = (persona.id, session)
    }

    func rewrite(_ request: NoticeRewriteRequest) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else { throw Unavailable() }
        // One fresh session per notice keeps transcripts from growing; the next is prewarmed.
        let session = prepared?.personaID == request.persona.id
            ? prepared!.session : LanguageModelSession(instructions: Self.instructions(for: request.persona))
        prepared = nil
        let avoid = request.avoid.isEmpty ? "" : "\nDo not reuse these recent wordings:\n" + request.avoid.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        Notice: \(request.source)
        Maximum \(request.maxLength) characters.\(avoid)
        """
        let response = try await session.respond(to: prompt, generating: Rewrite.self,
                                                  options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 80))
        prewarm(for: request.persona)
        return response.content.line
    }
}
#endif
