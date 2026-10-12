import Foundation
import NaturalLanguage

/// Filler phrases that never carry meaning in dictation, removed before the model
/// sees the text. Deliberately narrow: single words such as "like" or "right" can
/// be meaningful, so the model decides those from context.
public enum SpokenFillers {
    /// "I don't know what we call it" and close variants: a hedge, not a negation.
    static let hedge = #"(?i)\bI\s+(?:don't|do\s+not|dunno)\s+(?:know\s+)?what\s+(?:we|you|they|I|people)(?:'d|\s+would|\s+should|\s+will)?\s+call\s+(?:it|that|this|them)\b,?(?:\s+but\b,?)?"#
    /// "like you know" used as a pause.
    static let pause = #"(?i)\blike,?\s+you\s+know\b,?"#
    public static func remove(_ text: String, language: String?) -> String {
        guard language == "en" else { return text }
        var output = text
        for pattern in [hedge, pause] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let protected = DictationLiterals.ranges(in: output)
            let source = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: source.length)).reversed() {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      let range = Range(match.range, in: output) else { continue }
                output.replaceSubrange(range, with: " ")
            }
        }
        output = output.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    /// Text with filler hedges removed, for counting negations that carry meaning.
    static func withoutHedges(_ text: String) -> String {
        text.replacingOccurrences(of: hedge, with: " ", options: .regularExpression)
    }
}

/// Splits a long dictation into pieces the on-device model can edit reliably, at
/// sentence ends where possible, otherwise before discourse markers, never inside
/// a word. A short paragraph stays whole.
public enum DictationChunker {
    /// The on-device model drops or summarizes more as input grows, and a guard
    /// refusal costs the whole piece, so dictations over 60 words are edited in
    /// pieces. Measured 2026-10-05: the model largely serializes concurrent sessions
    /// (6 pieces: 16.1 s sequential, 14.0 s concurrent), so fewer, larger pieces are
    /// faster; but a mid-length dictation edited whole lost all of its cleanup to one
    /// dropped word (the 110-word fixture passed 2/5), and in halves it passed 5/5.
    public static let wholeLimit = 60
    public static let targetWords = 100

    /// Piece size for a dictation of `words` words: about half for a mid-length
    /// dictation (so one refused piece never costs all of it), ~100 for long ones.
    public static func pieceWords(forTotal words: Int) -> Int { min(targetWords, max(40, words / 2)) }

    public static func chunks(_ text: String, wholeLimit: Int = wholeLimit, targetWords: Int = targetWords) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > wholeLimit else { return [text] }
        // Keep the speaker's paragraph boundaries when a long dictation is
        // divided for the model. The old word split flattened every blank line.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n[ \t]*\n"#, with: "\n\n", options: .regularExpression)
        if normalized.contains("\n\n"), !text.contains("```"), !text.contains("~~~") {
            let paragraphs = normalized.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if paragraphs.count > 1 {
                return paragraphs.enumerated().flatMap { index, paragraph in
                    var parts = chunks(paragraph, wholeLimit: wholeLimit, targetWords: targetWords)
                    if index > 0 { parts[0] = "\n\n" + parts[0] }
                    return parts
                }
            }
        }
        let markers: Set<String> = ["so", "and", "but", "then", "also", "same", "okay", "ok", "now"]
        var chunks: [String] = []
        var current: [Substring] = []
        func flush() { if !current.isEmpty { chunks.append(current.joined(separator: " ")); current = [] } }
        for (index, word) in words.enumerated() {
            current.append(word)
            let endsSentence = word.last.map { ".?!".contains($0) } ?? false
            let next = index + 1 < words.count ? words[index + 1].lowercased().trimmingCharacters(in: .punctuationCharacters) : ""
            if current.count >= targetWords && endsSentence { flush() }
            else if current.count >= targetWords + targetWords / 4 && (word.hasSuffix(",") || markers.contains(next)) { flush() }
            else if current.count >= targetWords * 3 / 2 { flush() }
        }
        flush()
        // Never leave a tiny tail on its own.
        if chunks.count > 1, let last = chunks.last, last.split(whereSeparator: \.isWhitespace).count < targetWords / 4 {
            chunks.removeLast(); chunks[chunks.count - 1] += " " + last
        }
        return chunks
    }

    /// Sentences as NLTokenizer sees them, for telemetry (counts only).
    public static func sentenceCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).count
    }

    /// Joins edited pieces into one text. Where the source was cut mid-sentence, the
    /// next piece continues the previous sentence (its period and capital, added by
    /// the model at the cut, are undone). Existing source paragraphs and model-added paragraph breaks are preserved.
    public static func join(_ pieces: [String], sources: [String]? = nil, structured: Bool) -> String {
        var output = ""
        for (index, piece) in pieces.enumerated() {
            var text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !structured {
                text = text.replacingOccurrences(of: #"[ \t]+\n(?=\n)"#, with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: #"[ \t]+\n"#, with: " ", options: .regularExpression)
            }
            guard !text.isEmpty else { continue }
            if output.isEmpty { output = text; continue }
            let source = sources.flatMap { index < $0.count ? $0[index] : nil }
            let previousSource = sources.flatMap { index - 1 < $0.count ? $0[index - 1] : nil }
            let startsParagraph = source?.hasPrefix("\n\n") == true
            let cutMidSentence = previousSource.map { !($0.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".?!".contains($0) } ?? false) }
                ?? (text.first?.isLowercase ?? false)
            if cutMidSentence && !startsParagraph {
                if output.hasSuffix(".") { output.removeLast() }
                if let first = text.first, first.isUppercase, source?.first?.isLowercase == true, !text.hasPrefix("I ") {
                    text = first.lowercased() + text.dropFirst()
                }
            }
            output += (startsParagraph ? "\n\n" : " ") + text
        }
        return output
    }
}

