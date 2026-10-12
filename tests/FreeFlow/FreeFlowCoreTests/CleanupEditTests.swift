import Foundation
import Testing
@testable import OmniFlowApp

@Test func cleanupReportsAcceptedAndRefusedEdits() {
    let raw = "um put the files over their and we ship on tuesday"
    let validated = RewriteValidation.validate(source: raw, rewrite: "Put the files over there, and we ship on Wednesday.", vocabulary: [])
    #expect(validated.text == "Put the files over there, and we ship on tuesday.")
    let edits = CleanupEdits.compute(source: raw, result: validated.text, refused: validated.refused)
    let summary = edits.map { "\($0.original)→\($0.replacement) \($0.kind.rawValue) \($0.accepted ? "accepted" : "refused:" + ($0.refusalReason ?? ""))" }
    #expect(summary == ["um→ filler accepted", "put→Put capitalization accepted", "their→there, phonetic accepted",
                        "tuesday→tuesday. punctuation accepted", "tuesday→Wednesday. rewrite refused:meaning"])
    // Ranges point into both texts.
    let homophone = edits[2]
    #expect(homophone.originalRange?.range(in: raw).map { String(raw[$0]) } == "their")
    #expect(homophone.replacementRange?.range(in: validated.text).map { String(validated.text[$0]) } == "there,")
    #expect(edits[0].replacementRange == TextSpan(location: 0, length: 0))
    #expect(edits[4].replacementRange == nil && edits[4].originalRange?.range(in: raw).map { String(raw[$0]) } == "tuesday")
}

@Test func editKindsAreClassified() {
    func kind(_ a: String, _ b: String, _ vocabulary: [String] = []) -> CleanupEdit.Kind { CleanupEdits.classify(original: a, replacement: b, vocabulary: vocabulary) }
    #expect(kind("monday", "Monday") == .capitalization)
    #expect(kind("today", "today.") == .punctuation)
    #expect(kind("its", "it's") == .contraction)
    #expect(kind("there", "they're") == .contraction)
    #expect(kind("um so", "") == .filler)
    #expect(kind("today scratch that", "") == .retraction)
    #expect(kind("cloud code", "Claude Code", ["Claude Code"]) == .vocabulary)
    #expect(kind("to get her", "together") == .phonetic)
    #expect(kind("needs", "need") == .grammar)
    #expect(kind("there", "their") == .phonetic)
    #expect(kind("a", "the") == .grammar)
    #expect(kind("staging", "production") == .rewrite)
}

@Test func cleanupEditsRoundTripAndOldHistoryStillDecodes() throws {
    let edit = CleanupEdit(original: "their", replacement: "there", kind: .phonetic, accepted: true,
                           originalRange: TextSpan(location: 4, length: 5), replacementRange: TextSpan(location: 4, length: 5))
    let entry = DictationEntry(raw: "put their", text: "Put there.", note: "Polished", destination: "Notes", edits: [edit])
    let decoded = try JSONDecoder().decode(DictationEntry.self, from: JSONEncoder().encode(entry))
    #expect(decoded == entry && decoded.edits == [edit])
    // An entry saved before edits were recorded.
    let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"raw":"hello","text":"Hello.","note":"Polished","destination":"Notes","state":"delivered","revision":2}"#
    let legacy = try JSONDecoder().decode(DictationEntry.self, from: Data(old.utf8))
    #expect(legacy.edits == nil && legacy.text == "Hello." && legacy.revision == 2)
}
