import XCTest
@testable import AllOfMacOS

final class HardwareCareTests: XCTestCase {
    func testChargeHysteresis() {
        var policy = BatteryCarePolicy()
        func inhibit(_ percent: Int) -> Bool { policy.inhibit(mode: .limit80, percent: percent, onAC: true, temperature: 30) }
        XCTAssertFalse(inhibit(79))
        XCTAssertTrue(inhibit(80))
        XCTAssertTrue(inhibit(78))
        XCTAssertTrue(inhibit(76))
        XCTAssertFalse(inhibit(75))
        XCTAssertFalse(inhibit(79))
    }

    func testHeatHysteresis() {
        var policy = BatteryCarePolicy()
        func inhibit(_ temperature: Double) -> Bool { policy.inhibit(mode: .limit80, percent: 60, onAC: true, temperature: temperature) }
        XCTAssertFalse(inhibit(35))
        XCTAssertTrue(inhibit(36))
        XCTAssertTrue(inhibit(34))
        XCTAssertTrue(inhibit(33))
        XCTAssertFalse(inhibit(32))
    }

    func testMissingOrInvalidTemperaturePausesCharging() {
        for temperature in [nil, Double.nan, Double.infinity, -1, 100] as [Double?] {
            var policy = BatteryCarePolicy()
            XCTAssertTrue(policy.inhibit(mode: .limit80, percent: 50, onAC: true, temperature: temperature))
        }
    }

    func testBypassHasLowBatteryFloorAndRequiresAC() {
        var policy = BatteryCarePolicy()
        XCTAssertTrue(policy.inhibit(mode: .bypass, percent: 21, onAC: true, temperature: 30))
        XCTAssertFalse(policy.inhibit(mode: .bypass, percent: 20, onAC: true, temperature: 30))
        XCTAssertFalse(policy.inhibit(mode: .bypass, percent: 80, onAC: false, temperature: 30))
        XCTAssertFalse(policy.inhibit(mode: .off, percent: 100, onAC: true, temperature: 40))
        XCTAssertFalse(policy.inhibit(mode: .limit80, percent: 101, onAC: true, temperature: 30))
    }

    func testDisconnectResetsHysteresis() {
        var policy = BatteryCarePolicy()
        XCTAssertTrue(policy.inhibit(mode: .limit80, percent: 81, onAC: true, temperature: 40))
        XCTAssertFalse(policy.inhibit(mode: .limit80, percent: 78, onAC: false, temperature: 34))
        XCTAssertFalse(policy.inhibit(mode: .limit80, percent: 78, onAC: true, temperature: 34))
    }

    func testSMCCodecs() {
        XCTAssertEqual(SMCValue(type: "ui16", bytes: [0x12, 0x34]).number, 4660)
        XCTAssertEqual(SMCValue(type: "ui32", bytes: [0, 0, 1, 0]).number, 256)
        XCTAssertEqual(SMCValue(type: "sp78", bytes: [0xFE, 0x80]).number, -1.5)
        XCTAssertEqual(SMCValue(type: "fpe2", bytes: [0x2E, 0xE0]).number, 3000)
        let float = SMCValue(type: "flt ", bytes: [0, 0, 0, 0])
        XCTAssertEqual(float.encoding(4000)?.number, 4000)
        XCTAssertNil(float.encoding(.greatestFiniteMagnitude))
        XCTAssertNil(float.encoding(-1))
        XCTAssertNil(SMCValue(type: "flt ", bytes: [0, 0, 0x80, 0x7F]).number)
        XCTAssertNil(SMCValue(type: "ui16", bytes: [0]).number)
        XCTAssertNil(SMCValue(type: "fpe2", bytes: [0, 0]).encoding(20000))
    }

    func testQuietRequiresCPUAndGPUAndCoolReadings() {
        var sample = HardwareSample()
        XCTAssertFalse(sample.allowsQuietFan)
        sample.sensors = [.init(id: "Tp09", name: "", value: 50, unit: "°C")]
        XCTAssertFalse(sample.allowsQuietFan)
        sample.sensors.append(.init(id: "Tg05", name: "", value: 50, unit: "°C"))
        XCTAssertTrue(sample.allowsQuietFan)
        sample.sensors.append(.init(id: "other", name: "", value: 75, unit: "°C"))
        XCTAssertFalse(sample.allowsQuietFan)
    }

    func testWheelPreservesTotalAndStops() {
        var smooth = WheelSmoothing()
        smooth.add(x: -20, y: 120, at: 10)
        var x = 0.0, y = 0.0
        for i in 1...20 {
            let delta = smooth.step(at: 10 + Double(i) / 120)
            x += delta.x; y += delta.y
        }
        XCTAssertEqual(x, -20, accuracy: 0.00001)
        XCTAssertEqual(y, 120, accuracy: 0.00001)
        XCTAssertFalse(smooth.active)
        XCTAssertEqual(smooth.step(at: 20).y, 0)
    }

    func testWheelDirectionChangeDropsOldTailAndBoundsBurst() {
        var smooth = WheelSmoothing()
        smooth.add(x: 0, y: 100, at: 1)
        _ = smooth.step(at: 1.03)
        smooth.add(x: 0, y: -30, at: 1.04)
        XCTAssertEqual(smooth.step(at: 2).y, -30)
        smooth.add(x: 10000, y: -10000, at: 3)
        XCTAssertEqual(smooth.step(at: 4).x, 1200)
        XCTAssertFalse(smooth.active)
    }

