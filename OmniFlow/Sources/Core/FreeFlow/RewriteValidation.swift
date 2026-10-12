import Foundation
import NaturalLanguage

/// A Metaphone-style phonetic key: how a word sounds, so a recognizer's
/// mishearing ("their"/"there", "to get her"/"together", "cloud"/"Claude",
/// "ICs"/"IOCs") can be told apart from a change of meaning. No dependencies.
enum PhoneticKey {
    static func key(_ text: String) -> String {
        let letters = Array(text.uppercased().unicodeScalars.filter { $0.properties.isAlphabetic }.map(Character.init))
        guard !letters.isEmpty else { return "" }
        let vowels: Set<Character> = ["A", "E", "I", "O", "U"]
        func at(_ i: Int) -> Character? { i >= 0 && i < letters.count ? letters[i] : nil }
        var w = letters
        // Silent or simplified starts.
        if let first = at(0), let second = at(1) {
            let pair = String([first, second])
            if ["KN", "GN", "PN", "AE", "WR"].contains(pair) { w.removeFirst() }
            else if first == "X" { w[0] = "S" }
            else if pair == "WH" { w.remove(at: 1) }
        }
        var out = ""
        func emit(_ s: String) { if out.last.map(String.init) != s || s == "C" { out += s } }
        var i = 0
        while i < w.count {
            let c = w[i], prev = i > 0 ? w[i - 1] : nil, next = i + 1 < w.count ? w[i + 1] : nil
            let next2 = i + 2 < w.count ? w[i + 2] : nil
            if vowels.contains(c) { if i == 0 { emit("A") }; i += 1; continue }
            switch c {
            case "B": if !(prev == "M" && next == nil) { emit("B") }
            case "C":
                if next == "H" { emit("X"); i += 1 }
                else if next == "I" && next2 == "A" { emit("X") }
                else if let n = next, ["I", "E", "Y"].contains(n) { if prev != "S" { emit("S") } }
                else { emit("K") }
            case "D": if next == "G", let n2 = next2, ["E", "I", "Y"].contains(n2) { emit("J"); i += 1 } else { emit("T") }
            case "G":
                if next == "H", !(next2.map(vowels.contains) ?? false) { i += 1 }
                else if next == "N" { }
                else if let n = next, ["I", "E", "Y"].contains(n) { emit("J") }
                else { emit("K") }
            case "H": if let n = next, vowels.contains(n), !(prev.map { "CGPST".contains($0) } ?? false) { emit("H") }
            case "K": if prev != "C" { emit("K") }
            case "P": if next == "H" { emit("F"); i += 1 } else { emit("P") }
            case "Q": emit("K")
            case "S":
                if next == "H" { emit("X"); i += 1 }
                else if next == "I", let n2 = next2, ["O", "A"].contains(n2) { emit("X") }
                else { emit("S") }
            case "T":
                if next == "H" { emit("0"); i += 1 }
                else if next == "I", let n2 = next2, ["O", "A"].contains(n2) { emit("X") }
                else { emit("T") }
            case "V": emit("F")
            case "W", "Y": if let n = next, vowels.contains(n) { emit(String(c)) }
            case "X": emit("KS")
            case "Z": emit("S")
            default: emit(String(c))
            }
            i += 1
        }
        return out
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var previous = row[0]; row[0] = i
            for j in 1...y.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[y.count]
    }

    /// Whether two phrases sound alike: same key, or within one sound per four.
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let ka = key(a), kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        if ka == kb { return true }
        return distance(ka, kb) <= max(1, min(ka.count, kb.count) / 4)
    }
}

/// Decides, edit by edit, whether a proposed change is a transcription fix or a
/// change of meaning. Numbers, negation and names change only with support.
enum EditValidator {
    enum Verdict: Equatable { case accepted(String), refused(String) }

