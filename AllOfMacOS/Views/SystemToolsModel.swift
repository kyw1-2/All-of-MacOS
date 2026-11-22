import AppKit
import CoreWLAN
import IOBluetooth

/// A tool's live state, shown beside its name or on its tile.
enum SystemToolState: Equatable {
    case on(String = "On")
    case off(String = "Off")
    case value(String)

    var text: String {
        switch self {
        case .on(let text), .off(let text), .value(let text): return text
        }
    }

    var tone: AOMTone {
        switch self {
        case .on: return .success
        case .off, .value: return .neutral
        }
    }

    init(_ on: Bool) { self = on ? .on() : .off() }
}

/// A cleanup scan waiting for the user's review: checkboxes, sizes and one
/// Move to Trash button (or a read-only list, for Folder Sizes).
struct CleanupReview: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let candidates: [CleanupCandidate]
    var selected: Set<String>
    /// False for read-only lists (Folder Sizes): no checkboxes, no Trash.
    var allowsTrash = true
    /// Rows in sections by their note (the uninstaller's folders).
    var groupsByNote = false
    /// Return means Cancel, not Move to Trash.
    var safeDefault = false
    /// A second line for some rows (id → hint), shown instead of the note
    /// when rows are grouped by it.
    var hints: [String: String] = [:]
    var uninstallTarget: (url: URL, bundleID: String)?
    /// 7.5 (Codex D01): what the duplicate scan hashed, checked again
    /// right before anything moves; and the scan to run again.
    var duplicateSets: [FileTools.DuplicateSet]?
    var duplicateScan: (folder: URL, minimum: Int64)?
}

/// Processes in a sheet, each with Quit.
struct ProcessReview: Identifiable {
    let id = UUID()
    let title: String
    /// Activity's CPU or Memory sort; nil for every other list.
    var sort: ProcessTools.Order?
    var rows: [Row]
    struct Row: Identifiable, Hashable { let id: String; let pid: pid_t; let command: String; let detail: String }
}

/// Everything the System Tools page does: runs a tool by id, keeps toggle
/// states fresh, remembers favorites and recent tools, and reports results
/// truthfully (a toast only after real success; failures stay on screen).
@MainActor
final class SystemToolsModel: ObservableObject {
    struct ToolResult: Equatable {
        let tool: SystemToolID
        let message: String
        let succeeded: Bool
        let date: Date
    }

    static let favoritesKey = "AOMSystemToolsFavorites"
    static let recentKey = "AOMSystemToolsRecent"
    nonisolated static let recentLimit = 6

    @Published private(set) var states: [SystemToolID: SystemToolState] = [:]
    @Published var running: Set<SystemToolID> = []
    @Published private(set) var favorites: [SystemToolID]
    @Published private(set) var recent: [SystemToolID]
    @Published var lastResult: ToolResult?
    /// The window's toasts: results in the success tone, notes while
    /// something runs, failures in the danger tone with why.
    let toasts = AOMToastModel()
    var toast: String? {
        get { toasts.message }
        set {
            if let newValue { toasts.show(newValue, tone: .info, seconds: 4) } else { toasts.dismiss() }
        }
    }
    /// A cleanup scan waiting for the user's review, and the tool reporting it.
    @Published var cleanupReview: CleanupReview?
    /// 7.5 (Codex F06): Folder Sizes' map, shown in place in Free Up Space.
    @Published var storageMap: StorageMapModel?
    var cleanupTool: SystemToolID = .freeUpSpace
    /// The Free Up Space sheet's chosen scan and its preview.
    @Published var showFreeUpSpace = false
    @Published var cleanupScan: CleanupScan = .folderSizes
    /// Processes that hold a port or a file, with Quit.
    @Published var processReview: ProcessReview?
    /// The Network Info sheet opens from its tile and the This Mac strip.
    @Published var showNetworkInfo = false
    /// The startup disk's detail popover from the This Mac strip. A popover,
    /// not a sheet: the strip is the only way in and nothing here is modal.
    @Published var showStartupDisk = false
    var processTool: SystemToolID = .activity

    /// States read from helper processes (nvram, tmutil, launchctl), filled
    /// in off the main thread and merged into `states`.
    var slowStates: [SystemToolID: SystemToolState] = [:]
    var slowRefreshRunning = false
    var slowRefreshThrottle = RefreshThrottle(interval: 30)
    var slowRefreshGeneration = 0
    private(set) var isVisible = false

