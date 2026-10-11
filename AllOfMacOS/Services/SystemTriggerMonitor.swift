import AppKit
import IOKit.ps

/// Fires triggers that have no physical input: scheduled times and system
/// events. This is the AOM counterpart of BTT's Other Triggers section, which
/// covers everything that is not a trackpad, keyboard, or mouse gesture.
///
/// The monitor owns one timer plus a set of notification observers, and only
/// installs the ones its registered triggers actually need. A preset with no
/// scheduled triggers therefore costs nothing.
final class SystemTriggerMonitor {

    private struct Entry {
        let id: UUID
        let kind: SystemTriggerKind
        let actions: [TriggerAction]
        let appBundleID: String?
        let activationGroupID: UUID?
    }

    private var entries: [Entry] = []
    private var activationGroups: [ActivationGroup] = []

    private var timer: Timer?
    /// The absolute minute (day-scoped) a daily/weekly entry last fired, so a
    /// tick inside the same minute does not repeat it while the next day still
    /// fires. Keying on time-of-day alone would suppress every later day.
    private var lastFiredMinute: [UUID: Int] = [:]
    private var lastIntervalFire: [UUID: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Tracks which apps were running so launches and quits can be told apart.
    private var runningBundleIDs: Set<String> = []

    // MARK: - Registration

    func registerTriggers(_ triggers: [Trigger], groups: [ActivationGroup] = []) {
        unregisterAll()
        activationGroups = groups
        entries = triggers.compactMap { trigger in
            guard trigger.isEnabled, case .systemEvent(let kind) = trigger.input else { return nil }
            return Entry(id: trigger.id, kind: kind,
                         actions: trigger.actions,
                         appBundleID: trigger.appBundleID,
                         activationGroupID: trigger.activationGroupID)
        }
        guard !entries.isEmpty else { return }

        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        // Anchor interval entries now. Recording it lazily on the first tick
        // would restart the period on every tick, so the entry would never
        // reach its interval.
        let anchor = Date()
        for entry in entries {
            if case .everyMinutes = entry.kind { lastIntervalFire[entry.id] = anchor }
        }
        startTimerIfNeeded()
        installObserversIfNeeded()
    }

    func unregisterAll() {
        timer?.invalidate(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        entries.removeAll()
        lastFiredMinute.removeAll()
        lastIntervalFire.removeAll()
    }

    // MARK: - Scheduled triggers

    private var needsTimer: Bool {
        entries.contains {
            switch $0.kind {
            case .daily, .weekly, .everyMinutes: return true
            default: return false
            }
        }
    }

    private func startTimerIfNeeded() {
        guard needsTimer else { return }
        // 20s is frequent enough that a minute boundary is never missed, and
        // cheap enough to leave running for a whole session.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Called on a timer and once at registration. Evaluates the clock against
    /// every scheduled entry.
    func tick(now: Date = Date()) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .weekday, .year, .day], from: now)
        guard let hour = components.hour, let minute = components.minute,
              let weekday = components.weekday else { return }
        let minuteStamp = hour * 60 + minute
        // A day-scoped stamp so "09:00" on one day is distinct from "09:00" on
        // the next, while still collapsing repeat ticks within one minute.
        let dayStamp = (components.year ?? 0) * 1000 + (components.day ?? 0)

        for entry in entries {
            switch entry.kind {
            case .daily(let h, let m):
                guard h == hour, m == minute else { continue }
                let stamp = dayStamp * 1440 + minuteStamp
                guard lastFiredMinute[entry.id] != stamp else { continue }
                lastFiredMinute[entry.id] = stamp
                fire(entry, reason: "daily \(String(format: "%02d:%02d", h, m))")

            case .weekly(let days, let h, let m):
                guard days.contains(weekday), h == hour, m == minute else { continue }
                let stamp = dayStamp * 1440 + minuteStamp
                guard lastFiredMinute[entry.id] != stamp else { continue }
                lastFiredMinute[entry.id] = stamp
                fire(entry, reason: "weekly")

            case .everyMinutes(let interval):
                guard interval > 0 else { continue }
                // The anchor is set at registration, so a missing entry means
                // this trigger was added without one; adopt now and wait a
                // full period rather than firing immediately.
                guard let last = lastIntervalFire[entry.id] else {
                    lastIntervalFire[entry.id] = now
                    continue
                }
                guard now.timeIntervalSince(last) >= Double(interval) * 60 else { continue }
                lastIntervalFire[entry.id] = now
                fire(entry, reason: "every \(interval)m")

            default:
                continue
            }
        }
    }

