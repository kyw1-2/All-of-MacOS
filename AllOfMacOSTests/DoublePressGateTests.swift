import XCTest
@testable import AllOfMacOS

/// 3.4.32 audit: the UGREEN side buttons faked single/double click with
/// `Cycle Through Actions` and a 600 ms delay. These rules replace that.
final class DoublePressGateTests: XCTestCase {
    func testSecondPressInsideWindowCompletesThePair() {
        var gate = DoublePressGate()
        XCTAssertFalse(gate.register("k", now: 100.0, window: 0.3))
        XCTAssertTrue(gate.register("k", now: 100.2, window: 0.3))
    }

    func testSlowPressStartsANewPair() {
        var gate = DoublePressGate()
        XCTAssertFalse(gate.register("k", now: 100.0, window: 0.3))
        XCTAssertFalse(gate.register("k", now: 100.5, window: 0.3))
    }

    func testThirdPressDoesNotStayDouble() {
        var gate = DoublePressGate()
        XCTAssertFalse(gate.register("k", now: 100.0, window: 0.3))
        XCTAssertTrue(gate.register("k", now: 100.2, window: 0.3))
        // The pair was consumed; this one opens a new pair and must be deferred.
        XCTAssertFalse(gate.register("k", now: 100.4, window: 0.3))
    }

    func testKeysAreIndependent() {
        var gate = DoublePressGate()
        XCTAssertFalse(gate.register("a", now: 10.0, window: 0.3))
        XCTAssertFalse(gate.register("b", now: 10.1, window: 0.3))
        XCTAssertTrue(gate.register("a", now: 10.2, window: 0.3))
    }

    func testClearForgetsThePress() {
        var gate = DoublePressGate()
        XCTAssertFalse(gate.register("k", now: 1.0, window: 0.3))
        gate.clear("k")
        XCTAssertFalse(gate.register("k", now: 1.1, window: 0.3))
    }
}

/// The animation gate: an ordered-out SwiftUI scene is not a reason to keep
/// asking for frames.
final class AOMUIVisibilityTests: XCTestCase {
    func testVisibleOnlyWhenShownUnminimisedAndNotOccluded() {
        XCTAssertTrue(AOMUIVisibility.isVisible(windowIsVisible: true, isMiniaturized: false, occlusionVisible: true))
        XCTAssertFalse(AOMUIVisibility.isVisible(windowIsVisible: false, isMiniaturized: false, occlusionVisible: true))
        XCTAssertFalse(AOMUIVisibility.isVisible(windowIsVisible: true, isMiniaturized: true, occlusionVisible: true))
        XCTAssertFalse(AOMUIVisibility.isVisible(windowIsVisible: true, isMiniaturized: false, occlusionVisible: false))
    }
}
