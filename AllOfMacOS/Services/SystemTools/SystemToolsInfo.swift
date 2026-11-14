import AppKit
import IOKit

/// The macOS version text and the System Settings panes the tools link to.
enum SystemInfo {
    /// "27.2", or "27.2.1" with a patch number.
    static func versionText(_ version: OperatingSystemVersion) -> String {
        version.patchVersion > 0 ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
    }

    // MARK: System Settings panes

    /// The panes the tools open. Ids are the `CFBundleIdentifier`s of the
    /// Settings extensions in /System/Library/ExtensionKit/Extensions
    /// (checked on macOS 27.2); `x-apple.systempreferences:<id>` opens them.
    enum Pane: String, CaseIterable, Identifiable {
        case battery = "com.apple.Battery-Settings.extension"
        case displays = "com.apple.Displays-Settings.extension"
        case loginItems = "com.apple.LoginItems-Settings.extension"
        case timeMachine = "com.apple.Time-Machine-Settings.extension"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .battery: return "Battery"
            case .displays: return "Displays"
            case .loginItems: return "Login Items & Extensions"
            case .timeMachine: return "Time Machine"
            }
        }

        var url: URL { URL(string: "x-apple.systempreferences:\(rawValue)")! }
    }

    @discardableResult
    static func open(_ pane: Pane) -> Bool { NSWorkspace.shared.open(pane.url) }
}

/// Small readers and formatters the display, chime and VPN tiles share.
enum DisplaySoundState {
    /// Volume pill text: "45%" or "Muted".
    static func percentText(_ scalar: Float32?) -> String? {
        guard let scalar, scalar.isFinite else { return nil }
        return "\(Int((min(1, max(0, scalar)) * 100).rounded()))%"
    }

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
