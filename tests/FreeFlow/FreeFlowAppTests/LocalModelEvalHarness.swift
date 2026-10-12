import Foundation
import FoundationModels
import CryptoKit
import Testing
@testable import OmniFlowApp

/// Offline qualification only. No model downloads, networking or agent tool execution.
/// Export the production prompt to JSON, run the pinned local candidates, then import
/// their responses to score with the same assertions and validators as Apple's model.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIFLOW_LOCAL_EVAL"] == "1"))
func localModelQualification() async throws {
    let env = ProcessInfo.processInfo.environment
    let out = URL(fileURLWithPath: try #require(env["OMNIFLOW_LOCAL_EVAL_OUT"]))
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/cleanup-eval")
    let directories = [fixtures, fixtures.deletingLastPathComponent().appendingPathComponent("local-model-cleanup")]
    let cases = try directories.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { try JSONDecoder().decode(EvalCase.self, from: Data(contentsOf: $0)) }
    var requests: [[String: String]] = []
    for test in cases {
        let terms = DictationCleanup.terms(vocabulary: test.vocabulary)
        let baseline = RewriteValidation.matchSpokenTerms(
            RewriteValidation.collapseSpelledTerms(PolishMode.polished.prepare(test.raw, language: "en"), vocabulary: terms), vocabulary: terms)
        let vocabulary = test.vocabulary + "\n" + SpeechCorrections.finalCorrectedNames(in: test.raw).joined(separator: "\n")
        requests.append(["id": test.id, "raw": test.raw, "baseline": baseline,
            "instructions": DictationCleanup.instructions(structured: true, writingStyle: .technical, mode: .polished),
            "prompt": DictationCleanup.prompt(for: baseline, vocabulary: vocabulary, locale: EvalVariants.locale,
                spelling: AppleSpellingService())])
    }
    // Reuse the exact exported prompts, including their random boundary tokens.
    // Scoring must never regenerate/overwrite the evidence used for inference.
    let requestURL = out.appendingPathComponent("requests.json")
    if FileManager.default.fileExists(atPath: requestURL.path) {
        requests = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: requestURL))
        try #require(requests.count == cases.count)
        try #require(Set(requests.compactMap { $0["id"] }) == Set(cases.map(\.id)))
        for test in cases {
            try #require(requests.first { $0["id"] == test.id }?["raw"] == test.raw)
        }
    } else {
        try JSONSerialization.data(withJSONObject: requests, options: [.prettyPrinted, .sortedKeys]).write(to: requestURL)
    }
    let requestHash = SHA256.hash(data: try Data(contentsOf: requestURL)).map { String(format: "%02x", $0) }.joined()
    if env["OMNIFLOW_LOCAL_EVAL_APPLE"] == "1" {
        var apple: [[String: Any]] = []
        for request in requests {
            let started = ContinuousClock.now
            var row: [String: Any] = ["model": "apple/production", "id": try #require(request["id"]),
                "text": "", "requests_sha256": requestHash]
            do {
                let instructions = try #require(request["instructions"])
                let prompt = try #require(request["prompt"])
                let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                    instructions: instructions)
                row["text"] = try await session.respond(to: prompt,
                    options: GenerationOptions(temperature: 0, maximumResponseTokens: 2200)).content
            } catch { row["error"] = String(describing: error) }
            let elapsed = started.duration(to: .now).components
            row["seconds"] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            apple.append(row)
            try JSONSerialization.data(withJSONObject: apple, options: [.prettyPrinted, .sortedKeys])
                .write(to: out.appendingPathComponent("responses-apple.json"), options: .atomic)
            print("Apple matched: \(request["id"] ?? "") \(row["seconds"] ?? "")s")
        }
    }
    guard let input = env["OMNIFLOW_LOCAL_EVAL_RESPONSES"] else { return }
    struct Response: Decodable {
        let model: String, id: String, text: String
        let seconds: Double
        let error: String?, requests_sha256: String?
    }
    let responses = try JSONDecoder().decode([Response].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    var rows: [[String]] = [], outputs: [String] = []
    for response in responses {
        if let hash = response.requests_sha256 { try #require(hash == requestHash, "Responses belong to a different prompt export") }
        let test = try #require(cases.first { $0.id == response.id })
        let baseline = try #require(requests.first { $0["id"] == response.id }?["baseline"])
        var guarded = baseline
        var note = response.error ?? ""
        if response.error == nil, DictatedChart.validatesFences(in: response.text, source: baseline),
           case .success(let candidate) = CleanupPolicy.evaluateShape(raw: baseline, candidate: response.text, structured: true) {
            let validation = RewriteValidation.validate(source: baseline, rewrite: candidate,
                vocabulary: DictationCleanup.terms(vocabulary: test.vocabulary))
            guarded = ProperNouns.capitalize(validation.text, vocabulary: DictationCleanup.terms(vocabulary: test.vocabulary))
            note = "reverted clauses: \(validation.revertedClauses)"
        } else { note += " shape/error fallback" }
        guarded = PolishMode.contextualSpelling(PolishMode.separateTopics(SpeechDisfluencies.clean(guarded, language: "en")))
        for (suffix, text) in [("raw", response.text), ("validated", guarded)] {
            let score = EvalScore.assertions(text, test)
            let issues = EvalScore.readabilityIssues(text)
            rows.append([response.model + "/" + suffix, test.id, test.kind, "\(score.passed)/\(score.total)",
                String(format: "%.3f", EvalScore.wer(text, test.reference)), "\(DictationChunker.sentenceCount(text))",
                "\(DictationChunker.sentenceCount(test.reference))", String(format: "%.2f", ContentCoverage.fraction(source: test.reference, edited: text)),
                String(format: "%.2f", response.seconds), issues.map { "[\($0)] " }.joined() + note])
            outputs.append(text)
        }
    }
    let header = "variant\tcase\tkind\tassertions\twer\tsentences\tref_sentences\tcoverage\tseconds\tnote\n"
    try (header + rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
        .write(to: out.appendingPathComponent("results.tsv"), atomically: true, encoding: .utf8)
    try EvalReport.markdown(rows: rows, runOutputs: outputs)
        .write(to: out.appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
    try JSONSerialization.data(withJSONObject: outputs, options: .prettyPrinted).write(to: out.appendingPathComponent("outputs-by-row.json"))
}
