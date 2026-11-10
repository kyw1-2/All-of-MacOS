import AppKit
import IOKit.pwr_mgt

/// The current time, republished once a second while a phase runs, so only
/// the views that show the countdown redraw (the page observes the
/// controller, which changes only on transitions).
@MainActor
final class FocusTicker: ObservableObject {
    @Published var now: Date
    init(now: Date) { self.now = now }
}

/// What to say when a transition happens outside the window (HUD + sound).
struct FocusAnnouncement: Equatable {
    var symbol: String
    var title: String
    var detail: String?
    var playsSound: Bool
    var seconds: TimeInterval

    /// The one announcement for a batch of timer events: the last phase
    /// that ended decides. A batch that only catches up on time that passed
    /// while the Mac slept (or AOM was not running) is announced quietly.
    static func make(for events: [FocusTimerEvent], timer: FocusTimer, now: Date,
                     userInitiated: Bool, todaySessions: Int) -> FocusAnnouncement? {
        let lastCompletion = events.last { if case .completed = $0 { return true }; return false }
        if case .completed(let phase, let at)? = lastCompletion {
            if now.timeIntervalSince(at) > FocusTimer.catchUpTolerance {
                // Slept through the end: one quiet note, no sound.
                let time = at.formatted(date: .omitted, time: .shortened)
                let title = phase == .focus ? "Focus Ended" : "Break Ended"
                let detail = timer.run.map { "\($0.phase.title) until \(($0.endsAt ?? now).formatted(date: .omitted, time: .shortened))" }
                    ?? "At \(time), while the Mac was asleep"
                return FocusAnnouncement(symbol: phase.symbol, title: title, detail: detail, playsSound: false, seconds: 2.5)
            }
            switch phase {
            case .focus:
                if let run = timer.run, run.phase.isBreak {
                    let minutes = Int((run.length / 60).rounded())
                    let detail = run.phase == .longBreak ? "Take a \(minutes) min long break" : "Take a \(minutes) min break"
                    return FocusAnnouncement(symbol: "checkmark.circle.fill", title: "Focus Complete", detail: detail,
                                             playsSound: true, seconds: 2.5)
                }
                let count = "\(todaySessions) \(todaySessions == 1 ? "session" : "sessions") today"
                return FocusAnnouncement(symbol: "checkmark.circle.fill", title: "Focus Complete", detail: count,
                                         playsSound: true, seconds: 2.5)
            case .shortBreak, .longBreak:
                if let run = timer.run, run.phase == .focus {
                    return FocusAnnouncement(symbol: "timer", title: "Break Over",
                                             detail: "Focus · \(Int((run.length / 60).rounded())) min", playsSound: true, seconds: 2.5)
                }
                return FocusAnnouncement(symbol: "timer", title: "Break Over", detail: "Start the next session when you're ready",
                                         playsSound: true, seconds: 2.5)
            }
        }
        // The command itself, not the log entry it wrote.
        let lastCommand = events.last { if case .logged = $0 { return false }; return true }
        guard userInitiated, let last = lastCommand else { return nil }
        switch last {
        case .started(.focus, _):
            let ends = timer.nextDeadline.map { "Ends at \($0.formatted(date: .omitted, time: .shortened))" }
            return FocusAnnouncement(symbol: "timer", title: "Focus · \(timer.plan.focusMinutes) min", detail: ends,
                                     playsSound: false, seconds: 1.4)
        case .stopped(let phase, _):
            let logged = events.compactMap { event -> FocusLogEntry? in
                if case .logged(let entry) = event { return entry }
                return nil
            }.last
            let detail = logged.map { "\(FocusDurationFormat.minutes($0.focusedSeconds)) min focused" }
            return FocusAnnouncement(symbol: "stop.circle.fill", title: phase == .focus ? "Focus Stopped" : "Break Ended",
                                     detail: detail, playsSound: false, seconds: 1.4)
        default:
            return nil
        }
    }
}

