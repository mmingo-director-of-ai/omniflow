import Foundation

public enum WritingStyle: String, CaseIterable, Sendable {
    case faithful, apa, technical
    public var title: String {
        switch self {
        case .faithful: "Keep my style"
        case .apa: "APA-inspired prose"
        case .technical: "ASD-STE100-inspired technical"
        }
    }
    public func format(_ text: String) -> String {
        guard self != .faithful else { return text }
        return NumericContent.format(text, style: self)
    }

    public var instructions: String {
        switch self {
        case .faithful:
            "Preserve the speaker's tone, formality and numeric spelling. Apply the selected cleanup level without imposing a different writing style."
        case .apa:
            """
            Use APA-inspired English prose conventions, not academic document formatting.
            Spell out ordinary counts zero through nine; use numerals for 10 and above.
            Use numerals for measurements with units, ages, dates, times, money, percentages,
            statistics, numbered identifiers and table data. Spell out a number at the start of a
            sentence or minimally rephrase. Preserve code, paths, versions, identifiers and quoted
            literals exactly. Never turn 'to' or 'too' into a number without clear numeric meaning.
            Do not add citations, sections, formal language or facts absent from the dictation.
            """
        case .technical:
            """
            Use clear technical prose with precise terms. Preserve the speaker's tense and the timing of events: past events stay past, planned events stay planned. Split long sentences without dropping details. Do not turn narration into commands. Use imperatives only when the speaker gives instructions. Use numerals for technical quantities. Keep identifiers, code, paths and versions exactly.
            """
        }
    }
}

/// Canonicalizes numeric meaning for validation, not presentation. The model decides
/// contextual presentation; this guard rejects changed quantities, including word numbers.
public enum NumericContent {
    private static let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    private static let scales = ["hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000]
    private static var word: String { "(?:" + (units + Array(tens.keys).sorted() + Array(scales.keys).sorted()).joined(separator: "|") + ")" }
    private static var phrase: String { word + "(?:[ -]+(?:and[ -]+)?" + word + ")*" }
    private static var literal: String { #"[+-]?\d+(?:,\d{3})*(?:\.\d+)?"# }
    private static var atom: String { "(?:" + literal + "|" + phrase + ")" }

    public static func values(_ text: String) -> [String] {
        let pattern = "(?i)" + literal + "|(?<![\\p{L}\\d_])" + phrase + "(?![\\p{L}\\d_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).flatMap { match -> [String] in
            let value = source.substring(with: match.range).lowercased()
            if value.contains(where: { $0.isNumber }) { return [value.replacingOccurrences(of: ",", with: "")] }
            let tokens = value.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init).filter { $0 != "and" }
            var total = 0, group = 0
            var result: [String] = []
            var previousSmall = false
            for token in tokens {
                // Malformed repeated scale words are data, never an arithmetic trap.
                guard group <= 1_000_000_000, total <= 1_000_000_000_000_000_000 else { return ["unparsed:" + value] }
                if let n = units.firstIndex(of: token) {
                    // "two three" is two quantities, not five.
                    if previousSmall { result.append(String(total + group)); total = 0; group = 0 }
                    group += n; previousSmall = true
                } else if let n = tens[token] {
                    if group % 100 != 0 { result.append(String(total + group)); total = 0; group = 0 }
                    group += n; previousSmall = false
                } else if let n = scales[token] {
                    if n == 100 { group = max(group, 1) * n }
                    else { total += max(group, 1) * n; group = 0 }
                    previousSmall = false
                }
            }
            result.append(String(total + group))
            return result
        }
    }


