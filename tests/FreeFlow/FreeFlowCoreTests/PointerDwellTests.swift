import Foundation
import Testing
@testable import OmniFlowApp

@Test func hoverRequiresDwellAndDoesNotKeepStealingFocus() {
    var dwell = PointerDwell()
    let p = CGPoint(x: 100, y: 200)
    #expect((dwell.shouldFocus(at: p, time: 0, eligible: true)) == false)
    #expect((dwell.shouldFocus(at: p, time: 0.2, eligible: true)) == false)
    #expect((dwell.shouldFocus(at: p, time: 0.5, eligible: true)) == true)
    #expect((dwell.shouldFocus(at: p, time: 9, eligible: true)) == false)
    #expect((dwell.shouldFocus(at: CGPoint(x: 200, y: 200), time: 10, eligible: true)) == false)
    #expect((dwell.shouldFocus(at: CGPoint(x: 200, y: 200), time: 10.5, eligible: true)) == true)
}
@Test func disablingOrDraggingCancelsPendingHover() {
    var dwell = PointerDwell()
    let p = CGPoint(x: 100, y: 200)
    #expect((dwell.shouldFocus(at: p, time: 0, eligible: true)) == false)
    #expect((dwell.shouldFocus(at: p, time: 0.5, eligible: false)) == false)
    #expect((dwell.shouldFocus(at: p, time: 1, eligible: true)) == false)
    #expect((dwell.shouldFocus(at: p, time: 1.5, eligible: true)) == true)
}

@Test func releasingShortcutDoesNotStealFocusFromKeyboard() {
    var dwell = PointerDwell()
    let p = CGPoint(x: 100, y: 200)
    dwell.suppress(at: p)
    #expect((dwell.shouldFocus(at: p, time: 10, eligible: true)) == false)
    #expect((dwell.shouldFocus(at: CGPoint(x: 200, y: 200), time: 11, eligible: true)) == false)
    #expect((dwell.shouldFocus(at: CGPoint(x: 200, y: 200), time: 11.5, eligible: true)) == true)
}
