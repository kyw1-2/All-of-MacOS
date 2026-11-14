import AppKit
import Carbon
import CoreAudio
import IOKit.pwr_mgt

/// Everything Focus reads from or does to the rest of the Mac, behind one
/// seam. The app uses `FocusLiveSystem`; tests use a fake; isolated UI
/// previews use `FocusLiveSystem(isolated: true)`, which reads but never acts.
@MainActor
protocol FocusSystem: AnyObject {
    // Apps
    func runningApps() -> [FocusRunningApp]
    var frontmostBundleID: String? { get }
    func hide(pid: pid_t) -> Bool
    /// A normal quit (the app may ask to save). Never a force quit.
    func terminate(pid: pid_t) -> Bool
    func isRunning(pid: pid_t) -> Bool
    // Audio
    func audioActivity() -> FocusAudioActivity?
    var isOutputMuted: Bool { get }
    var outputDeviceUID: String? { get }
    func toggleOutputMute(completion: @escaping (Bool) -> Void)
    // Memory
    func appFootprints(for pids: [pid_t], completion: @escaping ([pid_t: UInt64]) -> Void)
    func memoryPressure() -> FocusMemoryPressure
    // Keep awake
    func beginKeepAwake(minutes: Int) -> IOPMAssertionID?
    func endKeepAwake(_ id: IOPMAssertionID)
    // Feedback
    func playSound(_ name: String)
    func showHUD(symbol: String, title: String, detail: String?, seconds: TimeInterval)
    // Shortcuts
    func runShortcut(_ shortcut: FocusShortcutRef, completion: @escaping @MainActor (Result<Void, FocusShortcutError>) -> Void)
    // Pause AOM (the master switch, a timed or indefinite pause, per-app pauses)
    var isAOMPaused: Bool { get }
    func isPaused(forApp bundleID: String) -> Bool
    var pausedApps: Set<String> { get }
    // Input
    var secondsSinceLastInput: TimeInterval { get }
}

@MainActor
final class FocusLiveSystem: FocusSystem {
    /// Reads the system but never changes it (isolated previews).
    let isolated: Bool
    private let memoryQueue = DispatchQueue(label: "com.kyw.allofmacos.focus.memory", qos: .utility)

    init(isolated: Bool) { self.isolated = isolated }

    // MARK: Apps

    func runningApps() -> [FocusRunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier else { return nil }
            return FocusRunningApp(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id,
                                   isHidden: app.isHidden, isActive: app.isActive, launchDate: app.launchDate)
        }
    }

    var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    func hide(pid: pid_t) -> Bool {
        guard !isolated, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        return app.hide()
    }

    func terminate(pid: pid_t) -> Bool {
        guard !isolated, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        return app.terminate()
    }

    func isRunning(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
    }

    // MARK: Audio

    func audioActivity() -> FocusAudioActivity? { FocusSystemProbes.audioActivity() }

    var isOutputMuted: Bool { AudioOutputService.isOutputMuted() }

    var outputDeviceUID: String? {
        AudioOutputService.currentDeviceID().map { AudioOutputService.string($0, kAudioDevicePropertyDeviceUID) }
    }

    func toggleOutputMute(completion: @escaping (Bool) -> Void) {
        guard !isolated else { completion(false); return }
        AudioOutputService.shared.toggleOutputMute(completion: completion)
    }

    // MARK: Memory

    func appFootprints(for pids: [pid_t], completion: @escaping ([pid_t: UInt64]) -> Void) {
        guard !pids.isEmpty else { completion([:]); return }
        memoryQueue.async {
            let totals = FocusSystemProbes.appFootprints(for: pids)
            DispatchQueue.main.async { completion(totals) }
        }
    }

    func memoryPressure() -> FocusMemoryPressure { FocusSystemProbes.memoryPressure() }

    // MARK: Keep awake

    func beginKeepAwake(minutes: Int) -> IOPMAssertionID? {
        guard !isolated else { return nil }
        let service = KeepAwakeService.shared
        // A Keep Awake the person turned on stays theirs.
        guard !service.isActive else { return nil }
        service.start(minutes: max(1, minutes), keepDisplay: true)
        return service.current?.id
    }

    func endKeepAwake(_ id: IOPMAssertionID) {
        let service = KeepAwakeService.shared
        // Only the assertion Focus created; one the person started later is left on.
        guard service.current?.id == id else { return }
        service.stop()
    }

    // MARK: Feedback

    func playSound(_ name: String) {
        guard !isolated, !name.isEmpty else { return }
        AOMSystemSound.play(name)
    }

    func showHUD(symbol: String, title: String, detail: String?, seconds: TimeInterval) {
        guard !isolated else { return }
        FocusHUD.shared.show(symbol: symbol, title: title, detail: detail, seconds: seconds)
    }

    // MARK: Shortcuts

    func runShortcut(_ shortcut: FocusShortcutRef, completion: @escaping @MainActor (Result<Void, FocusShortcutError>) -> Void) {
        guard !isolated else { return }
        FocusShortcutsCLI.run(shortcut, completion: completion)
    }

    // MARK: Pause AOM

    var isAOMPaused: Bool { !AutomationGate.isOn || TriggerSuppression.shared.isPaused }
    func isPaused(forApp bundleID: String) -> Bool { TriggerSuppression.shared.isPaused(forApp: bundleID) }
    var pausedApps: Set<String> { TriggerSuppression.shared.pause.appBundleIDs }

    // MARK: Input

    var secondsSinceLastInput: TimeInterval { FocusSystemProbes.secondsSinceLastInput() }
}
