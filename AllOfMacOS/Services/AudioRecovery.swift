import AppKit
import CoreAudio

/// Whether an AirPlay device can carry a direct session yet (6.5).
///
/// A direct session mutes the app with its tap for the session's whole life
/// (`muteBehavior = .muted`), so attaching to a HomePod that is still
/// reconnecting — right after wake, or while the receiver drops and comes
/// back — silences an app whose media controls keep working until the 5 s
/// watchdog gives up. The check fails open: only an explicit "not alive" or
/// a zero nominal rate holds the attach back, so a device whose properties
/// cannot be read keeps the 6.4 behaviour.
enum AirPlayDeviceReadiness {
    /// Pure: nil means the HAL did not answer for that property.
    static func isReady(alive: UInt32?, nominalRate: Double?) -> Bool {
        if let alive, alive == 0 { return false }
        if let nominalRate, !(nominalRate.isFinite && nominalRate > 0) { return false }
        return true
    }

    static func isReady(deviceID: AudioDeviceID) -> Bool {
        isReady(alive: uint32(deviceID, kAudioDevicePropertyDeviceIsAlive),
                nominalRate: float64(deviceID, kAudioDevicePropertyNominalSampleRate))
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func float64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var address = address(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// The two recoveries a person can ask for when a HomePod plays nothing
/// while the app's controls still work (6.5, ⌘K and `aom://audio-reconnect`).
/// Neither changes the system output: AOM never moves audio to the speakers
/// on its own, because the HomePod is the person's choice.
@MainActor
enum AudioRecovery {
    /// Rebuilds AOM's own taps and streams in one pass (the mixer's
    /// Reconnect for every app); playback continues natively meanwhile.
    static func reconnect() {
        guard #available(macOS 14.2, *) else {
            GestureHUD.shared.show(title: "Reconnect Audio", detail: "App audio needs macOS 14.2 or later.")
            return
        }
        AppAudioEngine.shared.retryAll()
        AudioEventLog.shared.record(.outputAutoRecovery, source: "system", detail: "Reconnect requested from ⌘K or a link")
        GestureHUD.shared.show(title: "Reconnecting Audio", detail: "AOM rebuilt its app audio; playback continues meanwhile.")
    }

    static let restartCommand = MacMagicSystemToolService.ToolCommand(path: "/usr/bin/killall", arguments: ["coreaudiod"])

    /// Restarts macOS's audio service (launchd starts it again at once) after
    /// a confirmation and the standard administrator prompt. For a receiver
    /// that stays silent for every app, with or without AOM.
    static func restartCoreAudio() {
        let alert = NSAlert()
        alert.messageText = "Restart Core Audio?"
        alert.informativeText = "Every app loses sound for a few seconds while macOS restarts its audio service. Use this when the HomePod stays silent for every app. macOS asks for an administrator password."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch SystemToolsCommand.runAsAdministrator([restartCommand]) {
        case .done:
            GestureLog.shared.logFromAnyThread("Core Audio restarted on request", level: .action)
            GestureHUD.shared.show(title: "Core Audio Restarted", detail: "Sound returns in a few seconds.")
            // The HAL comes back with new device objects; rebuild after it settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if #available(macOS 14.2, *) { AppAudioEngine.shared.retryAll() }
            }
        case .cancelled:
            break
        case .failed(let message):
            GestureHUD.shared.show(title: "Core Audio Didn't Restart", detail: message)
        }
    }
}
