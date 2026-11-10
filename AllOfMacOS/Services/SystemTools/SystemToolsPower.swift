import AppKit
import IOKit
import IOKit.pwr_mgt
import Darwin

/// Battery details (coconutBattery style), power assertions ("what keeps the
/// Mac awake", like `pmset -g assertions`), Low Power Mode, a sleep timer and
/// "stay awake while an app runs" (Amphetamine / Lungo style). Readers use
/// IOKit and pmset; parsers are pure and unit tested.
enum PowerTools {
    // MARK: pmset

    /// `pmset -g` lines ("lowpowermode         0") as key → first value word.
    /// The header lines ("System-wide power settings:") have no value and
    /// are skipped.
    static func parsePmsetSettings(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 2, !line.hasSuffix(":") else { continue }
            // "Sleep On Power Button 1" has a multi-word key; the value is the
            // first word that is a number.
            if let index = words.firstIndex(where: { Int($0) != nil }), index > 0 {
                result[words[..<index].joined(separator: " ")] = String(words[index])
            } else {
                result[String(words[0])] = String(words[1])
            }
        }
        return result
    }

    /// Whether this Mac offers Low Power Mode at all (pmset lists the key).
    static func supportsLowPowerMode(_ settings: [String: String]) -> Bool { settings["lowpowermode"] != nil }

    static func lowPowerArguments(on: Bool) -> [String] { ["-a", "lowpowermode", on ? "1" : "0"] }

    struct Assertion: Equatable, Identifiable {
        var id: String { "\(pid)|\(type)|\(name)" }
        let pid: pid_t
        let process: String
        let type: String
        let name: String
    }

    /// The assertion types that actually stop idle sleep (system or display).
    static let sleepPreventingTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion", "PreventDiskIdle"
    ]

    /// Public IOKit query: no helper process, privilege prompt or text parsing.
    /// A read failure is reported, never presented as an empty assertion list.
    static func activeAssertions() throws -> [Assertion] {
        var unmanaged: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&unmanaged)
        guard status == kIOReturnSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "macOS could not read the power assertions (\(status))."])
        }
        guard let dictionary = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSPropertyListReadCorruptError,
                          userInfo: [NSLocalizedDescriptionKey: "macOS returned an unreadable power-assertion list."])
        }
        return parseNativeAssertions(dictionary) { pid in
            var name = [CChar](repeating: 0, count: 256)
            let count = name.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            return count > 0 ? String(cString: name) : "PID \(pid)"
        }
    }

    static func parseNativeAssertions(_ byPID: [NSNumber: [[String: Any]]],
                                      processName: (pid_t) -> String) -> [Assertion] {
        var result: [Assertion] = []
        var seen = Set<String>()
        for (number, properties) in byPID {
            guard let pid = pid_t(exactly: number.int64Value), pid > 0 else { continue }
            var resolvedName: String?
            for property in properties {
                guard let type = property[kIOPMAssertionTypeKey as String] as? String,
                      sleepPreventingTypes.contains(type),
                      (property[kIOPMAssertionLevelKey as String] as? NSNumber)?.intValue == kIOPMAssertionLevelOn else { continue }
                if resolvedName == nil { resolvedName = processName(pid) }
                let assertion = Assertion(pid: pid, process: resolvedName ?? "PID \(pid)", type: type,
                                          name: property[kIOPMAssertionNameKey as String] as? String ?? "")
                if seen.insert(assertion.id).inserted { result.append(assertion) }
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    static func assertionKind(_ type: String) -> String {
        type.contains("Display") ? "Keeps the display on" : "Keeps the Mac awake"
    }

    // MARK: Battery details

    struct BatteryDetails: Equatable {
        let percent: Int
        let cycleCount: Int?
        let designCycles: Int?
        let designCapacity: Int?
        let fullChargeCapacity: Int?
        let currentCapacity: Int?
        let healthPercent: Int?
        let temperatureCelsius: Double?
        let voltage: Double?
        let isCharging: Bool
        let onPower: Bool
        let fullyCharged: Bool

        /// The lines of the Battery Details alert.
        var lines: [String] {
            var lines = ["Charge: \(percent)% · " + (isCharging ? "Charging" : fullyCharged ? "Fully charged" : onPower ? "On power, not charging" : "On battery")]
            if let cycleCount { lines.append("Cycle count: \(cycleCount)" + (designCycles.map { " of \($0) rated" } ?? "")) }
            if let healthPercent { lines.append("Maximum capacity: \(healthPercent)% of new") }
            if let fullChargeCapacity, let designCapacity { lines.append("Full charge: \(fullChargeCapacity) mAh of \(designCapacity) mAh design") }
            if let currentCapacity { lines.append("Now holding: \(currentCapacity) mAh") }
            if let temperatureCelsius { lines.append("Temperature: " + PowerTools.temperatureText(temperatureCelsius)) }
            if let voltage { lines.append(String(format: "Voltage: %.2f V", voltage)) }
            return lines
        }
    }

    static func temperatureText(_ celsius: Double) -> String { String(format: "%.1f °C", celsius) }

    /// The AppleSmartBattery dictionary (top level merged over BatteryData,
    /// as `SystemStatus.parseBattery` reads it). Temperature is reported in
    /// hundredths of a degree Celsius; values outside 0–80 °C are dropped as
    /// sensor noise.
    static func parseBatteryDetails(_ top: [String: Any]) -> BatteryDetails? {
        guard let basic = SystemStatus.parseBattery(top) else { return nil }
        let nested = top["BatteryData"] as? [String: Any] ?? [:]
        let properties = nested.merging(top) { _, topLevel in topLevel }
        func int(_ key: String) -> Int? { (properties[key] as? NSNumber)?.intValue }
        let rawMax = int("MaxCapacity") ?? 0
        let full = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? (rawMax > 100 ? rawMax : nil)
        let current = int("AppleRawCurrentCapacity") ?? (rawMax > 100 ? int("CurrentCapacity") : nil)
        var temperature: Double?
        if let raw = int("Temperature") ?? int("VirtualTemperature") {
            let celsius = Double(raw) / 100
            if (0...80).contains(celsius) { temperature = celsius }
        }
        let voltage = int("Voltage").map { Double($0) / 1000 }
        return BatteryDetails(percent: basic.percent, cycleCount: basic.cycleCount, designCycles: int("DesignCycleCount9C"),
                              designCapacity: int("DesignCapacity"), fullChargeCapacity: full, currentCapacity: current,
                              healthPercent: basic.healthPercent, temperatureCelsius: temperature, voltage: voltage,
                              isCharging: basic.isCharging, onPower: basic.onPower,
                              fullyCharged: (properties["FullyCharged"] as? NSNumber)?.boolValue ?? false)
    }

    static func batteryDetails() -> BatteryDetails? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return parseBatteryDetails(dictionary)
    }

    /// `system_profiler SPPowerDataType -json` battery condition: macOS says
    /// "Good" in JSON and shows it as "Normal" in System Information.
    static func parseBatteryCondition(_ json: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            if let health = item["sppower_battery_health_info"] as? [String: Any], let value = health["sppower_battery_health"] as? String {
                return value == "Good" ? "Normal" : value
            }
        }
        return nil
    }
}

