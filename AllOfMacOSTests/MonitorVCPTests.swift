import XCTest
@testable import AllOfMacOS

final class MonitorVCPTests: XCTestCase {
    func testGetAndSetFrames() {
        XCTAssertEqual(MonitorVCP.brightness.request(), [0x82, 0x01, 0x10, 0xac])
        XCTAssertEqual(MonitorVCP.volume.request(value: 0x0123), [0x84, 0x03, 0x62, 0x01, 0x23, 0xf8])
        XCTAssertEqual(MonitorVCP.brightness.request(value: 0), [0x84, 3, 0x10, 0, 0, 0xa8])
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