    let service = MacMagicSystemToolService.shared
    let preferences: SystemPreferenceStore = CFPreferenceStore()
    private let defaults: UserDefaults
    private var refreshTimer: Timer?
    private let stateObserver = SystemToolsStateObserver()
    private var eventRefresh: DispatchWorkItem?
    private var settlingRefreshes: [DispatchWorkItem] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Self.storedTools(defaults.stringArray(forKey: Self.favoritesKey))
        recent = Array(Self.storedTools(defaults.stringArray(forKey: Self.recentKey)).prefix(Self.recentLimit))
        // Rewrite lists that held merged or removed ids, so the user's
        // defaults match what the page offers.
        rewriteIfChanged(Self.favoritesKey, favorites)
        rewriteIfChanged(Self.recentKey, recent)
    }

    private func rewriteIfChanged(_ key: String, _ list: [SystemToolID]) {
        guard let stored = defaults.stringArray(forKey: key), stored != list.map(\.rawValue) else { return }
        defaults.set(list.map(\.rawValue), forKey: key)
    }

    /// A stored favorites or recent list: ids from 3.4.x are migrated to the
    /// tools that replaced them, unknown ids (removed tools, typos, a newer
    /// version's tools) are dropped silently, duplicates once.
    nonisolated static func storedTools(_ raw: [String]?) -> [SystemToolID] {
        var seen = Set<SystemToolID>()
        let retired = SystemToolCatalog.retiredIDs
        return (raw ?? []).compactMap { raw -> SystemToolID? in
            // Migration first: a retired id may have a successor (forceQuit → killApps).
            SystemToolMigration.map[raw] ?? SystemToolID(rawValue: raw)
        }.filter { !retired.contains($0) && seen.insert($0).inserted }
    }

    // MARK: - Lifecycle

    /// When `refreshStates` last ran (system uptime).
    private var lastStatesRefresh: TimeInterval?
    /// Selecting the page again this soon after a refresh keeps its states.
    static let appearRefreshInterval: TimeInterval = 2

    func appear() {
        guard refreshTimer == nil else { return }
        isVisible = true
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastStatesRefresh, now - last < Self.appearRefreshInterval {
            refreshSlowStates()
        } else {
            refreshStates()
            refreshSlowStates(force: true)
        }
        stateObserver.start { [weak self] _ in self?.scheduleEventRefresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.refreshStates()
                self.refreshSlowStates()
            }
        }
        refreshTimer?.tolerance = 3
    }

    deinit {
        refreshTimer?.invalidate()
        eventRefresh?.cancel()
        settlingRefreshes.forEach { $0.cancel() }
    }

    private func scheduleEventRefresh() {
        guard isVisible, eventRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.eventRefresh = nil
            guard self.isVisible else { return }
            self.refreshStates()
            self.refreshSlowStates()
        }
        eventRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func disappear() {
        isVisible = false
        stateObserver.stop()
        eventRefresh?.cancel(); eventRefresh = nil
        settlingRefreshes.forEach { $0.cancel() }; settlingRefreshes.removeAll()
        slowRefreshGeneration += 1
        slowRefreshThrottle.invalidate()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Favorites and recent

    func isFavorite(_ id: SystemToolID) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: SystemToolID) {
        if let index = favorites.firstIndex(of: id) { favorites.remove(at: index) } else { favorites.append(id) }
        defaults.set(favorites.map(\.rawValue), forKey: Self.favoritesKey)
    }

    /// Most recent first, no duplicates, at most `limit`.
    nonisolated static func updatedRecent(_ list: [SystemToolID], adding id: SystemToolID, limit: Int = recentLimit) -> [SystemToolID] {
        Array(([id] + list.filter { $0 != id }).prefix(limit))
    }

    private func noteUsed(_ id: SystemToolID) {
        recent = Self.updatedRecent(recent, adding: id)
        defaults.set(recent.map(\.rawValue), forKey: Self.recentKey)
    }

    // MARK: - States

    func refreshStates() {
        guard isVisible else { return }
        lastStatesRefresh = ProcessInfo.processInfo.systemUptime
        let interval = AOMPerformance.begin("SystemTools.refresh")
        defer { AOMPerformance.end("SystemTools.refresh", interval) }
        var next: [SystemToolID: SystemToolState] = [:]
        let style = preferences.value("AppleInterfaceStyle", domain: CFPreferenceStore.globalDomain) as? String
        next[.darkMode] = SystemToolState(style?.caseInsensitiveCompare("Dark") == .orderedSame)
        let awake = KeepAwakeService.shared
        next[.keepAwake] = awake.isActive ? .on(awake.origin == .externalDisplay ? "Display connected" : awake.endsAt.map { "Until " + $0.formatted(date: .omitted, time: .shortened) } ?? "On") : .off()
        let finder = UserDefaults(suiteName: SystemTweak.finder)
        next[.hidden] = SystemToolState(MacMagicSystemToolService.finderFlag("AppleShowAllFiles", in: finder, default: false))
        next[.desktop] = SystemToolState(MacMagicSystemToolService.finderFlag("CreateDesktop", in: finder, default: true))
        next[.dockAutoHide] = SystemToolState(SystemTweak.bool(preferences.value("autohide", domain: SystemTweak.dock)) ?? false)
        next[.hideMenuBar] = SystemToolState(SystemTweak.bool(preferences.value("_HIHideMenuBar", domain: CFPreferenceStore.globalDomain)) ?? false)
        next[.lowPower] = SystemToolState(ProcessInfo.processInfo.isLowPowerModeEnabled)
        next[.wifi] = CWWiFiClient.shared().interface().map { SystemToolState($0.powerOn()) } ?? .value("None")
        let tweaks: [(SystemToolID, SystemTweak)] = [(.extensions, .showAllExtensions), (.pathbar, .pathBar), (.statusbar, .statusBar),
                                                     (.posixtitle, .fullPathInTitle), (.dockactive, .dockActiveAppsOnly),
                                                     (.dockdelay, .dockInstantAutoHide), (.dockrecents, .dockRecentApps),
                                                     (.shotshadow, .screenshotShadows)]
        for (id, tweak) in tweaks { next[id] = SystemToolState(tweak.isOn(in: preferences) ?? false) }
        next[.showLibrary] = SystemToolState(!Self.isLibraryHidden())
        next[.shotformat] = .value((SystemTweak.screenshotFormat.currentString(in: preferences) ?? "png").uppercased())
        next[.shotfolder] = .value(URL(fileURLWithPath: SystemTweak.screenshotFolder.currentString(in: preferences) ?? "~/Desktop").lastPathComponent)
        if let mode = DisplayControlService.currentMode(CGMainDisplayID()) {
            next[.resolution] = .value("\(mode.pointWidth)×\(mode.pointHeight)")
        }
        // Without hardware brightness, no software dim means full brightness.
        let main = CGMainDisplayID()
        let level = DisplayControlService.supportsHardwareBrightness(main)
            ? DisplayControlService.brightness(main) : (DisplayControlService.softwareDim(main) ?? 1)
        if let text = DisplaySoundState.percentText(level) { next[.brightness] = .value(text) }
        let timer = SleepTimerService.shared
        next[.sleepTimer] = timer.isActive ? .on("At " + (timer.firesAt?.formatted(date: .omitted, time: .shortened) ?? "")) : .off()
        next[.awakeWhileApp] = SystemToolState(AppAwakeService.shared.isActive)
        if let services = VPNModel.shared.lastServices { next[.vpn] = Self.vpnState(services) }
        if let outdated = HomebrewModel.shared.outdated {
            next[.homebrew] = outdated.isEmpty ? .on("Up to date") : .value("\(outdated.count) to upgrade")
        }
        for (id, state) in slowStates { next[id] = state }
        if next != states { states = next }
    }

    /// States that need a helper process: the startup chime, the Metal HUD
    /// variable and the Time Machine state. One refresh at a time, off the
    /// main thread.
    func refreshSlowStates(force: Bool = false) {
        guard isVisible, !slowRefreshRunning,
              slowRefreshThrottle.shouldStart(at: ProcessInfo.processInfo.systemUptime, force: force) else { return }
        slowRefreshRunning = true
        let generation = slowRefreshGeneration
        Task.detached(priority: .utility) {
            let interval = AOMPerformance.begin("SystemTools.slowRefresh")
            // 7.2.2: Metal HUD (retired) and Time Machine left with their tiles,
            // so no helper process runs here any more (Codex audit E09).
            let slow: [SystemToolID: SystemToolState] = [:]
            let result = slow
            AOMPerformance.end("SystemTools.slowRefresh", interval)
            await MainActor.run {
                self.slowRefreshRunning = false
                guard self.isVisible else { return }
                guard generation == self.slowRefreshGeneration else {
                    self.refreshSlowStates(force: true)
                    return
                }
                if result != self.slowStates { self.slowStates = result; self.refreshStates() }
            }
        }
        // The VPN tile reads scutil (and, at most every 20 s, Tailscale) off
        // the main thread and refreshes the tile's value.
        VPNModel.shared.refreshForTiles()
    }

    nonisolated static func isLibraryHidden() -> Bool {
        var url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? true
    }

    nonisolated static func vpnState(_ services: [VPNTools.Service]) -> SystemToolState {
        let up = services.filter { $0.state == .connected }
        if up.count == 1 { return .on(DisplaySoundState.shortName(up[0].name, limit: 14)) }
        if up.count > 1 { return .on("\(up.count) on") }
        if services.contains(where: { $0.state == .connecting }) { return .value("Connecting") }
        return services.isEmpty ? .value("None") : .off()
    }

    /// System changes land a moment after the command returns (Finder
    /// relaunching, System Events applying the appearance).
    func refreshSoon() {
        slowRefreshGeneration += 1
        slowRefreshThrottle.invalidate()
        settlingRefreshes.forEach { $0.cancel() }; settlingRefreshes.removeAll()
        guard isVisible else { return }
        refreshSlowStates(force: true)
        refreshStates()
        for delay in [0.6, 2.0] {
            let work = DispatchWorkItem { [weak self] in self?.refreshStates() }
            settlingRefreshes.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: - Reporting

    func succeed(_ id: SystemToolID, _ message: String) {
        lastResult = ToolResult(tool: id, message: message, succeeded: true, date: Date())
        toasts.show(message, tone: .success)
        refreshSoon()
    }

    /// Failures are a danger toast that says why, long enough to read, and
    /// stay in the page header's last-result line.
    func fail(_ id: SystemToolID, _ title: String, _ message: String) {
        lastResult = ToolResult(tool: id, message: "\(title): \(message)", succeeded: false, date: Date())
        refreshSoon()
        toasts.show("\(title): \(message)", tone: .danger, seconds: Self.failureSeconds(message))
        GestureLog.shared.logFromAnyThread("System Tools — \(title): \(message)", level: .error)
    }

    /// 6 s, plus a second per 30 characters of reason, at most 12 s.
    nonisolated static func failureSeconds(_ message: String) -> Double {
        min(12, 6 + Double(message.count) / 30)
    }

    func fail(_ id: SystemToolID, _ error: Error) {
        fail(id, "\(SystemToolCatalog.info(id).title.replacingOccurrences(of: "…", with: "")) Didn't Finish", error.localizedDescription)
    }

    /// Long jobs run off the main thread, show a spinner on their tile and
    /// can't be started twice.
    func runInBackground<T>(_ id: SystemToolID, _ work: @escaping () throws -> T,
                            then done: @escaping (T) -> Void) {
        guard !running.contains(id) else { return }
        running.insert(id)
        Task.detached(priority: .userInitiated) {
            let outcome = Swift.Result<T, Error>(catching: work)
            await MainActor.run {
                self.running.remove(id)
                switch outcome {
                case .success(let value): done(value)
                case .failure(let error): self.fail(id, error)
                }
            }
        }
    }

    /// Runs one of AOM's existing actions (the same code the Automation page
    /// uses) and reports on its completion.
    func runAction(_ id: SystemToolID, _ type: ActionType, configure: (inout ActionParameters) -> Void = { _ in },
                   success: String?, failure: String) {
        var parameters = type.defaultParameters
        configure(&parameters)
        ActionExecutor.executeActions([TriggerAction(actionType: type, parameters: parameters)]) { ok in
            DispatchQueue.main.async {
                if ok {
                    if let success { self.succeed(id, success) } else { self.refreshSoon() }
                } else {
                    self.fail(id, "\(SystemToolCatalog.info(id).title.replacingOccurrences(of: "…", with: "")) Didn't Run", failure)
                }
            }
        }
    }

    // MARK: - Dispatch

    func run(_ id: SystemToolID) {
        guard !running.contains(id) else { return }
        noteUsed(id)
        switch id {
        // Quick Toggles
        case .darkMode:
            let wasDark = states[.darkMode] == .on()
            runAction(id, .toggleDarkMode, success: wasDark ? "Light appearance" : "Dark appearance",
                      failure: "Allow All of MacOS to control System Events in System Settings › Privacy & Security › Automation.")
        case .keepAwake: keepAwakeMenu()
        case .hideMenuBar: toggleHideMenuBar()
        case .dockAutoHide:
            let wasOn = states[.dockAutoHide] == .on()
            runAction(id, .toggleDockAutoHide, success: wasOn ? "Dock always shown" : "Dock hides automatically",
                      failure: "Allow All of MacOS to control System Events in System Settings › Privacy & Security › Automation.")
        case .hidden:
            Task {
                do { let next = try await service.toggleHiddenFiles(); succeed(id, next ? "Hidden files shown" : "Hidden files hidden") }
                catch { fail(id, "Hidden Files Not Changed", error.localizedDescription) }
            }
        case .desktop:
            Task {
                do { let next = try await service.toggleDesktopIcons(); succeed(id, next ? "Desktop icons shown" : "Desktop icons hidden") }
                catch { fail(id, "Desktop Icons Not Changed", error.localizedDescription) }
            }
        case .wifi:
            let wasOn = states[.wifi] == .on()
            runAction(id, .setWiFiPower, success: wasOn ? "Wi-Fi off" : "Wi-Fi on", failure: "macOS didn't change the Wi-Fi power.")
        case .bluetooth: bluetoothMenu()
        case .lowPower: toggleLowPowerMode()
        // Display
        case .resolution: resolutionMenu()
        case .brightness: brightnessMenu()
        // Power & Session
        case .lockScreen: runAction(id, .lockScreen, success: nil, failure: "The screen could not be locked.")
        case .sleep: runAction(id, .sleepComputer, success: nil, failure: "pmset could not put the Mac to sleep.")
        case .sleepDisplays: runAction(id, .sleepDisplay, success: nil, failure: "pmset could not turn the displays off.")
        case .batteryDetails: showBatteryDetails()
        case .sleepTimer: sleepTimerMenu()
        case .awakeWhileApp: awakeWhileAppMenu()
        // Apps
        case .activity: showActivity()
        case .killApps: AOMLauncherController.shared.show(route: .killApps)
        case .relaunchApp: relaunchAppMenu()
        case .uninstall: reviewUninstall(nil)
        case .loginItems: showLoginItems()
        case .awakeReasons: showAwakeReasons()
        case .resetSavedState: resetSavedState()
        // Storage
        case .freeUpSpace: cleanupScan = .folderSizes; showFreeUpSpace = true
        case .eject: ejectMenu()
        case .installDMG: FolderRulesModule.installDiskImage()
        // Network
        case .networkInfo: showNetworkInfo = true
        case .speedTest:
            toast = "Testing the connection (about 20 s)…"
            runInBackground(id, { try NetworkTools.runSpeedTest() }) { self.succeed(id, $0.summary) }
        case .vpn: VPNModel.shared.present()
        case .dns: flushDNS()
        // Homebrew
        case .homebrew: HomebrewModel.shared.present(.outdated, refresh: true)
        // Fix It
        case .finder: Task { await service.restartFinder(); succeed(id, "Finder restarted") }
        case .restartDock:
            runInBackground(id, { try SystemToolsCommand.restartProcesses(["Dock"]) }) { _ in self.succeed(id, "Dock restarted") }
        case .restartMenuBar:
            runInBackground(id, { try SystemToolsCommand.restartProcesses(["SystemUIServer", "ControlCenter"]) }) { _ in
                self.succeed(id, "Menu bar restarted")
            }
        case .launchServices: rebuildLaunchServices()
        case .spotlight:
            administrator(id, title: "Reindex Spotlight?",
                          message: "Spotlight erases its index of the startup disk and rebuilds it in the background. Search results are incomplete until it finishes, which can take an hour.",
                          button: "Reindex…", commands: [.init(path: "/usr/bin/mdutil", arguments: ["-E", "/"])],
                          success: "Spotlight is rebuilding its index")
        // Tweaks
        case .extensions: toggleTweak(id, .showAllExtensions, on: "File extensions shown", off: "File extensions as Finder decides")
        case .pathbar: toggleTweak(id, .pathBar, on: "Path bar shown", off: "Path bar hidden")
        case .statusbar: toggleTweak(id, .statusBar, on: "Status bar shown", off: "Status bar hidden")
        case .posixtitle: toggleTweak(id, .fullPathInTitle, on: "Full path in Finder titles", off: "Folder names in Finder titles")
        case .showLibrary: toggleLibraryFolder()
        case .dockactive: toggleTweak(id, .dockActiveAppsOnly, on: "Dock shows only open apps", off: "Dock shows kept apps")
        case .dockdelay: toggleTweak(id, .dockInstantAutoHide, on: "Hidden Dock appears instantly", off: "Dock delay back to default")
        case .dockrecents: toggleTweak(id, .dockRecentApps, on: "Recent apps in the Dock", off: "No recent apps in the Dock")
        case .shotshadow: toggleTweak(id, .screenshotShadows, on: "Window screenshots keep their shadow", off: "Window screenshots without shadow")
        case .shotformat: screenshotFormatMenu()
        case .menuBarSpacing: menuBarSpacingMenu()
        case .shotfolder: chooseScreenshotFolder()
        // 7.2.2: grouped tiles (Codex audit R04–R07)
        case .finderDisplay, .dockSettings, .screenshotDefaults, .repair: groupMenu(id)
        }
    }

    // MARK: - Toggles and pickers

    private func keepAwakeMenu() {
        let awake = KeepAwakeService.shared
        let menu = NSMenu()
        if awake.hasAssertion {
            menu.addItem(SystemToolMenuItem(title: "Turn Off Keep Awake") {
                awake.stop(); self.succeed(.keepAwake, "Keep Awake off")
            })
            menu.addItem(.separator())
        }
        let durations: [(String, Int?)] = [("15 Minutes", 15), ("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120),
                                           ("4 Hours", 240), ("8 Hours", 480), ("Until Turned Off", nil)]
        for keepDisplay in [false, true] {
            let header = NSMenuItem(title: keepDisplay ? "Mac and Display" : "Mac Only (display may sleep)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (title, minutes) in durations {
                menu.addItem(SystemToolMenuItem(title: title) {
                    if awake.start(minutes: minutes, keepDisplay: keepDisplay) { self.succeed(.keepAwake, "Keeping awake \(awake.remainingDescription ?? "")") }
                    else { self.fail(.keepAwake, "Keep Awake Didn't Start", "Check the battery stop rule and macOS power availability.") }
                })
            }
            if !keepDisplay { menu.addItem(.separator()) }
        }
        // Amphetamine's triggers and KeepingYouAwake's conditions.
        let rules = KeepAwakeRules.shared
        menu.addItem(.separator())
        menu.addItem(headerItem("Automatically"))
        let display = SystemToolMenuItem(title: "While an External Display Is Connected") {
            rules.whileExternalDisplay.toggle()
            self.succeed(.keepAwake, rules.whileExternalDisplay ? "Stays awake while a display is connected" : "External display rule off")
        }
        display.state = rules.whileExternalDisplay ? .on : .off
        menu.addItem(display)
        let battery = NSMenuItem(title: "Let the Mac Sleep on Low Battery", action: nil, keyEquivalent: "")
        let floors = NSMenu()
        for floor in [0] + KeepAwakeRules.batteryFloors {
            let item = SystemToolMenuItem(title: floor == 0 ? "Never" : "Below \(floor)%") {
                rules.batteryFloor = floor
                self.succeed(.keepAwake, floor == 0 ? "Keeps awake at any battery level" : "Turns off below \(floor)% battery")
            }
            item.state = rules.batteryFloor == floor ? .on : .off
            floors.addItem(item)
        }
        battery.submenu = floors
        menu.addItem(battery)
        popUp(menu)
    }

    /// 7.2.2: a grouped tile's options with their current state; each runs
    /// as its own tile did.
    private func groupMenu(_ group: SystemToolID) {
        let menu = NSMenu()
        for info in SystemToolCatalog.all where info.groupedInto == group && info.isAvailable {
            var title = info.title
            if case .value(let value)? = states[info.id] { title += " — \(value)" }
            let item = SystemToolMenuItem(title: title) { self.run(info.id) }
            if case .on? = states[info.id] { item.state = .on }
            item.toolTip = info.help
            menu.addItem(item)
        }
        if group == .screenshotDefaults {
            menu.addItem(.separator())
            menu.addItem(SystemToolMenuItem(title: "AOM's Own Capture Settings…") {
                AppState.current?.selectedMainTab = .capture
                AppDelegate.current?.showMainWindow()
            })
        }
        popUp(menu)
    }

    func toggleHideMenuBar() {
        let wasOn = states[.hideMenuBar] == .on()
        let script = "tell application \"System Events\" to tell dock preferences to set autohide menu bar to \(wasOn ? "false" : "true")"
        runInBackground(.hideMenuBar, { try SystemToolsCommand.runChecked("/usr/bin/osascript", ["-e", script]) }) { _ in
            self.succeed(.hideMenuBar, wasOn ? "Menu bar always shown" : "Menu bar hides automatically")
        }
    }

    private func bluetoothMenu() {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.name != nil }.sorted { ($0.name ?? "") < ($1.name ?? "") }
        guard !devices.isEmpty else {
            fail(.bluetooth, "No Paired Devices", "Pair the device in System Settings › Bluetooth first. If Bluetooth access was declined, allow All of MacOS in Privacy & Security › Bluetooth.")
            return
        }
        let menu = NSMenu()
        for device in devices {
            let name = device.name ?? ""
            let connected = device.isConnected()
            let item = SystemToolMenuItem(title: connected ? "Disconnect \(name)" : "Connect \(name)") {
                self.runAction(.bluetooth, .bluetoothDevice, configure: { $0.bluetoothDevice = name; $0.switchMode = connected ? "off" : "on" },
                               success: connected ? "\(name) disconnected" : "\(name) connected",
                               failure: "\(name) didn't \(connected ? "disconnect" : "connect"). Make sure it is on and in range.")
            }
            item.state = connected ? .on : .off
            menu.addItem(item)
        }
        popUp(menu)
    }

    func toggleLowPowerMode() {
        let isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        runInBackground(.lowPower, { try SystemToolsCommand.run("/usr/bin/pmset", ["-g"]).stdout }) { text in
            guard PowerTools.supportsLowPowerMode(PowerTools.parsePmsetSettings(text)) else {
                self.fail(.lowPower, "Low Power Mode Isn't Available", "pmset on this Mac has no lowpowermode setting."); return
            }
            self.administrator(.lowPower, title: isOn ? "Turn Off Low Power Mode?" : "Turn On Low Power Mode?",
                               message: "Low Power Mode lowers energy use on battery and power adapter; the Mac may feel slower while it is on.",
                               button: isOn ? "Turn Off…" : "Turn On…",
                               commands: [.init(path: "/usr/bin/pmset", arguments: PowerTools.lowPowerArguments(on: !isOn))],
                               success: isOn ? "Low Power Mode off" : "Low Power Mode on")
        }
    }

    private func toggleTweak(_ id: SystemToolID, _ tweak: SystemTweak, on: String, off: String) {
        do {
            let next = try tweak.toggle(in: preferences)
            applyTweak(id, tweak, message: next ? on : off)
        } catch { fail(id, "Setting Not Changed", error.localizedDescription) }
    }

    private func applyTweak(_ id: SystemToolID, _ tweak: SystemTweak, message: String) {
        switch tweak.apply {
        case .restartFinder:
            Task { await service.restartFinder(); succeed(id, message) }
        case .restartDock:
            runInBackground(id, { try SystemToolsCommand.restartProcesses(["Dock"]) }) { _ in self.succeed(id, message) }
        case .nextScreenshot:
            succeed(id, message + " (next screenshot)")
        }
    }

    private func screenshotFormatMenu() {
        let tweak = SystemTweak.screenshotFormat
        guard case .choice(let options, _) = tweak.kind else { return }
        let current = tweak.currentString(in: preferences)
        let menu = NSMenu()
        for option in options {
            let item = SystemToolMenuItem(title: option.uppercased()) {
                do { try tweak.setChoice(option, in: self.preferences); self.applyTweak(.shotformat, tweak, message: "Screenshots save as \(option.uppercased())") }
                catch { self.fail(.shotformat, "Format Not Changed", error.localizedDescription) }
            }
            item.state = option == current ? .on : .off
            menu.addItem(item)
        }
        popUp(menu)
    }

    /// 6.11 (Ice): `NSStatusItemSpacing` / `NSStatusItemSelectionPadding` in
    /// the current host's global domain, then Control Center and the system
    /// UI server relaunch; other apps' icons follow when they next start.
    enum MenuBarSpacing: String, CaseIterable {
        case standard, compact, tight
        var title: String {
            switch self {
            case .standard: return "Default"
            case .compact: return "Compact — more icons beside the notch"
            case .tight: return "Tight"
            }
        }
        /// (spacing, selection padding); nil restores macOS's values.
        var values: (Int, Int)? {
            switch self {
            case .standard: return nil
            case .compact: return (8, 6)
            case .tight: return (4, 4)
            }
        }
        static func current(spacing: Int?) -> MenuBarSpacing {
            switch spacing {
            case nil: return .standard
            case let value? where value <= 5: return .tight
            default: return .compact
            }
        }
        /// 7.6 (Codex MB05): the two keys as a store — read, write (nil
        /// removes), synchronize — so they change together or not at all.
        struct Store {
            var read: (String) -> Int?
            var write: (String, Int?) -> Void
            var synchronize: () -> Bool

            static let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]

            /// The current host's global domain, as `defaults -currentHost … -globalDomain`.
            static let live = Store(
                read: { key in
                    (CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                            kCFPreferencesCurrentHost) as? NSNumber)?.intValue
                },
                write: { key, value in
                    CFPreferencesSetValue(key as CFString, value.map { NSNumber(value: $0) }, kCFPreferencesAnyApplication,
                                          kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
                },
                synchronize: { CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) })
        }

        /// Pure apart from `store`: writes both keys, reads them back, and
        /// puts both previous values back (present or absent) when either
        /// didn't take. True when both now hold this choice's values.
        func apply(to store: Store) -> Bool {
            let previous = Store.keys.map { store.read($0) }
            let wanted: [Int?] = values.map { [$0.0, $0.1] } ?? [nil, nil]
            for (key, value) in zip(Store.keys, wanted) { store.write(key, value) }
            let synced = store.synchronize()
            if synced, Store.keys.map({ store.read($0) }) == wanted { return true }
            for (key, value) in zip(Store.keys, previous) { store.write(key, value) }
            _ = store.synchronize()
            return false
        }

        /// Pure: the `defaults` invocations for this choice.
        var commands: [[String]] {
            let base = ["-currentHost"]
            guard let (spacing, padding) = values else {
                return [base + ["delete", "-globalDomain", "NSStatusItemSpacing"],
                        base + ["delete", "-globalDomain", "NSStatusItemSelectionPadding"]]
            }
            return [base + ["write", "-globalDomain", "NSStatusItemSpacing", "-int", "\(spacing)"],
                    base + ["write", "-globalDomain", "NSStatusItemSelectionPadding", "-int", "\(padding)"]]
        }
    }

    private func menuBarSpacingMenu() {
        let current = MenuBarSpacing.current(spacing: MenuBarSpacing.Store.live.read("NSStatusItemSpacing"))
        let menu = NSMenu()
        for choice in MenuBarSpacing.allCases {
            let item = SystemToolMenuItem(title: choice.title) { self.setMenuBarSpacing(choice) }
            item.state = choice == current ? .on : .off
            menu.addItem(item)
        }
        popUp(menu)
    }

    private func setMenuBarSpacing(_ choice: MenuBarSpacing) {
        runInBackground(.menuBarSpacing, { () -> (written: Bool, restarted: [String]) in
            // Both keys or neither (Codex MB05); the restarts are reported apart.
            guard choice.apply(to: .live) else { return (false, []) }
            var restarted: [String] = []
            for host in ["ControlCenter", "SystemUIServer"] {
                let kill = Process()
                kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                kill.arguments = [host]
                kill.standardError = FileHandle.nullDevice
                try? kill.run()
                kill.waitUntilExit()
                if kill.terminationStatus == 0 { restarted.append(host) }
            }
            return (true, restarted)
        }) { outcome in
            let name = choice.title.components(separatedBy: " —").first ?? choice.title
            guard outcome.written else {
                self.fail(.menuBarSpacing, "Spacing Not Changed", "macOS didn't keep the two spacing settings, so both were put back as they were.")
                return
            }
            if outcome.restarted.count == 2 {
                self.succeed(.menuBarSpacing, "Menu bar spacing: \(name). Other apps' icons follow when they relaunch or after you log out.")
            } else {
                self.succeed(.menuBarSpacing, "Menu bar spacing saved as \(name); the menu bar didn't restart, so it shows after you log out.")
            }
        }
    }

    private func chooseScreenshotFolder() {
        let tweak = SystemTweak.screenshotFolder
        guard let url = pickFolder(message: "Choose where macOS saves screenshots.") else { return }
        do { try tweak.setFolder(url, in: preferences); applyTweak(.shotfolder, tweak, message: "Screenshots save to \(url.lastPathComponent)") }
        catch { fail(.shotfolder, "Folder Not Changed", error.localizedDescription) }
    }

    private func toggleLibraryFolder() {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let hidden = Self.isLibraryHidden()
        runInBackground(.showLibrary, { try SystemToolsCommand.runChecked("/usr/bin/chflags", [hidden ? "nohidden" : "hidden", library]) }) { _ in
            if Self.isLibraryHidden() == hidden { self.fail(.showLibrary, "Library Folder Not Changed", "chflags ran, but the folder's hidden flag didn't change."); return }
            self.succeed(.showLibrary, hidden ? "Library folder shown in Finder" : "Library folder hidden")
        }
    }

    // MARK: - Display

    func resolutionMenu() {
        let displays = DisplayControlService.displays()
        guard !displays.isEmpty else { fail(.resolution, "No Display Found", "CoreGraphics reported no active display."); return }
        let menu = NSMenu()
        for display in displays {
            let id = display.displayID
            guard let current = DisplayControlService.currentMode(id) else { continue }
            if displays.count > 1 { menu.addItem(headerItem(display.name)) }
            let canChange = DisplayControlService.canReturnToCurrentMode(id)
            if !canChange { menu.addItem(headerItem("macOS hides the current mode; change it in System Settings")) }
            for option in DisplayControlService.resolutionOptions(id, preferringHiDPI: current.isHiDPI) {
                let markers = DisplayControlService.markers(id, for: option).filter { $0 == .default }.map(\.label)
                let title = "\(option.pointWidth) × \(option.pointHeight)" + (option.isHiDPI ? " HiDPI" : "") + (markers.isEmpty ? "" : " (Default)")
                let item = SystemToolMenuItem(title: title) {
                    self.applyMode(display, width: option.pointWidth, height: option.pointHeight, refresh: current.refreshRate, hiDPI: current.isHiDPI)
                }
                item.state = option.matchesSize(current) ? .on : .off
                item.isEnabled = canChange
                menu.addItem(item)
            }
            let rates = Array(Set(DisplayControlService.refreshRates(id, pointWidth: current.pointWidth, pointHeight: current.pointHeight,
                                                                     hiDPI: current.isHiDPI).map { $0.rounded() })).sorted()
            if rates.count > 1 {
                let rateItem = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for rate in rates {
                    let item = SystemToolMenuItem(title: "\(Int(rate)) Hz") {
                        self.applyMode(display, width: current.pointWidth, height: current.pointHeight, refresh: rate, hiDPI: current.isHiDPI)
                    }
                    item.state = abs(rate - current.refreshRate) < 0.6 ? .on : .off
                    item.isEnabled = canChange
                    sub.addItem(item)
                }
                rateItem.submenu = sub
                menu.addItem(rateItem)
            }
            menu.addItem(.separator())
        }
        menu.addItem(SystemToolMenuItem(title: "Displays Settings…") { self.openPane(.resolution, .displays) })
        popUp(menu)
    }

    private func applyMode(_ display: DisplayTarget, width: Int, height: Int, refresh: Double, hiDPI: Bool) {
        let id = display.displayID
        guard DisplayControlService.setMode(id, pointWidth: width, pointHeight: height, refreshRate: refresh, hiDPI: hiDPI),
              let now = DisplayControlService.currentMode(id), now.pointWidth == width, now.pointHeight == height else {
            fail(.resolution, "Mode Not Changed", "\(display.name) didn't switch to \(width) × \(height). The display may not support that mode."); return
        }
        succeed(.resolution, "\(display.name): \(now.label)")
    }

    func brightnessMenu() {
        let displays = DisplayControlService.displays()
        let menu = NSMenu()
        for display in displays {
            let id = display.displayID
            let hardware = DisplayControlService.supportsHardwareBrightness(id)
            let current = DisplayControlService.brightness(id)
            menu.addItem(headerItem(display.name + (hardware ? "" : " (software dim)")))
            for percent in DisplaySoundState.brightnessPresets {
                let item = SystemToolMenuItem(title: "\(percent)%") {
                    if DisplayControlService.setBrightness(id, Float(percent) / 100) { self.succeed(.brightness, "\(display.name): \(percent)% brightness") }
                    else { self.fail(.brightness, "Brightness Not Changed", "\(display.name) refused the brightness change.") }
                }
                if let current, Int((current * 100).rounded()) == percent { item.state = .on }
                menu.addItem(item)
            }
            if !hardware, DisplayControlService.softwareDim(id) != nil {
                menu.addItem(SystemToolMenuItem(title: "Undo Software Dim") {
                    if DisplayControlService.clearSoftwareDim(id) { self.succeed(.brightness, "\(display.name): software dim removed") }
                    else { self.fail(.brightness, "Dim Not Removed", "The display's colour curve could not be restored.") }
                })
            }
            menu.addItem(.separator())
        }
        menu.addItem(SystemToolMenuItem(title: "Displays Settings…") { self.openPane(.brightness, .displays) })
        popUp(menu)
    }

    // MARK: - Power & Session

    func confirm(_ title: String, _ message: String, button: String, destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if destructive { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }


    func showBatteryDetails() {
        runInBackground(.batteryDetails, { () -> (PowerTools.BatteryDetails?, String?) in
            let condition = (try? SystemToolsCommand.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]))
                .flatMap { PowerTools.parseBatteryCondition($0.stdout) }
            return (PowerTools.batteryDetails(), condition)
        }) { details, condition in
            guard let details else { self.fail(.batteryDetails, "No Battery", "This Mac has no internal battery."); return }
            var lines = details.lines
            if let condition { lines.insert("Condition: \(condition)", at: 1) }
            self.info(.batteryDetails, title: "Battery", lines: lines, extra: ("Battery Settings…", { self.openPane(.batteryDetails, .battery) }))
        }
    }

    func sleepTimerMenu() {
        let timer = SleepTimerService.shared
        let menu = NSMenu()
        if timer.isActive, let date = timer.firesAt {
            menu.addItem(SystemToolMenuItem(title: "Cancel (Sleeps at \(date.formatted(date: .omitted, time: .shortened)))") {
                timer.cancel(); self.succeed(.sleepTimer, "Sleep timer cancelled")
            })
            menu.addItem(.separator())
        }
        let durations: [(String, Int)] = [("In 15 Minutes", 15), ("In 30 Minutes", 30), ("In 45 Minutes", 45),
                                          ("In 1 Hour", 60), ("In 1.5 Hours", 90), ("In 2 Hours", 120)]
        for (title, minutes) in durations {
            menu.addItem(SystemToolMenuItem(title: title) {
                timer.start(minutes: minutes)
                let at = timer.firesAt?.formatted(date: .omitted, time: .shortened) ?? ""
                self.succeed(.sleepTimer, "The Mac sleeps at \(at) (keep All of MacOS open)")
            })
        }
        popUp(menu)
    }

    func awakeWhileAppMenu() {
        let awake = AppAwakeService.shared
        let menu = NSMenu()
        if let name = awake.appName {
            menu.addItem(SystemToolMenuItem(title: "Stop (Awake While \(name) Runs)") { awake.stop(); self.succeed(.awakeWhileApp, "Awake-while-app off") })
            menu.addItem(.separator())
        }
        let apps = self.appMenu(ProcessTools.regularApps()) { app in
            if awake.start(for: app) { self.succeed(.awakeWhileApp, "Awake until \(app.localizedName ?? "the app") quits") }
            else { self.fail(.awakeWhileApp, "Didn't Start", "macOS refused the power assertion, or the app already quit.") }
        }
        for item in apps.items { menu.addItem(item) }
        popUp(menu)
    }

    func showAwakeReasons() {
        runInBackground(.awakeReasons, { try PowerTools.activeAssertions() }) { assertions in
            guard !assertions.isEmpty else { self.succeed(.awakeReasons, "Nothing is keeping the Mac awake"); return }
            self.processTool = .awakeReasons
            self.processReview = ProcessReview(title: "Keeping the Mac Awake", rows: assertions.map {
                .init(id: $0.id, pid: $0.pid, command: $0.process,
                      detail: "\(PowerTools.assertionKind($0.type)) · \($0.name.isEmpty ? $0.type : $0.name) · PID \($0.pid)")
            })
        }
    }

    // MARK: - Apps

    /// Top CPU and Top Memory in one list: the sort control changes `order`.
    func showActivity(_ order: ProcessTools.Order = .cpu) {
        runInBackground(.activity, { try ProcessTools.samples() }) { samples in
            let top = ProcessTools.top(samples, by: order)
            guard !top.isEmpty else { self.fail(.activity, "No Processes", "ps returned no processes."); return }
            self.processTool = .activity
            self.processReview = ProcessReview(title: order == .cpu ? "Activity · CPU" : "Activity · Memory", sort: order, rows: top.map {
                .init(id: "\($0.pid)", pid: $0.pid, command: $0.name, detail: ProcessTools.detail($0))
            })
        }
    }

    /// Called by the process sheet's sort control.
    func resortActivity(_ order: ProcessTools.Order) { showActivity(order) }

    func appMenu(_ apps: [NSRunningApplication], action: @escaping (NSRunningApplication) -> Void) -> NSMenu {
        let menu = NSMenu()
        if apps.isEmpty { menu.addItem(headerItem("No other apps are open")) }
        for app in apps {
            let item = SystemToolMenuItem(title: app.localizedName ?? app.bundleIdentifier ?? "App") { action(app) }
            item.image = app.icon.map { icon in let copy = icon.copy() as? NSImage ?? icon; copy.size = NSSize(width: 16, height: 16); return copy }
            menu.addItem(item)
        }
        return menu
    }

    func relaunchAppMenu() {
        popUp(appMenu(ProcessTools.regularApps()) { app in
            let name = app.localizedName ?? "the app"
            guard let bundle = app.bundleURL else { self.fail(.relaunchApp, "Can't Relaunch", "\(name) has no app bundle to reopen."); return }
            guard !self.running.contains(.relaunchApp) else { return }
            self.running.insert(.relaunchApp)
            app.terminate()
            self.reopen(app, bundle: bundle, name: name, triesLeft: 20)
        })
    }

    /// Apps with unsaved documents may ask first; waits up to 10 s for the
    /// quit before reopening, and reopens nothing if the app stays open.
    private func reopen(_ app: NSRunningApplication, bundle: URL, name: String, triesLeft: Int) {
        if app.isTerminated {
            NSWorkspace.shared.openApplication(at: bundle, configuration: NSWorkspace.OpenConfiguration()) { opened, error in
                let ok = opened != nil, message = error?.localizedDescription
                Task { @MainActor in
                    self.running.remove(.relaunchApp)
                    if ok { self.succeed(.relaunchApp, "\(name) relaunched") }
                    else { self.fail(.relaunchApp, "\(name) Didn't Reopen", message ?? "macOS didn't open it.") }
                }
            }
        } else if triesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reopen(app, bundle: bundle, name: name, triesLeft: triesLeft - 1) }
        } else {
            running.remove(.relaunchApp)
            fail(.relaunchApp, "\(name) Didn't Quit", "\(name) is still open. Answer its save dialog if it shows one, then try again. Nothing was reopened.")
        }
    }

    func showLoginItems() {
        runInBackground(.loginItems, { ProcessTools.loginItems() }) { result in
            var lines = result.items.prefix(40).map { "\($0.name) — \($0.kind)" }
            if result.items.count > 40 { lines.append("… and \(result.items.count - 40) more") }
            if result.systemEventsFailed {
                lines.insert("Open-at-login apps couldn't be read: "
                    + (result.failureDetail ?? "allow All of MacOS to control System Events (Privacy & Security › Automation)."), at: 0)
            }
            if lines.isEmpty { lines = ["No login items or launch agents found."] }
            lines.append("Items that apps add in the background are listed only in System Settings.")
            self.info(.loginItems, title: "Login Items", lines: lines, extra: ("Open Login Items Settings…", { self.openPane(.loginItems, .loginItems) }))
        }
    }

    func resetSavedState() {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        runInBackground(.resetSavedState, { () -> [CleanupCandidate] in
            FileTools.savedStateBundleIDs(library: library).compactMap { bundleID in
                let folder = FileTools.savedStateFolder(bundleID: bundleID, library: library)
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? bundleID
                let open = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
                return CleanupCandidate(url: folder, size: CleanupTools.allocatedSize(folder), note: name + (open ? " · open now: quit it first or it saves again" : ""))
            }.sorted { $0.note.localizedStandardCompare($1.note) == .orderedAscending }
        }) { items in
            self.review(.resetSavedState, title: "Saved Window State",
                        detail: "Apps reopen these windows at launch. Checked items move to the Trash, so the app starts without its old windows; documents are not touched.",
                        items: items, preselect: false, empty: "No app has saved window state")
        }
    }

    // MARK: - Storage

    /// The one Free Up Space sheet's scans: each entry was its own tool in
    /// 3.4.x and keeps its own confirmation-free preview.
    enum CleanupScan: String, CaseIterable, Identifiable {
        case folderSizes, largeFiles, oldDownloads, duplicates, orphans, devJunk, cache, trash
        var id: String { rawValue }

        var title: String {
            switch self {
            case .folderSizes: return "Folder Sizes"
            case .largeFiles: return "Large Files"
            case .oldDownloads: return "Old Downloads"
            case .duplicates: return "Duplicates"
            case .orphans: return "Removed Apps"
            case .devJunk: return "Xcode Junk"
            case .cache: return "Caches"
            case .trash: return "Trash"
            }
        }

        var symbol: String {
            switch self {
            case .folderSizes: return "chart.bar.doc.horizontal"
            case .largeFiles: return "externaldrive.badge.exclamationmark"
            case .oldDownloads: return "arrow.down.circle"
            case .duplicates: return "square.on.square"
            case .orphans: return "app.dashed"
            case .devJunk: return "hammer"
            case .cache: return "paintbrush"
            case .trash: return "trash"
            }
        }

        var help: String {
            switch self {
            case .folderSizes: return "Adds up what each item in a folder takes on disk."
            case .largeFiles: return "Finds files over a size you choose in a folder."
            case .oldDownloads: return "Lists Downloads items untouched for a while."
            case .duplicates: return "Finds identical files by size and SHA-256."
            case .orphans: return "Finds data in your Library left by apps that are no longer on this Mac. Nothing is checked until you choose."
            case .devJunk: return "Lists rebuildable Xcode data; archives are never listed."
            case .cache: return "Deletes the contents of ~/Library/Caches."
            case .trash: return "Permanently deletes everything in the Trash."
            }
        }
    }

    /// Called by the Free Up Space sheet when the sidebar's choice changes.
    func selectCleanup(_ scan: CleanupScan) {
        guard scan != cleanupScan else { return }
        cleanupScan = scan
        cleanupReview = nil
        storageMap?.cancel()
        storageMap = nil
    }

    /// Starts one scan of the Free Up Space sheet.
    func startCleanup(_ scan: CleanupScan) {
        switch scan {
        case .folderSizes: scanFolderSizes()
        case .largeFiles: scanLargeFiles()
        case .oldDownloads: scanOldDownloads()
        case .duplicates: scanDuplicates()
        case .orphans: scanOrphans()
        case .devJunk: scanDeveloperJunk()
        case .cache: clearCaches()
        case .trash: confirmEmptyTrash()
        }
    }

    func review(_ id: SystemToolID, title: String, detail: String, items: [CleanupCandidate], preselect: Bool, empty: String) {
        guard !items.isEmpty else { succeed(id, empty); return }
        cleanupTool = id
        cleanupReview = CleanupReview(title: title, detail: detail, candidates: items,
                                      selected: preselect ? Set(items.map(\.id)) : [])
    }

    /// Called by the review sheet's Move to Trash button.
    func trashSelected(_ review: CleanupReview) {
        let chosen = review.candidates.filter { review.selected.contains($0.id) }
        cleanupReview = nil
        guard !chosen.isEmpty else { return }
        let id: SystemToolID = review.uninstallTarget == nil ? cleanupTool : .uninstall
        if let sets = review.duplicateSets {
            // 7.6 (Codex DT01/DT02): set by set, checked right before each move;
            // done only when nothing failed or was held back.
            runInBackground(id, {
                FileTools.trashDuplicates(sets, selected: review.selected, hash: { try FileTools.sha256Hex(fileAt: $0) },
                                          trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
            }) { result in
                if result.succeeded { self.succeed(id, result.summary); return }
                self.lastResult = ToolResult(tool: id, message: result.summary, succeeded: false, date: Date())
                if let scan = review.duplicateScan {
                    self.toasts.show("Not All Moved: \(result.summary)", tone: .danger, seconds: Self.failureSeconds(result.summary),
                                     actionTitle: "Scan Again") { self.duplicates(minimum: scan.minimum, in: scan.folder) }
                } else {
                    self.fail(id, "Not All Moved", result.summary)
                }
            }
            return
        }
        runInBackground(id, { () -> CleanupTools.TrashOutcome in
            if let target = review.uninstallTarget {
                _ = try CleanupTools.checkUninstallTarget(target.url, expectedID: target.bundleID) {
                    !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
                }
            }
            return CleanupTools.moveToTrash(chosen)
        }) { outcome in
            if outcome.failures.isEmpty { self.succeed(id, outcome.summary) }
            else { self.fail(id, "Some Items Stayed", outcome.summary) }
        }
    }

    private func scanLargeFiles() {
        let menu = NSMenu()
        for (title, bytes) in [("Over 100 MB…", Int64(100_000_000)), ("Over 500 MB…", 500_000_000), ("Over 1 GB…", 1_000_000_000), ("Over 5 GB…", 5_000_000_000)] {
            menu.addItem(SystemToolMenuItem(title: title) { self.largeFiles(minimum: bytes) })
        }
        popUp(menu)
    }

    private func largeFiles(minimum: Int64) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan. ~/Library and hidden items are skipped."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        toast = "Scanning \(folder.lastPathComponent)…"
        runInBackground(.freeUpSpace, { CleanupTools.largeFiles(in: folder, minimumBytes: minimum) }) { items in
            self.review(.freeUpSpace, title: "Files over \(SystemStatus.size(minimum)) in \(folder.lastPathComponent)",
                        detail: "Largest first. Check the files you no longer need; they go to the Trash.",
                        items: items, preselect: false, empty: "No files over \(SystemStatus.size(minimum)) in \(folder.lastPathComponent)")
        }
    }

    private func scanOldDownloads() {
        let menu = NSMenu()
        for days in [30, 90, 180, 365] {
            menu.addItem(SystemToolMenuItem(title: "Untouched for \(days) Days…") { self.oldDownloads(days: days) })
        }
        popUp(menu)
    }

    private func oldDownloads(days: Int) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        runInBackground(.freeUpSpace, { CleanupTools.oldDownloads(in: downloads, days: days) }) { items in
            self.review(.freeUpSpace, title: "Downloads untouched for \(days) days",
                        detail: "Not added, changed or opened for \(days) days. Check what can go; it moves to the Trash.",
                        items: items, preselect: false, empty: "Nothing in Downloads is older than \(days) days")
        }
    }

    private func scanDuplicates() {
        let menu = NSMenu()
        for (title, bytes) in [("Files over 100 KB…", Int64(100_000)), ("Files over 1 MB…", 1_000_000), ("Files over 10 MB…", 10_000_000)] {
            menu.addItem(SystemToolMenuItem(title: title) { self.duplicates(minimum: bytes) })
        }
        popUp(menu)
    }

    private func duplicates(minimum: Int64) {
        guard let folder = pickFolder(message: "Choose a folder to search for identical files. ~/Library, hidden items and package contents are skipped.") else { return }
        duplicates(minimum: minimum, in: folder)
    }

    private func duplicates(minimum: Int64, in folder: URL) {
        toast = "Looking for duplicates in \(folder.lastPathComponent)…"
        runInBackground(.freeUpSpace, { () -> (sets: [FileTools.DuplicateSet], items: [CleanupCandidate], preselected: Set<String>, wasted: Int64) in
            let sets = FileTools.duplicateSets(FileTools.sizedFiles(in: folder, minimumBytes: minimum)) { try FileTools.sha256Hex(fileAt: $0) }
            let rows = FileTools.duplicateCandidates(sets)
            let wasted = sets.reduce(Int64(0)) { $0 + ($1.members.first?.fingerprint.size ?? 0) * Int64($1.members.count - 1) }
            return (sets, rows.items, rows.preselected, wasted)
        }) { result in
            guard !result.items.isEmpty else { self.succeed(.freeUpSpace, "No duplicates over \(SystemStatus.size(minimum)) in \(folder.lastPathComponent)"); return }
            self.cleanupTool = .freeUpSpace
            var review = CleanupReview(title: "\(result.sets.count) Sets of Duplicates in \(folder.lastPathComponent)",
                                       detail: "Same size and SHA-256. In each set the oldest copy is unchecked and stays; checked copies (\(SystemStatus.size(result.wasted))) move to the Trash. Each copy is checked again before it moves, and a set that changed since the scan stays.",
                                       candidates: result.items, selected: result.preselected)
            review.duplicateSets = result.sets
            review.duplicateScan = (folder, minimum)
            self.cleanupReview = review
        }
    }

    /// Pearcleaner's orphaned files: ~/Library data of apps that are no
    /// longer on this Mac. Bundle IDs can belong to helpers and frameworks
    /// too, so nothing starts checked.
    private func scanOrphans() {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        toast = "Looking for data of removed apps…"
        runInBackground(.freeUpSpace, { () -> (items: [CleanupCandidate], hints: [String: String]) in
            let items = CleanupTools.orphanedFiles(library: library, installed: CleanupTools.isInstalledOrRunning)
            return (items, Dictionary(uniqueKeysWithValues: items.map { ($0.id, CleanupTools.orphanHint(for: $0.url)) }))
        }) { result in
            guard !result.items.isEmpty else { self.succeed(.freeUpSpace, "No data of removed apps found"); return }
            let total = result.items.reduce(0) { $0 + $1.size }
            let apps = Set(result.items.map(\.note)).count
            self.cleanupTool = .freeUpSpace
            var review = CleanupReview(title: "Data of \(apps) Removed App\(apps == 1 ? "" : "s")",
                                       detail: "\(SystemStatus.size(total)) in your Library is named after apps that are no longer installed, grouped by app. Nothing is checked: a helper or a framework can share an app's ID, so check only what you recognise.",
                                       candidates: result.items, selected: [])
            review.groupsByNote = true
            review.hints = result.hints
            self.cleanupReview = review
        }
    }

    private func scanDeveloperJunk() {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        runInBackground(.freeUpSpace, { CleanupTools.developerJunk(library: library) }) { items in
            self.review(.freeUpSpace, title: "Xcode Junk", detail: "Xcode rebuilds or downloads these again when needed. Archives are not listed.",
                        items: items, preselect: true, empty: "No Xcode build data or caches found")
        }
    }

    /// 7.5 (Codex F06): the folder measured once, then walked down as a map.
    private func scanFolderSizes() {
        guard let folder = pickFolder(message: "Choose a folder; AOM measures everything in it so you can follow the space down.") else { return }
        storageMap?.cancel()
        let map = StorageMapModel(root: folder)
        storageMap = map
        map.start()
    }

    private func clearCaches() {
        guard confirm("Clear Caches?", "Everything in ~/Library/Caches except All of MacOS's own cache is deleted permanently. Apps rebuild their caches, so some may start slower once.",
                      button: "Clear Caches") else { return }
        runInBackground(.freeUpSpace, { try MacMagicSystemToolService.shared.clearDiskCache() }) { freed in
            self.succeed(.freeUpSpace, "Freed \(SystemStatus.size(freed))")
        }
    }

    private func confirmEmptyTrash() {
        guard confirm("Empty Trash?", "Items in your Trash will be permanently deleted.", button: "Empty Trash") else { return }
        Task {
            do {
                let result = try await service.forceEmptyTrash()
                if result.succeeded { succeed(.freeUpSpace, result.summary) } else { fail(.freeUpSpace, "Trash Not Fully Emptied", result.summary) }
            } catch { fail(.freeUpSpace, "Trash Not Emptied", error.localizedDescription) }
        }
    }

    func ejectMenu() {
        let volumes = DiskTools.volumes().filter(\.isEjectable)
        let menu = NSMenu()
        menu.addItem(SystemToolMenuItem(title: "Eject All Disks") {
            self.runAction(.eject, .ejectAllDisks, success: "Disks ejected (or none to eject)", failure: "A disk could not be ejected; a file on it may be open.")
        })
        if !volumes.isEmpty {
            menu.addItem(.separator())
            for volume in volumes {
                let item = SystemToolMenuItem(title: "\(volume.name) — \(SystemStatus.size(volume.available)) free of \(SystemStatus.size(volume.total))") {
                    self.runInBackground(.eject, { try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url) }) { _ in
                        self.succeed(.eject, "Ejected \(volume.name)")
                    }
                }
                item.image = (NSWorkspace.shared.icon(forFile: volume.url.path).copy() as? NSImage).map { $0.size = NSSize(width: 16, height: 16); return $0 }
                menu.addItem(item)
            }
        }
        popUp(menu)
    }


    // MARK: - Network

    /// Success only when every step exited 0; a standard user can't restart
    /// the DNS resolver, so the administrator prompt is offered.
    private func flushDNS() {
        Task {
            do {
                try await service.flushDNSCache()
                succeed(.dns, "DNS cache flushed")
            } catch let error as SystemToolError where error.needsAdministrator {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Flush DNS Needs an Administrator"
                alert.informativeText = "macOS refused part of the flush (\(error.localizedDescription)), so the DNS cache is not fully flushed. Flush it with an administrator password?"
                alert.addButton(withTitle: "Use Administrator Password…")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    lastResult = ToolResult(tool: .dns, message: "DNS cache not flushed", succeeded: false, date: Date()); return
                }
                switch service.flushDNSCacheAsAdministrator() {
                case .done: succeed(.dns, "DNS cache flushed")
                case .cancelled: lastResult = ToolResult(tool: .dns, message: "DNS cache not flushed", succeeded: false, date: Date())
                case .failed(let message): fail(.dns, "DNS Cache Not Flushed", message)
                }
            } catch {
                fail(.dns, "DNS Cache Not Flushed", error.localizedDescription)
            }
        }
    }

    /// Called by the process sheet's Quit button.
    func quitProcess(_ row: ProcessReview.Row) {
        let id = processTool
        guard confirm("Quit \(row.command)?", "Process \(row.pid) is asked to quit. Unsaved work in it may be lost.", button: "Quit") else { return }
        do {
            try NetworkTools.quit(pid: row.pid)
            processReview?.rows.removeAll { $0.pid == row.pid }
            if processReview?.rows.isEmpty == true { processReview = nil }
            succeed(id, "Asked \(row.command) to quit")
        } catch { fail(id, "Not Quit", error.localizedDescription) }
    }

    // MARK: - Maintenance

    func administrator(_ id: SystemToolID, title: String, message: String, button: String,
                       commands: [MacMagicSystemToolService.ToolCommand], success: String) {
        guard confirm(title, message + " macOS asks for an administrator password.", button: button, destructive: false) else { return }
        switch SystemToolsCommand.runAsAdministrator(commands) {
        case .done: succeed(id, success)
        case .cancelled: lastResult = ToolResult(tool: id, message: "Cancelled", succeeded: false, date: Date())
        case .failed(let message): fail(id, "\(title.replacingOccurrences(of: "?", with: "")) Failed", message)
        }
    }

    private func rebuildLaunchServices() {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard confirm("Rebuild Open With?", "AOM re-registers every app in the system, local and user domains, then compacts the Launch Services database. It takes a minute or two; Finder may be slow meanwhile.",
                      button: "Rebuild", destructive: false) else { return }
        toast = "Rebuilding Open With (a minute or two)…"
        runInBackground(.launchServices, {
            try SystemToolsCommand.runChecked(lsregister, ["-r", "-f", "-apps", "system,local,user"])
            try SystemToolsCommand.runChecked(lsregister, ["-gc"])
        }) { _ in self.succeed(.launchServices, "Open With rebuilt") }
    }


    // MARK: - Shared pieces

    /// A details alert with Copy (and an optional extra button). The first
    /// line becomes the last-result line.
    func info(_ id: SystemToolID, title: String, lines: [String], extra: (title: String, action: () -> Void)? = nil) {
        lastResult = ToolResult(tool: id, message: lines.first ?? title, succeeded: true, date: Date())
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy")
        if let extra { alert.addButton(withTitle: extra.title) }
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            copy(id, ([title] + lines).joined(separator: "\n"), message: "\(title) copied")
        case .alertThirdButtonReturn:
            extra?.action()
        default:
            break
        }
    }

    func openPane(_ id: SystemToolID, _ pane: SystemInfo.Pane) {
        if SystemInfo.open(pane) { lastResult = ToolResult(tool: id, message: "Opened \(pane.title) settings", succeeded: true, date: Date()) }
        else { fail(id, "Settings Didn't Open", "macOS couldn't open System Settings › \(pane.title).") }
    }

    func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Clipboard

    func copy(_ id: SystemToolID, _ text: String, message: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            fail(id, "Clipboard Not Changed", "macOS didn't accept the new clipboard text."); return
        }
        succeed(id, message)
    }

    // MARK: - Panels

    func popUp(_ menu: NSMenu) {
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func pickFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// An NSMenuItem that runs a closure — the AppKit bridge for the page's
/// choice menus.
@MainActor
final class SystemToolMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("SystemToolMenuItem is created in code only")
    }

    @objc private func runHandler() { handler() }
}
