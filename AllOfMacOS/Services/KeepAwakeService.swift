import AppKit
import IOKit.pwr_mgt

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

    func start(minutes: Int?, keepDisplay: Bool) {
        // Always replace: a live session switches duration, and an expired one
        // (system already released it) is cleared so a restart cannot be
        // blocked by the stale ID — the bug the audit reproduced.
        clearCurrent()
        guard let assertion = createAssertion(minutes, keepDisplay) else { return }
        current = assertion
        GestureLog.shared.logFromAnyThread("Keep Awake enabled\(minutes.map { " for \($0) min" } ?? "")", level: .action)
    }

    func stop() {
        guard current != nil else { return }
        clearCurrent()
        GestureLog.shared.logFromAnyThread("Keep Awake disabled", level: .action)
    }

    /// An assertion object may still exist after its deadline released it;
    /// callers offering "Turn Off" should use this, not `isActive`.
    var hasAssertion: Bool { current != nil }

    private func clearCurrent() {
        if let current { releaseAssertion(current.id) }
        current = nil
    }
}