    func testWheelBurstAccumulatesUnsentDisplacement() {
        var smooth = WheelSmoothing()
        smooth.add(x: 10, y: 20, at: 0)
        let first = smooth.step(at: 0.03)
        smooth.add(x: 30, y: 40, at: 0.04)
        let last = smooth.step(at: 1)
        XCTAssertEqual(first.x + last.x, 40, accuracy: 0.00001)
        XCTAssertEqual(first.y + last.y, 60, accuracy: 0.00001)
    }
}

final class SMCRecoveryTests: XCTestCase {
    final class FakeSMC: SMCWriting {
        var values: [String: SMCValue] = ["CH0B": .init(type: "ui8 ", bytes: [0])]
        var failAfterWrite = false
        var rejectedKeys = Set<String>()
        func read(_ key: String) throws -> SMCValue {
            guard let value = values[key] else { throw HardwareControlError.unavailable("Missing key") }
            return value
        }
        func write(_ key: String, value: SMCValue) throws {
            guard !rejectedKeys.contains(key) else { throw HardwareControlError.unavailable("Write rejected") }
            values[key] = value
            if failAfterWrite { throw HardwareControlError.unavailable("Lost readback") }
        }
    }
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    var journal: URL { directory.appendingPathComponent("journal.plist") }
    let blocked = SMCValue(type: "ui8 ", bytes: [2])

    func testNormalRestoreAndUnownedKeyRejection() throws {
        let smc = FakeSMC()
        let session = try SMCWriteSession(smc: smc, journal: journal)
        XCTAssertThrowsError(try session.write("CH0I", blocked))
        try session.write("CH0B", blocked)
        XCTAssertEqual(smc.values["CH0B"], blocked)
        try session.restore()
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [0])
    }

    func testCrashRecoveryRestoresPendingWrite() throws {
        let smc = FakeSMC()
        let session = try SMCWriteSession(smc: smc, journal: journal)
        smc.failAfterWrite = true
        XCTAssertThrowsError(try session.write("CH0B", blocked))
        smc.failAfterWrite = false
        _ = try SMCWriteSession(smc: smc, journal: journal)
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [0])
    }

    func testForeignChangeIsNotOverwritten() throws {
        let smc = FakeSMC()
        let session = try SMCWriteSession(smc: smc, journal: journal)
        try session.write("CH0B", blocked)
        smc.values["CH0B"] = .init(type: "ui8 ", bytes: [3])
        XCTAssertThrowsError(try session.write("CH0B", .init(type: "ui8 ", bytes: [0])))
        try session.restore()
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [3])
    }

    func testFailedRestoreRemainsRecoverable() throws {
        let smc = FakeSMC()
        let session = try SMCWriteSession(smc: smc, journal: journal)
        try session.write("CH0B", blocked)
        smc.failAfterWrite = true
        XCTAssertThrowsError(try session.restore())
        smc.failAfterWrite = false
        _ = try SMCWriteSession(smc: smc, journal: journal)
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [0])
    }

    func testFanTargetIsNotRestoredUntilAutoModeSucceeds() throws {
        let smc = FakeSMC()
        smc.values["F0Md"] = .init(type: "ui8 ", bytes: [0])
        smc.values["F0Tg"] = .init(type: "fpe2", bytes: [0, 0])
        let session = try SMCWriteSession(smc: smc, journal: journal)
        try session.write("F0Tg", smc.values["F0Tg"]!.encoding(6000)!)
        try session.write("F0Md", .init(type: "ui8 ", bytes: [1]))
        smc.rejectedKeys = ["F0Md"]
        XCTAssertThrowsError(try session.restore())
        XCTAssertEqual(smc.values["F0Md"]?.number, 1)
        XCTAssertEqual(smc.values["F0Tg"]?.number, 6000)
        smc.rejectedKeys = []
        try session.restore()
        XCTAssertEqual(smc.values["F0Md"]?.number, 0)
        XCTAssertEqual(smc.values["F0Tg"]?.number, 0)
    }

    func testForeignFanModeRelinquishesTargetWithoutWritingIt() throws {
        let smc = FakeSMC()
        smc.values["F0Md"] = .init(type: "ui8 ", bytes: [0])
        smc.values["F0Tg"] = .init(type: "fpe2", bytes: [0, 0])
        let session = try SMCWriteSession(smc: smc, journal: journal)
        try session.write("F0Tg", smc.values["F0Tg"]!.encoding(6000)!)
        try session.write("F0Md", .init(type: "ui8 ", bytes: [1]))
        smc.values["F0Md"] = .init(type: "ui8 ", bytes: [2])
        try session.restore()
        XCTAssertEqual(smc.values["F0Md"]?.number, 2)
        XCTAssertEqual(smc.values["F0Tg"]?.number, 6000)
    }

    func testCorruptJournalFailsClosed() throws {
        try Data("broken".utf8).write(to: journal)
        XCTAssertThrowsError(try SMCWriteSession(smc: FakeSMC(), journal: journal))
    }
}
