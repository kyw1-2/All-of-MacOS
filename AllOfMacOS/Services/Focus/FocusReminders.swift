import AppKit

/// The two optional break reminders: 20-20-20 eye breaks (every 20 minutes
/// at the screen, look 20 feet away for 20 seconds) and stand-up reminders.
enum FocusReminderKind: String, CaseIterable, Codable {
    case eyes, stand

    var symbol: String { self == .eyes ? "eye" : "figure.stand" }
    var title: String { self == .eyes ? "Eye Break" : "Time to Stand" }
}

enum FocusReminderDecision: Equatable {
    /// Not yet; look again then.
    case wait(until: Date)
    /// Show the reminder now.
    case remind
    /// The person was away long enough to count as a break.
    case rested
}

/// When a reminder is due. Time counts from the last rest: a shown
/// reminder, five minutes without any input, sleep or a locked screen.
struct FocusReminderClock: Equatable {
    var lastRestAt: Date
    static let awayThreshold: TimeInterval = 5 * 60

    mutating func evaluate(now: Date, interval: TimeInterval, secondsSinceInput: TimeInterval) -> FocusReminderDecision {
        if secondsSinceInput >= Self.awayThreshold {
            lastRestAt = now
            return .rested
        }
        let due = lastRestAt.addingTimeInterval(interval)
        if now >= due {
            lastRestAt = now
            return .remind
        }
        return .wait(until: due)
    }
}

/// Shows the reminders as a gentle HUD. One timer per reminder that is on,
/// none when both are off. A reminder waits during a focus break (that is
/// already a rest) and while AOM is paused.
@MainActor
final class FocusReminderController {
    static let eyeInterval: TimeInterval = 20 * 60

    let settings: FocusSettingsStore
    private let system: FocusSystem
    private let clock: () -> Date
    private let schedules: Bool
    /// True during a focus break (from the session controller).
    var isOnBreak: () -> Bool = { false }
    private(set) var clocks: [FocusReminderKind: FocusReminderClock] = [:]
    private var timers: [FocusReminderKind: Timer] = [:]
    private var observers: [NSObjectProtocol] = []

    init(system: FocusSystem, settings: FocusSettingsStore, clock: @escaping () -> Date = Date.init, schedules: Bool = true) {
        self.system = system
        self.settings = settings
        self.clock = clock
        self.schedules = schedules
    }

    func interval(for kind: FocusReminderKind) -> TimeInterval {
        kind == .eyes ? Self.eyeInterval : TimeInterval(settings.settings.standMinutes) * 60
    }

    func isEnabled(_ kind: FocusReminderKind) -> Bool {
        kind == .eyes ? settings.settings.eyeBreaksEnabled : settings.settings.standBreaksEnabled
    }

    /// Starts or stops each reminder to match the settings.
    func refresh() {
        let now = clock()
        for kind in FocusReminderKind.allCases {
            if isEnabled(kind) {
                if clocks[kind] == nil { clocks[kind] = FocusReminderClock(lastRestAt: now) }
                schedule(kind, at: clocks[kind]!.lastRestAt.addingTimeInterval(interval(for: kind)))
            } else {
                clocks[kind] = nil
                timers[kind]?.invalidate()
                timers[kind] = nil
            }
        }
        updateObservers()
    }

    /// Sleep, screen sleep and a locked or switched-away session count as rest.
    func rested() {
        let now = clock()
        for kind in clocks.keys { clocks[kind]?.lastRestAt = now }
        refresh()
    }

    /// Checks one reminder (its timer fired). Public for tests.
    @discardableResult
    func check(_ kind: FocusReminderKind) -> FocusReminderDecision? {
        guard isEnabled(kind), var reminderClock = clocks[kind] else { return nil }
        let now = clock()
        if isOnBreak() || system.isAOMPaused {
            reminderClock.lastRestAt = now
            clocks[kind] = reminderClock
            schedule(kind, at: now.addingTimeInterval(interval(for: kind)))
            return .rested
        }
        let decision = reminderClock.evaluate(now: now, interval: interval(for: kind),
                                              secondsSinceInput: system.secondsSinceLastInput)
        clocks[kind] = reminderClock
        switch decision {
        case .remind:
            if kind == .eyes {
                system.showHUD(symbol: kind.symbol, title: kind.title, detail: "Look about 20 feet away for 20 seconds",
                               seconds: 5)
            } else {
                system.showHUD(symbol: kind.symbol, title: kind.title,
                               detail: "\(settings.settings.standMinutes) min at the screen. Stand up and stretch", seconds: 5)
            }
            schedule(kind, at: now.addingTimeInterval(interval(for: kind)))
        case .rested:
            schedule(kind, at: now.addingTimeInterval(interval(for: kind)))
        case .wait(let until):
            schedule(kind, at: until)
        }
        return decision
    }

    private func schedule(_ kind: FocusReminderKind, at date: Date) {
        timers[kind]?.invalidate()
        timers[kind] = nil
        guard schedules else { return }
        let delay = max(1, date.timeIntervalSince(clock()))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.check(kind) }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        timers[kind] = timer
    }

    private func updateObservers() {
        let wanted = schedules && !clocks.isEmpty
        if wanted, observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                         NSWorkspace.sessionDidBecomeActiveNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rested() }
                })
            }
        } else if !wanted, !observers.isEmpty {
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observers.removeAll()
        }
    }

    func tearDown() {
        for timer in timers.values { timer.invalidate() }
        timers.removeAll()
        clocks.removeAll()
        updateObservers()
    }
}