    // MARK: - Event triggers

    private func installObserversIfNeeded() {
        let needsDisplay = entries.contains { if case .displayChanged = $0.kind { return true }; return false }
        if needsDisplay {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.fireMatching { if case .displayChanged = $0 { return true }; return false }
            })
        }

        let needsLock = entries.contains {
            switch $0.kind { case .screenLocked, .screenUnlocked: return true; default: return false }
        }
        if needsLock {
            // The distributed notification is how lock state is observable
            // without a private API; the payload key distinguishes lock/unlock.
            let center = DistributedNotificationCenter.default()
            observers.append(center.addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in
                self?.fireMatching { if case .screenLocked = $0 { return true }; return false }
            })
            observers.append(center.addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
            ) { [weak self] _ in
                self?.fireMatching { if case .screenUnlocked = $0 { return true }; return false }
            })
        }

        let needsPower = entries.contains { if case .powerSourceChanged = $0.kind { return true }; return false }
        if needsPower {
            let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                Unmanaged<SystemTriggerMonitor>.fromOpaque(context).takeUnretainedValue().powerSourceChanged()
            }, Unmanaged.passUnretained(self).toOpaque())
            if let source {
                let runLoopSource = source.takeRetainedValue()
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
                powerSource = runLoopSource
            }
        }

        let needsWorkspace = entries.contains {
            switch $0.kind { case .appLaunched, .appQuit: return true; default: return false }
        }
        if needsWorkspace {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                self?.applicationChanged(note, launched: true)
            })
            workspaceObservers.append(center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                self?.applicationChanged(note, launched: false)
            })
        }
    }

    private var powerSource: CFRunLoopSource?

    private func powerSourceChanged() {
        let onAC = SystemTriggerMonitor.isOnACPower()
        fireMatching {
            if case .powerSourceChanged(let wantsAC) = $0 { return wantsAC == onAC }
            return false
        }
    }

    /// Reads the current power source through IOKit rather than shelling out to
    /// `pmset`, so this stays a cheap synchronous check on the main queue.
    static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
        }
        return true
    }

    private func applicationChanged(_ notification: Notification, launched: Bool) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        if launched {
            guard !runningBundleIDs.contains(bundleID) else { return }
            runningBundleIDs.insert(bundleID)
        } else {
            guard runningBundleIDs.contains(bundleID) else { return }
            runningBundleIDs.remove(bundleID)
        }
        fireMatching {
            switch $0 {
            case .appLaunched(let wanted): return launched && wanted == bundleID
            case .appQuit(let wanted): return !launched && wanted == bundleID
            default: return false
            }
        }
    }

    // MARK: - Firing

    private func fireMatching(_ predicate: (SystemTriggerKind) -> Bool) {
        for entry in entries where predicate(entry.kind) {
            fire(entry, reason: entry.kind.displayName)
        }
    }

    /// Reuses the shared resolver so a scheduled trigger honours the same
    /// app-scoping and activation-group rules as a gesture. A system trigger
    /// with no matching context is skipped rather than forced to run.
    private func fire(_ entry: Entry, reason: String) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let allowed = TriggerResolver.resolve(
            [entry],
            payload: entry.kind,
            frontBundleID: front,
            payloadOf: { $0.kind },
            appBundleIDOf: { $0.appBundleID },
            groups: activationGroups,
            activationGroupIDOf: { $0.activationGroupID }
        )
        guard !allowed.isEmpty else { return }
        GestureLog.shared.logFromAnyThread("System trigger fired: \(reason)", level: .action)
        ActionExecutor.fire(triggerID: entry.id, fallbackActions: entry.actions)
    }
}
