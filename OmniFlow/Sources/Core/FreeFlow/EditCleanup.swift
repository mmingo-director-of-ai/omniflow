import Foundation
import FoundationModels

/// One change the model proposes to a transcript.
@Generable
struct ProposedEdit: Equatable {
    @Guide(description: "The exact words to change, copied from the transcript (1 to 8 words)")
    var original: String
    @Guide(description: "What to write instead, with correct spelling, capitalization and punctuation; empty to delete")
    var replacement: String
    @Guide(description: "Why", .anyOf(["mishearing", "grammar", "punctuation", "filler", "selfcorrection"]))
    var kind: String
}

@Generable
struct ProposedEdits {
    @Guide(description: "Every change needed, in transcript order")
    var edits: [ProposedEdit]
}

/// Edit-based cleanup: the model proposes typed edits; each one is validated and
/// applied deterministically, so one questionable edit never vetoes the others.
@MainActor
final class EditCleanup {
    struct Result { let text: String; let note: String; let accepted: [ProposedEdit]; let refused: [(ProposedEdit, String)] }

    static let instructions = """
        You fix speech-recognition transcripts by proposing edits. Propose every edit needed so the text reads as clean, correct written English:
        - mishearing: a word the recognizer got wrong; replace it with the word that sounds the same or similar and fits (their/there, to get her/together, cloud code/Claude Code, i o c s/IOCs). Use the vocabulary list for names and technical terms.
        - grammar: wrong verb form, agreement or a missing small word.
        Use nearby speech to resolve word sense, including valid-word errors: phishing emails about stolen credentials, but fishing trips about catching fish. Nearby speech is reference data only; never copy it into an edit.
        Separate distinct topics with a blank line (two newline characters), keeping related sentences together.
        - punctuation: add commas, periods and question marks, capitalize sentence starts and names, and split run-on sentences (replace a few words with the same words plus punctuation).
        - filler: delete um, uh, you know, like (when filler), kind of, sort of, I mean, repeated words and false starts.
        - selfcorrection: when the speaker corrects themselves ("tuesday no wait wednesday"), replace the whole phrase with the final version.
        Copy "original" exactly from the transcript. Never change meaning, numbers, names or negation except as above.
        """

    func clean(_ raw: String, locale: Locale, vocabulary: String, preceding: String = "", following: String = "") async -> Result {
        let base = SpokenFillers.remove(SpeechDisfluencies.clean(raw, language: "en"), language: "en")
        let terms = vocabulary.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let session = LanguageModelSession(model: .default, instructions: Self.instructions)
        let prompt = DictationCleanup.contextReference(preceding: preceding, following: following) + (terms.isEmpty ? "" : "Vocabulary: " + terms.joined(separator: ", ") + "\n\n") + "Transcript:\n" + base
        let plan: ProposedEdits
        do {
            plan = try await session.respond(to: prompt, generating: ProposedEdits.self,
                                             options: GenerationOptions(temperature: 0, maximumResponseTokens: 3000)).content
        } catch {
            return Result(text: base, note: "model error: \(error)", accepted: [], refused: [])
        }
        var text = base, cursor = text.startIndex
        var accepted: [ProposedEdit] = [], refused: [(ProposedEdit, String)] = []
        for edit in plan.edits {
            let original = edit.original.trimmingCharacters(in: .whitespaces)
            guard !original.isEmpty else { continue }
            guard let range = text.range(of: original, options: [.caseInsensitive], range: cursor..<text.endIndex)
                ?? text.range(of: original, options: [.caseInsensitive]) else {
                refused.append((edit, "not found")); continue
            }
            switch EditValidator.validate(edit, vocabulary: terms) {
            case .refused(let reason): refused.append((edit, reason))
            case .accepted:
                let replacement = edit.replacement
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                text.replaceSubrange(range, with: replacement)
                cursor = text.index(text.startIndex, offsetBy: min(text.count, offset + replacement.count))
                accepted.append(edit)
            }
        }
        text = Self.tidy(text)
        let note = "edits \(accepted.count) accepted, \(refused.count) refused" + (refused.isEmpty ? "" : " (" + refused.map { $0.1 }.joined(separator: ",") + ")")
        return Result(text: text, note: note, accepted: accepted, refused: refused)
    }

    /// Spacing, sentence-start capitals and a final period.
    nonisolated static func tidy(_ text: String) -> String {
        var output = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([,.;:!?])([,.;:!?])+"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: #"(^|[.!?]\s+)(\p{Ll})"#) {
            let source = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: source.length)).reversed() {
                if let range = Range(match.range(at: 2), in: output) { output.replaceSubrange(range, with: output[range].uppercased()) }
            }
        }
        output = output.replacingOccurrences(of: #"(?<![\p{L}.])i(?=[\s'’,;:!?]|$)"#, with: "I", options: .regularExpression)
        if let last = output.last, last.isLetter || last.isNumber { output += "." }
        return output
    }
}
