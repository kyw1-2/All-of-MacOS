import XCTest
@testable import AllOfMacOS

final class HardwareControllerTests: XCTestCase {
    private var directory: URL!
    private var sample = HardwareSample()
    private var pressure = false
    private var smc: SMCRecoveryTests.FakeSMC!
    private var controller: HardwareController!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        smc = SMCRecoveryTests.FakeSMC()
        smc.values["CH0C"] = .init(type: "ui8 ", bytes: [0])
        smc.values["F0Md"] = .init(type: "ui8 ", bytes: [0])
        smc.values["F0Tg"] = SMCValue(type: "fpe2", bytes: [0, 0]).encoding(3000)!
        sample.batteryPercent = 81
        sample.batteryTemperature = 30
        sample.onAC = true
        sample.fanCount = 1
        sample.fans = [.init(id: 0, rpm: 3000, minimum: 2000, maximum: 6000)]
        sample.sensors = [.init(id: "Tp09", name: "", value: 50, unit: "°C"),
                          .init(id: "Tg05", name: "", value: 50, unit: "°C")]
        controller = try HardwareController(smc: smc, journal: directory.appendingPathComponent("recovery.plist"),
                                            readSample: { self.sample }, thermalPressure: { self.pressure })
    }

    override func tearDownWithError() throws {
        try controller.stop()
        controller = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testBothChargeKeysAndStopRestore() throws {
        try controller.configure(battery: .limit80, fan: .auto)
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [2])
        XCTAssertEqual(smc.values["CH0C"]?.bytes, [2])
        sample.batteryPercent = 75
        try controller.tick()
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [0])
        XCTAssertEqual(smc.values["CH0C"]?.bytes, [0])
        try controller.stop()
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [0])
    }

    func testCHTEFallbackAndNoAdapterDisconnect() throws {
        smc.values.removeValue(forKey: "CH0B")
        smc.values.removeValue(forKey: "CH0C")
        smc.values["CHTE"] = .init(type: "ui32", bytes: [0, 0, 0, 0])
        try controller.configure(battery: .bypass, fan: .auto)
        XCTAssertEqual(smc.values["CHTE"]?.bytes, [1, 0, 0, 0])
        XCTAssertNil(smc.values["CH0I"])
        sample.onAC = false
        try controller.tick()
        XCTAssertEqual(smc.values["CHTE"]?.bytes, [0, 0, 0, 0])
    }

    func testExistingBatteryOwnerIsRejected() {
        smc.values["CH0B"] = .init(type: "ui8 ", bytes: [2])
        smc.values["CHTE"] = .init(type: "ui32", bytes: [0, 0, 0, 0])
        XCTAssertThrowsError(try controller.configure(battery: .limit80, fan: .auto))
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [2])
        XCTAssertEqual(smc.values["CH0C"]?.bytes, [0])
    }

    func testMaxSetsVerifiedTargetAndRestoresAuto() throws {
        try controller.configure(battery: .off, fan: .max)
        XCTAssertEqual(smc.values["F0Tg"]?.number, 6000)
        XCTAssertEqual(smc.values["F0Md"]?.bytes, [1])
        try controller.stop()
        XCTAssertEqual(smc.values["F0Md"]?.bytes, [0])
        XCTAssertEqual(smc.values["F0Tg"]?.number, 3000)
    }

    func testQuietReturnsToAutoUnderHeatAndRequiresCoolRecovery() throws {
        try controller.configure(battery: .off, fan: .quiet)
        XCTAssertEqual(smc.values["F0Tg"]?.number, 2000)
        pressure = true
        try controller.tick()
        XCTAssertEqual(smc.values["F0Md"]?.bytes, [0])
        pressure = false
        sample.sensors[0] = .init(id: "Tp09", name: "", value: 70, unit: "°C")
        try controller.tick()
        XCTAssertEqual(smc.values["F0Md"]?.bytes, [0])
        sample.sensors[0] = .init(id: "Tp09", name: "", value: 60, unit: "°C")
        try controller.tick()
        XCTAssertEqual(smc.values["F0Md"]?.bytes, [1])
        sample.sensors.removeAll()
        try controller.tick()
        XCTAssertEqual(smc.values["F0Md"]?.bytes, [0])
    }

    func testFanlessAndForeignManualControlAreRejected() {
        sample.fanCount = 0
        sample.fans = []
        XCTAssertThrowsError(try controller.configure(battery: .off, fan: .max))
        sample.fanCount = 1
        sample.fans = [.init(id: 0, rpm: 3000, minimum: 2000, maximum: 6000)]
        smc.values["F0Md"] = .init(type: "ui8 ", bytes: [1])
        XCTAssertThrowsError(try controller.configure(battery: .off, fan: .max))
        XCTAssertEqual(smc.values["F0Tg"]?.number, 3000)
    }

    func testPartialFanFailureReleasesOnlyOurFan() throws {
        smc.values["F1Md"] = .init(type: "ui8 ", bytes: [1])
        smc.values["F1Tg"] = smc.values["F0Tg"]
        sample.fanCount = 2
        sample.fans.append(.init(id: 1, rpm: 3000, minimum: 2000, maximum: 6000))
        XCTAssertThrowsError(try controller.configure(battery: .off, fan: .max))
        try controller.stop()
        XCTAssertEqual(smc.values["F0Md"]?.bytes, [0])
        XCTAssertEqual(smc.values["F1Md"]?.bytes, [1])
    }

    func testLegacyFanMaskPreservesBothFansAndRestores() throws {
        smc.values.removeValue(forKey: "F0Md")
        smc.values["FS! "] = .init(type: "ui16", bytes: [0, 0])
        smc.values["F1Tg"] = smc.values["F0Tg"]
        sample.fanCount = 2
        sample.fans.append(.init(id: 1, rpm: 3000, minimum: 2200, maximum: 6500))
        try controller.configure(battery: .off, fan: .max)
        XCTAssertEqual(smc.values["FS! "]?.number, 3)
        XCTAssertEqual(smc.values["F1Tg"]?.number, 6500)
        try controller.tick()
        try controller.stop()
        XCTAssertEqual(smc.values["FS! "]?.number, 0)
    }
}
