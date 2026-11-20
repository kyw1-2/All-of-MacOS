import Foundation

enum BatteryCareMode: String, Codable, CaseIterable {
    case off, limit80, bypass
    /// 6.10: the adapter is cut (`CHIE`) so the Mac runs on its battery
    /// down to a target, as AlDente's Discharge does on macOS 26+ firmware.
    case discharge

    /// The helper protocol carries the target in the mode string: "discharge-70".
    static func parse(_ text: String) -> (mode: BatteryCareMode, target: Int?)? {
        if text.hasPrefix("discharge-") {
            guard let target = Int(text.dropFirst("discharge-".count)), (10...95).contains(target) else { return nil }
            return (.discharge, target)
        }
        return BatteryCareMode(rawValue: text).map { ($0, nil) }
    }
}

/// Pure: whether the adapter stays cut. Discharge starts only on AC and runs
/// until the battery reaches the target (the adapter reads as gone while it
/// is cut, so AC is not asked again); it never runs below 10 %.
struct DischargePolicy {
    private(set) var active = false
    /// 7.1: the target was reached. Without this latch the restored adapter
    /// read as on-AC at target + 1 % and the cut started again: a 70 ↔ 71 %
    /// micro-cycle for as long as the helper kept ticking (the app's own
    /// stop only ran while a battery view was open). A new discharge makes
    /// a new policy.
    private(set) var completed = false

    mutating func cutsAdapter(percent: Int, target: Int, onAC: Bool) -> Bool {
        if completed { return false }
        if percent <= max(10, target) { active = false; completed = true; return false }
        if !active, onAC { active = true }
        return active
    }
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
