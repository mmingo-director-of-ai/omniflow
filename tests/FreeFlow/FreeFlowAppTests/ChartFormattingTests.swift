import Foundation
import Testing
@testable import OmniFlowApp

@MainActor @Test func chartFormatterOnlyHandlesExplicitPresentationRequests() {
    #expect(ChartFormattingService.isExplicitRequest("Create a bar chart. Development has 2 servers."))
    #expect(ChartFormattingService.isExplicitRequest("Please show a line chart with supplied data."))
    #expect(!ChartFormattingService.isExplicitRequest("We should discuss the bar chart."))
    #expect(!ChartFormattingService.isExplicitRequest("Do not create a bar chart with these values."))
}

@MainActor @Test func chartFormatterPreservesUnitsAndAccompanyingCaveats() {
    let raw = "Create a bar chart. Development has 2 servers. Staging has 3 servers. Production has 8 servers."
    let valid = "```freeflow-chart\n" + #"{"type":"bar","title":"servers","data":[{"label":"Development","value":2},{"label":"Staging","value":3},{"label":"Production","value":8}]}"# + "\n```"
    #expect(ChartFormattingService.validatedCandidate(valid, raw: raw))
    #expect(!ChartFormattingService.validatedCandidate(valid, raw: raw + " Verify allocation tomorrow."))
    #expect(ChartFormattingService.validatedCandidate(valid + "\nVerify allocation tomorrow.", raw: raw + " Verify allocation tomorrow."))
    #expect(!ChartFormattingService.validatedCandidate(valid.replacingOccurrences(of: "servers", with: "machines"), raw: raw))
    #expect(!ChartFormattingService.validatedCandidate(valid.replacingOccurrences(of: ":8", with: ":9"), raw: raw))
}
