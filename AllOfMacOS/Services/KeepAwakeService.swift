import AppKit
import IOKit.pwr_mgt
import IOKit.ps

/// Amphetamine / KeepingYouAwake parity: keeps the Mac (optionally the
/// display) awake with a power assertion while enabled. A duration turns the
/// assertion off by itself — IOPMAssertionCreateWithDescription releases it at
/// the deadline, so no timer has to survive sleep or relaunch.
///
/// Lifecycle rules (audited 2026-10-25):
/// - `start` always replaces: a live session switches duration, and a session
///   whose deadline already passed is cleaned up before the new one is created.
/// - `isActive` stops reporting true at the deadline even though the app-side
///   ID is still around; `stop`/Turn Off is always offered while an assertion
///   exists so the user can always clear the state.
@MainActor
final class KeepAwakeService: ObservableObject {
    static let shared = KeepAwakeService()

    struct Assertion: Equatable {
        let id: IOPMAssertionID
        let minutes: Int?
        let keepDisplay: Bool
        let endsAt: Date?
    }

    /// Test seam: creates a power assertion. The default talks to IOKit; tests
    /// substitute a fake and observe create/release pairs.
    var createAssertion: (@MainActor (Int?, Bool) -> Assertion?) = { minutes, keepDisplay in
        let type = (keepDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        var id: IOPMAssertionID = 0
        let result: IOReturn
        var endsAt: Date?
        if let minutes, minutes > 0 {
            endsAt = Date().addingTimeInterval(TimeInterval(minutes) * 60)
            result = IOPMAssertionCreateWithDescription(type, "All of MacOS Keep Awake" as CFString,
                                                        "AOM keeps the Mac awake" as CFString, nil, nil,
                                                        TimeInterval(minutes * 60),
                                                        kIOPMAssertionTimeoutActionRelease as CFString,
                                                        &id)
        } else {
            result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "All of MacOS Keep Awake" as CFString, &id)
        }
        guard result == kIOReturnSuccess, id != 0 else { return nil }
        return Assertion(id: id, minutes: minutes, keepDisplay: keepDisplay, endsAt: endsAt)
    }

    /// Test seam: releases a previously created assertion.
    var releaseAssertion: (@MainActor (IOPMAssertionID) -> Void) = { IOPMAssertionRelease($0) }

    @Published private(set) var current: Assertion?

    /// Why the current assertion exists: the user, or a rule that also ends it.
    enum Origin: Equatable { case manual, externalDisplay }
    @Published private(set) var origin: Origin = .manual

    /// False again as soon as a timed assertion passes its deadline — the
    /// system releases it, so the menus must not keep advertising an active pin.
    var isActive: Bool {
        guard let current else { return false }
        if let endsAt = current.endsAt, endsAt <= Date() { return false }
        return true
    }

    var currentMinutes: Int? { current?.minutes }
    var endsAt: Date? { current?.endsAt }

    var remainingDescription: String? {
        guard let endsAt, isActive else { return isActive ? "until turned off" : nil }
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "until " + formatter.string(from: Date(), to: endsAt)
    }

    func toggle(minutes: Int?, keepDisplay: Bool) {
        if isActive { stop() } else { start(minutes: minutes, keepDisplay: keepDisplay) }
    }

    func start(minutes: Int?, keepDisplay: Bool, origin: Origin = .manual) {
        // Always replace: a live session switches duration, and an expired one
        // (system already released it) is cleared so a restart cannot be
        // blocked by the stale ID — the bug the audit reproduced.
        clearCurrent()
        guard let assertion = createAssertion(minutes, keepDisplay) else { return }
        current = assertion
        self.origin = origin
        let detail = minutes.map { "Active (\($0) min)" } ?? "Active indefinitely"
        GestureLog.shared.logFromAnyThread("Keep Awake enabled\(minutes.map { " for \($0) min" } ?? "")", level: .action)
        GestureHUD.shared.show(title: "Caffeine", detail: "ON — \(detail)")
    }