/// Runs focus sessions: the timer (1 Hz only while a phase runs), sleep and
/// wake, the session log, and what a focus phase does to the Mac (hide
/// distracting apps, mute, keep awake, run shortcuts), undoing only what it
/// did itself. All time comes from the injected clock.
@MainActor
final class FocusSessionController: ObservableObject {
    /// What a focus phase changed, kept with the timer so a relaunch can
    /// undo it.
    struct Effects: Codable, Equatable {
        var active = false
        var mutedOutput = false
        var mutedDeviceUID: String?
        var keepAwakeID: UInt32?
    }

    private struct Persisted: Codable {
        var timer: FocusTimer
        var effects: Effects
    }

    static let stateFileName = "state.json"

    @Published private(set) var timer: FocusTimer
    @Published private(set) var stats = FocusStats()
    /// The last shortcut failure, shown on the page until a run succeeds.
    @Published private(set) var shortcutProblem: String?
    let ticker: FocusTicker

    let settings: FocusSettingsStore
    let lists: FocusListsStore
    let log: FocusLogStore
    let activity: FocusActivityStore
    private let system: FocusSystem
    private let clock: () -> Date
    private let calendar: Calendar
    private let directory: URL
    /// Starts the 1 Hz timer and system observers (off in unit tests that
    /// drive `tick()` themselves).
    private let schedules: Bool

    /// Called after every transition and every tick (status board, status item).
    var onChange: (() -> Void)?

    private(set) var effects = Effects()
    private var tickTimer: Timer?
    private var midnightTimer: Timer?
    private var sessionObservers: [NSObjectProtocol] = []
    private var distractionObserver: NSObjectProtocol?
    private var lastDistractionHUD: [String: Date] = [:]

    init(system: FocusSystem, settings: FocusSettingsStore, lists: FocusListsStore, log: FocusLogStore,
         activity: FocusActivityStore, directory: URL, clock: @escaping () -> Date = Date.init,
         calendar: Calendar = .current, schedules: Bool = true) {
        self.system = system
        self.settings = settings
        self.lists = lists
        self.log = log
        self.activity = activity
        self.directory = directory
        self.clock = clock
        self.calendar = calendar
        self.schedules = schedules
        let now = clock()
        ticker = FocusTicker(now: now)
        if let saved = FocusStorage.load(Persisted.self, named: Self.stateFileName, in: directory) {
            timer = saved.timer
            effects = saved.effects
        } else {
            timer = FocusTimer(plan: settings.settings.plan)
        }
        if timer.isIdle { timer.plan = settings.settings.plan }
        stats = log.stats(now: now, calendar: calendar)
    }

    var now: Date { clock() }

    // MARK: Launch

    /// Continues a session that was running when AOM quit: completes what
    /// ended meanwhile (without a HUD at launch), restores Keep Awake and
    /// the distraction watch for a focus phase still running, and undoes a
    /// mute left from a focus that ended.
    func restoreAfterLaunch() {
        let now = clock()
        let events = timer.advance(to: now)
        process(events, userInitiated: false, announces: false)
        if timer.phase == .focus, timer.isRunning {
            if effects.active {
                // The power assertion ended with the old process.
                effects.keepAwakeID = nil
                if settings.settings.keepsAwake { effects.keepAwakeID = system.beginKeepAwake(minutes: remainingMinutes(now)) }
                updateDistractionWatch()
            } else {
                beginFocusEffects()
            }
        } else if effects.active {
            endFocusEffects()
        }
        persist()
        scheduleTicking()
        scheduleMidnightRefresh()
        onChange?()
    }

    // MARK: Commands

    /// Hotkey, status menu, Workspace: start with the saved plan, or end the
    /// running session.
    func toggle(userInitiated: Bool = true) {
        if timer.isIdle { start(userInitiated: userInitiated) } else { stop(userInitiated: userInitiated) }
    }

    func start(plan: FocusPlan? = nil, userInitiated: Bool = false) {
        let now = clock()
        guard timer.isIdle else { return }
        process(timer.start(plan: plan ?? settings.settings.plan, at: now), userInitiated: userInitiated)
    }