    public static func format(_ text: String, style: WritingStyle) -> String {
        let pattern = "(?i)(?<![\\p{L}\\d_./+-])(?:" + literal + "|" + phrase + ")(?![\\p{L}\\d_/]|\\.[\\p{L}\\d_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        let protected = DictationLiterals.ranges(in: text)
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.numberStyle = .spellOut
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            if protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            let original = source.substring(with: match.range)
            if original.hasPrefix("+") || (original.count > 1 && original.hasPrefix("0")) { continue }
            let quantities = values(original)
            guard quantities.count == 1, let value = Int(quantities[0]), value >= 0 else { continue }
            let before = source.substring(to: match.range.location)
            let after = source.substring(from: NSMaxRange(match.range))
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            // Keep line labels and Markdown table data as numerals. Quantities with
            // units, dates, ages, currency and identifiers also use numerals.
            let line = before.components(separatedBy: "\n").last ?? ""
            let unitPattern = #"(?i)^\s*(?:%|percent\b|seconds?\b|minutes?\b|hours?\b|days?\b|weeks?\b|months?\b|years?\s+old\b|ms\b|GB\b|MB\b|KB\b|TB\b|bytes?\b|kg\b|g\b|km\b|cm\b|mm\b|meters?\b|metres?\b|miles?\b|feet\b|inches\b|degrees?\b|dollars?\b|euros?\b|a\.?m\.?\b|p\.?m\.?\b)"#
            let prefixPattern = #"(?i)(?:[$€£¥]|\b(?:version|port|build|chapter|section|step|figure|table|at|January|February|March|April|May|June|July|August|September|October|November|December))\s*$"#
            let numericContext = after.range(of: unitPattern, options: .regularExpression) != nil
                || before.range(of: prefixPattern, options: .regularExpression) != nil
                || line.contains("|")
                || (line.trimmingCharacters(in: .whitespaces).isEmpty && after.hasPrefix(". "))
            let startsSentence = trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
            let replacement: String
            // "one of the", "no one", "this one": idiom, not a quantity. Keep the word.
            let idiomaticOne = !original.contains(where: \.isNumber) && original.lowercased() == "one"
                && (after.range(of: #"(?i)^\s+(?:of|another|by\s+one|or\s+two|or\s+another)\b"#, options: .regularExpression) != nil
                    || before.range(of: #"(?i)\b(?:no|any|every|each|which|this|that|the|one|someone)\s+$"#, options: .regularExpression) != nil)
            if idiomaticOne && !numericContext { continue }
            if style == .technical || numericContext { replacement = String(value) }
            else if value < 10 || startsSentence {
                guard let words = formatter.string(from: NSNumber(value: value)) else { continue }
                replacement = startsSentence ? words.prefix(1).uppercased() + words.dropFirst() : words
            } else { replacement = String(value) }
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    /// Only resolve a local, explicit correction with the same optional unit.
    /// Other corrections are left to the model and existing semantic guards.
    public static func resolvingCorrections(_ text: String) -> String {
        let cue = #"(?:no,?[ ]+(?:wait|sorry)(?:[, ]+I mean)?|wait|I meant|no(?:[, ]+I mean)?|sorry|I mean|make that|rather|actually)"#
        let pattern = "(?i)(?<![\\p{L}\\d_])" + atom + #"(?:[ \t]+((?!no\b|sorry\b|wait\b)[a-z]+))?(?:[ \t]*[,—–-][ \t]*|[ \t]+(?=(?:no|sorry|I mean|I meant|make that)\b))"# + cue + #"\s*[,—–-]?\s*("# + atom + #")(?:\s+\1\b)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var output = text
        let protected = DictationLiterals.ranges(in: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            if protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            // If there was a unit before the cue it must also follow the replacement.
            let unit = match.range(at: 1).location == NSNotFound ? "" : source.substring(with: match.range(at: 1))
            let number = source.substring(with: match.range(at: 2))
            let entire = source.substring(with: match.range)
            if !unit.isEmpty && !entire.lowercased().hasSuffix(unit.lowercased()) { continue }
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: number + (unit.isEmpty ? "" : " " + unit))
        }
        return output
    }
}

/// Local replacements only within a closed family; broad restarts remain ambiguous.
public enum SpeechCorrections {
    private static let nameCorrectionPattern = #"\b((?:[\p{L}'’]+[ \t]+){1,6})([A-Z][\p{L}'’-]*(?:[ \t]+[A-Z][\p{L}'’-]*){0,2})\s*[,—–]\s*(?i:sorry|actually|I meant|I mean|no,?[ ]+wait|wait|no|make that)\s*[,—–]?\s*(?i:\1)([A-Z][\p{L}'’-]*(?:[ \t]+[A-Z][\p{L}'’-]*){0,2})\b"#
    private static func nameCorrections(_ text: String) -> [NSTextCheckingResult] {
        guard !text.contains("`"), !text.contains("~~~"), let regex = try? NSRegularExpression(pattern: nameCorrectionPattern) else { return [] }
        let protected = DictationLiterals.ranges(in: text)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            !protected.contains { NSIntersectionRange($0, match.range).length > 0 }
        }
    }
    public static func finalCorrectedNames(in text: String) -> [String] {
        let source = text as NSString
        return nameCorrections(text).map { source.substring(with: $0.range(at: 3)) }
    }
    private static let families = [
        "Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday",
        "January|February|March|April|May|June|July|August|September|October|November|December",
        "red|orange|yellow|green|blue|purple|pink|black|white|gray|grey|brown",
        "left|right", "north|south|east|west"
    ]

    /// After resolving a closed-family correction, retain its final detail. This
    /// does not claim to validate arbitrary semantic rewrites by the model.
    public static func preservesCorrectedDetails(source: String, candidate: String) -> Bool {
        let corrected = resolve(source)
        guard corrected != source else { return true }
        let pattern = "(?i)\\b(?:" + families.joined(separator: "|") + ")\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        func details(_ text: String) -> [String] {
            let value = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: value.length))
                .map { value.substring(with: $0.range).lowercased() }.sorted()
        }
        return details(corrected) == details(candidate)
    }

    /// "Scratch that" (or strike / delete / forget that) standing alone at a clause
    /// boundary retracts what came just before it: the preceding sentence, or the
    /// clause before the cue within a sentence. "Scratch that itch" is not a cue.
    static func resolveRetractions(_ text: String) -> String {
        guard !text.contains("`"), !text.contains("~~~") else { return text }
        let cue = #"(?:scratch|strike|delete|forget)[ \t]+that"#
        let patterns = [
            // "Ship it today. Scratch that. Ship it Monday."
            #"(?i)(?:^|(?<=[.!?])[ \t]+)[^.!?\n]+[.!?][ \t]+"# + cue + #"[.!]?(?=[ \t]|$)[ \t]*"#,
            // "We ship today, scratch that, we ship Monday."
            #"(?i)(?:^|(?<=[.!?])[ \t]+)[^.!?\n,;]+[,;—–-][ \t]*"# + cue + #"[ \t]*(?:[,;—–-][ \t]*|(?=[.!?]))"#
        ]
        var output = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let protected = DictationLiterals.ranges(in: output)
            let source = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: source.length)).reversed() {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      let range = Range(match.range, in: output) else { continue }
                let startsSentence = match.range.location == 0 || source.substring(to: match.range.location).trimmingCharacters(in: .whitespaces).last.map { ".!?".contains($0) } == true
                var rest = String(output[range.upperBound...])
                // The sentence that remains starts here: capitalize an ordinary lowercase word.
                if startsSentence, let first = rest.first, first.isLowercase,
                   let word = rest.split(separator: " ").first, word.dropFirst().allSatisfy({ !$0.isUppercase }) {
                    rest = first.uppercased() + rest.dropFirst()
                }
                let prefix = String(output[..<range.lowerBound])
                output = prefix + (prefix.isEmpty || prefix.hasSuffix(" ") ? "" : " ") + rest
            }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// Repeated predicate + explicit correction identifies an abandoned owner.
    /// Additive "too/as well" is not a replacement; other paraphrases stay with the model.
    static func resolveSubjectCorrections(_ text: String) -> String {
        let subject = #"(?:the[ \t]+team|[\p{L}][\p{L}'’-]{0,30})"#
        let predicate = #"([\p{L}'’]+(?:[ \t]+[\p{L}'’]+){1,7}?)"#
        let pattern = #"(?i)(^|(?<=[.!?])[ \t]+)"# + subject + #"[ \t]+"# + predicate
            + #"[ \t,;—–]+(?:actually|I mean|I meant|sorry|no[ \t]+wait)[ \t,;—–]+("# + subject + #")[ \t]+\2\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString, protected = DictationLiterals.ranges(in: text)
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: output) else { continue }
            let after = source.substring(from: NSMaxRange(match.range))
            guard after.range(of: #"(?i)^[ \t,]+(?:too|also|as well)\b"#, options: .regularExpression) == nil else { continue }
            output.replaceSubrange(range, with: source.substring(with: match.range(at: 1))
                + source.substring(with: match.range(at: 3)) + " " + source.substring(with: match.range(at: 2)))
        }
        return output
    }

    public static func resolve(_ text: String) -> String {
        var output = NumericContent.resolvingCorrections(resolveSubjectCorrections(resolveRetractions(text)))
        let nameSource = output as NSString
        for match in nameCorrections(output).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: nameSource.substring(with: match.range(at: 1)) + nameSource.substring(with: match.range(at: 3)))
        }
        for family in families {
            let atom = "(?:" + family + ")"
            let pattern = "(?i)\\b" + atom + "(?:[ \\t]*[,—–-][ \\t]*|[ \\t]+(?=(?:no|sorry|I mean|I meant|make that)\\b))(?:no,?[ ]+(?:wait|sorry)(?:[, ]+I mean)?|wait|I meant|no(?:[, ]+I mean)?|sorry|actually|I mean|make that)\\s*[,—–-]?\\s*(" + atom + ")\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = output as NSString
            let protected = DictationLiterals.ranges(in: output)
            for match in regex.matches(in: output, range: NSRange(location: 0, length: source.length)).reversed() {
                if protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
                guard let range = Range(match.range, in: output) else { continue }
                output.replaceSubrange(range, with: source.substring(with: match.range(at: 1)))
            }
        }
        return output
    }
}

/// Literal spans must survive both deterministic editing and local-model output.
public enum DictationLiterals {
    static func ranges(in text: String) -> [NSRange] {
        // Quoted literals, code, URLs, paths, emails and compound identifiers.
        // Apostrophes inside ordinary contractions are not quote delimiters.
        let pattern = #"(?s:~~~.*?(?:~~~|$))|`+[^`]*`+|"[^"\n]*"|“[^”\n]*”|‘[^’\n]*’|(?<![\p{L}])'[^'\n]+'|(?:https?://|/)[^\s,;]+|[\p{L}\d_.+-]+@[\p{L}\d_.-]+|[\p{L}\d_]+(?:[-_./][\p{L}\d_]+)+|\b(?:[\p{L}_]+\d+[\p{L}\d_]*|\d+[\p{L}_]+[\p{L}\d_]*)\b|(?<![\p{L}\d])(?:0\d+|[+]\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    public static func preserved(source: String, candidate: String) -> Bool {
        let original = source as NSString
        return ranges(in: source).allSatisfy { candidate.contains(original.substring(with: $0)) }
    }
}
