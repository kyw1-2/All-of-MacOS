import XCTest
import IOKit.hid
@testable import AllOfMacOS

final class MouseSideButtonHIDTests: XCTestCase {
    func testFailedManagerOpenCanBeRetried() {
        var attempts = 0
        let hid = MouseSideButtonHID(openManager: { _ in
            attempts += 1
            return kIOReturnNotPermitted
        })
        hid.start()
        XCTAssertFalse(hid.isRunning)
        hid.start()
        XCTAssertFalse(hid.isRunning)
        XCTAssertEqual(attempts, 2, "A permission failure must not permanently block start()")
        hid.stop()
    }

    func testOnlySideButtonBindingsNeedHIDFallback() {
        let monitor = MouseButtonMonitor()
        defer { monitor.unregisterAll() }
        monitor.registerEntries([Trigger(name: "Middle", input: .mouse(MouseTriggerSpec(button: 2, kind: .click)))])
        XCTAssertFalse(monitor.needsSideButtonHID)
        monitor.registerEntries([Trigger(name: "Back", input: .mouse(MouseTriggerSpec(button: 3, kind: .click)))])
        XCTAssertTrue(monitor.needsSideButtonHID)
        monitor.registerEntries([])
        XCTAssertFalse(monitor.needsSideButtonHID)
    }

    func testButtonAndConsumerMappings() {
        XCTAssertEqual(MouseSideButtonHID.button(page: 9, usage: 4), 3)
        XCTAssertEqual(MouseSideButtonHID.button(page: 9, usage: 5), 4)
        XCTAssertEqual(MouseSideButtonHID.button(page: 12, usage: 0x224), 3)
        XCTAssertEqual(MouseSideButtonHID.button(page: 12, usage: 0x225), 4)
        XCTAssertNil(MouseSideButtonHID.button(page: 12, usage: 0x226))
    }
    func testUGREENKeyboardCollectionIsAllowlistedWithoutGeneralKeyboardCapture() {
        XCTAssertTrue(MouseSideButtonHID.isKnownCompositeReceiver(vendor: 0x2b89, product: 0x0912))
        XCTAssertFalse(MouseSideButtonHID.isKnownCompositeReceiver(vendor: 0x2b89, product: 0x0913))
        XCTAssertFalse(MouseSideButtonHID.isKnownCompositeReceiver(vendor: 0x05ac, product: 0x0281))
    }
    func testCGObservationSuppressesDelayedHIDDuplicate() {
        var events = MouseSideButtonDeduplicator()
        let press = MouseSideButtonDeduplicator.Edge(button: 3, down: true)
        XCTAssertNil(events.noteCG(press, time: 10))
        XCTAssertFalse(events.shouldDeliverHID(press, time: 10.025))
        XCTAssertTrue(events.shouldDeliverHID(press, time: 10.2))
    }
    func testEachCGEdgeConsumesExactlyOneDelayedHIDEdge() {
        var events = MouseSideButtonDeduplicator()
        let edge = MouseSideButtonDeduplicator.Edge(button: 3, down: true)
        XCTAssertNil(events.noteCG(edge, time: 10))
        XCTAssertFalse(events.shouldDeliverHID(edge, time: 10.01))
        // A distinct second press isn't swallowed by a stale CG timestamp.
        XCTAssertTrue(events.shouldDeliverHID(edge, time: 10.02))
        XCTAssertNil(events.noteCG(edge, time: 11))
        XCTAssertFalse(events.shouldDeliverHID(edge, time: 11.02))
    }

    func testCGObservationAfterHIDPassesItsSuppressionVerdict() {
        var events = MouseSideButtonDeduplicator()
        let press = MouseSideButtonDeduplicator.Edge(button: 4, down: true)
        events.noteHID(press, time: 12, swallow: true)
        XCTAssertEqual(events.noteCG(press, time: 12.02), true)
        XCTAssertNil(events.noteCG(press, time: 12.04))
    }
    func testRapidNativePressesAreMatchedOneForOneWhenHIDDeliveryIsDelayed() {
        var events = MouseSideButtonDeduplicator()
        let edge = MouseSideButtonDeduplicator.Edge(button: 3, down: true)
        XCTAssertNil(events.noteCG(edge, time: 10))
        XCTAssertNil(events.noteCG(edge, time: 10.02))
        XCTAssertFalse(events.shouldDeliverHID(edge, time: 10.001))
        XCTAssertFalse(events.shouldDeliverHID(edge, time: 10.021))
        XCTAssertTrue(events.shouldDeliverHID(edge, time: 10.04))
    }

    func testRapidFallbackPressesKeepEachSuppressionVerdict() {
        var events = MouseSideButtonDeduplicator()
        let edge = MouseSideButtonDeduplicator.Edge(button: 4, down: true)
        events.noteHID(edge, time: 20, swallow: true)
        events.noteHID(edge, time: 20.02, swallow: false)
        XCTAssertEqual(events.noteCG(edge, time: 20.025), true)
        XCTAssertEqual(events.noteCG(edge, time: 20.03), false)
        XCTAssertNil(events.noteCG(edge, time: 20.04))
    }

    func testOldEdgesDoNotConsumeNewClicksAndButtonsRemainIndependent() {
        var events = MouseSideButtonDeduplicator()
        let a = MouseSideButtonDeduplicator.Edge(button: 3, down: true)
        let b = MouseSideButtonDeduplicator.Edge(button: 4, down: true)
        XCTAssertNil(events.noteCG(a, time: 1))
        XCTAssertTrue(events.shouldDeliverHID(b, time: 1.01))
        XCTAssertTrue(events.shouldDeliverHID(a, time: 2))
        events.noteHID(a, time: 2, swallow: true)
        XCTAssertNil(events.noteCG(a, time: 3))
    }

}