    func pause() { process(timer.pause(at: clock()), userInitiated: false) }
    func resume() {
        let now = clock()
        process(timer.resume(at: now), userInitiated: false)
        // A long pause may have outlasted the Keep Awake deadline.
        if timer.phase == .focus, effects.active, settings.settings.keepsAwake {
            if let id = effects.keepAwakeID { system.endKeepAwake(id) }
            effects.keepAwakeID = system.beginKeepAwake(minutes: remainingMinutes(now))
            persist()
        }
    }
    func skip() { process(timer.skip(at: clock()), userInitiated: false) }
    func stop(userInitiated: Bool = false) { process(timer.stop(at: clock()), userInitiated: userInitiated) }

    /// Applies new lengths: the next phases use them; a running phase keeps
    /// its length.
    func setPlan(_ plan: FocusPlan) {
        timer.plan = plan.normalized
        settings.settings.plan = plan.normalized
        persist()
        onChange?()
    }

    /// Called once a second while running, on wake and on launch.
    func tick() {
        let now = clock()
        ticker.now = now
        let events = timer.advance(to: now)
        if events.isEmpty { onChange?() } else { process(events, userInitiated: false) }
    }

    func refreshStats() {
        stats = log.stats(now: clock(), calendar: calendar)
    }

    // MARK: Events

    private func process(_ events: [FocusTimerEvent], userInitiated: Bool, announces: Bool = true) {
        guard !events.isEmpty else { return }
        let now = clock()
        ticker.now = now
        var endsFocus = false
        for event in events {
            switch event {
            case .logged(let entry): log.append(entry, now: now)
            case .started(.focus, _): beginFocusEffects()
            case .completed(.focus, _), .skipped(.focus, _), .stopped(.focus, _): endsFocus = true; endFocusEffects()
            default: break
            }
        }
        stats = log.stats(now: now, calendar: calendar)
        let announcement = announces ? FocusAnnouncement.make(for: events, timer: timer, now: now,
                                                              userInitiated: userInitiated,
                                                              todaySessions: stats.todaySessions) : nil
        if let announcement {
            let announce = { [weak self] in
                guard let self else { return }
                if announcement.playsSound { self.system.playSound(self.settings.settings.endSound) }
                self.system.showHUD(symbol: announcement.symbol, title: announcement.title,
                                    detail: announcement.detail, seconds: announcement.seconds)
            }
            // The end sound waits for Focus's own mute to come off.
            if endsFocus, unmuting { pendingAnnouncement = announce } else { announce() }
        }
        persist()
        scheduleTicking()
        onChange?()
    }

    private var unmuting = false
    private var pendingAnnouncement: (() -> Void)?

    // MARK: Focus effects

    private func remainingMinutes(_ now: Date) -> Int {
        Int(((timer.run?.remaining(at: now) ?? 0) / 60).rounded(.up)) + 1
    }

    private func beginFocusEffects() {
        guard !effects.active else { return }
        effects.active = true
        let options = settings.settings
        let now = clock()
        if options.hidesDistractions, !system.isAOMPaused { hideRunningDistractions() }
        if options.mutesSound, !system.isOutputMuted {
            let device = system.outputDeviceUID
            system.toggleOutputMute { [weak self] ok in
                guard let self, ok else { return }
                self.effects.mutedOutput = true
                self.effects.mutedDeviceUID = device
                self.persist()
            }
        }
        if options.keepsAwake, effects.keepAwakeID == nil {
            effects.keepAwakeID = system.beginKeepAwake(minutes: remainingMinutes(now))
        }
        if let shortcut = options.startShortcut { runShortcut(shortcut) }
        updateDistractionWatch()
    }

    private func endFocusEffects() {
        guard effects.active else { return }
        effects.active = false
        updateDistractionWatch()
        if let id = effects.keepAwakeID {
            system.endKeepAwake(id)
            effects.keepAwakeID = nil
        }
        if effects.mutedOutput {
            effects.mutedOutput = false
            // Only Focus's own mute, on the device it muted, if still muted.
            if system.isOutputMuted, system.outputDeviceUID == effects.mutedDeviceUID {
                unmuting = true
                system.toggleOutputMute { [weak self] _ in
                    guard let self else { return }
                    self.unmuting = false
                    self.pendingAnnouncement?()
                    self.pendingAnnouncement = nil
                }
            }
            effects.mutedDeviceUID = nil
        }
        if let shortcut = settings.settings.endShortcut { runShortcut(shortcut) }
    }

