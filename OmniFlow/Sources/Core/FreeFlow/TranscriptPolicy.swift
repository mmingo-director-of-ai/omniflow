import Foundation

public struct TranscriptBuffer {
    private var finalized = ""
    private var volatile = ""
    public init() {}
    public var text: String { (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
    public mutating func receive(_ text: String, isFinal: Bool) {
        if isFinal { finalized += text; volatile = "" } else { volatile = text }
    }
}

public enum CleanupPolicy {
    /// Why a model candidate was refused. Reported to telemetry by name only.
    public enum Rejection: String, Error, Sendable {
        case empty, tooLong, tooShort, codeChanged, literalsChanged, correctedDetailsChanged
        case promptEnvelope, preamble, numbersChanged, negationChanged, greetingChanged, contentDropped, contentAdded
    }

    public static func accept(raw: String, candidate: String, structured: Bool = false) -> String? {
        try? evaluate(raw: raw, candidate: candidate, structured: structured).get()
    }

    /// Below this share of the dictation's distinct content words, an edit is a summary.
    public static let minimumCoverage = 0.75

    /// `requireCoverage` rejects edits that drop content; dictation cleanup sets it,
    /// chart formatting (which rewrites prose into data) does not.
    public static func evaluate(raw: String, candidate: String, structured: Bool = false, requireCoverage: Bool = false,
                                vocabulary: String = "") -> Result<String, Rejection> {
        let text: String
        switch evaluateShape(raw: raw, candidate: candidate, structured: structured) {
        case .success(let shaped): text = shaped
        case .failure(let rejection): return .failure(rejection)
        }
        // Compare quantities, not their typography. Only explicit local corrections may
        // remove a superseded quantity or the corrective “no”.
        let corrected = SpeechCorrections.resolve(raw)
        let originalNumbers = NumericContent.values(corrected)
        let editedNumbers = NumericContent.values(text)
        guard structured ? originalNumbers.sorted() == editedNumbers.sorted() : originalNumbers == editedNumbers else { return .failure(.numbersChanged) }
        // A filler hedge ("I don't know what we call it") is not a negation; removing it is fine.
        guard negationCount(SpokenFillers.withoutHedges(corrected)) == negationCount(SpokenFillers.withoutHedges(text)) else { return .failure(.negationChanged) }
        if let originalGreeting = greeting(raw), greeting(text) != originalGreeting { return .failure(.greetingChanged) }
        if requireCoverage, ContentCoverage.fraction(source: raw, edited: text) < minimumCoverage
            || !ContentTerms.missing(source: raw, candidate: text, vocabulary: vocabulary).isEmpty { return .failure(.contentDropped) }
        if requireCoverage, !ContentTerms.added(source: raw, candidate: text, vocabulary: vocabulary).isEmpty { return .failure(.contentAdded) }
        return .success(text)
    }

    /// Whole-reply checks that no per-word validation can repair: an empty or
    /// runaway reply, a preamble or prompt envelope, changed code or literals,
    /// or a dropped greeting. Dictation cleanup judges the words themselves
    /// stretch by stretch (`RewriteValidation`).
    public static func evaluateShape(raw: String, candidate: String, structured: Bool = false) -> Result<String, Rejection> {
        var text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        // A model may wrap the entire Markdown document; retain actual code fences.
        if structured, text.hasPrefix("```markdown\n"), text.hasSuffix("\n```"),
           text.components(separatedBy: "```").count == 3 {
            text = String(text.dropFirst(12).dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count <= max(structured ? 300 : 80, raw.count * (structured ? 4 : 2)) else { return .failure(.tooLong) }
        guard text.count >= max(1, raw.count / 3) else { return .failure(.tooShort) }
        // Explicit inline/fenced code is literal, even when numeric typography is flexible.
        if let code = try? NSRegularExpression(pattern: "`+[^`]+`+") {
            let source = raw as NSString
            for match in code.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
                guard text.contains(source.substring(with: match.range)) else { return .failure(.codeChanged) }
            }
        }
        guard DictationLiterals.preserved(source: raw, candidate: text) else { return .failure(.literalsChanged) }
        guard SpeechCorrections.preservesCorrectedDetails(source: raw, candidate: text) else { return .failure(.correctedDetailsChanged) }
        guard !isPromptEnvelope(text) else { return .failure(.promptEnvelope) }
        let lower = text.lowercased()
        if lower.hasPrefix("transcript:"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("transcript:") { return .failure(.preamble) }
        let preambles = ["here is", "here's", "cleaned transcript:", "as an ai", "```"]
        guard !preambles.filter({ !structured || $0 != "```" }).contains(where: lower.hasPrefix) else { return .failure(.preamble) }
        if let originalGreeting = greeting(raw), greeting(text) != originalGreeting { return .failure(.greetingChanged) }
        return .success(text)
    }
    private static func isPromptEnvelope(_ candidate: String) -> Bool {
        var payload = candidate
        if payload.hasPrefix("```"), payload.hasSuffix("```"),
           let newline = payload.firstIndex(of: "\n") {
            payload = String(payload[payload.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let keys = Set(object.keys.map { $0.lowercased() })
        return keys.contains("transcript") && keys.isSubset(of: ["transcript", "vocabulary"])
    }
    private static func greeting(_ text: String) -> String? {
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let start = words.drop(while: { ["um", "uh", "erm", "hmm"].contains($0) }).first
        return start.flatMap { ["hello", "hi", "hey"].contains($0) ? $0 : nil }
    }
    static func negationCount(_ text: String) -> Int {
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = normalized.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
        let negations: Set<String> = ["no", "not", "never", "without", "cannot", "can't", "won't", "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "weren't", "shouldn't", "wouldn't", "couldn't", "hasn't", "haven't", "hadn't", "mustn't"]
        return words.filter { negations.contains($0) }.count
    }

}

public struct TargetFingerprint: Equatable {
    public let pid: Int32
    public let value: String?
    public let selection: String?
    public init(pid: Int32, value: String?, selection: String?) {
        self.pid = pid; self.value = value; self.selection = selection
    }
    public func matches(_ other: Self) -> Bool { self == other }
    public func allowsInsertion(current: Self, inputOccurred: Bool, dynamicContent: Bool = false) -> Bool {
        if dynamicContent { return pid == current.pid && !inputOccurred }
        guard matches(current) else { return false }
        // Readable text + selection prove that non-editing input left the draft intact.
        // Opaque or partially exposed editors still need an uninterrupted input session.
        return !inputOccurred || (value != nil && selection != nil)
    }
}
