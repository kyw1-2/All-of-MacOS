import AppKit
import IOKit.pwr_mgt

/// Amphetamine / KeepingYouAwake parity: keeps the Mac (optionally the
/// display) awake with a power assertion while enabled. A duration turns the
/// assertion off by itself — IOPMAssertionCreateWithDescription releases it at
/// the deadline, so no timer has to survive sleep or relaunch.
@MainActor
final class KeepAwakeService: ObservableObject {
    static let shared = KeepAwakeService()

    @Published private(set) var isActive = false
    @Published private(set) var endsAt: Date?

    private var assertionID: IOPMAssertionID = 0

    var remainingDescription: String? {
        guard let endsAt else { return isActive ? "until turned off" : nil }
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "until " + formatter.string(from: Date(), to: endsAt)
    }

    func toggle(minutes: Int?, keepDisplay: Bool) {
        if isActive { stop() } else { start(minutes: minutes, keepDisplay: keepDisplay) }
    }

    func start(minutes: Int?, keepDisplay: Bool) {
        guard assertionID == 0 else { return }
        let type = (keepDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        let result: IOReturn
        if let minutes, minutes > 0 {
            let deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
            result = IOPMAssertionCreateWithDescription(type, "All of MacOS Keep Awake" as CFString,
                                                        "AOM keeps the Mac awake" as CFString, nil, nil,
                                                        TimeInterval(minutes * 60),
                                                        kIOPMAssertionTimeoutActionRelease as CFString,
                                                        &assertionID)
            if result == kIOReturnSuccess { endsAt = deadline }
        } else {
            result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "All of MacOS Keep Awake" as CFString, &assertionID)
        }
        guard result == kIOReturnSuccess, assertionID != 0 else { assertionID = 0; return }
        isActive = true
        GestureLog.shared.logFromAnyThread("Keep Awake enabled\(minutes.map { " for \($0) min" } ?? "")", level: .action)
    }

    func stop() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
        endsAt = nil
        GestureLog.shared.logFromAnyThread("Keep Awake disabled", level: .action)
    }
}
