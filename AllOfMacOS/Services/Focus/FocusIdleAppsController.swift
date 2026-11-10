import AppKit

/// One rule as the page shows it: the app if it runs, how long it has been
/// idle, what holds it back, what happens next, and its memory.
struct FocusIdleRow: Identifiable, Equatable {
    var rule: FocusIdleRule
    var app: FocusRunningApp?
    var idleSeconds: TimeInterval?
    var exclusion: FocusIdleExclusion?
    var memoryBytes: UInt64?
    var nextAction: FocusIdleAction?
    var nextActionAt: Date?
    var id: UUID { rule.id }

    /// "Idle 42 min · 286 MB · quits in 18 min", "In front · 1.3 GB", "Not open".
    func statusLine(now: Date) -> String {
        guard let app else { return "Not open" }
        var parts: [String] = []
        if let exclusion, exclusion != .ruleOff {
            parts.append(exclusion.description)
        } else if app.isHidden {
            parts.append(idleSeconds.map { "Hidden · idle \(FocusDurationFormat.short($0))" } ?? "Hidden")
        } else if let idleSeconds {
            parts.append("Idle \(FocusDurationFormat.short(idleSeconds))")
        } else {
            parts.append("Open")
        }
        if let memoryBytes { parts.append(FocusByteFormat.string(memoryBytes)) }
        if exclusion == nil, let action = nextAction, let at = nextActionAt, at > now {
            parts.append("\(action == .quit ? "quits" : "hides") in \(FocusDurationFormat.short(at.timeIntervalSince(now)))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Hides and quits idle apps by rule (Quitter), quits the idlest listed apps
/// first while memory pressure is high, and logs what it did. Event driven:
/// app activations feed the idle tracker, and one timer waits for the next
/// threshold. With the feature off it holds no observer, timer or pressure
/// source.
@MainActor
final class FocusIdleAppsController: ObservableObject {
    @Published private(set) var pressure: FocusMemoryPressure = .unknown
    @Published private(set) var swapUsedBytes: UInt64?
    /// Footprints by pid, refreshed while the page shows them and before a quit.
    @Published private(set) var memory: [pid_t: UInt64] = [:]
    @Published private(set) var isActive = false

    let settings: FocusSettingsStore
    let lists: FocusListsStore
    let activity: FocusActivityStore
    private let system: FocusSystem
    private let clock: () -> Date
    private let schedules: Bool

    private(set) var tracker: FocusIdleTracker
    private var observers: [NSObjectProtocol] = []
    private var evaluationTimer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Actions wait this long after wake or unlock, so the first minutes
    /// back belong to the person.
    static let wakeGrace: TimeInterval = 120
    private var actionsAllowedAfter: Date = .distantPast
    private var away = false

    private struct PendingQuit {
        var bundleID: String
        var name: String
        var idleSeconds: TimeInterval
        var memoryBytes: UInt64?
        var underPressure: Bool
        var askedAt: Date
        var reportedStillOpen = false
    }
    private var pendingQuits: [pid_t: PendingQuit] = [:]

    // Memory-pressure episodes: at most 5 quits, 15 s apart, then a pause.
    static let reliefInterval: TimeInterval = 15
    static let reliefLimit = 5
    static let reliefCooldown: TimeInterval = 600
    private var relieving = false
    private var reliefQuits = 0
    private var reliefAllowedAfter: Date = .distantPast

    var onChange: (() -> Void)?

    init(system: FocusSystem, settings: FocusSettingsStore, lists: FocusListsStore, activity: FocusActivityStore,
         clock: @escaping () -> Date = Date.init, schedules: Bool = true) {
        self.system = system
        self.settings = settings
        self.lists = lists
        self.activity = activity
        self.clock = clock
        self.schedules = schedules
        tracker = FocusIdleTracker(startedAt: clock(), frontmost: system.frontmostBundleID)
    }

    var rules: [FocusIdleRule] { lists.lists.idleRules }
    var hasRules: Bool { !rules.isEmpty }
    /// The feature is on and at least one rule can act.
    var shouldRun: Bool { settings.settings.idleAppsEnabled && rules.contains { $0.isEnabled && $0.hidesOrQuits } }

    // MARK: Lifecycle

    /// Starts or stops observing to match the settings and rules.
    func refresh() {
        if shouldRun { activate() } else { deactivate() }
        updatePressureSource()
        onChange?()
    }

    private func activate() {
        guard !isActive else { evaluate(); return }
        isActive = true
        tracker = FocusIdleTracker(startedAt: clock(), frontmost: system.frontmostBundleID)
        actionsAllowedAfter = clock()
        guard schedules else { return }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (NSRunningApplication?) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { handler(app) }
            })
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            self?.appActivated(bundleID: app?.bundleIdentifier, pid: app?.processIdentifier)
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let id = app?.bundleIdentifier else { return }
            self?.appLaunched(bundleID: id)
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let app else { return }
            self?.appTerminated(bundleID: app.bundleIdentifier, pid: app.processIdentifier)
        }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] _ in self?.scheduleEvaluation(after: 1) }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(name) { [weak self] _ in self?.wentAway() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(name) { [weak self] _ in self?.cameBack() }
        }
        evaluate()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        evaluationTimer?.invalidate()
        evaluationTimer = nil
        pendingQuits.removeAll()
        relieving = false
    }

    func tearDown() {
        deactivate()
        pressureSource?.cancel()
        pressureSource = nil
    }

    // MARK: Events (public for tests)

    func appActivated(bundleID: String?, pid: pid_t?) {
        let now = clock()
        tracker.activated(bundleID, at: now)
        // Someone answered (or cancelled) a quit: start over for that app.
        if let pid, pendingQuits[pid]?.reportedStillOpen == true { pendingQuits[pid] = nil }
        scheduleEvaluation(after: 1)
    }

    func appLaunched(bundleID: String) {
        tracker.launched(bundleID, at: clock())
        scheduleEvaluation(after: 1)
    }

    func appTerminated(bundleID: String?, pid: pid_t) {
        if let bundleID { tracker.terminated(bundleID) }
        if let pending = pendingQuits.removeValue(forKey: pid) {
            activity.add(FocusActivity(date: clock(), kind: pending.underPressure ? .quitUnderPressure : .quit,
                                       appName: pending.name, bundleID: pending.bundleID,
                                       idleSeconds: pending.idleSeconds, memoryBytes: pending.memoryBytes))
            onChange?()
        }
        memory[pid] = nil
    }

    func wentAway() {
        away = true
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }

    func cameBack() {
        away = false
        actionsAllowedAfter = clock().addingTimeInterval(Self.wakeGrace)
        scheduleEvaluation(after: Self.wakeGrace + 1)
    }

    // MARK: Evaluation

    func context(now: Date) -> FocusIdleContext {
        FocusIdleContext(now: now, audio: system.audioActivity(), aomPaused: system.isAOMPaused,
                         pausedApps: system.pausedApps, waitingToQuit: Set(pendingQuits.keys))
    }

    func idleSeconds(for app: FocusRunningApp, now: Date) -> TimeInterval {
        tracker.idleSeconds(for: app.bundleID, launchedAt: app.launchDate, at: now)
    }

    /// Decides for every running app with a rule, acts on what is due and
    /// waits for the next threshold.
    func evaluate() {
        guard isActive else { return }
        let now = clock()
        checkPendingQuits(now: now)
        let rulesByID = Dictionary(rules.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        let apps = system.runningApps().filter { rulesByID[$0.bundleID] != nil }
        guard !apps.isEmpty else { evaluationTimer?.invalidate(); evaluationTimer = nil; return }
        let context = context(now: now)
        let decisions = apps.compactMap { app -> FocusIdleDecision? in
            guard let rule = rulesByID[app.bundleID] else { return nil }
            return FocusIdlePolicy.decide(app: app, rule: rule, idleSeconds: idleSeconds(for: app, now: now), context: context)
        }
        let mayAct = !away && now >= actionsAllowedAfter
        if mayAct {
            for decision in decisions {
                switch decision.action {
                case .hide?:
                    if system.hide(pid: decision.app.pid) {
                        activity.add(FocusActivity(date: now, kind: .hid, appName: decision.app.name,
                                                   bundleID: decision.app.bundleID, idleSeconds: decision.idleSeconds))
                    } else {
                        activity.add(FocusActivity(date: now, kind: .failed, appName: decision.app.name,
                                                   bundleID: decision.app.bundleID, note: "macOS refused to hide it"))
                    }
                case .quit?:
                    quit(decision, underPressure: false)
                case nil:
                    break
                }
            }
        }
        // The next look: the earliest threshold, a minute while something
        // due is held back by audio, recording or the front, five minutes
        // while AOM is paused, or the end of the wake grace.
        var next = decisions.compactMap(\.nextThreshold).min()
        if decisions.contains(where: { $0.isDue && ($0.exclusion?.isTransient ?? false) }) {
            next = min(next ?? .distantFuture, now.addingTimeInterval(context.aomPaused ? 300 : 60))
        }
        if !mayAct, decisions.contains(where: \.isDue) {
            next = min(next ?? .distantFuture, max(actionsAllowedAfter, now).addingTimeInterval(1))
        }
        if !pendingQuits.isEmpty { next = min(next ?? .distantFuture, now.addingTimeInterval(30)) }
        if let next { scheduleEvaluation(at: next) } else { evaluationTimer?.invalidate(); evaluationTimer = nil }
        onChange?()
    }

    private func scheduleEvaluation(after seconds: TimeInterval) {
        scheduleEvaluation(at: clock().addingTimeInterval(seconds))
    }

    private func scheduleEvaluation(at date: Date) {
        guard isActive, schedules, !away else { return }
        if let existing = evaluationTimer, existing.isValid, existing.fireDate <= date { return }
        evaluationTimer?.invalidate()
        let timer = Timer(fire: max(date, Date().addingTimeInterval(0.5)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluationTimer = nil
                self?.evaluate()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        evaluationTimer = timer
    }

    // MARK: Quitting

    /// Measures the app (for "freed"), checks again that nothing protects
    /// it, then asks it to quit the normal way. `manual` (Quit Idle Apps
    /// Now) is not held back by AOM's global pause.
    private func quit(_ decision: FocusIdleDecision, underPressure: Bool, manual: Bool = false,
                      completion: (() -> Void)? = nil) {
        let pid = decision.app.pid
        guard pendingQuits[pid] == nil else { completion?(); return }
        // Reserve it so a second evaluation does not ask twice while measuring.
        pendingQuits[pid] = PendingQuit(bundleID: decision.app.bundleID, name: decision.app.name,
                                        idleSeconds: decision.idleSeconds, memoryBytes: nil,
                                        underPressure: underPressure, askedAt: clock())
        system.appFootprints(for: [pid]) { [weak self] totals in
            guard let self else { return }
            self.memory[pid] = totals[pid] ?? self.memory[pid]
            let now = self.clock()
            var context = self.context(now: now)
            context.waitingToQuit.remove(pid)
            guard let current = self.system.runningApps().first(where: { $0.pid == pid }),
                  FocusIdlePolicy.exclusion(for: current, rule: decision.rule, context: context,
                                            ignoresGlobalPause: manual) == nil else {
                self.pendingQuits[pid] = nil
                completion?()
                return
            }
            self.pendingQuits[pid]?.memoryBytes = totals[pid]
            self.pendingQuits[pid]?.askedAt = now
            if !self.system.terminate(pid: pid) {
                self.pendingQuits[pid] = nil
                self.activity.add(FocusActivity(date: now, kind: .failed, appName: decision.app.name,
                                                bundleID: decision.app.bundleID, note: "macOS refused to quit it"))
            }
            self.onChange?()
            completion?()
        }
    }

    /// An app asked to quit a minute ago and still open is probably asking
    /// to save: say so once and leave it until someone uses it.
    private func checkPendingQuits(now: Date) {
        for (pid, pending) in pendingQuits {
            if !system.isRunning(pid: pid) {
                appTerminated(bundleID: pending.bundleID, pid: pid)
            } else if !pending.reportedStillOpen, now.timeIntervalSince(pending.askedAt) >= 60 {
                pendingQuits[pid]?.reportedStillOpen = true
                activity.add(FocusActivity(date: now, kind: .quitDeclined, appName: pending.name, bundleID: pending.bundleID,
                                           note: "It may be asking to save changes"))
            }
        }
    }

    /// Quit Idle Apps Now: the candidates, idlest first (for the confirmation).
    func quitNowCandidates() -> [FocusIdleDecision] {
        let now = clock()
        var context = context(now: now)
        context.waitingToQuit = Set(pendingQuits.keys)
        return FocusIdlePolicy.quitNowCandidates(apps: system.runningApps(), rules: rules,
                                                 idle: { self.idleSeconds(for: $0, now: now) }, context: context)
    }

    func quit(_ decisions: [FocusIdleDecision]) {
        for decision in decisions { quit(decision, underPressure: false, manual: true) }
        if isActive { scheduleEvaluation(after: 30) }
    }

    // MARK: Memory pressure

    private func updatePressureSource() {
        let wanted = schedules && isActive && settings.settings.memoryPressureEnabled
        if wanted, pressureSource == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let event = source?.data else { return }
                MainActor.assumeIsolated { self?.pressureChanged(FocusMemoryPressure(event)) }
            }
            source.activate()
            pressureSource = source
            pressureChanged(system.memoryPressure())
        } else if !wanted, let source = pressureSource {
            source.cancel()
            pressureSource = nil
            relieving = false
        }
    }

    /// Reads the pressure level and swap now (the page, on appear).
    func refreshPressure() {
        pressure = system.memoryPressure()
        swapUsedBytes = FocusSystemProbes.swapUsedBytes()
    }

    func pressureChanged(_ level: FocusMemoryPressure) {
        pressure = level
        swapUsedBytes = FocusSystemProbes.swapUsedBytes()
        onChange?()
        if level.isHigh { relievePressure() }
    }

    /// Quits the idlest listed app, waits for memory to come back, looks
    /// again, and stops when pressure is normal, after five apps, or when no
    /// app qualifies.
    func relievePressure() {
        let now = clock()
        guard isActive, settings.settings.memoryPressureEnabled, !relieving, now >= reliefAllowedAfter,
              !away, now >= actionsAllowedAfter else { return }
        relieving = true
        reliefQuits = 0
        reliefStep()
    }

    private func reliefStep() {
        let now = clock()
        guard relieving, isActive, pressure.isHigh, reliefQuits < Self.reliefLimit else { finishRelief(); return }
        let apps = system.runningApps()
        let minimumIdle = TimeInterval(settings.settings.memoryPressureMinimumIdleMinutes) * 60
        var context = context(now: now)
        context.waitingToQuit = Set(pendingQuits.keys)
        let candidates = FocusIdlePolicy.pressureCandidates(apps: apps, rules: rules, idle: { self.idleSeconds(for: $0, now: now) },
                                                            footprints: memory, minimumIdle: minimumIdle, context: context)
        guard let first = candidates.first else { finishRelief(); return }
        reliefQuits += 1
        quit(first, underPressure: true) { [weak self] in
            guard let self else { return }
            // Memory comes back over a few seconds; tests drive this inline.
            let next = { [weak self] in
                guard let self else { return }
                self.pressure = self.system.memoryPressure()
                self.reliefStep()
            }
            if self.schedules {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.reliefInterval) { MainActor.assumeIsolated { next() } }
            } else {
                next()
            }
        }
    }

    private func finishRelief() {
        guard relieving else { return }
        relieving = false
        if reliefQuits > 0 { reliefAllowedAfter = clock().addingTimeInterval(Self.reliefCooldown) }
    }

    // MARK: Page

    /// The rules with their live state. Reads audio state once.
    func rows(now: Date) -> [FocusIdleRow] {
        let apps = system.runningApps()
        let context = context(now: now)
        return rules.map { rule in
            guard let app = apps.first(where: { $0.bundleID == rule.bundleID }) else {
                return FocusIdleRow(rule: rule)
            }
            var row = FocusIdleRow(rule: rule, app: app, memoryBytes: memory[app.pid])
            row.exclusion = FocusIdlePolicy.exclusion(for: app, rule: rule, context: context)
            guard isActive else { return row }
            let idle = idleSeconds(for: app, now: now)
            row.idleSeconds = idle
            let idleSince = now.addingTimeInterval(-idle)
            let hideAt = app.isHidden ? nil : rule.hideAfterMinutes.map { idleSince.addingTimeInterval(TimeInterval($0) * 60) }
            let quitAt = rule.quitAfterMinutes.map { idleSince.addingTimeInterval(TimeInterval($0) * 60) }
            let upcoming = [(FocusIdleAction.hide, hideAt), (.quit, quitAt)]
                .compactMap { action, date in date.map { (action, $0) } }
                .filter { $0.1 > now }
                .min { $0.1 < $1.1 }
            row.nextAction = upcoming?.0
            row.nextActionAt = upcoming?.1
            return row
        }
    }

    /// Measures the listed apps that run (the page calls it every few seconds).
    func refreshMemory() {
        let pids = system.runningApps().filter { app in rules.contains { $0.bundleID == app.bundleID } }.map(\.pid)
        system.appFootprints(for: pids) { [weak self] totals in
            guard let self else { return }
            var updated = self.memory.filter { pids.contains($0.key) }
            for (pid, bytes) in totals { updated[pid] = bytes }
            if updated != self.memory { self.memory = updated }
        }
    }

    /// Memory freed today by quits that finished.
    var freedToday: UInt64 { activity.freedToday(now: clock()) }

}
