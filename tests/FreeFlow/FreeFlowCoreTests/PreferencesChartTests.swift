import Foundation
import Testing
@testable import OmniFlowApp

@Test func appPreferencesUseExactBundleAndInheritIndependently() {
    let profiles = [ApplicationProfile(name: "Editor", bundleID: "com.editor", writingStyle: "technical")]
    let editor = ResolvedDictationPreferences.resolve(bundleID: "com.editor", profiles: profiles, defaultWritingStyle: .apa, defaultOutputStyle: "markdown")
    #expect(editor.writingStyle == .technical)
    #expect(editor.outputStyle == "markdown")
    for id in [nil, "com.editor.child", "COM.EDITOR"] as [String?] {
        #expect(ResolvedDictationPreferences.resolve(bundleID: id, profiles: profiles, defaultWritingStyle: .apa, defaultOutputStyle: "natural").writingStyle == .apa)
    }
    let stored = try? JSONEncoder().encode(profiles)
    #expect(stored.flatMap { try? JSONDecoder().decode([ApplicationProfile].self, from: $0) } == profiles)
}

@Test func replacementCollisionLongestMatchAndNoCascades() {
    let rules = [PhraseReplacement(phrase: "free", replacement: "OPEN"), PhraseReplacement(phrase: "free flow", replacement: "FreeFlow"), PhraseReplacement(phrase: "FreeFlow", replacement: "Something else")]
    #expect(PhraseReplacements.apply("FREE FLOW is free. carefree stays.", rules: rules) == "FreeFlow is OPEN. carefree stays.")
    #expect(PhraseReplacements.apply("alpha beta", rules: [.init(phrase: "alpha", replacement: "beta"), .init(phrase: "beta", replacement: "gamma")]) == "beta gamma")
    #expect(PhraseReplacements.apply("foo", rules: [.init(phrase: "foo", replacement: "$1\\literal"), .init(phrase: "FOO", replacement: "wrong")]) == "$1\\literal")
}

@Test func replacementPreservesCodeUnicodeAndBoundaries() {
    let rule = PhraseReplacement(phrase: "café", replacement: "Coffee")
    #expect(PhraseReplacements.apply("☕ CAFÉ cafés café_1 café.", rules: [rule]) == "☕ Coffee cafés café_1 Coffee.")
    let text = "free flow `free flow`\n```swift\nfree flow\n```\nfree flow\n~~~\nfree flow\n~~~"
    #expect(PhraseReplacements.apply(text, rules: [.init(phrase: "free flow", replacement: "FreeFlow")]) == "FreeFlow `free flow`\n```swift\nfree flow\n```\nFreeFlow\n~~~\nfree flow\n~~~")
    #expect(PhraseReplacements.apply("```\nfree flow", rules: [.init(phrase: "free flow", replacement: "FreeFlow")]) == "```\nfree flow")
}

@Test func chartParsingRejectsUnsafeOrAmbiguousData() {
    #expect(DictatedChart.parse(json: #"{"type":"bar","data":[{"label":"A","value":2}]}"#)?.data.first?.value == 2)
    for json in [
        #"{"type":"scatter","data":[{"label":"A","value":2}]}"#,
        #"{"type":"bar","data":[]}"#,
        #"{"type":"bar","data":[{"label":"A","value":1e999}]}"#,
        #"{"type":"pie","data":[{"label":"A","value":-1}]}"#,
        #"{"type":"pie","data":[{"label":"A","value":0}]}"#,
        #"{"type":"bar","data":[{"label":"A","value":2},{"label":"A","value":3}]}"#,
        #"{"type":"bar","data":[{"label":"A","value":"2"}]}"#,
        #"{"type":"bar","script":"alert()","data":[{"label":"A","value":2}]}"#
    ] { #expect(DictatedChart.parse(json: json) == nil) }
    #expect(!DictatedChart(type: .line, data: (0...100).map { .init(label: String($0), value: 1) }).isValid)
}

@Test func malformedChartFencesNeverBecomeAcceptedCharts() {
    let good = "```freeflow-chart\n" + #"{"type":"line","data":[{"label":"A","value":2}]}"# + "\n```"
    #expect(DictatedChart.validatesFences(in: good))
    #expect(!DictatedChart.validatesFences(in: String(good.dropLast(3))))
    #expect(!DictatedChart.validatesFences(in: "```freeflow-chart\n{invalid}\n```"))
    #expect(DictatedChart.validatesFences(in: "Ordinary text"))
    #expect(CleanupPolicy.accept(raw: "Make a line chart with A two", candidate: good, structured: true) != nil)
    #expect(CleanupPolicy.accept(raw: "Make a line chart with A three", candidate: good, structured: true) == nil)
    #expect(WritingStyle.apa.format(good) == good)
}

@Test func chartLabelsAndTitlesMustBeSuppliedAsWholePhrases() {
    let chart = "```freeflow-chart\n" + #"{"type":"bar","title":"Quarterly Sales","data":[{"label":"North America","value":2}]}"# + "\n```"
    #expect(DictatedChart.validatesFences(in: chart, source: "Make a bar chart titled quarterly sales with north   america two."))
    #expect(!DictatedChart.validatesFences(in: chart, source: "Make a bar chart titled quarterly sales with Europe two."))
    #expect(!DictatedChart.validatesFences(in: chart, source: "Make a bar chart titled Revenue with North America two."))
    let shortLabel = "```freeflow-chart\n" + #"{"type":"bar","data":[{"label":"East","value":2}]}"# + "\n```"
    #expect(!DictatedChart.validatesFences(in: shortLabel, source: "Make a bar chart with northeast two."))
    #expect(DictatedChart.validatesFences(in: shortLabel, source: "Make a bar chart with EAST two."))
    let unicode = "```freeflow-chart\n" + #"{"type":"bar","data":[{"label":"Café","value":2}]}"# + "\n```"
    #expect(DictatedChart.validatesFences(in: unicode, source: "Chart cafe\u{301} two"))
}
