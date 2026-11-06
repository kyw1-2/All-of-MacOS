import XCTest
@testable import AllOfMacOS

final class MouseSideButtonHIDTests: XCTestCase {
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
    func testCGObservationAfterHIDPassesItsSuppressionVerdict() {
        var events = MouseSideButtonDeduplicator()
        let press = MouseSideButtonDeduplicator.Edge(button: 4, down: true)
        events.noteHID(press, time: 12, swallow: true)
        XCTAssertEqual(events.noteCG(press, time: 12.02), true)
        XCTAssertNil(events.noteCG(press, time: 12.04))
    }
}
