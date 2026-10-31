import AppKit

/// Everything Focus runs, created once. In unit tests and isolated UI
/// previews it uses a throwaway settings suite and its own data folder,
/// and its system seam reads but never acts (no hiding, quitting, muting,
/// Keep Awake, shortcuts, sounds or HUDs).
@MainActor
final class FocusEnvironment {
    static let shared = FocusEnvironment()

    let isolated: Bool
    let directory: URL
    let system: FocusSystem
    let settings: FocusSettingsStore
    let lists: FocusListsStore
    let log: FocusLogStore
    let activity: FocusActivityStore
    let session: FocusSessionController
    let idleApps: FocusIdleAppsController
    let reminders: FocusReminderController
    let statusItem: FocusStatusItemController
    private(set) var started = false

    private init() {
        isolated = PresetManager.isRunningTests || PresetManager.isUIPreview
        directory = FocusStorage.defaultDirectory
        let system: FocusSystem = FocusPreviewSystem.isRequested ? FocusPreviewSystem() : FocusLiveSystem(isolated: isolated)
        self.system = system
        settings = FocusSettingsStore(defaults: TriggerSuppression.defaultsForCurrentProcess(tag: "Focus"))
        lists = FocusListsStore(directory: directory)
        log = FocusLogStore(directory: directory)
        activity = FocusActivityStore(directory: directory)
        // Timers and observers run in the app and in previews, never under XCTest.
        let schedules = !PresetManager.isRunningTests
        session = FocusSessionController(system: system, settings: settings, lists: lists, log: log, activity: activity,
                                         directory: directory, schedules: schedules)
        idleApps = FocusIdleAppsController(system: system, settings: settings, lists: lists, activity: activity,
                                           schedules: schedules && !PresetManager.isUIPreview)
        reminders = FocusReminderController(system: system, settings: settings, schedules: schedules && !PresetManager.isUIPreview)
        statusItem = FocusStatusItemController(isolated: isolated)
        statusItem.attach(session)
        statusItem.openPage = { FocusModule.openPage() }
        reminders.isOnBreak = { [weak session] in session?.timer.phase?.isBreak ?? false }
        session.onChange = { [weak self] in self?.sessionChanged() }
        idleApps.onChange = { FocusModule.publishStatus() }
        settings.onChange = { [weak self] old, new in self?.settingsChanged(from: old, to: new) }
        lists.onChange = { [weak self] old, new in self?.listsChanged(from: old, to: new) }
    }

    /// Launch: continue a session left running, start what the settings
    /// turn on. Nothing runs for a feature that is off.
    func start() {
        guard !started else { return }
        started = true
        session.restoreAfterLaunch()
        idleApps.refresh()
        reminders.refresh()
        FocusModule.publishStatus()
        // Settings › Data › Reset Preferences removes the settings key and
        // posts this; Focus then runs with the defaults.
        resetObserver = NotificationCenter.default.addObserver(forName: .aomSettingChanged, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.reload() }
        }
        // Pending log and state writes finish before AOM exits.
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statusItem.remove()
                FocusStorage.flush()
            }
        }
    }

    private var resetObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    private func sessionChanged() {
        statusItem.update()
        FocusModule.publishStatus()
    }

    private func settingsChanged(from old: FocusSettings, to new: FocusSettings) {
        if old.plan != new.plan, session.timer.plan != new.plan { session.setPlan(new.plan) }
        if old.hidesDistractions != new.hidesDistractions { session.updateDistractionWatch() }
        if old.showsMenuBarCountdown != new.showsMenuBarCountdown { statusItem.update() }
        if old.idleAppsEnabled != new.idleAppsEnabled || old.memoryPressureEnabled != new.memoryPressureEnabled
            || old.memoryPressureMinimumIdleMinutes != new.memoryPressureMinimumIdleMinutes {
            idleApps.refresh()
        }
        if old.eyeBreaksEnabled != new.eyeBreaksEnabled || old.standBreaksEnabled != new.standBreaksEnabled
            || old.standMinutes != new.standMinutes {
            reminders.refresh()
        }
        FocusModule.publishStatus()
    }

    private func listsChanged(from old: FocusLists, to new: FocusLists) {
        if old.idleRules != new.idleRules { idleApps.refresh() }
        if old.distractingApps != new.distractingApps { session.updateDistractionWatch() }
        FocusModule.publishStatus()
    }
}

/// Focus (Session, Flow and Raycast Focus timers; Quitter's idle-app rules;
/// a memory saver for 8 GB Macs; break reminders). Per-app input sources
/// live in Settings › General (`AppInputSourcesModule`). `AOMProductivityModules`
/// calls the entry points.
@MainActor
enum FocusModule {
    static var environment: FocusEnvironment { .shared }

    /// Called once at launch (never in UI previews or unit tests).
    static func start() {
        environment.start()
    }

    /// Starts a focus session with the saved length, or ends the running one.
    /// The hotkey, the status menu and Workspace call this.
    static func toggleSession() {
        environment.session.toggle(userInitiated: true)
    }

    /// A focus or break is running or paused. `AOMModuleStatusBoard.focus.isOn`
    /// is also on while idle-app rules are on, so views that mean "a session
    /// is live" (the sidebar's On pill, the quick action's pulse) read this;
    /// the status board changes at every transition, so observing it is enough.
    static var isSessionActive: Bool { environment.session.timer.run != nil }

