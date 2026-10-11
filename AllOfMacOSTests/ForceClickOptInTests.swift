import XCTest
import AppKit
@testable import AllOfMacOS

/// Force Click must never change what an ordinary click does.
///
/// This trackpad reports 1.0 for an ordinary press, so a threshold alone would
/// turn every existing corner and middle click into a force click. The judgement
/// is therefore gated on an explicit opt-in, and these tests pin that gate.
final class ForceClickOptInTests: XCTestCase {
    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: "AOMForcePressEnabled")
        UserDefaults.standard.removeObject(forKey: "AOMForcePressThreshold")
        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
    }
    override func setUp() { super.setUp(); clearDefaults() }
    override func tearDown() { clearDefaults(); super.tearDown() }

    /// A contact carrying full pressure, exactly like a real press on this
    /// hardware, must still resolve to the plain click while the feature is off.
    func testFullPressureIsIgnoredWhileForceClickIsDisabled() {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "test" })
        var corner = Trigger(name: "Corner", input: .trackpadGesture(.cornerClickTopLeft))
        corner.suppressClick = true
        monitor.registerTriggers([corner])

        // The suppression path is the same judgement the fire path uses.
        let pressed = [TouchPoint(id: 0, x: 0.05, y: 0.95, size: 0.4, pressure: 1.0)]
        monitor.processTouchFrame(pressed, count: 1, timestamp: 1, pressedButtons: 0)
        XCTAssertEqual(monitor.clickGestureForTesting(x: 0.05, y: 0.95), .cornerClickTopLeft,
                       "an ordinary corner click must survive a full pressure reading")
    }

    /// With the feature on and the default threshold, an ordinary press still
    /// must not become a force click on this hardware.
    func testDefaultThresholdIsAboveAnOrdinaryPressReading() {
        UserDefaults.standard.set(true, forKey: "AOMForcePressEnabled")
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "test" })
        // 0.9 is what an ordinary press reads here; the default threshold is 0.95.
        // The centre of the pad is in no zone at all, so a press there is not
        // a position click; the middle strip is.
        let pressed = [TouchPoint(id: 0, x: 0.5, y: 0.95, size: 0.4, pressure: 0.9)]
        monitor.processTouchFrame(pressed, count: 1, timestamp: 1, pressedButtons: 0)
        XCTAssertEqual(monitor.clickGestureForTesting(x: 0.5, y: 0.95), .middleClickTop,
                       "an ordinary press must not cross the default force threshold")
    }

    /// A user who raises the pressure past the threshold and enables the
    /// feature gets the force gesture, including in the corner zones.
    func testForceGestureFiresOnlyWhenEnabledAndAboveThreshold() {
        UserDefaults.standard.set(true, forKey: "AOMForcePressEnabled")
        UserDefaults.standard.set(0.5, forKey: "AOMForcePressThreshold")
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "test" })
        let pressed = [TouchPoint(id: 0, x: 0.05, y: 0.95, size: 0.4, pressure: 0.8)]
        monitor.processTouchFrame(pressed, count: 1, timestamp: 1, pressedButtons: 0)
        XCTAssertEqual(monitor.clickGestureForTesting(x: 0.05, y: 0.95), .cornerForceClickTopLeft)

        monitor.processTouchFrame(pressed, count: 1, timestamp: 1.1, pressedButtons: 0)
        // The centre is in no corner, so the force press is the plain one.
        XCTAssertEqual(monitor.clickGestureForTesting(x: 0.5, y: 0.5), .forceClick)
    }

    /// Fingers lifting clears the peak, so a stale reading cannot leak into the
    /// next, unrelated click.
    func testLiftingClearsThePeakPressure() {
        UserDefaults.standard.set(true, forKey: "AOMForcePressEnabled")
        UserDefaults.standard.set(0.5, forKey: "AOMForcePressThreshold")
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "test" })
        let pressed = [TouchPoint(id: 0, x: 0.5, y: 0.95, size: 0.4, pressure: 0.9)]
        monitor.processTouchFrame(pressed, count: 1, timestamp: 1, pressedButtons: 0)
        monitor.processTouchFrame([], count: 0, timestamp: 1.1, pressedButtons: 0)
        XCTAssertEqual(monitor.clickGestureForTesting(x: 0.5, y: 0.95), .middleClickTop,
                       "the peak must reset when the fingers lift")
    }
}