    private func runShortcut(_ shortcut: FocusShortcutRef) {
        system.runShortcut(shortcut) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.shortcutProblem = nil
                self.activity.add(FocusActivity(date: self.clock(), kind: .shortcut, appName: "“\(shortcut.name)”"))
            case .failure(let error):
                let reason = error.errorDescription ?? "it failed"
                self.shortcutProblem = "Couldn't run “\(shortcut.name)” because \(reason)."
                self.activity.add(FocusActivity(date: self.clock(), kind: .shortcutFailed, appName: "“\(shortcut.name)”", note: reason))
            }
            self.onChange?()
        }
    }

    // MARK: Distracting apps

    private func hideRunningDistractions() {
        let ids = Set(lists.lists.distractingApps.map(\.bundleID))
        guard !ids.isEmpty else { return }
        for app in system.runningApps() where ids.contains(app.bundleID) && !system.isPaused(forApp: app.bundleID) {
            _ = system.hide(pid: app.pid)
        }
    }

    /// The activation watch exists only during a focus phase with hiding on.
    func updateDistractionWatch() {
        let wanted = schedules && effects.active && timer.phase == .focus && settings.settings.hidesDistractions
            && !lists.lists.distractingApps.isEmpty
        if wanted, distractionObserver == nil {
            distractionObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier else { return }
                let pid = app.processIdentifier
                let name = app.localizedName ?? id
                MainActor.assumeIsolated { self?.distractingAppActivated(bundleID: id, pid: pid, name: name) }
            }
        } else if !wanted, let observer = distractionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            distractionObserver = nil
        }
    }

    /// A distracting app came forward during a running focus phase: hide it
    /// again, with a gentle HUD at most every 20 s per app.
    func distractingAppActivated(bundleID: String, pid: pid_t, name: String) {
        let now = clock()
        guard timer.phase == .focus, timer.isRunning, settings.settings.hidesDistractions, !system.isAOMPaused,
              !system.isPaused(forApp: bundleID),
              lists.lists.distractingApps.contains(where: { $0.bundleID == bundleID }) else { return }
        guard system.hide(pid: pid) else { return }
        guard settings.settings.showsDistractionHUD else { return }
        if let last = lastDistractionHUD[bundleID], now.timeIntervalSince(last) < 20 { return }
        lastDistractionHUD[bundleID] = now
        let minutes = Int(((timer.run?.remaining(at: now) ?? 0) / 60).rounded(.up))
        system.showHUD(symbol: "timer", title: "Focus: \(minutes) min left", detail: "\(name) is hidden", seconds: 1.4)
    }

    // MARK: Scheduling

    private func scheduleTicking() {
        guard schedules else { return }
        if timer.isRunning {
            if tickTimer == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                tickTimer = timer
            }
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
        // Sleep and wake matter only while a session exists.
        if timer.isIdle {
            for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            sessionObservers.removeAll()
        } else if sessionObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                         NSWorkspace.sessionDidBecomeActiveNotification] {
                sessionObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                })
            }
        }
    }

    /// Today's figures change at midnight even without a session.
    private func scheduleMidnightRefresh() {
        guard schedules else { return }
        midnightTimer?.invalidate()
        let now = clock()
        guard let next = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5),
                                           matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStats()
                self?.onChange?()
                self?.scheduleMidnightRefresh()
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    private func persist() {
        FocusStorage.save(Persisted(timer: timer, effects: effects), named: Self.stateFileName, in: directory)
    }

    /// Stops timers and observers (tests, termination).
    func tearDown() {
        tickTimer?.invalidate(); tickTimer = nil
        midnightTimer?.invalidate(); midnightTimer = nil
        for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sessionObservers.removeAll()
        if let distractionObserver { NSWorkspace.shared.notificationCenter.removeObserver(distractionObserver) }
        distractionObserver = nil
    }
}
