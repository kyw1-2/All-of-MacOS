import AppKit
import IOKit

/// About-this-Mac facts, boot and wake reasons, and the System Settings
/// panes the tools link to.
enum SystemInfo {
    struct Overview: Equatable {
        let modelName: String?
        let modelIdentifier: String?
        let chip: String?
        let memory: UInt64
        let osVersion: String
        let build: String?

        var lines: [String] {
            var lines: [String] = []
            let model = [modelName, modelIdentifier.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            if !model.isEmpty { lines.append("Model: \(model)") }
            if let chip { lines.append("Chip: \(chip)") }
            lines.append("Memory: " + SystemStatus.memorySize(memory))
            lines.append("macOS: \(osVersion)" + (build.map { " (\($0))" } ?? ""))
            return lines
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// "27.2", or "27.2.1" with a patch number.
    static func versionText(_ version: OperatingSystemVersion) -> String {
        version.patchVersion > 0 ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
    }

    /// `system_profiler SPHardwareDataType -json` → the marketing name
    /// ("MacBook Air"); there is no public API for it.
    static func parseMachineName(_ json: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let items = root["SPHardwareDataType"] as? [[String: Any]] else { return nil }
        return items.first?["machine_name"] as? String
    }

    /// Blocking (system_profiler takes about a second): call off the main thread.
    static func overview() -> Overview {
        let profiler = try? SystemToolsCommand.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json", "-detailLevel", "mini"])
        return Overview(modelName: profiler.flatMap { parseMachineName($0.stdout) },
                        modelIdentifier: sysctlString("hw.model"),
                        chip: sysctlString("machdep.cpu.brand_string"),
                        memory: ProcessInfo.processInfo.physicalMemory,
                        osVersion: versionText(ProcessInfo.processInfo.operatingSystemVersion),
                        build: sysctlString("kern.osversion"))
    }

    /// The serial number from the platform expert (what About This Mac shows).
    static func serialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return value?.isEmpty == false ? value : nil
    }

    /// `kern.shutdownreason` / `kern.wakereason` are low-level tokens
    /// ("ap_restart", "lid"); these are the ones with a plain meaning. The
    /// raw text is shown as well, because Apple doesn't document the list.
    static func explainReason(_ raw: String) -> String? {
        let tokens = raw.lowercased()
        let meanings: [(String, String)] = [("lid", "lid opened"), ("pwrbtn", "power button"), ("ap_restart", "normal restart"),
                                            ("wdog", "watchdog reset (system hang)"), ("panic", "kernel panic"),
                                            ("usb", "USB device"), ("keyboard", "keyboard"), ("rtc", "scheduled wake"),
                                            ("ethernet", "network"), ("wifi", "network")]
        var found: [String] = []
        for (token, meaning) in meanings where tokens.contains(token) && !found.contains(meaning) { found.append(meaning) }
        return found.isEmpty ? nil : found.joined(separator: ", ")
    }

    // MARK: System Settings panes

    /// The panes the tools open. Ids are the `CFBundleIdentifier`s of the
    /// Settings extensions in /System/Library/ExtensionKit/Extensions
    /// (checked on macOS 27.2); `x-apple.systempreferences:<id>` opens them.
    enum Pane: String, CaseIterable, Identifiable {
        case general = "com.apple.systempreferences.GeneralSettings"
        case about = "com.apple.SystemProfiler.AboutExtension"
        case softwareUpdate = "com.apple.Software-Update-Settings.extension"
        case storage = "com.apple.settings.Storage"
        case wifi = "com.apple.wifi-settings-extension"
        case bluetooth = "com.apple.BluetoothSettings"
        case network = "com.apple.Network-Settings.extension"
        case airDrop = "com.apple.AirDrop-Handoff-Settings.extension"
        case battery = "com.apple.Battery-Settings.extension"
        case displays = "com.apple.Displays-Settings.extension"
        case sound = "com.apple.Sound-Settings.extension"
        case appearance = "com.apple.Appearance-Settings.extension"
        case desktopDock = "com.apple.Desktop-Settings.extension"
        case controlCenter = "com.apple.ControlCenter-Settings.extension"
        case wallpaper = "com.apple.Wallpaper-Settings.extension"
        case accessibility = "com.apple.Accessibility-Settings.extension"
        case privacy = "com.apple.settings.PrivacySecurity.extension"
        case loginItems = "com.apple.LoginItems-Settings.extension"
        case timeMachine = "com.apple.Time-Machine-Settings.extension"
        case keyboard = "com.apple.Keyboard-Settings.extension"
        case trackpad = "com.apple.Trackpad-Settings.extension"
        case notifications = "com.apple.Notifications-Settings.extension"
        case focus = "com.apple.Focus-Settings.extension"
        case sharing = "com.apple.Sharing-Settings.extension"
        case startupDisk = "com.apple.Startup-Disk-Settings.extension"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .about: return "About"
            case .softwareUpdate: return "Software Update"
            case .storage: return "Storage"
            case .wifi: return "Wi-Fi"
            case .bluetooth: return "Bluetooth"
            case .network: return "Network"
            case .airDrop: return "AirDrop & Handoff"
            case .battery: return "Battery"
            case .displays: return "Displays"
            case .sound: return "Sound"
            case .appearance: return "Appearance"
            case .desktopDock: return "Desktop & Dock"
            case .controlCenter: return "Menu Bar & Control Center"
            case .wallpaper: return "Wallpaper"
            case .accessibility: return "Accessibility"
            case .privacy: return "Privacy & Security"
            case .loginItems: return "Login Items & Extensions"
            case .timeMachine: return "Time Machine"
            case .keyboard: return "Keyboard"
            case .trackpad: return "Trackpad"
            case .notifications: return "Notifications"
            case .focus: return "Focus"
            case .sharing: return "Sharing"
            case .startupDisk: return "Startup Disk"
            }
        }

