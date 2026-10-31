import Foundation

/// Apple's Metal Performance HUD (frame rate, GPU time, memory) for every
/// app launched from now on: `launchctl setenv MTL_HUD_ENABLED 1` puts the
/// variable into the user session's launchd environment, which apps opened
/// afterwards inherit; `unsetenv` removes it. Apps already open never see
/// the change, and the setting lasts until logout.
enum MetalHUD {
    static let variable = "MTL_HUD_ENABLED"
    static let launchctl = URL(fileURLWithPath: "/bin/launchctl")

    static var readArguments: [String] { ["getenv", variable] }
    static func writeArguments(on: Bool) -> [String] { on ? ["setenv", variable, "1"] : ["unsetenv", variable] }

    /// `launchctl getenv MTL_HUD_ENABLED` prints the value and a newline,
    /// or nothing when the variable isn't set. AOM writes "1"; a number
    /// other than 0 counts as on, anything else as off.
    static func isOn(getenvOutput: String) -> Bool {
        isOn(value: getenvOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The value as AOM's own process sees it (`getenv`): what this process
    /// was launched with, which can differ from the session's current value.
    static func isOn(value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), let number = Int(value) else { return false }
        return number != 0
    }

    static func processValue() -> String? {
        getenv(variable).map { String(cString: $0) }
    }
}
