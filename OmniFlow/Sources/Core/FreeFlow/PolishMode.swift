import Foundation

public enum PolishMode: String, CaseIterable, Sendable {
    case verbatim, light, polished
    public var title: String {
        switch self { case .verbatim: "Verbatim"; case .light: "Light cleanup"; case .polished: "Polished" }
    }
    public var instructions: String {
        switch self {
        case .verbatim: "Return the original words."
        case .light: "Keep the speaker's wording. Split run-on speech into sentences with correct punctuation and capitalization, delete filler words and hesitation sounds, and fix only clearly misheard words. Do not rewrite for style or reorder thoughts."
        case .polished: """
            Reconstruct the speaker's final intended message as clear, grammatical writing.
            Break run-on speech into complete sentences, one thought per sentence, and into paragraphs where the topic changes or an explanation leads to a distinct conclusion or next step.
            Repair broken grammar: wrong tense or verb form, agreement, missing small words, doubled words and fragments.
            Remove abandoned sentence starts, accidental repetitions, filler and hesitation.
            Keep only the final explicit self-correction, including corrected people, dates and quantities.
            Preserve every substantive point, request, condition, uncertainty, emphasis and final intended fact.
            Improve flow without summarizing, embellishing, adding explanations or changing the speaker's position.
            Fix a misheard word only when the context makes the intended word unambiguous; when it is ambiguous, keep the recognized words. Never invent a fact, name or number.
            """
        }
    }
    /// Explicit topic transitions supply reliable paragraph boundaries even
    /// when the model punctuates correctly but leaves one wall of text.
    static func separateTopics(_ text: String) -> String {
        guard !text.contains("```"), !text.contains("~~~"),
              let pattern = try? NSRegularExpression(pattern: #"(?i)([.!?])[ \t]+(?=(?:separately|on another note|on a separate note|moving on|turning to|as for|back to)\b)"#) else { return text }
        var output = text
        let protected = DictationLiterals.ranges(in: text)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let span = NSRange(location: match.range.location, length: min((text as NSString).length - match.range.location, match.range.length + 1))
            guard !protected.contains(where: { NSIntersectionRange($0, span).length > 0 }),
                  let range = Range(match.range, in: output) else { continue }
            let punctuation = (text as NSString).substring(with: match.range(at: 1))
            output.replaceSubrange(range, with: punctuation + "\n\n")
        }
        return output
    }

    /// A gerund subject followed by an orphaned contrast and copula is a
    /// broken sentence, not three separate thoughts. Keep the uncertainty.
    static func repairConclusionFragments(_ text: String) -> String {
        let pattern = #"(?i)\b((?:so[ \t]+)?(?:switching|replacing|using|choosing|upgrading|moving|changing|trying)[^.!?\n]{1,160})\.[ \t]+instead of[ \t]+([^.!?\n,]{1,100}),?[ \t]+maybe[ \t]+((?:the|a|an|our)[^.!?\n]{1,100})([.!?]|$)"#
        return replaceUnquoted(text, pattern: pattern) { source, match in
            let subject = source.substring(with: match.range(at: 1))
            guard subject.range(of: #"(?i)\b(?:is|are|was|were|has|have|had|will|would|can|could|should|must|may|might|worked|works|failed|fails|helped|helps)\b"#, options: .regularExpression) == nil else {
                return source.substring(with: match.range)
            }
            return subject + " instead of "
                + source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                + " may be " + source.substring(with: match.range(at: 3))
                + source.substring(with: match.range(at: 4))
        }
    }

