import Testing
@testable import OmniFlowApp

@Test @MainActor func pasteVerificationRequiresTheExactSelectedReplacement() {
    #expect(!InsertionService.verifiesPaste(before: "hello there", selection: "11:0", after: "hello there", text: "hello"))
    #expect(!InsertionService.verifiesPaste(before: "hello there", selection: "11:0", after: "hello world there", text: "world"))
    #expect(InsertionService.verifiesPaste(before: "hello there", selection: "6:5", after: "hello world", text: "world"))
    #expect(InsertionService.verifiesPaste(before: "👋 there", selection: "3:5", after: "👋 world", text: "world"))
    #expect(!InsertionService.verifiesPaste(before: "draft", selection: nil, after: "draft text", text: "text"))
    #expect(!InsertionService.verifiesPaste(before: "draft", selection: "-1:3", after: "text", text: "text"))
    #expect(!InsertionService.verifiesPaste(before: "draft", selection: "1:9223372036854775807", after: "text", text: "text"))
}
