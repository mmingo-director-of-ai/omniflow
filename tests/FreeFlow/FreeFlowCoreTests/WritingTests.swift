import Testing
@testable import OmniFlowApp

@Test func equivalentNumberSpellingsPreserveMeaning() {
    #expect(CleanupPolicy.accept(raw: "We need 2 servers and twelve workers.", candidate: "We need two servers and 12 workers.") != nil)
    #expect(CleanupPolicy.accept(raw: "We need twenty five servers.", candidate: "We need 25 servers.") != nil)
    #expect(CleanupPolicy.accept(raw: "We need two thousand workers.", candidate: "We need 2,000 workers.") != nil)
    #expect(CleanupPolicy.accept(raw: "We need two servers.", candidate: "We need three servers.") == nil)
    #expect(CleanupPolicy.accept(raw: "Version 1.2 uses port 443.", candidate: "Version 12 uses port 443.") == nil)
}

@Test func explicitNumericBacktrackingUsesTheCorrection() {
    #expect(CleanupPolicy.accept(raw: "Send 2, no, 3 servers tomorrow.", candidate: "Send three servers tomorrow.") != nil)
    #expect(CleanupPolicy.accept(raw: "Send two servers, sorry, three servers tomorrow.", candidate: "Send three servers tomorrow.") != nil)
    #expect(CleanupPolicy.accept(raw: "Send 2, no, 3 servers tomorrow.", candidate: "Send two servers tomorrow.") == nil)
    #expect(CleanupPolicy.accept(raw: "Send 2 servers and 3 workers tomorrow.", candidate: "Send three workers tomorrow.") == nil)
    #expect(CleanupPolicy.accept(raw: "Do not send 2 servers, sorry, 3 servers tomorrow.", candidate: "Send three servers tomorrow.") == nil)
}

@Test func numericValidationKeepsTechnicalLiteralsAndCompositeValues() {
    #expect(CleanupPolicy.accept(raw: "Use v2 and build_9.", candidate: "Use v3 and build_9.") == nil)
    #expect(CleanupPolicy.accept(raw: "Set the threshold to -2.", candidate: "Set the threshold to 2.") == nil)
    #expect(CleanupPolicy.accept(raw: "Use `retry(2)` here.", candidate: "Use `retry(two)` here.") == nil)
    #expect(CleanupPolicy.accept(raw: "We have one hundred twenty five servers.", candidate: "We have 125 servers.") != nil)
}

@Test func apaFormattingEnforcesCountsAndMeasurementExceptions() {
    #expect(WritingStyle.apa.format("We need 2 servers and twelve workers.") == "We need two servers and 12 workers.")
    #expect(WritingStyle.apa.format("Wait five seconds and allocate two GB.") == "Wait 5 seconds and allocate 2 GB.")
    #expect(WritingStyle.apa.format("Use `retry(2)` with v2 and /tmp/2.") == "Use `retry(2)` with v2 and /tmp/2.")
    #expect(WritingStyle.faithful.format("Use 2 servers.") == "Use 2 servers.")
    #expect(WritingStyle.technical.format("Use two servers.") == "Use 2 servers.")
}

@Test func clearDateCorrectionsAndSentenceEndNumbers() {
    #expect(SpeechCorrections.resolve("Meet Monday, actually Tuesday, with Sarah.") == "Meet Tuesday, with Sarah.")
    #expect(SpeechCorrections.resolve("Meet Monday and Tuesday with Sarah.") == "Meet Monday and Tuesday with Sarah.")
    #expect(WritingStyle.apa.format("We need twelve.") == "We need 12.")
    #expect(WritingStyle.apa.format("2 servers arrived.") == "Two servers arrived.")
}
