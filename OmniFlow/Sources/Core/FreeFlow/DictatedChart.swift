import Foundation

/// A deliberately small chart interchange format. No expressions, URLs or executable content.
public struct DictatedChart: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case bar, line, pie }
    public struct Point: Codable, Equatable, Sendable {
        public let label: String
        public let value: Double
        public init(label: String, value: Double) { self.label = label; self.value = value }
    }
    public let type: Kind
    public let title: String?
    public let data: [Point]
    public init(type: Kind, title: String? = nil, data: [Point]) { self.type = type; self.title = title; self.data = data }

    public static func parse(json: String) -> Self? {
        guard json.utf8.count <= 32_768, let bytes = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys).isSubset(of: ["type", "title", "data"]),
              let rows = object["data"] as? [[String: Any]],
              rows.allSatisfy({ Set($0.keys) == Set(["label", "value"]) }),
              let chart = try? JSONDecoder().decode(Self.self, from: bytes), chart.isValid else { return nil }
        return chart
    }
    public var isValid: Bool {
        guard (title?.count ?? 0) <= 160, (1...100).contains(data.count),
              data.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 120 && $0.value.isFinite && abs($0.value) <= 1e15 }),
              Set(data.map(\.label)).count == data.count else { return false }
        if type == .pie { return data.allSatisfy { $0.value >= 0 } && data.contains { $0.value > 0 } }
        return true
    }
    /// Validate every declared chart block before accepting model output. Plain Markdown is unaffected.
    public static func validatesFences(in text: String, source: String? = nil) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let opening = lines[i].trimmingCharacters(in: .whitespaces)
            if opening.hasPrefix("```freeflow-chart") {
                guard opening == "```freeflow-chart" else { return false }
                i += 1
                var payload: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "```" {
                    payload.append(lines[i]); i += 1
                }
                guard i < lines.count, let chart = parse(json: payload.joined(separator: "\n")) else { return false }
                if let source {
                    let labels = chart.data.map(\.label) + (chart.title.map { [$0] } ?? [])
                    guard labels.allSatisfy({ containsSuppliedPhrase($0, in: source) }) else { return false }
                }
            }
            i += 1
        }
        return true
    }
    /// Case and whitespace may change for presentation. Substrings of unrelated words do not count.
    /// Normalize canonical Unicode composition without folding accents or changing supplied wording.
    private static func containsSuppliedPhrase(_ phrase: String, in source: String) -> Bool {
        func normalized(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let phrase = normalized(phrase)
        guard !phrase.isEmpty else { return false }
        let text = normalized(source)
        let pattern = #"(?<![\p{L}\p{M}\p{N}_])"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?![\p{L}\p{M}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    public static let instructions = """
        Only when the speaker explicitly requests a bar, line or pie chart AND supplies every category and numeric value,
        format that supplied data in a fenced block with language freeflow-chart. Its JSON schema is exactly
        {"type":"bar"|"line"|"pie","title":"optional supplied title","data":[{"label":"supplied category","value":number}]}.
        Keep labels, order and all values faithful to the transcript. Do not add examples, calculate totals or percentages,
        invent titles, interpolate, or fabricate missing values. A pie chart requires nonnegative values and a positive total.
        Use at most 100 unique labels. If data is incomplete, preserve the spoken request as prose. Charts are presentation
        of supplied data only. A request to research or generate chart data remains a request. JSON keys are structural;
        never put the complete transcript inside JSON. Preserve any accompanying substantive prose outside the fence.
        """
}