    static let fillers: Set<String> = ["um", "uh", "erm", "like", "so", "basically", "actually", "literally", "just", "really",
                                       "you", "know", "kind", "sort", "of", "i", "mean", "right", "okay", "well", "anyway"]
    static let functionWords: Set<String> = ["a", "an", "the", "to", "too", "two", "of", "in", "on", "at", "for", "by", "buy", "it", "its", "it's",
        "is", "are", "was", "were", "be", "been", "being", "has", "have", "had", "do", "does", "did", "don't", "doesn't", "didn't",
        "will", "would", "can", "could", "should", "their", "there", "they're", "your", "you're", "then", "than", "and", "or", "but",
        "that", "this", "these", "those", "we", "they", "he", "she", "i", "me", "us", "them", "him", "her", "my", "our", "with", "from", "as", "so"]
    static let cues = ["no", "sorry", "wait", "i mean", "i meant", "actually", "scratch that", "make that", "strike that"]

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted).filter { !$0.isEmpty }
    }

    /// Small grammatical words can still carry commitments, conditions and order.
    /// Canonicalize contractions so typography alone never changes this signature.
    static func meaningAnchors(_ text: String) -> [String] {
        let anchors: Set<String> = ["can", "could", "may", "might", "must", "should", "will", "would",
            "if", "unless", "until", "before", "after", "only", "maybe", "perhaps", "probably", "possibly",
            "roughly", "approximately", "too", "also"]
        return words(text.replacingOccurrences(of: "’", with: "'")).compactMap { word in
            if anchors.contains(word) { return word }
            if word.hasSuffix("'ll") { return "will" }
            let contractions = ["can't": "can", "cannot": "can", "couldn't": "could", "won't": "will",
                                "wouldn't": "would", "shouldn't": "should", "mustn't": "must", "mightn't": "might"]
            return contractions[word]
        }
    }

    static func validate(_ edit: ProposedEdit, vocabulary: [String]) -> Verdict {
        let from = words(edit.original), to = words(edit.replacement)
        guard !from.isEmpty, from.count <= 12 else { return .refused("span") }
        // Punctuation, capitalization, sentence splits and merges: the words are unchanged.
        if from.joined() == to.joined() { return .accepted("punctuation") }
        // A term the user taught is never rewritten into something else.
        let original = " " + from.joined(separator: " ") + " ", replaced = " " + to.joined(separator: " ") + " "
        if vocabulary.contains(where: { term in
            let key = " " + words(term).joined(separator: " ") + " "
            return key.count > 2 && original.contains(key) && !replaced.contains(key)
        }) { return .refused("vocabulary") }
        let hasCue = cues.contains { cue in edit.original.lowercased().range(of: #"\b"# + cue + #"\b"#, options: .regularExpression) != nil }
        let sourceAnchors = meaningAnchors(edit.original), targetAnchors = meaningAnchors(edit.replacement)
        if sourceAnchors != targetAnchors,
           !(hasCue && isSubsequence(targetAnchors, of: sourceAnchors)),
           !(hasStutter(from) && isSubsequence(to, of: from) && isSubsequence(targetAnchors, of: sourceAnchors)) {
            return .refused("meaning")
        }
        // A correction cue ("no wait", "no, sorry") is not a negation of the content.
        let withoutCues = edit.original.replacingOccurrences(of: #"(?i)\bno\b[ ,]*(?=wait|sorry|i mean|i meant|actually|make that)"#, with: "", options: .regularExpression)
        if CleanupPolicy.negationCount(SpokenFillers.withoutHedges(withoutCues)) != CleanupPolicy.negationCount(SpokenFillers.withoutHedges(edit.replacement)) {
            return .refused("negation")
        }
        let numbersBefore = NumericContent.values(edit.original), numbersAfter = NumericContent.values(edit.replacement)
        if numbersBefore != numbersAfter {
            // A spoken self-correction may drop the abandoned quantity, never invent one.
            guard hasCue, Set(numbersAfter).isSubset(of: Set(numbersBefore)) else { return .refused("numbers") }
        }
        // Pure deletions: filler, stutters, or an explicitly abandoned phrase.
        if isSubsequence(to, of: from) {
            let removed = removedWords(from, keeping: to)
            if removed.allSatisfy({ fillers.contains($0) || functionWords.contains($0) }) { return .accepted("filler") }
            if hasStutter(from) { return .accepted("repeat") }
            if hasCue { return .accepted("selfcorrection") }
            return .refused("deletion")
        }
        // Substitutions: every changed stretch must sound alike, be a known term,
        // or swap function words / inflections.
        let lowerVocabulary = Set(vocabulary.map { $0.lowercased() })
        if lowerVocabulary.contains(edit.replacement.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))) { return .accepted("vocabulary") }
        if PhoneticKey.soundsAlike(from.joined(separator: " "), to.joined(separator: " ")) { return .accepted("sound") }
        if from.joined() == to.joined().replacingOccurrences(of: " ", with: "") || from.joined() == to.joined() { return .accepted("spacing") }
        let changedFrom = removedWords(from, keeping: to), changedTo = removedWords(to, keeping: from)
        if (changedFrom + changedTo).allSatisfy({ functionWords.contains($0) || fillers.contains($0) }) { return .accepted("grammar") }
        if changedFrom.count == changedTo.count, zip(changedFrom, changedTo).allSatisfy({ inflection($0, $1) }) { return .accepted("grammar") }
        // A broken auxiliary plus verb ("have finish" → "finished") changes
        // token count but keeps the same lexical verb. Do not strip modals:
        // "could ship" must not become the factual assertion "shipped".
        let auxiliaries: Set<String> = ["is", "are", "was", "were", "be", "been", "being", "has", "have", "had", "do", "does", "did"]
        let verbsFrom = changedFrom.filter { !auxiliaries.contains($0) }
        let verbsTo = changedTo.filter { !auxiliaries.contains($0) }
        func regularForms(_ word: String) -> Set<String> {
            var forms: Set<String> = [word]
            for suffix in ["ing", "ed", "es", "s", "d"] where word.hasSuffix(suffix) && word.count > suffix.count + 2 {
                forms.insert(String(word.dropLast(suffix.count)))
            }
            return forms
        }
        if !verbsFrom.isEmpty, verbsFrom.count == verbsTo.count,
           zip(verbsFrom, verbsTo).allSatisfy({ !regularForms($0).isDisjoint(with: regularForms($1)) }) {
            return .accepted("grammar")
        }
        if hasCue, isSubsequence(to.filter { !from.contains($0) }, of: []) { return .accepted("selfcorrection") }
        return .refused("meaning")
    }

    static func inflection(_ a: String, _ b: String) -> Bool {
        if functionWords.contains(a) && functionWords.contains(b) { return true }
        let prefix = zip(a, b).prefix { $0 == $1 }.count
        return prefix >= 3 && prefix >= min(a.count, b.count) - 3 || PhoneticKey.soundsAlike(a, b)
    }

    static func isSubsequence(_ small: [String], of large: [String]) -> Bool {
        var index = large.startIndex
        for word in small {
            guard let found = large[index...].firstIndex(of: word) else { return false }
            index = large.index(after: found)
        }
        return true
    }

    static func removedWords(_ from: [String], keeping kept: [String]) -> [String] {
        var remaining = kept
        return from.filter { word in
            if let i = remaining.firstIndex(of: word) { remaining.remove(at: i); return false }
            return true
        }
    }

    static func hasStutter(_ words: [String]) -> Bool {
        zip(words, words.dropFirst()).contains { $0 == $1 }
    }
}

