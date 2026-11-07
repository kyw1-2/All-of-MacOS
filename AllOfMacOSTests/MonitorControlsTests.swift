import XCTest
import Foundation
import CoreFoundation
@testable import AllOfMacOS

final class MonitorControlsTests: XCTestCase {
    private final class Bus: MonitorBus {
        let port = NSObject()
        var writes: [[UInt8]] = []
        var succeeds = true
        var readableInput = true
        var otherFeaturesReadable = true
        var responseFlags: UInt16 = 0
        var muteValue: UInt16 = 2
        var writeGate: DispatchSemaphore?

        func ports(for ids: [UInt32]) -> [UInt32: CFTypeRef] {
            ids.contains(1) ? [1: port] : [:]
        }

        func probe(_ feature: MonitorVCP, on port: CFTypeRef) -> MonitorVCP.Reading? {
            switch feature {
            case .volume: return otherFeaturesReadable ? .init(current: 40, maximum: 200) : nil
            case .inputSource: return readableInput ? .init(current: responseFlags | 0x11, maximum: 0) : nil
            case .mute: return otherFeaturesReadable ? .init(current: responseFlags | muteValue, maximum: 0) : nil
            case .contrast: return otherFeaturesReadable ? .init(current: 50, maximum: 100) : nil
            case .brightness: return nil
            }
        }

        func send(_ packet: [UInt8], to port: CFTypeRef) -> Bool {
            _ = writeGate?.wait(timeout: .now() + 3)
            writes.append(packet)
            return succeeds
        }
    }

    private func discover(_ controls: MonitorControls) {
        let ready = expectation(description: "probe")
        controls.reset(displays: [1, 2]) { ready.fulfill() }
        wait(for: [ready], timeout: 2)
    }

    func testProbeIsPerDisplayAndFeature() {
        let controls = MonitorControls(bus: Bus())
        discover(controls)
        XCTAssertNil(controls.level(2, .volume))
        XCTAssertNil(controls.level(1, .brightness))
        XCTAssertEqual(controls.level(1, .volume), 0.2)
        XCTAssertFalse(controls.request(1, .brightness, 0))
    }

