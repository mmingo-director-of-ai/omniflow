import Foundation

/// Remove a narrow set of English hesitation sounds, not meaningful phrases like
/// “like”, “well”, or “you know”. Literal spans and other languages stay untouched.
public enum SpeechDisfluencies {
    public static func clean(_ text: String, language: String?) -> String {
        guard language == "en" else { return text }
        let source = text as NSString
        var protected = DictationLiterals.ranges(in: text)
        if let fences = try? NSRegularExpression(pattern: #"(?s)~~~.*?(?:~~~|$)|```.*?(?:```|$)"#) {
            protected += fences.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        }
        let pattern = #"(?:,[ \t]*)?(?<![\p{L}\d_/-])(?:um|uh|erm|(?:Um|Uh|Erm)(?=,))(?![\p{L}\d_/-])(?:,[ \t]*|[ \t]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let before = source.substring(to: match.range.location)
            let after = (output as NSString).substring(from: NSMaxRange(match.range))
            var range = match.range
            var replacement = ""
            if let last = before.last, !last.isWhitespace, let next = after.first, next.isLetter { replacement = " " }
            let prefix = before.trimmingCharacters(in: .whitespacesAndNewlines)
            if (prefix.isEmpty || prefix.last.map({ ".!?".contains($0) }) == true),
               let next = after.first, next.isLowercase,
               !protected.contains(where: { NSLocationInRange(NSMaxRange(range), $0) }) {
                replacement += String(next).uppercased()
                range.length += String(next).utf16.count
            }
            if let swiftRange = Range(range, in: output) { output.replaceSubrange(swiftRange, with: replacement) }
        }
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }
}
