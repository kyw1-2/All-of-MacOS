import Foundation
import IOKit

/// 6.10: AlDente's power flow and health from the AppleSmartBattery registry
/// entry — reading is allowed for any user (writing is gated on macOS 27).
struct BatteryTelemetry: Equatable {
    var percent: Int?
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    /// Watts: adapter in, the whole Mac's draw, battery (+ charging, − discharging).
    var adapterWatts: Double?
    var systemWatts: Double?
    var batteryWatts: Double?
    var adapterRating: Int?
    var cycleCount: Int?
    /// Full-charge capacity as a share of the design capacity.
    var health: Int?
    /// Why the battery is not charging while plugged in, when macOS says.
    var notChargingReason: Int?

    /// Pure: from the registry properties.
    static func from(_ p: [String: Any]) -> BatteryTelemetry {
        var t = BatteryTelemetry()
        t.percent = (p["CurrentCapacity"] as? Int).flatMap { (0...100).contains($0) ? $0 : nil }
        t.isCharging = p["IsCharging"] as? Bool ?? false
        t.externalConnected = p["ExternalConnected"] as? Bool ?? false
        t.fullyCharged = p["FullyCharged"] as? Bool ?? false
        t.cycleCount = p["CycleCount"] as? Int
        let battery = p["BatteryData"] as? [String: Any]
        let design = (battery?["DesignCapacity"] as? Int) ?? (p["DesignCapacity"] as? Int)
        let full = (p["AppleRawMaxCapacity"] as? Int) ?? (battery?["AppleRawMaxCapacity"] as? Int) ?? (p["NominalChargeCapacity"] as? Int)
        if let design, let full, design > 0 { t.health = min(100, Int((Double(full) / Double(design) * 100).rounded())) }
        if let adapter = p["AdapterDetails"] as? [String: Any] { t.adapterRating = adapter["Watts"] as? Int }
        if let charger = p["ChargerData"] as? [String: Any], let reason = charger["NotChargingReason"] as? Int, reason != 0 {
            t.notChargingReason = reason
        }
        if let telemetry = p["PowerTelemetryData"] as? [String: Any] {
            // Milliwatts.
            func watts(_ key: String) -> Double? { (telemetry[key] as? Int).map { Double($0) / 1000 } }
            t.adapterWatts = watts("SystemPowerIn")
            t.systemWatts = watts("SystemLoad")
            // What goes into (+) or comes out of (−) the battery: the adapter's
            // power minus what the Mac draws. Derived, so no sign is assumed.
            if let load = t.systemWatts {
                let input = t.externalConnected ? (t.adapterWatts ?? 0) : 0
                let flow = input - load
                t.batteryWatts = abs(flow) < 0.3 ? 0 : flow
            }
        }
        return t
    }

    static func read() -> BatteryTelemetry? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return from(dictionary)
    }

    /// The level "Hold Here" asks macOS for: the current one rounded up to
    /// macOS's 5 % steps, never below 80 % (macOS 27 cannot hold lower).
    static func holdLimit(for percent: Int) -> Int {
        min(100, max(80, Int((Double(percent) / 5).rounded(.up)) * 5))
    }
}
