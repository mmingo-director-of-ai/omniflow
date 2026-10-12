import Foundation

public struct ApplicationProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var bundleID: String
    /// nil inherits the user's global preference.
    public var writingStyle: String?
    public var outputStyle: String?
    public init(id: UUID = UUID(), name: String = "", bundleID: String = "", writingStyle: String? = nil, outputStyle: String? = nil) {
        self.id = id; self.name = name; self.bundleID = bundleID
        self.writingStyle = writingStyle; self.outputStyle = outputStyle
    }
}

public struct ResolvedDictationPreferences: Sendable {
    public let writingStyle: WritingStyle
    public let outputStyle: String
    public static func resolve(bundleID: String?, profiles: [ApplicationProfile], defaultWritingStyle: WritingStyle, defaultOutputStyle: String) -> Self {
        let profile = bundleID.flatMap { id in profiles.first { !$0.bundleID.isEmpty && $0.bundleID == id } }
        return Self(writingStyle: profile?.writingStyle.flatMap(WritingStyle.init(rawValue:)) ?? defaultWritingStyle,
                    outputStyle: profile?.outputStyle.flatMap { ["natural", "markdown", "agent"].contains($0) ? $0 : nil } ?? defaultOutputStyle)
    }
}

public struct PhraseReplacement: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var phrase: String
    public var replacement: String
    public var enabled: Bool
    public init(id: UUID = UUID(), phrase: String = "", replacement: String = "", enabled: Bool = true) {
        self.id = id; self.phrase = phrase; self.replacement = replacement; self.enabled = enabled
    }
}

public enum PhraseReplacements {
    /// Match against the original only. Longest overlapping phrase wins; earlier rules break ties.
    /// Matching ignores case, keeps Unicode letter/mark boundaries, and preserves Markdown code.
    public static func apply(_ text: String, rules: [PhraseReplacement]) -> String {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let protected = protectedCodeRanges(text)
        var candidates: [(range: NSRange, value: String, order: Int)] = []
        for (order, rule) in rules.prefix(500).enumerated() where rule.enabled {
            let phrase = rule.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, phrase.count <= 500, rule.replacement.count <= 2000 else { continue }
            let pattern = #"(?<![\p{L}\p{M}\p{N}_])"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?![\p{L}\p{M}\p{N}_])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: full) where !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                candidates.append((match.range, rule.replacement, order))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.range.location < rhs.range.location
        }
        var selected: [(range: NSRange, value: String, order: Int)] = []
        for candidate in candidates where !selected.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) { selected.append(candidate) }
        let output = NSMutableString(string: text)
        for candidate in selected.sorted(by: { $0.range.location > $1.range.location }) {
            output.replaceCharacters(in: candidate.range, with: candidate.value)
        }
        return output as String
    }

    private static func protectedCodeRanges(_ text: String) -> [NSRange] {
        // Protect complete and unfinished fenced blocks, plus inline backtick spans.
        let pattern = #"(?ms)^\h*(`{3,}|~{3,})[^\n]*\n.*?(?:^\h*\1\h*$|\z)|(`+)[^`]*\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }
}