        var url: URL { URL(string: "x-apple.systempreferences:\(rawValue)")! }

        /// Grouped the way the Settings sidebar groups them, for the menu.
        static let menuSections: [[Pane]] = [
            [.general, .about, .softwareUpdate, .storage, .startupDisk],
            [.wifi, .bluetooth, .network, .airDrop, .sharing],
            [.battery, .displays, .sound, .appearance, .desktopDock, .controlCenter, .wallpaper],
            [.accessibility, .privacy, .loginItems, .notifications, .focus, .timeMachine],
            [.keyboard, .trackpad]
        ]
    }

    @discardableResult
    static func open(_ pane: Pane) -> Bool { NSWorkspace.shared.open(pane.url) }
}

/// Small readers for the Display & Sound tiles' live state.
enum DisplaySoundState {
    /// Volume pill text: "45%" or "Muted".
    static func percentText(_ scalar: Float32?) -> String? {
        guard let scalar, scalar.isFinite else { return nil }
        return "\(Int((min(1, max(0, scalar)) * 100).rounded()))%"
    }

    /// The menu's volume presets.
    static let volumePresets: [Int] = [0, 10, 25, 50, 75, 100]
    static let brightnessPresets: [Int] = [10, 25, 50, 75, 100]

    /// `nvram StartupMute` prints "StartupMute\t%01" when the chime is off;
    /// a missing variable (non-zero exit) means the chime plays.
    static func startupChimeOn(nvramOutput: String, status: Int32) -> Bool {
        guard status == 0 else { return true }
        return !nvramOutput.contains("%01")
    }

    static func startupChimeArguments(on: Bool) -> [String] { ["StartupMute=" + (on ? "%00" : "%01")] }

    /// A short pill for long device names ("MacBook Air Speakers" → "MacBook Air Spea…").
    static func shortName(_ name: String, limit: Int = 14) -> String {
        name.count > limit ? String(name.prefix(limit - 1)) + "…" : name
    }
}
