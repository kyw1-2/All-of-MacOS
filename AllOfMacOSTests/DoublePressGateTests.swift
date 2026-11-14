import XCTest
@testable import AllOfMacOS

final class DoublePressGateTests: XCTestCase {
    func testPairWithinWindow() {
        var gate = DoublePressGate()
        XCTAssertFalse(gate.register("a", now: 0, window: 0.3))
        XCTAssertTrue(gate.register("a", now: 0.2, window: 0.3))
    }

    func testPressesOutsideWindowDoNotPair() {
        var gate = DoublePressGate()
        XCTAssertFalse(gate.register("a", now: 0, window: 0.3))
        XCTAssertFalse(gate.register("a", now: 0.4, window: 0.3))
    }

    func testThirdPressStartsNewPair() {
        var gate = DoublePressGate()
        XCTAssertFalse(gate.register("a", now: 0, window: 0.3))
        XCTAssertTrue(gate.register("a", now: 0.1, window: 0.3))
        XCTAssertFalse(gate.register("a", now: 0.2, window: 0.3))
    }

    func testDifferentKeysDoNotPair() {
        var gate = DoublePressGate()
        XCTAssertFalse(gate.register("a", now: 0, window: 0.3))
        XCTAssertFalse(gate.register("b", now: 0.1, window: 0.3))
        XCTAssertTrue(gate.register("b", now: 0.15, window: 0.3))
        XCTAssertTrue(gate.register("a", now: 0.2, window: 0.3))
    }

    func testKeyboardDoublePressDefaultAndClamp() {
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        // Unset, it follows the macOS double-click speed.
        XCTAssertEqual(TriggerTimingSettings.keyboardDoublePressMs(d, system: 0.5), 500)
        XCTAssertEqual(TriggerTimingSettings.keyboardDoublePressMs(d, system: 0.8), 800)
        d.set(5000, forKey: TriggerTimingSettings.keyboardDoublePressKey)
        XCTAssertEqual(TriggerTimingSettings.keyboardDoublePressMs(d, system: 0.5), 1500)
    }
}
