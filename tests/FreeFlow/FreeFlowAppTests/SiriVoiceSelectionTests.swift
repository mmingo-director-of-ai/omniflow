import Foundation
import Testing
@testable import OmniFlowApp

private let voice6 = SiriVoice(id: "en-US:fmvoice:female:en-US-G:premium:1", name: "en-US-G", language: "en-US")
private let damonID = "en-US:natural:male:damon:premium:2"

@Test func missingSavedSiriVoiceIsNamedAndFallsBack() throws {
    let missing = try #require(SiriVoice.missingSelection(in: [voice6], selectedID: damonID))
    #expect(missing.id == damonID)
    #expect(missing.displayName.hasPrefix("Damon"))
    #expect(SiriVoice.preferred(in: [voice6], selectedID: damonID)?.id == voice6.id)
}

@Test func installedOrUnsetOrUnknownSiriVoiceIsNotReportedMissing() {
    #expect(SiriVoice.missingSelection(in: [voice6], selectedID: voice6.id) == nil)
    #expect(SiriVoice.missingSelection(in: [voice6], selectedID: nil) == nil)
    // An empty list means the lookup failed, not that the voice is gone.
    #expect(SiriVoice.missingSelection(in: [], selectedID: damonID) == nil)
}
