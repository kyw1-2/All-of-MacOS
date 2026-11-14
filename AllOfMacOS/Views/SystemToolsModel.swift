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
    var processTool: SystemToolID = .ports

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
        return (raw ?? []).compactMap { raw -> SystemToolID? in
            SystemToolID(rawValue: raw) ?? SystemToolMigration.map[raw]
        }.filter { seen.insert($0).inserted }
    }

    // MARK: - Lifecycle

    func appear() {
        guard refreshTimer == nil else { return }
        isVisible = true
        refreshStates()
        refreshSlowStates(force: true)
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
        let interval = AOMPerformance.begin("SystemTools.refresh")
        defer { AOMPerformance.end("SystemTools.refresh", interval) }
        var next: [SystemToolID: SystemToolState] = [:]
        let style = preferences.value("AppleInterfaceStyle", domain: CFPreferenceStore.globalDomain) as? String
        next[.darkMode] = SystemToolState(style?.caseInsensitiveCompare("Dark") == .orderedSame)
        let awake = KeepAwakeService.shared
        next[.keepAwake] = awake.isActive ? .on(awake.endsAt.map { "Until " + $0.formatted(date: .omitted, time: .shortened) } ?? "On") : .off()
        let finder = UserDefaults(suiteName: SystemTweak.finder)
        next[.hidden] = SystemToolState(MacMagicSystemToolService.finderFlag("AppleShowAllFiles", in: finder, default: false))
        next[.desktop] = SystemToolState(MacMagicSystemToolService.finderFlag("CreateDesktop", in: finder, default: true))
        next[.dockAutoHide] = SystemToolState(SystemTweak.bool(preferences.value("autohide", domain: SystemTweak.dock)) ?? false)
        next[.hideMenuBar] = SystemToolState(SystemTweak.bool(preferences.value("_HIHideMenuBar", domain: CFPreferenceStore.globalDomain)) ?? false)
        next[.lowPower] = SystemToolState(ProcessInfo.processInfo.isLowPowerModeEnabled)
        next[.wifi] = CWWiFiClient.shared().interface().map { SystemToolState($0.powerOn()) } ?? .value("None")
        next[.keyboardClean] = KeyboardCleaningLock.shared.isActive ? .on("Locked") : .off()
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
            var slow: [SystemToolID: SystemToolState] = [:]
            if let output = try? SystemToolsCommand.run("/usr/sbin/nvram", ["StartupMute"]) {
                slow[.startupChime] = SystemToolState(DisplaySoundState.startupChimeOn(nvramOutput: output.stdout, status: output.status))
            }
            if let output = try? SystemToolsCommand.run(MetalHUD.launchctl.path, MetalHUD.readArguments) {
                slow[.metalHUD] = SystemToolState(MetalHUD.isOn(getenvOutput: output.stdout))
            }
            if let output = try? SystemToolsCommand.run("/usr/bin/tmutil", ["status"]), let status = DiskTools.parseBackupStatus(output.stdout) {
                slow[.timeMachine] = status.running
                    ? .on(status.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "Running") : .off("Idle")
            }
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
        case .keyboardClean: lockKeyboard()
        // Display
        case .resolution: resolutionMenu()
        case .brightness: brightnessMenu()
        case .metalHUD: toggleMetalHUD()
        // Power & Session
        case .lockScreen: runAction(id, .lockScreen, success: nil, failure: "The screen could not be locked.")
        case .sleep: runAction(id, .sleepComputer, success: nil, failure: "pmset could not put the Mac to sleep.")
        case .sleepDisplays: runAction(id, .sleepDisplay, success: nil, failure: "pmset could not turn the displays off.")
        case .batteryDetails: showBatteryDetails()
        case .sleepTimer: sleepTimerMenu()
        case .awakeWhileApp: awakeWhileAppMenu()
        case .restart: session(id, .restart, title: "Restart the Mac?", button: "Restart")
        case .shutDown: session(id, .shutDown, title: "Shut down the Mac?", button: "Shut Down")
        case .logOut:
            // The action asks first itself (destructive actions confirm).
            runAction(id, .logOut, success: nil, failure: "The log-out was cancelled or refused.")
        case .quitAll: quitAllApps()
        // Apps
        case .activity: showActivity()
        case .forceQuit: forceQuitMenu()
        case .relaunchApp: relaunchAppMenu()
        case .uninstall: reviewUninstall(nil)
        case .loginItems: showLoginItems()
        case .awakeReasons: showAwakeReasons()
        case .resetSavedState: resetSavedState()
        // Storage
        case .freeUpSpace: cleanupScan = .folderSizes; showFreeUpSpace = true
        case .eject: ejectMenu()
        case .timeMachine: timeMachineMenu()
        case .snapshots: showLocalSnapshots()
        case .verifyDisk: verifyStartupDisk()
        case .installDMG: FolderRulesModule.installDiskImage()
        // Network
        case .networkInfo: showNetworkInfo = true
        case .speedTest:
            toast = "Testing the connection (about 20 s)…"
            runInBackground(id, { try NetworkTools.runSpeedTest() }) { self.succeed(id, $0.summary) }
        case .ping: pingHost()
        case .ports: portsMenu()
        case .vpn: VPNModel.shared.present()
        case .dns: flushDNS()
        case .renewDHCP: renewDHCP()
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
        case .fontCaches:
            runInBackground(id, { try SystemToolsCommand.runChecked("/usr/bin/atsutil", ["databases", "-removeUser"]) }) { _ in
                self.succeed(id, "Font caches removed; log out and back in to rebuild them")
            }
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
        case .shotfolder: chooseScreenshotFolder()
        case .startupChime: toggleStartupChime()
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
                    awake.start(minutes: minutes, keepDisplay: keepDisplay)
                    if awake.isActive { self.succeed(.keepAwake, "Keeping awake \(awake.remainingDescription ?? "")") }
                    else { self.fail(.keepAwake, "Keep Awake Didn't Start", "macOS refused the power assertion.") }
                })
            }
            if !keepDisplay { menu.addItem(.separator()) }
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

    private func lockKeyboard() {
        let lock = KeyboardCleaningLock.shared
        if lock.isActive { lock.stop(); succeed(.keyboardClean, "Keyboard unlocked"); return }
        let menu = NSMenu()
        for seconds in [30, 60, 120] {
            let title = seconds < 60 ? "Lock for \(seconds) Seconds" : "Lock for \(seconds / 60) Minute\(seconds == 60 ? "" : "s")"
            menu.addItem(SystemToolMenuItem(title: title) {
                do {
                    try lock.start(seconds: seconds)
                    self.lastResult = ToolResult(tool: .keyboardClean, message: "Keyboard locked for \(seconds) s", succeeded: true, date: Date())
                    self.refreshStates()
                    // The state flips back when the lock ends by itself.
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds) + .milliseconds(700)) { self.refreshStates() }
                } catch { self.fail(.keyboardClean, "Keyboard Not Locked", error.localizedDescription) }
            })
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

    func toggleMetalHUD() {
        let wasOn = states[.metalHUD] == .on()
        runInBackground(.metalHUD, { () -> Bool in
            try SystemToolsCommand.runChecked(MetalHUD.launchctl.path, MetalHUD.writeArguments(on: !wasOn))
            let check = try SystemToolsCommand.run(MetalHUD.launchctl.path, MetalHUD.readArguments)
            return MetalHUD.isOn(getenvOutput: check.stdout)
        }) { isOn in
            self.slowStates[.metalHUD] = SystemToolState(isOn)
            guard isOn != wasOn else {
                self.fail(.metalHUD, "Metal HUD Not Changed", "launchctl ran, but MTL_HUD_ENABLED is still \(wasOn ? "set" : "unset").")
                return
            }
            self.succeed(.metalHUD, isOn ? "Metal HUD on for apps you open from now on (apps already open don't change)"
                                         : "Metal HUD off for apps you open from now on")
        }
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

    private func session(_ id: SystemToolID, _ command: SystemToolsCommand.SessionCommand, title: String, button: String) {
        guard confirm(title, "Apps are asked to quit; any app with unsaved changes can still stop it.",
                      button: button) else { return }
        runInBackground(id, { try SystemToolsCommand.perform(command) }) { _ in
            self.lastResult = ToolResult(tool: id, message: "\(button) requested", succeeded: true, date: Date())
        }
    }

    private func quitAllApps() {
        let own = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != own && $0.bundleIdentifier != "com.apple.finder"
        }
        guard !apps.isEmpty else { succeed(.quitAll, "No other apps are open"); return }
        let names = apps.compactMap(\.localizedName).sorted()
        let list = names.prefix(12).joined(separator: ", ") + (names.count > 12 ? " and \(names.count - 12) more" : "")
        guard confirm("Quit \(apps.count) App\(apps.count == 1 ? "" : "s")?",
                      "\(list) will be asked to quit. Apps with unsaved documents may ask what to do.", button: "Quit All") else { return }
        apps.forEach { $0.terminate() }
        running.insert(.quitAll)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.running.remove(.quitAll)
            let left = apps.filter { !$0.isTerminated }
            if left.isEmpty { self.succeed(.quitAll, "Quit \(apps.count) app\(apps.count == 1 ? "" : "s")") }
            else {
                self.fail(.quitAll, "Some Apps Are Still Open",
                          "Quit \(apps.count - left.count) of \(apps.count). Still open (probably asking about unsaved work): "
                            + left.compactMap(\.localizedName).joined(separator: ", "))
            }
        }
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

    func forceQuitMenu() {
        popUp(appMenu(ProcessTools.regularApps()) { app in
            let name = app.localizedName ?? "the app"
            guard self.confirm("Force Quit \(name)?", "\(name) stops at once. Unsaved changes in it are lost.", button: "Force Quit") else { return }
            guard app.forceTerminate() else { self.fail(.forceQuit, "Not Force Quit", "macOS refused to stop \(name)."); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if app.isTerminated { self.succeed(.forceQuit, "\(name) force quit") }
                else { self.fail(.forceQuit, "\(name) Is Still Open", "macOS accepted the request, but \(name) hasn't stopped yet.") }
            }
        })
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
            fail(.relaunchApp, "\(name) Didn't Quit", "\(name) is still open, probably asking about unsaved work. Nothing was reopened.")
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
        case folderSizes, largeFiles, oldDownloads, duplicates, devJunk, cache, trash
        var id: String { rawValue }

        var title: String {
            switch self {
            case .folderSizes: return "Folder Sizes"
            case .largeFiles: return "Large Files"
            case .oldDownloads: return "Old Downloads"
            case .duplicates: return "Duplicates"
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
    }

    /// Starts one scan of the Free Up Space sheet.
    func startCleanup(_ scan: CleanupScan) {
        switch scan {
        case .folderSizes: scanFolderSizes()
        case .largeFiles: scanLargeFiles()
        case .oldDownloads: scanOldDownloads()
        case .duplicates: scanDuplicates()
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
        let id = cleanupTool
        runInBackground(id, { CleanupTools.moveToTrash(chosen) }) { outcome in
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
        toast = "Looking for duplicates in \(folder.lastPathComponent)…"
        runInBackground(.freeUpSpace, { () -> (items: [CleanupCandidate], preselected: Set<String>, groups: Int, wasted: Int64) in
            let groups = FileTools.duplicateGroups(FileTools.sizedFiles(in: folder, minimumBytes: minimum)) { try FileTools.sha256Hex(fileAt: $0) }
            let rows = FileTools.duplicateCandidates(groups)
            return (rows.items, rows.preselected, groups.count, groups.reduce(0) { $0 + FileTools.wasted($1) })
        }) { result in
            guard !result.items.isEmpty else { self.succeed(.freeUpSpace, "No duplicates over \(SystemStatus.size(minimum)) in \(folder.lastPathComponent)"); return }
            self.cleanupTool = .freeUpSpace
            self.cleanupReview = CleanupReview(title: "\(result.groups) Sets of Duplicates in \(folder.lastPathComponent)",
                                               detail: "Same size and SHA-256. In each set the oldest copy is unchecked and stays; checked copies (\(SystemStatus.size(result.wasted))) move to the Trash.",
                                               candidates: result.items, selected: result.preselected)
        }
    }

    private func scanDeveloperJunk() {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        runInBackground(.freeUpSpace, { CleanupTools.developerJunk(library: library) }) { items in
            self.review(.freeUpSpace, title: "Xcode Junk", detail: "Xcode rebuilds or downloads these again when needed. Archives are not listed.",
                        items: items, preselect: true, empty: "No Xcode build data or caches found")
        }
    }

    private func scanFolderSizes() {
        guard let folder = pickFolder(message: "Choose a folder; AOM adds up what each item in it takes on disk.") else { return }
        toast = "Measuring \(folder.lastPathComponent)…"
        runInBackground(.freeUpSpace, { FileTools.folderSizes(in: folder) }) { sizes in
            guard !sizes.isEmpty else { self.succeed(.freeUpSpace, "\(folder.lastPathComponent) is empty or unreadable"); return }
            let total = sizes.reduce(0) { $0 + $1.size }
            let items = sizes.prefix(200).map {
                CleanupCandidate(url: folder.appendingPathComponent($0.name), size: $0.size,
                                 note: "\($0.files) file\($0.files == 1 ? "" : "s") · \(total > 0 ? Int((Double($0.size) / Double(total) * 100).rounded()) : 0)% of the folder")
            }
            self.lastResult = ToolResult(tool: .freeUpSpace, message: "\(folder.lastPathComponent): \(SystemStatus.size(total))", succeeded: true, date: Date())
            self.cleanupTool = .freeUpSpace
            self.cleanupReview = CleanupReview(title: "\(folder.lastPathComponent) · \(SystemStatus.size(total))",
                                               detail: "Biggest first, measured as allocated space (packages included). Use Show in Finder to look inside; nothing is changed here.",
                                               candidates: Array(items), selected: [], allowsTrash: false)
        }
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

    func timeMachineMenu() {
        if slowStates[.timeMachine]?.tone == .success { showTimeMachine(); return }
        let menu = NSMenu()
        menu.addItem(SystemToolMenuItem(title: "Back Up Now") { self.backUpNow() })
        menu.addItem(SystemToolMenuItem(title: "Backup Details…") { self.showTimeMachine() })
        popUp(menu)
    }

    func backUpNow() {
        runInBackground(.timeMachine, { () -> Void in
            let destinations = try SystemToolsCommand.run("/usr/bin/tmutil", ["destinationinfo"])
            guard DiskTools.hasDestination(destinations) else {
                throw SystemToolError.invalidInput("Time Machine has no backup disk. Set one up in System Settings › General › Time Machine.")
            }
            try SystemToolsCommand.runChecked("/usr/bin/tmutil", ["startbackup"])
        }) { _ in
            self.succeed(.timeMachine, "Time Machine backup started")
            self.refreshSlowStates()
        }
    }

    func showTimeMachine() {
        runInBackground(.timeMachine, { () -> [String] in
            let status = (try? SystemToolsCommand.run("/usr/bin/tmutil", ["status"])).flatMap { DiskTools.parseBackupStatus($0.stdout) }
            let destinations = try SystemToolsCommand.run("/usr/bin/tmutil", ["destinationinfo"])
            var lines = [status.map(DiskTools.backupStatusText) ?? "Status unknown"]
            if DiskTools.hasDestination(destinations) {
                let latest = try? SystemToolsCommand.run("/usr/bin/tmutil", ["latestbackup"])
                if let latest, latest.succeeded, let path = latest.stdout.split(whereSeparator: \.isNewline).last {
                    lines.append("Latest backup: " + URL(fileURLWithPath: String(path)).lastPathComponent)
                } else {
                    lines.append("Latest backup: not readable now (the backup disk may be disconnected)")
                }
            } else {
                lines.append("No backup disk is set up.")
            }
            return lines
        }) { lines in
            self.info(.timeMachine, title: "Time Machine", lines: lines, extra: ("Time Machine Settings…", { self.openPane(.timeMachine, .timeMachine) }))
        }
    }

    func verifyStartupDisk() {
        guard confirm("Verify the Startup Disk?",
                      "diskutil checks the startup volume without changing it. It takes a few minutes, and the Mac may pause for a moment while the check starts.",
                      button: "Verify", destructive: false) else { return }
        toast = "Verifying the startup disk (a few minutes)…"
        runInBackground(.verifyDisk, { try SystemToolsCommand.run("/usr/sbin/diskutil", DiskTools.verifyArguments()) }) { output in
            let result = DiskTools.parseVerify(output.stdout + "\n" + output.stderr, status: output.status)
            if result.ok { self.succeed(.verifyDisk, result.summary) }
            else { self.fail(.verifyDisk, "Verification Found a Problem", result.summary + "\n\nTo repair it, use First Aid in Disk Utility (it may need macOS Recovery for the startup disk).") }
        }
    }

    func showLocalSnapshots() {
        runInBackground(.snapshots, { try SystemToolsCommand.runChecked("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).stdout }) { text in
            let names = DiskTools.parseLocalSnapshots(text)
            let timeMachine = names.filter(DiskTools.isTimeMachineSnapshot)
            var lines = ["\(names.count) local snapshot\(names.count == 1 ? "" : "s") of the startup disk"]
            if !timeMachine.isEmpty { lines.append("\(timeMachine.count) from Time Machine (removable)") }
            if names.count > timeMachine.count { lines.append("\(names.count - timeMachine.count) from macOS updates (macOS removes these itself)") }
            lines += names.prefix(12).map { "• " + $0.replacingOccurrences(of: "com.apple.", with: "") }
            let thin: (String, () -> Void)? = timeMachine.isEmpty ? nil : ("Thin Time Machine Snapshots…", {
                self.administrator(.snapshots, title: "Thin Local Snapshots?",
                                   message: "macOS removes Time Machine's local snapshots of the startup disk to free up to 20 GB. Backups on your backup disk are not touched.",
                                   button: "Thin…", commands: [.init(path: "/usr/bin/tmutil", arguments: DiskTools.thinArguments)],
                                   success: "Time Machine snapshots thinned")
            })
            self.info(.snapshots, title: "Local Snapshots", lines: lines, extra: thin)
        }
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

    func renewDHCP() {
        guard let interface = SystemStatus.preferredAddress(SystemStatus.ipv4Addresses())?.interface else {
            fail(.renewDHCP, "No Active Interface", "No network interface has an IPv4 address to renew."); return
        }
        administrator(.renewDHCP, title: "Renew the DHCP Lease on \(interface)?",
                      message: "The connection on \(interface) drops for a few seconds while the router hands out an address.",
                      button: "Renew…", commands: [.init(path: "/usr/sbin/ipconfig", arguments: ["set", interface, "DHCP"])],
                      success: "DHCP renewed on \(interface)")
    }

    func pingHost() {
        guard let typed = promptText("Ping", "Host name or IP address (empty for 1.1.1.1):", placeholder: "apple.com") else { return }
        let host = typed.isEmpty ? "1.1.1.1" : typed
        guard NetworkTools.isValidHost(host) else { fail(.ping, "Not a Host Name", "“\(host)” isn't a host name or IP address."); return }
        runInBackground(.ping, { try NetworkTools.ping(host: host) }) { result in
            if result.received > 0 { self.succeed(.ping, "\(host): \(result.summary)") }
            else { self.fail(.ping, "No Reply from \(host)", "\(result.sent) pings sent, none answered. The host may block ping, or the network is down.") }
        }
    }

    /// What's Using a Port and Listening Ports in one sheet.
    func portsMenu() {
        let menu = NSMenu()
        menu.addItem(SystemToolMenuItem(title: "A Port…") { self.portLookup() })
        menu.addItem(SystemToolMenuItem(title: "Listening Ports") { self.showListeningPorts() })
        popUp(menu)
    }

    private func portLookup() {
        guard let text = promptText("What's Using a Port", "Port number (1–65535):", placeholder: "8080") else { return }
        guard let port = NetworkTools.port(from: text) else {
            fail(.ports, "Not a Port", "“\(text)” isn't a port number from 1 to 65535."); return
        }
        runInBackground(.ports, { try NetworkTools.users(ofPort: port) }) { users in
            guard !users.isEmpty else { self.succeed(.ports, "Nothing you can see is using port \(port)"); return }
            self.processTool = .ports
            self.processReview = ProcessReview(title: "Port \(port)", rows: users.map {
                .init(id: $0.id, pid: $0.pid, command: $0.command,
                      detail: "PID \($0.pid) · \($0.proto) \($0.name)\($0.state.isEmpty ? "" : " · \($0.state)")")
            })
        }
    }

    private func showListeningPorts() {
        runInBackground(.ports, { try NetworkTools.listeningUsers() }) { users in
            guard !users.isEmpty else { self.succeed(.ports, "Nothing you can see is listening"); return }
            self.processTool = .ports
            self.processReview = ProcessReview(title: "Listening Ports", rows: users.map {
                .init(id: $0.id, pid: $0.pid, command: $0.command, detail: "PID \($0.pid) · \($0.proto) \($0.name)")
            })
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

    func toggleStartupChime() {
        let isOn = slowStates[.startupChime] != .off()
        administrator(.startupChime, title: isOn ? "Turn Off the Startup Sound?" : "Turn On the Startup Sound?",
                      message: "The setting is stored in the Mac's firmware (StartupMute) and applies from the next start.",
                      button: isOn ? "Turn Off…" : "Turn On…",
                      commands: [.init(path: "/usr/sbin/nvram", arguments: DisplaySoundState.startupChimeArguments(on: !isOn))],
                      success: isOn ? "Startup sound off" : "Startup sound on")
        refreshSlowStates()
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

    func promptText(_ title: String, _ message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