/// Rewrite-then-validate: the model rewrites a passage freely, the rewrite is
/// aligned with the source word by word, and each changed stretch must pass
/// `EditValidator`. A refused stretch takes its whole clause back to the
/// source wording, still punctuated, so a revert never leaves a half-edited
/// sentence ("We need the team needs…"). One doubtful change no longer costs
/// the whole passage, as the former whole-document gate did.
enum RewriteValidation {
    struct Result: Sendable {
        let text: String
        /// Changed stretches by verdict and reason ("accepted.sound", "refused.meaning").
        let counts: [String: Int]
        let revertedClauses: Int
        /// Proposed changes that are not in `text`: refused, or reverted with their clause ("clause").
        let refused: [Refusal]
    }

    struct Refusal: Sendable, Equatable { let original: String; let replacement: String; let reason: String }

    struct Token { let text: String; let trailing: String; let key: String; let marker: Bool }

    /// Words with the whitespace after them. Markdown markers (-, *, 1.) and bare
    /// punctuation are kept in place but take no part in the alignment.
    static func tokenize(_ text: String) -> [Token] {
        guard let regex = try? NSRegularExpression(pattern: #"(\S+)(\s*)"#) else { return [] }
        let source = text as NSString
        var lineStart = true
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let word = source.substring(with: match.range(at: 1)), trailing = source.substring(with: match.range(at: 2))
            let key = EditValidator.words(word).joined(separator: " ")
            let marker = key.isEmpty || (lineStart && word.range(of: #"^(\d+[.)]|#+)$"#, options: .regularExpression) != nil)
            lineStart = trailing.contains("\n")
            return Token(text: word, trailing: trailing, key: marker ? "" : key, marker: marker)
        }
    }

    private enum Op { case same(source: Int, rewrite: Int), change(source: [Int], rewrite: [Int]) }

    /// Expanded forms and the contraction a speaker says as one word.
    static let contractions: [String: String] = [
        "they are": "they're", "we are": "we're", "you are": "you're", "i am": "I'm", "it is": "it's", "it has": "it's",
        "that is": "that's", "there is": "there's", "what is": "what's", "he is": "he's", "she is": "she's", "let us": "let's",
        "do not": "don't", "does not": "doesn't", "did not": "didn't", "is not": "isn't", "are not": "aren't", "was not": "wasn't",
        "were not": "weren't", "can not": "can't", "cannot": "can't", "will not": "won't", "would not": "wouldn't",
        "should not": "shouldn't", "could not": "couldn't", "have not": "haven't", "has not": "hasn't",
        "i will": "I'll", "we will": "we'll", "you will": "you'll", "they will": "they'll",
        "i have": "I've", "we have": "we've", "they have": "they've", "i would": "I'd"]

    static func validate(source: String, rewrite: String, vocabulary: [String]) -> Result {
        let src = tokenize(source).filter { !$0.marker }
        var rw = tokenize(rewrite)
        var dropped = Set<Int>()
        let aligned = rw.indices.filter { !rw[$0].marker }
        let x = src.map(\.key), y = aligned.map { rw[$0].key }
        var lcs = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = [], from: [Int] = [], to: [Int] = []
        func flush() { if !from.isEmpty || !to.isEmpty { ops.append(.change(source: from, rewrite: to)); from = []; to = [] } }
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] { flush(); ops.append(.same(source: i, rewrite: aligned[j])); i += 1; j += 1 }
            else if j < y.count, i == x.count || lcs[i][j + 1] >= lcs[i + 1][j] { to.append(aligned[j]); j += 1 }
            else { from.append(i); i += 1 }
        }
        flush()

        // Judge each changed stretch.
        var counts: [String: Int] = [:]
        var reasons = Array(repeating: "", count: ops.count)
        let contextCues = EditValidator.cues.filter { $0 != "no" }
        let refused: [Bool] = ops.enumerated().map { index, op in
            guard case .change(let s, let r) = op else { return false }
            let original = s.map { src[$0].text }.joined(separator: " "), replacement = r.map { rw[$0].text }.joined(separator: " ")
            let verdict: EditValidator.Verdict
            if r.isEmpty, original.range(of: #"(?i)\b(scratch|strike|delete|forget)\s+that\b"#, options: .regularExpression) != nil {
                // Dropping only the cue would keep what the speaker retracted. Keep the
                // cue; `resolveRetractions` then removes it with the retracted words.
                counts["kept.retraction", default: 0] += 1; return true
            } else if s.isEmpty {
                // Pure insertion: only small function words may appear from nowhere.
                verdict = r.allSatisfy({ EditValidator.functionWords.contains(rw[$0].key) }) && EditValidator.meaningAnchors(replacement).isEmpty
                    ? .accepted("grammar") : .refused("insertion")
            } else {
                verdict = EditValidator.validate(ProposedEdit(original: original, replacement: replacement, kind: "rewrite"), vocabulary: vocabulary)
            }
            switch verdict {
            case .accepted(let reason):
                counts["accepted." + reason, default: 0] += 1
                // The speaker said one word ("there", "don't"); the model wrote two ("they are",
                // "does not"). Keep the speaker's voice: write the contraction.
                if s.count == 1, r.count >= 2 {
                    for k in 0..<(r.count - 1) {
                        let pair = rw[r[k]].key + " " + rw[r[k + 1]].key
                        guard let short = contractions[pair], !dropped.contains(r[k]) else { continue }
                        let first = rw[r[k]].text, second = rw[r[k + 1]].text
                        let cased = first.first?.isUppercase == true ? short.prefix(1).uppercased() + short.dropFirst() : short
                        let tail = String(second.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                        rw[r[k]] = Token(text: cased + tail, trailing: rw[r[k + 1]].trailing, key: short.lowercased(), marker: false)
                        dropped.insert(r[k + 1])
                        counts["kept.contraction", default: 0] += 1
                    }
                }
                return false
            case .refused("deletion"):
                // A correction cue just before the stretch ("we need to, I mean, the team
                // needs") licenses dropping the abandoned words even when the alignment
                // split the cue into its own stretch.
                let context = src[max(0, s[0] - 4)..<s[0]].map(\.key).joined(separator: " ")
                if contextCues.contains(where: { context.range(of: #"\b"# + $0 + #"\b"#, options: .regularExpression) != nil }) {
                    counts["accepted.selfcorrection", default: 0] += 1; return false
                }
                counts["refused.deletion", default: 0] += 1; reasons[index] = "deletion"; return true
            case .refused(let reason): counts["refused." + reason, default: 0] += 1; reasons[index] = reason; return true
            }
        }

        // Clauses end at a rewrite token closing with , ; : . ! ? or a line break.
        func closesClause(_ index: Int) -> Bool {
            rw[index].trailing.contains("\n") || rw[index].text.last.map { ",;:.!?".contains($0) } == true
        }
        var output = "", reverted = 0
        var refusals: [Refusal] = []
        var clauseOps: [Int] = [], rewriteStart = 0
        func emitClause(through rewriteEnd: Int) {
            defer { clauseOps = []; rewriteStart = rewriteEnd + 1 }
            let span = rewriteStart <= rewriteEnd ? Array(rewriteStart...rewriteEnd).filter { !dropped.contains($0) } : []
            guard clauseOps.contains(where: { refused[$0] }) else {
                output += span.map { rw[$0].text + rw[$0].trailing }.joined()
                return
            }
            reverted += 1
            for index in clauseOps {
                guard case .change(let s, let r) = ops[index] else { continue }
                // A kept retraction cue is not a refusal: it is resolved below.
                guard !refused[index] || !reasons[index].isEmpty || !r.isEmpty else { continue }
                refusals.append(Refusal(original: s.map { src[$0].text }.joined(separator: " "),
                                        replacement: r.filter { !dropped.contains($0) }.map { rw[$0].text }.joined(separator: " "),
                                        reason: refused[index] ? reasons[index] : "clause"))
            }
            let sources = clauseOps.flatMap { index -> [Int] in
                switch ops[index] { case .same(let s, _): [s]; case .change(let s, _): s }
            }
            let markers = span.prefix { rw[$0].marker }.map { rw[$0].text + rw[$0].trailing }.joined()
            // Sentence starts are capitalized by `tidy`.
            var text = sources.map { src[$0].text }.joined(separator: " ")
            let dangling: Set<String> = ["and", "or", "but", "to", "of", "with", "for", "from", "the", "a", "an"]
            let endsOnConnector = EditValidator.words(text).last.map(dangling.contains) ?? false
            if let last = span.last, let mark = rw[last].text.last, ",;:.!?".contains(mark),
               !(endsOnConnector && ".!?".contains(mark)),
               text.last.map({ !",;:.!?".contains($0) }) ?? false {
                text.append(mark)
            }
            // A refused deletion after the last rewrite token belongs to that
            // sentence, not a new fragment ("the export.later.").
            if span.isEmpty, !text.isEmpty {
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let last = output.last, ".!?".contains(last) { output.removeLast() }
            }
            if !output.isEmpty, !text.isEmpty, output.last?.isWhitespace == false { output += " " }
            output += markers + text + (span.last.map { rw[$0].trailing } ?? " ")
        }
        var lastRewrite = -1
        func endsSentence(_ token: Token) -> Bool {
            token.text.last.map { ".!?".contains($0) } == true || token.trailing.contains("\n\n")
        }
        for (index, op) in ops.enumerated() {
            // An omitted complete sentence is independent of the next edited
            // clause. Restore it without undoing valid grammar in that clause.
            if refused[index], !reasons[index].isEmpty, case .change(let s, let r) = op,
               r.isEmpty, let first = s.first, let last = s.last,
               (first == 0 || endsSentence(src[first - 1])), endsSentence(src[last]) {
                emitClause(through: lastRewrite)
                if output.last?.isWhitespace == false { output += " " }
                let original = s.map { src[$0].text + src[$0].trailing }.joined()
                output += original
                if output.last?.isWhitespace == false { output += " " }
                refusals.append(Refusal(original: original.trimmingCharacters(in: .whitespacesAndNewlines),
                                        replacement: "", reason: reasons[index]))
                reverted += 1
                continue
            }
            clauseOps.append(index)
            let last: Int? = switch op { case .same(_, let r): r; case .change(_, let r): r.last }
            if let last { lastRewrite = last }
            if let last, closesClause(last), index + 1 < ops.count { emitClause(through: last) }
        }
        emitClause(through: rw.count - 1)
        // An explicit "scratch that" retracts the sentence before it. Give an
        // unpunctuated cue its sentence boundaries so it can be resolved.
        // A cue after a subject or helper verb ("I need to scratch that itch") is an ordinary verb.
        let helpers = "to|will|would|can|could|should|must|might|may|please|just|i|we|you|they|he|she|it|i'll|we'll|you'll|let's|don't|didn't|gonna|wanna"
        let bounded = output.replacingOccurrences(of: #"(?i)(?<![\p{L}'’])(?!(?:"# + helpers + #")[ \t])([\p{L}\p{N}'’]+)[ \t]+((?:scratch|strike|delete|forget)[ \t]+that)[ \t]+(?=[\p{L}])"#,
                                                  with: "$1. $2. ", options: .regularExpression)
        let resolved = SpeechCorrections.resolveRetractions(bounded)
        return Result(text: EditCleanup.tidy(resolved), counts: counts, revertedClauses: reverted, refused: refusals)
    }

    /// "cloud code" → "Claude Code": a run of words that sounds exactly like a
    /// multi-word vocabulary term takes the term's spelling. Single words are left
    /// to the model and the user's replacements: "cloud" alone is usually cloud.
    static func matchSpokenTerms(_ text: String, vocabulary: [String]) -> String {
        var output = text
        for term in vocabulary {
            let termWords = term.split(whereSeparator: \.isWhitespace)
            guard termWords.count >= 2, termWords.count <= 4 else { continue }
            let key = termWords.map { PhoneticKey.key(String($0)) }
            guard !key.contains("") else { continue }
            let tokens = output.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard tokens.count >= key.count else { continue }
            let protected = DictationLiterals.ranges(in: output)
            var offsets = [Int](), offset = 0
            for token in tokens { offsets.append(offset); offset += token.utf16.count + 1 }
            var rebuilt: [String] = [], index = 0
            while index < tokens.count {
                let window = tokens[index..<min(tokens.count, index + key.count)]
                let bare = window.map { $0.trimmingCharacters(in: .punctuationCharacters) }
                let span = NSRange(location: offsets[index], length: window.joined(separator: " ").utf16.count)
                if window.count == key.count, bare.map({ PhoneticKey.key($0) }) == key, bare.joined(separator: " ") != term,
                   !protected.contains(where: { NSIntersectionRange($0, span).length > 0 }) {
                    let head = String(window.first!.prefix { !$0.isLetter && !$0.isNumber })
                    let tail = String(window.last!.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                    rebuilt.append(head + term + tail); index += key.count
                } else { rebuilt.append(tokens[index]); index += 1 }
            }
            output = rebuilt.joined(separator: " ")
        }
        return output
    }

    /// "k q l" → "KQL" and "i o c s" → "IOCs" when the spelled letters form a
    /// vocabulary term. Only exact vocabulary matches collapse, so ordinary
    /// single-letter words ("a", "I") are untouched.
    static func collapseSpelledTerms(_ text: String, vocabulary: [String]) -> String {
        let terms = Dictionary(vocabulary.map { ($0.lowercased().filter { $0.isLetter || $0.isNumber }, $0) }, uniquingKeysWith: { a, _ in a })
        guard !terms.isEmpty, let regex = try? NSRegularExpression(pattern: #"(?i)\b(?:[a-z][ \t]+){1,7}[a-z]\b"#) else { return text }
        var output = text
        let protected = DictationLiterals.ranges(in: text)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: output) else { continue }
            let letters = output[range].filter(\.isLetter).lowercased()
            // Longest run first, then drop leading letters ("a k q l" → "a KQL").
            for start in 0..<max(1, letters.count - 1) {
                let key = String(letters.dropFirst(start))
                guard key.count >= 2, let term = terms[key] else { continue }
                let kept = output[range].split(whereSeparator: \.isWhitespace).prefix(start).joined(separator: " ")
                output.replaceSubrange(range, with: kept.isEmpty ? term : kept + " " + term)
                break
            }
        }
        return output
    }
}

/// Capitalizes names the model left lowercase: vocabulary terms in their taught
/// spelling, weekdays and months, and words NaturalLanguage recognizes as a
/// person, place or organization once capitalized ("tell priya" → "tell Priya").
/// A probe alone also capitalizes ordinary words in name-like positions
/// ("wire", "bar"), so a word must also be missing from the English word
/// embedding, whose vocabulary holds common words but not names.
@MainActor
enum ProperNouns {
    private static let commonWords = NLEmbedding.wordEmbedding(for: .english)

    private static let calendar: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "april", "june", "july", "august", "september", "october", "november", "december"]

    static func capitalize(_ text: String, vocabulary: [String]) -> String {
        var output = text
        for term in vocabulary where term.contains(where: \.isUppercase) {
            let pattern = #"(?i)(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}_])"#
            output = output.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: term), options: .regularExpression)
        }
        guard output.count <= 4000, !output.contains("`") else { return output }
        let tagger = NLTagger(tagSchemes: [.nameType])
        var changes: [Range<String.Index>] = []
        output.enumerateSubstrings(in: output.startIndex..., options: .byWords) { word, range, _, _ in
            guard let word, let first = word.first, first.isLowercase, word.count > 2,
                  !EditValidator.functionWords.contains(word), !EditValidator.fillers.contains(word) else { return }
            if calendar.contains(word) { changes.append(range); return }
            guard let commonWords = Self.commonWords, !commonWords.contains(word) else { return }
            // Probe: does this word read as a name when capitalized in its sentence?
            var probe = output
            probe.replaceSubrange(range, with: word.prefix(1).uppercased() + word.dropFirst())
            tagger.string = probe
            let (tag, _) = tagger.tag(at: probe.index(probe.startIndex, offsetBy: output.distance(from: output.startIndex, to: range.lowerBound)),
                                      unit: .word, scheme: .nameType)
            if let tag, [NLTag.personalName, .placeName, .organizationName].contains(tag) { changes.append(range) }
        }
        for range in changes.reversed() { output.replaceSubrange(range, with: output[range].prefix(1).uppercased() + output[range].dropFirst()) }
        return output
    }
}
