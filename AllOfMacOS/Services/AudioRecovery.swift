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

/// Why a HomePod crackles when AOM's own stream is clean (6.5). Measured on
/// 2026-11-19: in 30 minutes CoreAudio reported about 15 overloads on the
/// AirPlay device, 2 of them AOM's; the rest were Chrome's audio thread
/// missing its 2.7 ms deadline on page faults and timeouts while 7.2 of 8 GB
/// of swap was in use and kernel_task held 35 % for cooling.
enum AudioSystemLoad {
    enum Cause: Equatable {
        case memory(swappedGB: Double)
        case heat(ProcessInfo.ThermalState)
    }

    /// Pure: swap of 4 GB or more, or three quarters of the swap file, and
    /// a serious or critical thermal state.
    static func causes(swapUsed: UInt64, swapTotal: UInt64, thermal: ProcessInfo.ThermalState) -> [Cause] {
        var causes: [Cause] = []
        let gb = Double(swapUsed) / 1_073_741_824
        if gb >= 4 || (swapTotal > 0 && Double(swapUsed) / Double(swapTotal) >= 0.75 && gb >= 1) {
            causes.append(.memory(swappedGB: (gb * 10).rounded() / 10))
        }
        if thermal == .serious || thermal == .critical { causes.append(.heat(thermal)) }
        return causes
    }

    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    static func current() -> [Cause] {
        let swap = swapUsage() ?? (0, 0)
        return causes(swapUsed: swap.used, swapTotal: swap.total, thermal: ProcessInfo.processInfo.thermalState)
    }

    /// One line for the mixer and the HUD, or nil.
    static func summary(_ causes: [Cause]) -> String? {
        let parts = causes.map { cause -> String in
            switch cause {
            case .memory(let gb): return "the Mac is short of memory (\(gb) GB swapped)"
            case .heat: return "the Mac is slowing down to cool"
            }
        }
        guard !parts.isEmpty else { return nil }
        return "Crackle likely: " + parts.joined(separator: " and ")
    }

    /// 7.3.1 (audit AUD-08): the measured state and what it does to audio,
    /// without naming apps or guessing at causes ("charging in the sun").
    static func detail(_ causes: [Cause]) -> String {
        causes.map { cause -> String in
            switch cause {
            case .memory(let gb):
                return "\(gb) GB of memory is swapped to disk; an app's audio thread that waits for paged memory misses its 2.7 ms deadline. Closing the apps using the most memory frees it."
            case .heat(let state):
                return "Thermal state is \(state == .critical ? "critical" : "serious"); macOS slows the processor and audio threads run late until it cools."
            }
        }.joined(separator: " ")
    }
}

extension AudioRecovery {
    /// ⌘K "Check HomePod Audio": what is in the way right now.
    static func checkHomePod() {
        let causes = AudioSystemLoad.current()
        if let line = AudioSystemLoad.summary(causes) {
            GestureHUD.shared.show(title: line, detail: AudioSystemLoad.detail(causes))
        } else {
            GestureHUD.shared.show(title: "No load problem found",
                                   detail: "Memory and temperature are fine. If it still crackles, try Reconnect App Audio.")
        }
    }
}