    /// Canonical API spellings only when the passage is explicitly about APIs.
    /// These are not general replacements for someone's diction or transcription.
    static func speechAPISpelling(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { paragraph in
            guard paragraph.range(of: #"(?i)\b(?:API|APIs|SpeechAnalyzer|SpeechTranscriber|DictationTranscriber)\b"#, options: .regularExpression) != nil,
                  paragraph.range(of: #"(?i)\b(?:speech|dictation|diction)[ \t,]+(?:transcription[ \t]+or[ \t]+)?transcriber\b"#, options: .regularExpression) != nil else { return paragraph }
            var result = replaceUnquoted(paragraph, pattern: #"(?i)\bspeech(?:[ \t]*,[ \t]*transcription[ \t]+or[ \t]+|[ \t]+)transcriber\b"#) { _, _ in "SpeechTranscriber" }
            result = replaceUnquoted(result, pattern: #"(?i)\b(?:dictation|diction)[ \t]+transcriber\b"#) { _, _ in "DictationTranscriber" }
            return result
        }.joined(separator: "\n\n")
    }

    /// A developed explanation followed by a proposed solution gets breathing
    /// room. A bare "so" or a short two-sentence thought is insufficient evidence.
    static func separateConclusions(_ text: String) -> String {
        let pattern = #"(?i)([.!?])[ \t]+(?=(?:so[ \t]+)?(?:switching|replacing|using|choosing|upgrading|moving|changing|trying)\b[^.!?\n]{1,200}\b(?:may be|might be|could be|is|seems to be)\b[^.!?\n]{0,60}\b(?:key|solution|fix|next step|answer|approach)\b)"#
        return replaceUnquoted(text, pattern: pattern) { source, match in
            let before = source.substring(to: match.range.location)
                .components(separatedBy: "\n\n").last ?? ""
            guard before.split(whereSeparator: \.isWhitespace).count >= 25,
                  before.contains(where: { ".!?".contains($0) }) else {
                return source.substring(with: match.range)
            }
            return source.substring(with: match.range(at: 1)) + "\n\n"
        }
    }

    private static func replaceUnquoted(_ text: String, pattern: String,
                                        replacement: (NSString, NSTextCheckingResult) -> String) -> String {
        guard !text.contains("```"), !text.contains("~~~"),
              let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString, protected = DictationLiterals.ranges(in: text)
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: output) else { continue }
            // Look-ahead paragraph rules must also protect the following clause.
            let next = NSMaxRange(match.range)
            if protected.contains(where: { NSLocationInRange(next, $0) }) { continue }
            output.replaceSubrange(range, with: replacement(source, match))
        }
        return output
    }

    /// A common recognizer substitution that a dictionary cannot distinguish.
    /// Require nearby security evidence and leave ambiguous/literal fishing alone.
    static func contextualSpelling(_ text: String) -> String {
        guard !text.contains("```"), !text.contains("~~~"),
              let regex = try? NSRegularExpression(pattern: #"(?i)\bfishing(?=[ \t]+e-?mails?\b)"#) else { return text }
        let source = text as NSString
        let protected = DictationLiterals.ranges(in: text)
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: output) else { continue }
            let start = max(0, match.range.location - 240)
            let end = min(source.length, NSMaxRange(match.range) + 240)
            // Do not borrow evidence across a paragraph/topic boundary.
            let before = source.substring(with: NSRange(location: start, length: match.range.location - start))
                .components(separatedBy: "\n\n").last ?? ""
            let after = source.substring(with: NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)))
                .components(separatedBy: "\n\n").first ?? ""
            let context = before + "fishing" + after
            let security = #"(?i)\b(suspicious|malicious|cybersecurity|scams?|security team)\b|\b(?:steal|stolen|harvest|fake)\b.{0,40}\b(?:passwords?|credentials?)\b"#
            let literal = #"(?i)\b(fish|fishes|lake|river|angling|boats?|lures?|tackle|bait|trout|salmon|fishing trips?)\b"#
            guard context.range(of: security, options: .regularExpression) != nil,
                  context.range(of: literal, options: .regularExpression) == nil else { continue }
            let word = source.substring(with: match.range)
            let replacement = word == word.uppercased() ? "PHISHING" : word.first?.isUppercase == true ? "Phishing" : "phishing"
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    /// Spoken HTTP digits are identifiers, not quantities to add together. Require
    /// both network context and a local code/response cue; never guess other numbers.
    static func technicalStatusCodes(_ text: String) -> String {
        let digits = ["zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "for": "4",
                      "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"]
        let digit = "(?:[0-9]|zero|oh|one|two|three|four|five|six|seven|eight|nine)"
        let pattern = "(?i)\\b(?:[1-5]|one|two|three|four|for|five)[ \\t]+" + digit + "[ \\t]+" + digit + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString, protected = DictationLiterals.ranges(in: text)
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: output) else { continue }
            let prefix = ns.substring(to: match.range.location).components(separatedBy: "\n\n").last ?? ""
            let before = String(prefix.suffix(300))
            let after = ns.substring(from: NSMaxRange(match.range))
            guard before.range(of: #"(?i)\b(?:HTTP|HTTPS|API|server|endpoint|status code|response code)\b"#, options: .regularExpression) != nil,
                  before.range(of: #"(?i)\b(?:HTTP|status(?: code)?|response(?: code)?|error(?: code)?|returns?|returning|returned|responds?|responding|responded|(?:it|that) should be)[ \t]+(?:(?:an?|with)[ \t]+)?$"#, options: .regularExpression) != nil,
                  after.range(of: #"(?i)^[ \t]+(?:hours?|days?|minutes?|seconds?|people|dollars?|percent)\b"#, options: .regularExpression) == nil else { continue }
            let code = ns.substring(with: match.range).lowercased().split(whereSeparator: \.isWhitespace)
                .map { digits[String($0)] ?? String($0) }.joined()
            output.replaceSubrange(range, with: code)
        }
        return output
    }

    /// High-confidence grammar frames only. A literal "get her" and a stranded
    /// preposition ("refer to so…") are valid speech, not global replacements.
    static func contextualPhrases(_ text: String) -> String {
        var output = text
        let rules: [(String, String)] = [(#"(?i)\bto get her\b"#, "together"), (#"(?i)\bto(?=[ ,]+so[ \t]+(?:we|they|you|he|she|it|I)\b)"#, "too")]
        for (pattern, replacement) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = output as NSString, protected = DictationLiterals.ranges(in: output)
            for match in regex.matches(in: output, range: NSRange(location: 0, length: source.length)).reversed() {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      let range = Range(match.range, in: output) else { continue }
                let before = String(source.substring(to: match.range.location).components(separatedBy: CharacterSet(charactersIn: ".!?\n")).last!.suffix(200))
                let after = source.substring(from: NSMaxRange(match.range))
                let supported: Bool
                if replacement == "together" {
                    let objects = "(?:keys|certificates|files|packages|settings|changes|components|pieces|parts|tests|modules|widgets|systems|tools|services)"
                    let fitting = "(?i)\\b" + objects + #"[ \t]+(?:fit|work|operate|function|run)[ \t]+$"#
                    let combining = #"(?i)\b(?:rotate|synchronize|combine|merge|compile|install|upgrade|deploy|bundle|update|ship)[ \t]+(?:(?:the|these|those|our|your|their)[ \t]+)?(?:[a-z-]+[ \t]+){0,2}"# + objects + #"[ \t]+$"#
                    supported = before.range(of: fitting, options: .regularExpression) != nil ||
                        (before.range(of: combining, options: .regularExpression) != nil && after.range(of: #"(?i)^[ \t]+with\b"#, options: .regularExpression) != nil)
                } else {
                    let destination = #"(?i)\bto[ \t]+(?:the|our|your|their|these|those)[ \t]+[a-z-]+(?:[ \t]+[a-z-]+)?[ \t]+$"#
                    let movement = #"(?i)\b(?:go|going|went|send|sent|sending|give|gave|giving|take|took|taking|bring|brought|bringing|deliver|delivered|delivering)\b"#
                    supported = before.range(of: destination, options: .regularExpression) != nil && before.range(of: movement, options: .regularExpression) != nil
                }
                if supported { output.replaceSubrange(range, with: replacement) }
            }
        }
        return output
    }

    public func prepare(_ raw: String, language: String?) -> String {
        guard self != .verbatim else { return raw }
        let base = SpokenFillers.remove(SpeechDisfluencies.clean(raw, language: language), language: language)
        guard self == .polished, language == "en" else { return base }
        let corrected = Self.repairConclusionFragments(Self.speechAPISpelling(SpeechCorrections.resolve(Self.contextualPhrases(Self.technicalStatusCodes(base)))))
        guard !corrected.contains("`"), !corrected.contains("~~~") else { return corrected }
        // Restrict deterministic restart removal to repeated grammatical prefixes.
        // Single-word emphasis (very very) and grammatical “that that” are untouched.
        let pattern = #"(?i)\b((?:I|we|you|they|he|she|it|the|a|an|please|can|could|would|do|don't|we're|I'm|let's)(?:[ \t]+[\p{L}\p{N}'’]+){1,7}|(?:within|in|on|at|for|from|with|to)[ \t]+(?:the|a|an|our|your|their|his|her|its|my))[ \t,]+\1\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return corrected }
        var output = corrected
        for _ in 0..<3 {
            let source = output as NSString
            let protected = DictationLiterals.ranges(in: output)
            let matches = regex.matches(in: output, range: NSRange(location: 0, length: source.length))
            var changed = false
            for match in matches.reversed() {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      let range = Range(match.range, in: output) else { continue }
                output.replaceSubrange(range, with: source.substring(with: match.range(at: 1)))
                changed = true
            }
            if !changed { break }
        }
        return output
    }
}
