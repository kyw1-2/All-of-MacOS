import Foundation

enum BatteryCareMode: String, Codable, CaseIterable {
    case off, limit80, bypass
}

struct BatteryCarePolicy {
    private(set) var holding = false
    private(set) var overheated = false

    mutating func inhibit(mode: BatteryCareMode, percent: Int, onAC: Bool, temperature: Double?) -> Bool {
        guard mode != .off, onAC, (0...100).contains(percent), percent > 20 else {
            holding = false
            overheated = false
            return false
        }
        let temperature = temperature.flatMap { $0.isFinite && (0...80).contains($0) ? $0 : nil }
        if let temperature {
            if temperature > 35 { overheated = true }
            if temperature < 33 { overheated = false }
        }
        if percent >= 80 { holding = true }
        if percent <= 75 { holding = false }
        // An unknown temperature pauses charging while this optional policy is active.
        return mode == .bypass || holding || overheated || temperature == nil
    }
}

enum FanPreset: String, Codable, CaseIterable {
    case auto, quiet, max
}

struct HardwareSample: Codable, Equatable {
    struct Sensor: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let value: Double
        let unit: String
    }
    struct Fan: Codable, Equatable, Identifiable {
        let id: Int
        let rpm: Double
        let minimum: Double?
        let maximum: Double?
    }
    var sensors: [Sensor] = []
    var fans: [Fan] = []
    var fanCount: Int?
    var batteryPercent: Int?
    var batteryTemperature: Double?
    var batteryWatts: Double?
    var onAC = false
    var charging = false
    var message = ""

    var allowsQuietFan: Bool {
        let temperatures = sensors.filter { $0.unit == "°C" && $0.id != "TB0T" }
        return temperatures.contains { $0.id == "Tp09" } && temperatures.contains { $0.id == "Tg05" } && temperatures.allSatisfy { $0.value < 75 }
    }
}
