import Foundation
import FoundationModels
import NaturalLanguage
import Testing
@testable import OmniFlowApp

/// Opt-in quality evaluation of dictation cleanup against tests/fixtures/cleanup-eval.
/// Run `scripts/eval-cleanup.sh`, or OMNIFLOW_EVAL=1 with optional
/// OMNIFLOW_EVAL_VARIANTS=a,b,…, OMNIFLOW_EVAL_CASES=id,… and OMNIFLOW_EVAL_RUNS=n
/// (each prompt carries a random boundary, so runs differ slightly); results.md,
/// results.tsv and outputs.json go to OMNIFLOW_EVAL_OUT (default /tmp/cleanup-eval).
/// Record a changed baseline in docs/omniflow/cleanup-eval.md.
struct EvalCase: Decodable {
    let id: String, kind: String, raw: String, reference: String
    let mustContain: [String], mustNotContain: [String], vocabulary: String
}

enum EvalScore {
    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
    }
    /// Word error rate of `output` against `reference`.
    static func wer(_ output: String, _ reference: String) -> Double {
        let a = words(reference), b = words(output)
        guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return Double(row[b.count]) / Double(a.count)
    }
    /// Required phrases containing a capital ("Priya", "KQL") match case-sensitively;
    /// "thirty|30" accepts either alternative. Forbidden phrases ignore case. The
    /// last assertion is readability (`readabilityIssues`).
    static func assertions(_ output: String, _ test: EvalCase) -> (passed: Int, total: Int) {
        let lower = output.lowercased()
        func contains(_ phrase: Substring) -> Bool {
            phrase.contains(where: \.isUppercase) ? output.contains(phrase) : lower.contains(phrase.lowercased())
        }
        let hits = test.mustContain.filter { $0.split(separator: "|").contains(where: contains) }.count
            + test.mustNotContain.filter { !lower.contains($0.lowercased()) }.count
            + (readabilityIssues(output).isEmpty ? 1 : 0)
        return (hits, test.mustContain.count + test.mustNotContain.count + 1)
    }

    /// Signs of a half-applied edit: a word repeated back to back, the same verb
    /// twice within three words ("we need the team needs"), or a sentence ending
    /// on a word that cannot end one ("…before the.").
    static func readabilityIssues(_ text: String) -> [String] {
        var issues: [String] = []
        let tokens = words(text)
        for (a, b) in zip(tokens, tokens.dropFirst()) where a == b && !["that", "had", "very"].contains(a) { issues.append("repeated \(a)") }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        var verbs: [(index: Int, lemma: String)] = []
        var index = 0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            defer { index += 1 }
            guard tag == .verb else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? text[range].lowercased()
            if !["be", "have", "do", "will", "can", "would", "should", "could"].contains(lemma),
               let previous = verbs.last(where: { $0.lemma == lemma }), index - previous.index <= 3 { issues.append("verb \(lemma) twice") }
            verbs.append((index, lemma))
            return true
        }
        let dangling: Set<String> = ["the", "a", "an", "to", "of", "and", "or", "but", "with", "for", "from", "by", "at", "in", "on", "which"]
        for sentence in text.split(whereSeparator: { ".!?".contains($0) }) {
            if let last = words(String(sentence)).last, dangling.contains(last) { issues.append("dangling \(last)") }
        }
        return issues
    }
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIFLOW_EVAL"] == "1"))
func cleanupEvaluation() async throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/cleanup-eval")
    let cases = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { try JSONDecoder().decode(EvalCase.self, from: Data(contentsOf: $0)) }
    let only = ProcessInfo.processInfo.environment["OMNIFLOW_EVAL_CASES"].map { Set($0.split(separator: ",").map(String.init)) }
    let variants = (ProcessInfo.processInfo.environment["OMNIFLOW_EVAL_VARIANTS"] ?? "a,b").split(separator: ",").map(String.init)
    let out = ProcessInfo.processInfo.environment["OMNIFLOW_EVAL_OUT"] ?? "/tmp/cleanup-eval"
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    var rows: [String] = ["variant\tcase\tkind\tassertions\twer\tsentences\tref_sentences\tcoverage\tseconds\tnote"]
    var outputs: [String: [String: String]] = [:]
    var runOutputs: [String] = []
    let runs = max(1, Int(ProcessInfo.processInfo.environment["OMNIFLOW_EVAL_RUNS"] ?? "") ?? 1)
    for variant in variants {
        for _ in 0..<runs {
        for test in cases where only?.contains(test.id) ?? true {
            let started = Date()
            let (text, note) = await EvalVariants.run(variant, test)
            let seconds = Date().timeIntervalSince(started)
            let score = EvalScore.assertions(text, test)
            rows.append([variant, test.id, test.kind, "\(score.passed)/\(score.total)", String(format: "%.3f", EvalScore.wer(text, test.reference)),
                         "\(DictationChunker.sentenceCount(text))", "\(DictationChunker.sentenceCount(test.reference))",
                         String(format: "%.2f", ContentCoverage.fraction(source: test.reference, edited: text)),
                         String(format: "%.1f", seconds), (EvalScore.readabilityIssues(text).map { "[\($0)] " }.joined() + note)
                            .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")].joined(separator: "\t"))
            outputs[variant, default: [:]][test.id] = text
            runOutputs.append(text)
        }
        }
    }
    try rows.joined(separator: "\n").write(toFile: out + "/results.tsv", atomically: true, encoding: .utf8)
    try JSONSerialization.data(withJSONObject: outputs, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out + "/outputs.json"))
    try JSONSerialization.data(withJSONObject: runOutputs, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: out + "/outputs-by-row.json"))
    try EvalReport.markdown(rows: rows.dropFirst().map { $0.components(separatedBy: "\t") }, runOutputs: runOutputs)
        .write(toFile: out + "/results.md", atomically: true, encoding: .utf8)
}