    func testWriteOnlyInputSwitchWorksWithoutGetVCP() {
        let bus = Bus()
        bus.readableInput = false
        let controls = MonitorControls(bus: bus)
        discover(controls)
        XCTAssertTrue(controls.supports(1, .inputSource))
        XCTAssertNil(controls.rawValue(1, .inputSource))
        let done = expectation(description: "write-only input switch")
        XCTAssertTrue(controls.requestRaw(1, .inputSource, 0x0f) { result in
            XCTAssertEqual(result, .applied)
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(bus.writes, [MonitorVCP.inputSource.request(value: 0x0f)])
        XCTAssertNil(controls.rawValue(1, .inputSource), "Last write must not be reported as verified current source")
    }

    func testNoGhostInputMenuWhenNoVCPFeatureResponds() {
        let bus = Bus()
        bus.readableInput = false
        bus.otherFeaturesReadable = false
        let controls = MonitorControls(bus: bus)
        discover(controls)
        XCTAssertFalse(controls.supports(1, .inputSource))
        XCTAssertNil(controls.unverifiedRequestedInput(1))
        XCTAssertFalse(controls.requestRaw(1, .inputSource, 0x11))
        XCTAssertTrue(bus.writes.isEmpty)
    }

    func testFlaggedInputSourceAndZeroMuteNormalizeReadback() {
        let bus = Bus()
        bus.responseFlags = 0x8000
        bus.muteValue = 0
        let controls = MonitorControls(bus: bus)
        discover(controls)
        XCTAssertEqual(controls.rawValue(1, .inputSource), 0x11)
        XCTAssertEqual(controls.rawValue(1, .mute), 0)
        XCTAssertFalse(controls.requestRaw(1, .mute, 0), "zero can be read, but should never be sent")
    }

    func testWriteOnlyInputTracksUnverifiedRequestWithoutForgingReadback() {
        let bus = Bus()
        bus.readableInput = false
        let controls = MonitorControls(bus: bus)
        discover(controls)
        XCTAssertNil(controls.unverifiedRequestedInput(1))
        let done = expectation(description: "requested input")
        XCTAssertTrue(controls.requestRaw(1, .inputSource, 0x10) { outcome in
            XCTAssertEqual(outcome, .applied)
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertNil(controls.rawValue(1, .inputSource))
        XCTAssertEqual(controls.unverifiedRequestedInput(1), 0x10)
        discover(controls)
        XCTAssertNil(controls.unverifiedRequestedInput(1), "a new DDC topology cannot inherit unverified state")
    }

    func testRawSourceAndMuteWritesAreValidated() {
        let bus = Bus()
        let controls = MonitorControls(bus: bus)
        discover(controls)
        XCTAssertEqual(controls.rawValue(1, .inputSource), 0x11)
        XCTAssertFalse(controls.requestRaw(1, .inputSource, 0x14))
        XCTAssertFalse(controls.requestRaw(1, .inputSource, 0x800f))
        XCTAssertFalse(controls.requestRaw(1, .mute, 0))
        XCTAssertFalse(controls.request(1, .inputSource, 0.5))
        let switched = expectation(description: "input switch")
        XCTAssertTrue(controls.requestRaw(1, .inputSource, 0x12) { result in
            XCTAssertEqual(result, .applied)
            switched.fulfill()
        })
        wait(for: [switched], timeout: 2)
        XCTAssertEqual(bus.writes, [MonitorVCP.inputSource.request(value: 0x12)])
        XCTAssertEqual(controls.rawValue(1, .inputSource), 0x12)
    }

    func testDragWritesLatestValueAndUpdatesCache() {
        let bus = Bus()
        let controls = MonitorControls(bus: bus)
        discover(controls)
        let skipped = expectation(description: "superseded drag")
        XCTAssertTrue(controls.request(1, .volume, 0.25) { result in
            XCTAssertEqual(result, .cancelled)
            skipped.fulfill()
        })
        let done = expectation(description: "last write")
        XCTAssertTrue(controls.request(1, .volume, 0.75) { ok in XCTAssertEqual(ok, .applied); done.fulfill() })
        wait(for: [skipped, done], timeout: 2)
        XCTAssertEqual(bus.writes, [MonitorVCP.volume.request(value: 150)])
        XCTAssertEqual(controls.level(1, .volume), 0.75)
    }

    func testWriteFailureDisablesOnlyThatControlUntilReprobe() {
        let bus = Bus()
        bus.succeeds = false
        let controls = MonitorControls(bus: bus)
        discover(controls)
        let done = expectation(description: "failed write")
        XCTAssertTrue(controls.request(1, .volume, 0.5) { ok in XCTAssertEqual(ok, .failed); done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertFalse(controls.request(1, .volume, 0.1))
        discover(controls)
        XCTAssertEqual(controls.level(1, .volume), 0.2)
    }

    func testVolumeTracksOnlyTheBoundOutputAndClearsOnDisconnect() {
        let controls = MonitorControls(bus: Bus())
        discover(controls)
        controls.bindOutput(device: 17, display: 1)
        XCTAssertEqual(controls.outputLevel(device: 17), 0.2)
        XCTAssertNil(controls.outputLevel(device: 18))
        controls.bindOutput(device: 18, display: nil)
        XCTAssertNil(controls.outputLevel(device: 17))
        controls.bindOutput(device: 17, display: 1)
        controls.reset(displays: []) {}
        XCTAssertNil(controls.outputLevel(device: 17))
    }

    func testStalledWriteReleasesCallerBeforeDriverReturns() {
        let bus = Bus()
        let gate = DispatchSemaphore(value: 0)
        bus.writeGate = gate
        defer { gate.signal() }
        let controls = MonitorControls(bus: bus)
        discover(controls)
        let failed = expectation(description: "driver timeout")
        XCTAssertTrue(controls.request(1, .volume, 0.5) { result in
            XCTAssertEqual(result, .failed)
            failed.fulfill()
        })
        wait(for: [failed], timeout: 2)
        XCTAssertNil(controls.level(1, .volume))
    }

    func testDisconnectInvalidatesDelayedWrite() {
        let bus = Bus()
        let controls = MonitorControls(bus: bus)
        discover(controls)
        let stale = expectation(description: "stale completion")
        XCTAssertTrue(controls.request(1, .volume, 1) { result in XCTAssertEqual(result, .cancelled); stale.fulfill() })
        controls.reset(displays: []) {}
        wait(for: [stale], timeout: 2)
        XCTAssertTrue(bus.writes.isEmpty)
        XCTAssertNil(controls.level(1, .volume))
    }
}