/// How much of the dictation's content survived an edit. A cleanup removes filler
/// and fixes a few misheard words; it never drops a fifth of what was said.
public enum ContentCoverage {
    static let ignored: Set<String> = [
        "the", "and", "but", "that", "this", "with", "for", "from", "then", "there", "their", "they", "them",
        "like", "know", "just", "kind", "sort", "stuff", "really", "actually", "basically", "right", "okay",
        "wanna", "gonna", "want", "going", "what", "call", "don't", "dont", "i'm", "we're", "it's", "let's",
        "can", "could", "would", "should", "will", "have", "has", "had", "are", "was", "were", "been", "being",
        "all", "our", "your", "you", "its", "also", "maybe", "think", "see", "get", "got", "thing", "things"
    ]

    static func contentWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { $0.count >= 3 && !ignored.contains($0) }
    }

    /// Fraction of the source's distinct content words found in the edit (by stem).
    public static func fraction(source: String, edited: String) -> Double {
        func stem(_ word: String) -> String {
            for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
                return String(word.dropLast(suffix.count))
            }
            return word
        }
        let wanted = Set(contentWords(source).map(stem))
        guard !wanted.isEmpty else { return 1 }
        let present = Set(contentWords(edited).map(stem))
        return Double(wanted.intersection(present).count) / Double(wanted.count)
    }
}

/// Nouns, names and glossary terms must survive an edit. Fluent rewrites can drop a
/// single word ("Claude released mods" → "Claude released"); counting distinct
/// words cannot see that, so each occurrence is counted. Case-insensitive and
/// lemma-tolerant ("mod"/"mods"); filler nouns ("stuff", "kind of") are exempt.
public enum ContentTerms {
    static let fillerNouns: Set<String> = ["stuff", "kind", "sort", "thing", "things", "lot", "bit", "way", "guy", "guys", "um", "uh"]

    struct Term: Hashable { let key: String; let word: String }

    static func terms(in text: String, vocabulary: [String]) -> [Term] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .lemma])
        tagger.string = text
        var terms: [Term] = []
        var previous: String?
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = text[range].lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            let name = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0
            let isName = [NLTag.personalName, .placeName, .organizationName].contains(name)
            let isTerm = vocabulary.contains(word)
            guard (tag == .noun || isName || isTerm), word.count >= 2, word.contains(where: \.isLetter),
                  !fillerNouns.contains(word) else { previous = nil; return true }
            let key = key(word, lemma: tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue)
            // An accidental immediate repeat ("table table") may be removed.
            if key != previous { terms.append(Term(key: key, word: word)) }
            previous = key
            return true
        }
        return terms
    }

    static func key(_ word: String, lemma: String?) -> String {
        if let lemma = lemma?.lowercased(), !lemma.isEmpty { return lemma }
        for suffix in ["es", "s"] where word.count > suffix.count + 2 && word.hasSuffix(suffix) { return String(word.dropLast(suffix.count)) }
        return word
    }

    /// Source terms that occur fewer times in the candidate than in the source.
    public static func missing(source: String, candidate: String, vocabulary: String = "") -> [String] {
        let glossary = vocabulary.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        let required = terms(in: source, vocabulary: glossary)
        guard !required.isEmpty else { return [] }
        // Candidate side: every word, by surface form, lemma and plural stem.
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = candidate
        var available: [String: Int] = [:]
        tagger.enumerateTags(in: candidate.startIndex..<candidate.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitWhitespace, .omitPunctuation]) { lemma, range in
            let word = candidate[range].lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            for form in Set([word, key(word, lemma: lemma?.rawValue), key(word, lemma: nil)]) { available[form, default: 0] += 1 }
            return true
        }
        // Words the edit joined or hyphenated ("set up" → "setup", "plug in" → "plug-in").
        let compact = candidate.lowercased().filter { $0.isLetter || $0.isNumber }
        var missing: [String] = []
        for (key, group) in Dictionary(grouping: required, by: \.key) {
            let word = group[0].word
            let found = max(available[key] ?? 0, available[word] ?? 0)
            guard found < group.count else { continue }
            if word.count >= 3, compact.components(separatedBy: word).count - 1 >= group.count { continue }
            missing.append(word)
        }
        return missing.sorted()
    }
}

extension ContentTerms {
    /// Nouns, names and glossary terms in the candidate that the speaker never said.
    /// The model must not insert content: a glossary term just because it was
    /// offered ("OmniFlow"), or words copied from the prompt's example.
    public static func added(source: String, candidate: String, vocabulary: String = "") -> [String] {
        let glossary = Set(vocabulary.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 })
        let spoken = Set(source.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let compactSource = source.lowercased().filter { $0.isLetter || $0.isNumber }
        let sourceKeys = Set(terms(in: source, vocabulary: []).map(\.key))
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .lemma])
        tagger.string = candidate
        var added: Set<String> = []
        tagger.enumerateTags(in: candidate.startIndex..<candidate.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let phrase = candidate[range].lowercased()
            let words = phrase.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let isName = [NLTag.personalName, .placeName, .organizationName].contains(tag)
            let isNoun = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0 == .noun
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            for word in words where word.count >= 2 && word.contains(where: \.isLetter) && !fillerNouns.contains(word) {
                guard isName || isNoun || glossary.contains(word) else { continue }
                // Nouns the speaker did not say: inserted content, often copied from the prompt's example.
                if spoken.contains(word) || compactSource.contains(word) || sourceKeys.contains(key(word, lemma: lemma))
                    || sourceKeys.contains(key(word, lemma: nil)) { continue }
                added.insert(word)
            }
            return true
        }
        return added.sorted()
    }
}