/// The tables recorded in docs/omniflow/cleanup-eval.md.
enum EvalReport {
    static func markdown(rows: [[String]], runOutputs: [String]) -> String {
        precondition(rows.count == runOutputs.count)
        let variants = rows.map { $0[0] }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        func pair(_ cell: String) -> (Int, Int) { let p = cell.split(separator: "/").compactMap { Int($0) }; return (p[0], p[1]) }
        var lines = ["| variant | assertions per run | WER | sentence-count error | coverage | readable | mean s | max s | runs |",
                     "|---|---|---|---|---|---|---|---|---|"]
        for variant in variants {
            let mine = rows.filter { $0[0] == variant }
            let runs = max(1, mine.count / max(1, Set(mine.map { $0[1] }).count))
            let passedRuns = (0..<runs).map { run in mine.enumerated().filter { $0.offset / (mine.count / runs) == run }.map { pair($0.element[3]).0 }.reduce(0, +) }
            let passed = mine.map { pair($0[3]).0 }.reduce(0, +), total = mine.map { pair($0[3]).1 }.reduce(0, +)
            func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(1, values.count)) }
            let seconds = mine.compactMap { Double($0[8]) }
            let readable = mine.filter { !$0[9].hasPrefix("[") }.count
            let spread = runs > 1 ? " [\(passedRuns.min() ?? 0)–\(passedRuns.max() ?? 0)]" : ""
            lines.append(String(format: "| %@: %@ | %.1f/%d (%.0f%%)%@ | %.3f | %.2f | %.2f | %d/%d | %.1f | %.1f | %d |", variant, EvalVariants.names[variant] ?? variant,
                                Double(passed) / Double(runs), total / runs, 100 * Double(passed) / Double(max(1, total)), spread, mean(mine.compactMap { Double($0[4]) }),
                                mean(mine.map { Double(abs((Int($0[5]) ?? 0) - (Int($0[6]) ?? 0))) }), mean(mine.compactMap { Double($0[7]) }),
                                readable, mine.count, mean(seconds), seconds.max() ?? 0, runs))
        }
        lines += ["", "| kind | " + variants.joined(separator: " | ") + " |", "|---|" + String(repeating: "---|", count: variants.count)]
        for kind in Set(rows.map { $0[2] }).sorted() {
            let cells = variants.map { variant -> String in
                let scores = rows.filter { $0[0] == variant && $0[2] == kind }.map { pair($0[3]) }
                return "\(scores.map(\.0).reduce(0, +))/\(scores.map(\.1).reduce(0, +))"
            }
            lines.append("| \(kind) | " + cells.joined(separator: " | ") + " |")
        }
        lines += ["", "Cases below full marks:", ""]
        for (row, text) in zip(rows, runOutputs) { let (p, t) = pair(row[3]); if p < t { lines.append("- \(row[0]) \(row[1]) \(row[3]): \(text)") } }
        return lines.joined(separator: "\n") + "\n"
    }
}

