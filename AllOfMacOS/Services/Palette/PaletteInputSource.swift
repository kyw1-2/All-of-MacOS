import Carbon
import Foundation

/// 6.8: the launcher types in English (Raycast's "Auto-switch input source").
///
/// Opening the launcher with a Korean input method left the first keys as
/// Hangul ("ㅏㅑㅣㅣ" for "kill"). While the panel is open the ASCII-capable
/// layout the user has (ABC, U.S.) is selected; on close the previous input
/// source comes back, unless the user changed it meanwhile.
/// `defaults write com.kyw.allofmacos AOMLauncherSwitchesToEnglish -bool false` turns it off.
@MainActor
enum PaletteInputSource {
    static let defaultsKey = "AOMLauncherSwitchesToEnglish"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private static var previous: TISInputSource?
    private static var selected: TISInputSource?

    static func id(of source: TISInputSource?) -> String? {
        guard let source, let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    /// Pure: whether to switch, from the current source's ID and ASCII flag.
    nonisolated static func needsSwitch(currentID: String?, currentIsASCII: Bool) -> Bool {
        guard let currentID else { return false }
        return !currentIsASCII && !currentID.isEmpty
    }

    /// Selects the user's ASCII-capable layout when the current source types
    /// something else (Korean, Japanese …). Remembers what to restore.
    static func switchToEnglish() {
        guard isEnabled, !PresetManager.isUIPreview else { return }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard needsSwitch(currentID: id(of: current), currentIsASCII: isASCIICapable(current)),
              let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              TISSelectInputSource(ascii) == noErr else { return }
        previous = current
        selected = ascii
    }

    /// Drops the remembered source without switching (the launcher ran an action).
    static func forget() {
        previous = nil
        selected = nil
    }

    /// Gives the previous source back if the switch is still in effect.
    static func restore() {
        defer { previous = nil; selected = nil }
        guard let previous, let selected else { return }
        let now = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard id(of: now) == id(of: selected) else { return }
        TISSelectInputSource(previous)
    }
}