    func stop() {
        guard current != nil else { return }
        clearCurrent()
        GestureLog.shared.logFromAnyThread("Keep Awake disabled", level: .action)
        GestureHUD.shared.show(title: "Caffeine", detail: "OFF")
    }

    /// An assertion object may still exist after its deadline released it;
    /// callers offering "Turn Off" should use this, not `isActive`.
    var hasAssertion: Bool { current != nil }

    private func clearCurrent() {
        if let current { releaseAssertion(current.id) }
        current = nil
        origin = .manual
    }
}

/// Keep Awake's automatic rules, after KeepingYouAwake and Amphetamine (see
/// the 2026-11-18 binary review): stay awake while an external display is
/// connected, let the Mac sleep again below a battery level, and stop when
/// the session switches to another user. Notifications only, no timer.
@MainActor
final class KeepAwakeRules {
    static let shared = KeepAwakeRules()
    static let externalDisplayKey = "AOMKeepAwakeWhileExternalDisplay"
    static let batteryFloorKey = "AOMKeepAwakeBatteryFloor"
    static let batteryFloors = [10, 20, 30, 50]

    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    var whileExternalDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: Self.externalDisplayKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.externalDisplayKey); evaluateDisplays() }
    }

    /// 0: never stop for the battery.
    var batteryFloor: Int {
        get { UserDefaults.standard.integer(forKey: Self.batteryFloorKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.batteryFloorKey); evaluateBattery() }
    }

    /// Whether the rule wants an assertion: on, and a display that is not
    /// built in is connected.
    nonisolated static func wantsDisplayAssertion(enabled: Bool, builtInFlags: [Bool]) -> Bool {
        enabled && builtInFlags.contains(false)
    }

    /// Whether to let the Mac sleep: on battery at or below the floor.
    nonisolated static func shouldStopForBattery(floor: Int, percent: Int?, onBattery: Bool) -> Bool {
        guard floor > 0, onBattery, let percent else { return false }
        return percent <= floor
    }

    func start() {
        guard observers.isEmpty, !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KeepAwakeRules.shared.evaluateDisplays() }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // KeepingYouAwake: another user at the Mac ends it.
                    guard KeepAwakeService.shared.hasAssertion else { return }
                    KeepAwakeService.shared.stop()
                }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KeepAwakeRules.shared.evaluateDisplays() }
            })
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            // Power changes re-check the display rule too (Codex D01): after a
            // low-battery stop, plugging in brings an external display's
            // session back without waiting for a display event.
            DispatchQueue.main.async { MainActor.assumeIsolated { KeepAwakeRules.shared.evaluateDisplays() } }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        evaluateDisplays()
    }

    func evaluateDisplays() {
        let awake = KeepAwakeService.shared
        let flags = NSScreen.screens.compactMap { screen -> Bool? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDisplayIsBuiltin($0.uint32Value) != 0 }
        }
        let battery = SystemStatus.battery()
        let lowBattery = Self.shouldStopForBattery(floor: batteryFloor, percent: battery?.percent,
                                                   onBattery: battery.map { !$0.onPower } ?? false)
        let wanted = Self.wantsDisplayAssertion(enabled: whileExternalDisplay, builtInFlags: flags) && !lowBattery
        if wanted, !awake.isActive {
            awake.start(minutes: nil, keepDisplay: false, origin: .externalDisplay)
        } else if !wanted, awake.isActive, awake.origin == .externalDisplay {
            awake.stop()
        }
        evaluateBattery()
    }

    func evaluateBattery() {
        let awake = KeepAwakeService.shared
        guard awake.hasAssertion, batteryFloor > 0 else { return }
        let battery = SystemStatus.battery()
        let onBattery = battery.map { !$0.onPower } ?? false
        guard Self.shouldStopForBattery(floor: batteryFloor, percent: battery?.percent, onBattery: onBattery) else { return }
        awake.stop()
        GestureHUD.shared.show(title: "Keep Awake Off", detail: "Battery at \(battery?.percent ?? 0)%")
    }
}
