import Foundation

/// Runs exclusively on the helper's serial queue. There is no arbitrary-key RPC.
final class HardwareController {
    private let smc: SMCWriting
    private let writes: SMCWriteSession
    private let readSample: () -> HardwareSample
    private let thermalPressure: () -> Bool
    private var policy = BatteryCarePolicy()
    private var battery: BatteryCareMode = .off
    private var fan: FanPreset = .auto
    private var batteryKeys: [String] = []
    private var quietSuspended = false
    private static let batteryKeys: Set<String> = ["CH0B", "CH0C", "CHTE"]
    private static let fanKeys = SMCWriteSession.keys.subtracting(batteryKeys)

    init(smc: SMCWriting, journal: URL, readSample: @escaping () -> HardwareSample, thermalPressure: @escaping () -> Bool) throws {
        self.smc = smc
        self.readSample = readSample
        self.thermalPressure = thermalPressure
        writes = try SMCWriteSession(smc: smc, journal: journal)
    }

    func configure(battery: BatteryCareMode, fan: FanPreset) throws {
        // Release the previous policy before taking ownership of another.
        try stop()
        self.battery = battery
        self.fan = fan
        if battery != .off {
            let sample = readSample()
            guard sample.batteryPercent != nil else { throw HardwareControlError.unavailable("No readable battery") }
            let b = try? smc.read("CH0B")
            let c = try? smc.read("CH0C")
            if b != nil || c != nil {
                guard b?.bytes == [0], c?.bytes == [0] else {
                    throw HardwareControlError.unavailable("Charging keys are incomplete or owned by another utility")
                }
                batteryKeys = ["CH0B", "CH0C"]
            } else if let value = try? smc.read("CHTE"), value.bytes == [0, 0, 0, 0] {
                batteryKeys = ["CHTE"]
            } else {
                throw HardwareControlError.unavailable("Legacy charging control is unsupported or already owned by another utility")
            }
        }
        try tick()
    }

    func tick() throws {
        let sample = readSample()
        if battery != .off {
            guard let percent = sample.batteryPercent else {
                throw HardwareControlError.unavailable("Battery telemetry was lost")
            }
            let inhibit = policy.inhibit(mode: battery, percent: percent, onAC: sample.onAC, temperature: sample.batteryTemperature)
            for key in batteryKeys {
                let current = try smc.read(key)
                let bytes: [UInt8] = key == "CHTE" ? [inhibit ? 1 : 0, 0, 0, 0] : [inhibit ? 2 : 0]
                try writes.write(key, SMCValue(type: current.type, bytes: bytes))
            }
        }
        guard fan != .auto else { return }
        guard let count = sample.fanCount, count > 0, sample.fans.count == count else {
            throw HardwareControlError.unavailable("No controllable fans on this Mac")
        }
        if fan == .quiet {
            if !sample.allowsQuietFan || thermalPressure() { quietSuspended = true }
            else if sample.sensors.filter({ $0.unit == "°C" && $0.id != "TB0T" }).allSatisfy({ $0.value < 65 }) { quietSuspended = false }
            if quietSuspended {
                try writes.restore(keys: Self.fanKeys)
                return
            }
        }
        for item in sample.fans {
            guard let minimum = item.minimum, let maximum = item.maximum,
                  minimum >= 500, maximum > minimum, maximum <= 20000 else {
                throw HardwareControlError.unavailable("Fan limits could not be verified")
            }
            let targetKey = "F\(item.id)Tg"
            let current = try smc.read(targetKey)
            guard let target = current.encoding(fan == .max ? maximum : minimum) else {
                throw HardwareControlError.unavailable("Unsupported fan target format")
            }
            let modeKey = "F\(item.id)Md"
            if let mode = try? smc.read(modeKey), mode.type == "ui8 ", mode.bytes.count == 1 {
                // Existing manual fan control is never acquired.
                guard mode.bytes == [0] || writes.owns(modeKey) else {
                    throw HardwareControlError.unavailable("Another utility already controls the fans")
                }
                try writes.write(targetKey, target)
                try writes.write(modeKey, SMCValue(type: mode.type, bytes: [1]))
            } else {
                let mask = try smc.read("FS! ")
                guard mask.type == "ui16", mask.bytes.count == 2, let number = mask.number else {
                    throw HardwareControlError.unavailable("Unsupported fan mode")
                }
                let bits = UInt16(number)
                guard bits == 0 || writes.owns("FS! ") else {
                    throw HardwareControlError.unavailable("Another utility already controls the fans")
                }
                try writes.write(targetKey, target)
                let updated = bits | (1 << item.id)
                try writes.write("FS! ", SMCValue(type: "ui16", bytes: [UInt8(updated >> 8), UInt8(truncatingIfNeeded: updated)]))
            }
        }
    }

    func stop() throws {
        battery = .off
        fan = .auto
        policy = BatteryCarePolicy()
        quietSuspended = false
        batteryKeys = []
        try writes.restore()
    }
}
