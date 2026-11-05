import XCTest
import Foundation
import CoreFoundation
@testable import AllOfMacOS

final class MonitorControlsTests: XCTestCase {
    private final class Bus: MonitorBus {
        let port = NSObject()
        var writes: [[UInt8]] = []
        var succeeds = true
        var writeGate: DispatchSemaphore?

        func ports(for ids: [UInt32]) -> [UInt32: CFTypeRef] {
            ids.contains(1) ? [1: port] : [:]
        }

        func probe(_ feature: MonitorVCP, on port: CFTypeRef) -> MonitorVCP.Reading? {
            feature == .volume ? .init(current: 40, maximum: 200) : nil
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
