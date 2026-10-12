import Foundation
import Testing
@testable import OmniFlowApp

@Test func streamingReplacesOnlyOwnedSpanIncludingUnicode() {
    var span = OwnedText(value: "Hi 👋 world!", selection: NSRange(location: 6, length: 5))
    #expect(span.replacementRange == NSRange(location: 6, length: 5))
    #expect(span.value(replacingWith: "Sarah") == "Hi 👋 Sarah!")
    span.commit("Sarah")
    #expect(span.value(replacingWith: "Sarah and 李") == "Hi 👋 Sarah and 李!")
    span.commit("Sarah and 李")
    #expect(span.value(replacingWith: span.originalSelection) == "Hi 👋 world!")
}