/// "Sleep in N minutes" (Raycast's Sleep Timer extension). The timer lives in
/// AOM, so it only fires while AOM is running; the tile says so. When it ends
/// it runs `pmset sleepnow`, which any user may do.
@MainActor
final class SleepTimerService: ObservableObject {
    static let shared = SleepTimerService()
    @Published private(set) var firesAt: Date?
    private var timer: Timer?

    var isActive: Bool { firesAt.map { $0 > Date() } ?? false }

    func start(minutes: Int) {
        cancel()
        let date = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        firesAt = date
        timer = Timer.scheduledTimer(withTimeInterval: date.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.firesAt = nil
                self?.timer = nil
                _ = try? SystemToolsCommand.run("/usr/bin/pmset", ["sleepnow"])
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        firesAt = nil
    }
}

/// Keeps the Mac awake until a chosen app quits (Amphetamine's "while app is
/// running" trigger). One power assertion, released when the app terminates,
/// when the user turns it off, or when AOM quits (macOS drops it then).
@MainActor
final class AppAwakeService: ObservableObject {
    static let shared = AppAwakeService()
    @Published private(set) var appName: String?
    private var assertion: IOPMAssertionID = 0
    private var pid: pid_t = 0
    private var observer: NSObjectProtocol?

    var isActive: Bool { appName != nil }

    func start(for app: NSRunningApplication) -> Bool {
        stop()
        var id: IOPMAssertionID = 0
        let reason = "All of MacOS: awake while \(app.localizedName ?? "an app") runs" as CFString
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess else { return false }
        assertion = id
        pid = app.processIdentifier
        appName = app.localizedName ?? app.bundleIdentifier ?? "App"
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] note in
            let ended = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in if let self, ended == self.pid { self.stop() } }
        }
        // The app may have quit between the menu and the click.
        if app.isTerminated { stop(); return false }
        return true
    }

    func stop() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        pid = 0
        appName = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}