    /// This module's items in the status menu's Productivity section:
    /// "Start Focus · 25 min" or "Stop Focus · 18:22 left", and "Quit Idle
    /// Apps Now" while there are idle-app rules.
    static func statusMenuItems() -> [NSMenuItem] {
        let env = environment
        let session = env.session
        let title = sessionMenuTitle(timer: session.timer, plan: env.settings.settings.plan, now: session.now)
        let item = QuickAccessMenuAction.item(title, symbol: "timer") { MainActor.assumeIsolated { toggleSession() } }
        item.toolTip = session.timer.isIdle ? "Starts a focus session" : "Ends the focus session"
        if let shortcut = CaptureShortcuts.shared.shortcut(for: .toggleFocusSession) {
            let key = keyCodeToString(shortcut.keyCode)
            if key.count == 1 {
                item.keyEquivalent = key.lowercased()
                item.keyEquivalentModifierMask = shortcut.modifiers.intersection([.command, .option, .control, .shift])
            }
        }
        var items = [item]
        if env.idleApps.hasRules {
            let quit = QuickAccessMenuAction.item("Quit Idle Apps Now", symbol: "memorychip") {
                MainActor.assumeIsolated { quitIdleAppsNow() }
            }
            quit.toolTip = "Quits the apps in Focus › Idle apps that aren't in use"
            items.append(quit)
        }
        return items
    }

    /// "Start Focus · 25 min", "Stop Focus · 18:22 left",
    /// "Stop Focus · Break, 4:10 left", "Stop Focus · Paused, 18:22 left".
    static func sessionMenuTitle(timer: FocusTimer, plan: FocusPlan, now: Date) -> String {
        guard let run = timer.run else { return "Start Focus · \(plan.focusMinutes) min" }
        let left = FocusDurationFormat.countdown(run.remaining(at: now))
        if run.isPaused { return "Stop Focus · Paused, \(left) left" }
        if run.phase.isBreak { return "Stop Focus · \(run.phase.title), \(left) left" }
        return "Stop Focus · \(left) left"
    }

    /// Asks before quitting: names the apps and their memory. Apps with
    /// unsaved changes still ask to save; nothing is force quit.
    static func quitIdleAppsNow() {
        let env = environment
        let candidates = env.idleApps.quitNowCandidates()
        guard !candidates.isEmpty else {
            env.system.showHUD(symbol: "memorychip", title: "No Idle Apps to Quit",
                               detail: "Listed apps are in use, playing or recording audio, or not open", seconds: 2.5)
            return
        }
        guard !env.isolated else { return }
        env.system.appFootprints(for: candidates.map(\.app.pid)) { totals in
            let names = candidates.map { decision -> String in
                totals[decision.app.pid].map { "\(decision.app.name) (\(FocusByteFormat.string($0)))" } ?? decision.app.name
            }
            let total = candidates.compactMap { totals[$0.app.pid] }.reduce(0, +)
            let alert = NSAlert()
            alert.messageText = candidates.count == 1 ? "Quit \(candidates[0].app.name)?"
                : "Quit \(candidates.count) idle apps\(total > 0 ? " using \(FocusByteFormat.string(total))" : "")?"
            alert.informativeText = ListFormatter.localizedString(byJoining: names)
                + ". Apps with unsaved changes ask to save first."
            alert.addButton(withTitle: candidates.count == 1 ? "Quit App" : "Quit Apps")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            env.idleApps.quit(candidates)
        }
    }

    /// Shows the main window on the Focus page.
    static func openPage() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.appState?.selectedMainTab = .focus
        delegate.showMainWindow()
    }

    /// Writes Workspace's Focus tile: on while a session runs or idle-app
    /// rules are on; today's sessions as the count; the time left or
    /// today's summary as the detail.
    static func publishStatus() {
        let env = environment
        let status = AOMModuleStatusBoard.focus
        let summary = statusSummary(timer: env.session.timer, stats: env.session.stats, now: env.session.ticker.now,
                                    idleRulesOn: env.idleApps.shouldRun)
        if status.isOn != summary.isOn { status.isOn = summary.isOn }
        if status.count != summary.count { status.count = summary.count }
        if status.unit != summary.unit { status.unit = summary.unit }
        if status.detail != summary.detail { status.detail = summary.detail }
        let attention = env.session.shortcutProblem
        if status.attention != attention { status.attention = attention }
    }

    struct StatusSummary: Equatable {
        var isOn: Bool
        var count: Int
        var unit: String
        var detail: String
    }

    static func statusSummary(timer: FocusTimer, stats: FocusStats, now: Date, idleRulesOn: Bool) -> StatusSummary {
        let count = stats.todaySessions
        let unit = count == 1 ? "session" : "sessions"
        let detail: String
        if let run = timer.run {
            let left = FocusDurationFormat.countdown(run.remaining(at: now))
            if run.isPaused { detail = "Paused · \(left) left" }
            else if run.phase.isBreak { detail = "\(run.phase.title) · \(left) left" }
            else { detail = "\(left) left" }
        } else if count > 0 || stats.todaySeconds >= 60 {
            detail = stats.todaySummary
        } else if idleRulesOn {
            detail = "Watching idle apps"
        } else {
            detail = "No session today"
        }
        return StatusSummary(isOn: timer.run != nil || idleRulesOn, count: count, unit: unit, detail: detail)
    }
}
