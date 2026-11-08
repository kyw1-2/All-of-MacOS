import AppKit
import XCTest
@testable import AllOfMacOS

final class UGREENThumbWheelTests: XCTestCase {
    func testSideWheelVolumeDirectionAndClamping() {
        XCTAssertEqual(UGREENThumbWheelMapping.volumeDelta(ticks: 1), 3)
        XCTAssertEqual(UGREENThumbWheelMapping.volumeDelta(ticks: -1), -3)
        XCTAssertEqual(UGREENThumbWheelMapping.volumeDelta(ticks: 4), 12)
        XCTAssertEqual(UGREENThumbWheelMapping.volumeDelta(ticks: -100), -12)
        XCTAssertEqual(UGREENThumbWheelMapping.volumeDelta(ticks: 0), 0)
    }

    func testUGREENPanRelativeOnly() {
        XCTAssertEqual(UGREENThumbWheelMapping.vendor, 0x2b89)
        XCTAssertEqual(UGREENThumbWheelMapping.product, 0x0912)
        for (page, usage) in UGREENThumbWheelMapping.usages {
            XCTAssertTrue(UGREENThumbWheelMapping.isWheel(page: page, usage: usage, isRelative: true))
            XCTAssertFalse(UGREENThumbWheelMapping.isWheel(page: page, usage: usage, isRelative: false),
                           "Do not synthesize from absolute HID button usages")
        }
        XCTAssertFalse(UGREENThumbWheelMapping.isWheel(page: 12, usage: 0x224, isRelative: true))
        XCTAssertFalse(UGREENThumbWheelMapping.isWheel(page: 7, usage: 0x04, isRelative: true))
    }

    func testSignedEightBitDeltaAndBounds() {
        XCTAssertEqual(UGREENThumbWheelMapping.ticks(raw: 255, bitSize: 8, isRelative: true), -1)
        XCTAssertEqual(UGREENThumbWheelMapping.ticks(raw: 254, bitSize: 8, isRelative: true), -2)
        XCTAssertEqual(UGREENThumbWheelMapping.ticks(raw: -1, bitSize: 8, isRelative: true), -1)
        XCTAssertEqual(UGREENThumbWheelMapping.ticks(raw: 1, bitSize: 8, isRelative: true), 1)
        XCTAssertEqual(UGREENThumbWheelMapping.ticks(raw: 127, bitSize: 8, isRelative: true), 8)
        XCTAssertEqual(UGREENThumbWheelMapping.ticks(raw: -127, bitSize: 8, isRelative: true), -8)
        XCTAssertEqual(UGREENThumbWheelMapping.ticks(raw: 65_535, bitSize: 16, isRelative: true), -1)
        XCTAssertNil(UGREENThumbWheelMapping.ticks(raw: 0, bitSize: 8, isRelative: true))
        XCTAssertNil(UGREENThumbWheelMapping.ticks(raw: 255, bitSize: 8, isRelative: false))
        XCTAssertNil(UGREENThumbWheelMapping.ticks(raw: 256, bitSize: 8, isRelative: true))
        XCTAssertNil(UGREENThumbWheelMapping.ticks(raw: 1, bitSize: 0, isRelative: true))
    }

    func testNativeHorizontalScrollSuppressesHIDFallback() {
        XCTAssertFalse(MouseWheelInterceptor.shouldSynthesize(elapsedSinceNative: 0))
        XCTAssertFalse(MouseWheelInterceptor.shouldSynthesize(elapsedSinceNative: 0.02))
        XCTAssertFalse(MouseWheelInterceptor.shouldSynthesize(elapsedSinceNative: 0.08))
        XCTAssertTrue(MouseWheelInterceptor.shouldSynthesize(elapsedSinceNative: 0.1))
        XCTAssertTrue(MouseWheelInterceptor.shouldSynthesize(elapsedSinceNative: .infinity),
                      "no native scroll has been seen since startup")
    }

    func testHorizontalEventHasAllThreeFieldFormatsAndNoVerticalScroll() throws {
        let point = CGPoint(x: 128, y: 512)
        let event = try XCTUnwrap(UGREENThumbWheelMapping.scrollEvent(ticks: -2, location: point))
        XCTAssertEqual(event.location, point)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), -2)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -72)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2), -72 * 65_536)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), SyntheticInput.selfTag)
        XCTAssertNil(UGREENThumbWheelMapping.scrollEvent(ticks: 0, location: point))
        XCTAssertNil(UGREENThumbWheelMapping.scrollEvent(ticks: 9, location: point))
    }
}