@MainActor
enum EvalVariants {
    static let locale = Locale(identifier: "en-US")

    nonisolated static let names = ["a": "model alone, 3-line prompt", "b": "cleanup pipeline", "c": "pipeline prompt, unvalidated",
                        "d": "cleanup pipeline, unchunked", "e": "edit-based (typed edits)"]

    static func run(_ variant: String, _ test: EvalCase) async -> (String, String) {
        switch variant {
        case "a": return await rawModel(test)
        case "b": return await pipeline(test, unchunked: false)
        case "c": return await promptWithoutGuards(test)
        case "d": return await pipeline(test, unchunked: true)
        case "e": return await edits(test)
        default: return (test.raw, "unknown variant")
        }
    }

    /// (a) The model alone: a three-line prompt, the whole paragraph, no guards.
    static func rawModel(_ test: EvalCase) async -> (String, String) {
        let session = LanguageModelSession(model: .default, instructions: """
            Rewrite this speech-recognition transcript as clean, correct written English.
            Fix misheard words, grammar, punctuation and run-on sentences; remove filler words.
            Keep every point and detail; do not add anything. Output only the rewritten text.
            """)
        let vocabulary = test.vocabulary.isEmpty ? "" : "Vocabulary: " + test.vocabulary.replacingOccurrences(of: "\n", with: ", ") + "\n\n"
        do {
            return (try await session.respond(to: vocabulary + test.raw, options: GenerationOptions(temperature: 0)).content, "")
        } catch { return (test.raw, "error: \(error)") }
    }

    /// (b)/(d) The cleanup pipeline with technical style and Markdown, chunked or whole.
    static func pipeline(_ test: EvalCase, unchunked: Bool) async -> (String, String) {
        let service = CleanupService()
        service.usesMeaningContext = ProcessInfo.processInfo.environment["OMNIFLOW_EVAL_MEANING"] != "0"
        if unchunked { service.wholeLimit = 100_000 }
        let result = await service.clean(test.raw, locale: locale, vocabulary: test.vocabulary, structured: true, writingStyle: .technical, mode: .polished)
        let refused = result.edits.filter { !$0.accepted }
        return (result.text, result.note + " | edits \(result.edits.count - refused.count) accepted, \(refused.count) refused"
                + refused.map { " [\($0.original)→\($0.replacement): \($0.refusalReason ?? "")]" }.joined())
    }

    /// (c) The shipped prompt and instructions, whole paragraph, no guards.
    static func promptWithoutGuards(_ test: EvalCase) async -> (String, String) {
        let baseline = PolishMode.polished.prepare(test.raw, language: "en")
        let session = LanguageModelSession(model: .default,
            instructions: DictationCleanup.instructions(structured: true, writingStyle: .technical, mode: .polished))
        let prompt = DictationCleanup.prompt(for: baseline, vocabulary: test.vocabulary, locale: locale, spelling: AppleSpellingService())
        do {
            return (try await session.respond(to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: 2200)).content, "")
        } catch { return (baseline, "error: \(error)") }
    }

    /// (e) Edit-based: the model proposes typed edits; each is validated and applied.
    static func edits(_ test: EvalCase) async -> (String, String) {
        let result = await EditCleanup().clean(test.raw, locale: locale, vocabulary: test.vocabulary)
        return (result.text, result.note)
    }
}

@Test func evaluationFailuresShowTheirOwnRunOutput() {
    let first = ["b", "example", "grammar", "1/2", "0.5", "1", "1", "1.0", "0.1", "done"]
    var second = first; second[3] = "2/2"
    let report = EvalReport.markdown(rows: [first, second], runOutputs: ["Earlier failed output", "Later successful output"])
    #expect(report.contains("1/2: Earlier failed output"))
    #expect(!report.contains("Later successful output"))
}
