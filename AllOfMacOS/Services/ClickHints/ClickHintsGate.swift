import Foundation

/// Why hint mode doesn't start (pure rules; `ClickHintsModule` gathers the
/// live values).
enum ClickHintsBlock: Equatable {
    /// The lock screen is up: nothing happens, not even a HUD.
    case screenLocked
    /// Secure keyboard entry is on (a password field or app).
    case secureInput
    /// Pause AOM, timed or until resumed, or the master switch is off.
    case paused
    /// Pause AOM for the front app.
    case pausedForApp
    /// The front app is on the excluded list.
    case excludedApp(String)
    case accessibilityMissing

    /// The HUD that says why, or nil for silence.
    var hud: (title: String, detail: String)? {
        switch self {
        case .screenLocked:
            return nil
        case .secureInput:
            return ("Secure Input Is On", "A password field or app is using secure keyboard entry, so click hints stay off until it ends.")
        case .paused:
            return ("AOM Is Paused", "Resume AOM from the menu bar to use click hints.")
        case .pausedForApp:
            return ("AOM Is Paused Here", "AOM is paused for this app. Resume it from the menu bar to use click hints.")
        case .excludedApp(let name):
            return ("Click Hints Off", "Click hints are off in \(name). Change it in Text Actions › Click Hints › Excluded Apps.")
        case .accessibilityMissing:
            return ("Accessibility Needed", "Allow All of MacOS in System Settings › Privacy & Security › Accessibility, then try again.")
        }
    }
}

enum ClickHintsGate {
    /// Everything the rules look at, as values.
    struct Context: Equatable {
        var screenLocked = false
        var secureInput = false
        /// `AutomationGate.isOn`.
        var masterSwitchOn = true
        /// `TriggerSuppression` global pause.
        var globallyPaused = false
        /// `TriggerSuppression` pause for the front app.
        var appPaused = false
        var bundleID: String?
        var appName: String?
        var excludedApps: [String] = ClickHintsSettings.defaultExcludedApps
        var accessibilityTrusted = true
    }

    /// The first rule that blocks, in this order: lock screen, secure input,
    /// pause, per-app pause, excluded app, Accessibility.
    static func check(_ context: Context) -> ClickHintsBlock? {
        if context.screenLocked { return .screenLocked }
        if context.secureInput { return .secureInput }
        if !context.masterSwitchOn || context.globallyPaused { return .paused }
        if context.appPaused { return .pausedForApp }
        if let id = context.bundleID, isExcluded(id, in: context.excludedApps) {
            return .excludedApp(context.appName ?? id)
        }
        if !context.accessibilityTrusted { return .accessibilityMissing }
        return nil
    }

    /// Bundle identifiers compare without case (macOS treats them so).
    static func isExcluded(_ bundleID: String, in list: [String]) -> Bool {
        contains(list, bundleID)
    }

    static func contains(_ list: [String], _ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return list.contains { $0.lowercased() == id }
    }
}
