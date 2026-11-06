import XCTest
@testable import AllOfMacOS

final class MonitorVCPTests: XCTestCase {
    func testGetAndSetFrames() {
        XCTAssertEqual(MonitorVCP.brightness.request(), [0x82, 0x01, 0x10, 0xac])
        XCTAssertEqual(MonitorVCP.volume.request(value: 0x0123), [0x84, 0x03, 0x62, 0x01, 0x23, 0xf8])
        XCTAssertEqual(MonitorVCP.brightness.request(value: 0), [0x84, 3, 0x10, 0, 0, 0xa8])
    }

    func testExtendedDDCFeaturesAndRawEnumerations() {
        XCTAssertEqual(MonitorVCP.contrast.rawValue, 0x12)
        XCTAssertEqual(MonitorVCP.inputSource.rawValue, 0x60)
        XCTAssertEqual(MonitorVCP.mute.rawValue, 0x8D)
        XCTAssertTrue(MonitorVCP.validInputSource(0x11))
        XCTAssertTrue(MonitorVCP.validInputSource(0x12))
        XCTAssertTrue(MonitorVCP.validInputSource(0x0F))
        XCTAssertTrue(MonitorVCP.validInputSource(0x1B))
        XCTAssertFalse(MonitorVCP.validInputSource(0x13))
        let source = reply([0x6e, 0x88, 2, 0, 0x60, 0, 0, 0, 0, 0x11])
        XCTAssertEqual(MonitorVCP.inputSource.decode(source)?.current, 0x11)
        XCTAssertEqual(MonitorVCP.inputSource.decode(source)?.fraction, 0)
        XCTAssertNil(MonitorVCP.contrast.decode(source))
    }

    func testCombinedSliderCrossesHardwareFloorWithoutAmplification() {
        let low = MonitorCombinedBrightness.target(slider: 0)
        XCTAssertEqual(low.hardware, 0)
        XCTAssertEqual(low.gain, 0.1, accuracy: 0.00001)
        let floor = MonitorCombinedBrightness.target(slider: 0.1)
        XCTAssertEqual(floor.hardware, 0)
        XCTAssertEqual(floor.gain, 1)
        let high = MonitorCombinedBrightness.target(slider: 1)
        XCTAssertEqual(high.hardware, 1)
        XCTAssertEqual(high.gain, 1)
        XCTAssertEqual(MonitorCombinedBrightness.slider(hardware: 0, gain: 0.1), 0, accuracy: 0.00001)
        XCTAssertEqual(MonitorCombinedBrightness.slider(hardware: 0.5, gain: 1), 0.55, accuracy: 0.00001)
    }

    private func reply(_ body: [UInt8]) -> [UInt8] {
        body + [body.reduce(0x50, ^)]
    }

    func testNonHundredMaximumAndScaling() throws {
        let data = reply([0x6e, 0x88, 2, 0, 0x62, 0, 1, 0x90, 0, 200])
        let level = try XCTUnwrap(MonitorVCP.volume.decode(data))
        XCTAssertEqual(level.fraction, 0.5)
        XCTAssertEqual(level.scaled(0.25), 100)
        XCTAssertEqual(level.scaled(-1), 0)
        XCTAssertEqual(level.scaled(2), 400)
    }

    func testRejectsMalformedOrUnrelatedReplies() {
        let valid: [UInt8] = [0x6e, 0x88, 2, 0, 0x10, 0, 0, 100, 0, 50]
        for (index, bad): (Int, UInt8) in [(0, 0), (1, 0x87), (2, 3), (3, 1), (4, 0x62),
                                          (5, 1), (7, 0), (9, 101)] {
            var corrupt = valid
            corrupt[index] = bad
            XCTAssertNil(MonitorVCP.brightness.decode(reply(corrupt)))
        }
        let frame = reply(valid)
        XCTAssertNil(MonitorVCP.brightness.decode(Array(frame.dropLast())))
        XCTAssertNil(MonitorVCP.brightness.decode(frame + [0]))
        var badChecksum = frame
        badChecksum[10] ^= 1
        XCTAssertNil(MonitorVCP.brightness.decode(badChecksum))
    }

    func testCombinedBrightnessCrossesHardwareFloorBothWays() {
        XCTAssertEqual(MonitorBrightnessStep.next(hardware: 0.03, gain: 1, up: false), .brightness(0))
        XCTAssertEqual(MonitorBrightnessStep.next(hardware: 0, gain: 1, up: false), .gamma(0.9375))
        XCTAssertEqual(MonitorBrightnessStep.next(hardware: 0, gain: 0.9375, up: true), .gamma(1))
        XCTAssertEqual(MonitorBrightnessStep.next(hardware: 0, gain: 1, up: true), .brightness(0.0625))
    }

    func testFallbackAndUltraDimRespectTheMinimum() {
        XCTAssertEqual(MonitorBrightnessStep.next(hardware: 0, gain: 0.12, up: false), .gamma(0.1))
        XCTAssertEqual(MonitorBrightnessStep.next(hardware: nil, gain: 0.12, up: false), .brightness(0.1))
        XCTAssertEqual(MonitorBrightnessStep.next(hardware: nil, gain: 1, up: true), .brightness(1))
    }
}
