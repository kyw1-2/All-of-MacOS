import Foundation
import IOKit

final class HardwareReader {
    private var smc: SMCTransport?
    private var attemptedSMC = false

    func sample() -> HardwareSample {
        let interval = AOMPerformance.begin("Hardware.sample")
        defer { AOMPerformance.end("Hardware.sample", interval) }
        var sample = HardwareSample()
        if !attemptedSMC { smc = try? SMCTransport(); attemptedSMC = true }
        let channels = [
            ("Tp09", "CPU sensor", "°C"), ("Tg05", "GPU sensor", "°C"), ("TB0T", "Battery sensor", "°C"),
            ("PCPC", "CPU package", "W"), ("PG0R", "GPU power", "W"), ("PSTR", "System power", "W")
        ]
        if let smc {
            for (key, label, unit) in channels {
                guard let value = try? smc.read(key).number, value.isFinite,
                      (unit == "°C" ? 1...125 : 0...1000).contains(value) else { continue }
                sample.sensors.append(.init(id: key, name: label, value: value, unit: unit))
            }
            if let count = try? smc.read("FNum").number, (0...4).contains(count), count.rounded() == count {
                sample.fanCount = Int(count)
                for i in 0..<Int(count) {
                    guard let rpm = try? smc.read("F\(i)Ac").number, (0...20000).contains(rpm) else { continue }
                    sample.fans.append(.init(id: i, rpm: rpm, minimum: try? smc.read("F\(i)Mn").number,
                                            maximum: try? smc.read("F\(i)Mx").number))
                }
            }
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return sample }
        defer { IOObjectRelease(service) }
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, nil, 0) == KERN_SUCCESS,
              let data = raw?.takeRetainedValue() as? [String: Any] else { return sample }
        func number(_ key: String) -> Double? { (data[key] as? NSNumber)?.doubleValue }
        if let current = number("CurrentCapacity"), let maximum = number("MaxCapacity"), maximum > 0 {
            let percent = Int((current / maximum * 100).rounded())
            if (0...100).contains(percent) { sample.batteryPercent = percent }
        }
        if let temp = number("Temperature").map({ $0 / 100 }), (0...80).contains(temp) { sample.batteryTemperature = temp }
        if let volts = number("Voltage"), let current = data["InstantAmperage"] as? NSNumber {
            // Some IOKit versions bridge the signed current as an unsigned 64-bit number.
            let amperage = Int64(bitPattern: current.uint64Value)
            let watts = Double(amperage) * volts / 1_000_000
            if watts.isFinite, abs(watts) < 1000 { sample.batteryWatts = watts }
        }
        sample.onAC = (data["ExternalConnected"] as? NSNumber)?.boolValue ?? false
        sample.charging = (data["IsCharging"] as? NSNumber)?.boolValue ?? false
        return sample
    }
}
