import AppKit
import CoreAudio
import UniformTypeIdentifiers

/// The 3.3.6 tools: Display & Sound, Battery & Energy, Apps & Processes,
/// Disk & Storage, System Info and the new Finder, Files and Network tools.
/// Same rules as the rest of the page: success is reported only after the
/// change was confirmed, anything destructive asks first, admin steps use the
/// administrator prompt, scans preview before the Trash.
extension SystemToolsModel {
    // MARK: - States

    /// Cheap states, read on the main thread with the others.
    func refresh336States(into next: inout [SystemToolID: SystemToolState]) {
        next[.lowPower] = SystemToolState(ProcessInfo.processInfo.isLowPowerModeEnabled)
        next[.hideMenuBar] = SystemToolState(SystemTweak.bool(preferences.value("_HIHideMenuBar", domain: CFPreferenceStore.globalDomain)) ?? false)
        // The public read-only accessors; macOS offers no way to set these.
        next[.reduceTransparency] = SystemToolState(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        next[.reduceMotion] = SystemToolState(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let main = CGMainDisplayID()
        if let mode = DisplayControlService.currentMode(main) {
            next[.resolution] = .value("\(mode.pointWidth)×\(mode.pointHeight)")
        }
        if let level = DisplayControlService.brightness(main) { next[.brightness] = .value(DisplaySoundState.percentText(level) ?? "—") }
        if let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            next[.wallpaper] = .value(DisplaySoundState.shortName(url.deletingPathExtension().lastPathComponent, limit: 12))
        }
        if let output = AudioOutputService.currentDeviceID() {
            next[.soundOutput] = .value(DisplaySoundState.shortName(AudioOutputService.string(output, kAudioObjectPropertyName)))
        }
        if let input = AudioOutputService.defaultInputDeviceID() {
            next[.soundInput] = .value(DisplaySoundState.shortName(AudioOutputService.string(input, kAudioObjectPropertyName)))
        }
        if AudioOutputService.isOutputMuted() { next[.volume] = .value("Muted") }
        else if let text = DisplaySoundState.percentText(AudioOutputService.currentVolume()) { next[.volume] = .value(text) }
        let timer = SleepTimerService.shared
        next[.sleepTimer] = timer.isActive ? .on("At " + (timer.firesAt?.formatted(date: .omitted, time: .shortened) ?? "")) : .off()
        let awake = AppAwakeService.shared
        next[.awakeWhileApp] = awake.appName.map { .on(DisplaySoundState.shortName($0, limit: 10)) } ?? .off()
        next[.showLibrary] = SystemToolState(!Self.isLibraryHidden())
        for (id, state) in slowStates { next[id] = state }
    }

    /// States that need a helper process: alert volume, startup chime and
    /// Time Machine. One refresh at a time, off the main thread.
    func refreshSlowStates() {
        guard !slowRefreshRunning else { return }
        slowRefreshRunning = true
        Task.detached(priority: .utility) {
            var slow: [SystemToolID: SystemToolState] = [:]
            if let output = try? SystemToolsCommand.run("/usr/bin/osascript", ["-e", "alert volume of (get volume settings)"]),
               output.succeeded, let value = Int(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
                slow[.alertVolume] = .value("\(value)%")
            }
            if let output = try? SystemToolsCommand.run("/usr/sbin/nvram", ["StartupMute"]) {
                slow[.startupChime] = SystemToolState(DisplaySoundState.startupChimeOn(nvramOutput: output.stdout, status: output.status))
            }
            if let output = try? SystemToolsCommand.run("/usr/bin/tmutil", ["status"]), let status = DiskTools.parseBackupStatus(output.stdout) {
                slow[.backupNow] = status.running
                    ? .on(status.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "Running") : .off("Idle")
            }
            let result = slow
            await MainActor.run {
                self.slowRefreshRunning = false
                if result != self.slowStates { self.slowStates = result; self.refreshStates() }
            }
        }
    }

    static func isLibraryHidden() -> Bool {
        var url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? true
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

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// osascript errors read "…: execution error: Not authorized to send
    /// Apple events to Finder. (-1743)"; that one gets a pointer to the
    /// right setting.
    private func appleEventsMessage(_ error: Error, app: String) -> String {
        let text = error.localizedDescription
        if text.contains("-1743") {
            return "Allow All of MacOS to control \(app) in System Settings › Privacy & Security › Automation, then try again."
        }
        return text
    }

    // MARK: - Quick Toggles

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

    func toggleHideMenuBar() {
        let wasOn = states[.hideMenuBar] == .on()
        let script = "tell application \"System Events\" to tell dock preferences to set autohide menu bar to \(wasOn ? "false" : "true")"
        runInBackground(.hideMenuBar, { try SystemToolsCommand.runChecked("/usr/bin/osascript", ["-e", script]) }) { _ in
            self.succeed(.hideMenuBar, wasOn ? "Menu bar always shown" : "Menu bar hides automatically")
        }
    }

    // MARK: - Display & Sound

    func resolutionMenu() {
        let displays = DisplayControlService.displays()
        guard !displays.isEmpty else { fail(.resolution, "No Display Found", "CoreGraphics reported no active display."); return }
        let menu = NSMenu()
        for display in displays {
            let id = display.displayID
            guard let current = DisplayControlService.currentMode(id) else { continue }
            if displays.count > 1 { menu.addItem(header(display.name)) }
            let canChange = DisplayControlService.canReturnToCurrentMode(id)
            if !canChange { menu.addItem(header("macOS hides the current mode; change it in System Settings")) }
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
            menu.addItem(header(display.name + (hardware ? "" : " (software dim)")))
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

    func chooseWallpaper() {
        guard let url = pickFiles(types: [.image], multiple: false, message: "Choose a picture for the wallpaper on every display.")?.first else { return }
        var failures: [String] = []
        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
            catch { failures.append("\(screen.localizedName): \(error.localizedDescription)") }
        }
        if failures.isEmpty { succeed(.wallpaper, "Wallpaper set to \(url.lastPathComponent)") }
        else { fail(.wallpaper, "Wallpaper Not Set Everywhere", failures.joined(separator: "; ")) }
    }

    func soundOutputMenu() {
        let devices = AudioOutputService.devices()
        guard !devices.isEmpty else { fail(.soundOutput, "No Output Devices", "Core Audio reported no sound output."); return }
        let current = AudioOutputService.currentDeviceID()
        let menu = NSMenu()
        for device in devices {
            let item = SystemToolMenuItem(title: device.name) {
                AudioOutputService.shared.select(name: device.name, uid: device.uid) { ok in
                    DispatchQueue.main.async {
                        if ok { self.succeed(.soundOutput, "Sound output: \(device.name)") }
                        else { self.fail(.soundOutput, "Output Not Changed", "macOS didn't switch to \(device.name).") }
                    }
                }
            }
            item.state = device.id == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(SystemToolMenuItem(title: "Sound Settings…") { self.openPane(.soundOutput, .sound) })
        popUp(menu)
    }

    func soundInputMenu() {
        let devices = AudioOutputService.inputDevices()
        guard !devices.isEmpty else { fail(.soundInput, "No Microphones", "Core Audio reported no sound input."); return }
        let current = AudioOutputService.defaultInputDeviceID()
        let menu = NSMenu()
        for device in devices {
            let item = SystemToolMenuItem(title: device.name) {
                if AudioOutputService.selectInput(uid: device.uid), AudioOutputService.defaultInputDeviceID() == device.id {
                    self.succeed(.soundInput, "Sound input: \(device.name)")
                } else { self.fail(.soundInput, "Input Not Changed", "macOS didn't switch to \(device.name).") }
            }
            item.state = device.id == current ? .on : .off
            menu.addItem(item)
        }
        popUp(menu)
    }

    func volumeMenu() {
        guard AudioOutputService.canAdjustOutputVolume() else {
            fail(.volume, "No Volume Control", "The current output has no software volume (HDMI and AirPlay devices often set it on the device)."); return
        }
        let current = AudioOutputService.currentVolume().map { Int(($0 * 100).rounded()) }
        let menu = NSMenu()
        for percent in DisplaySoundState.volumePresets {
            let item = SystemToolMenuItem(title: percent == 0 ? "0% (Silent)" : "\(percent)%") {
                AudioOutputService.shared.setVolume(percent: Double(percent)) { ok in
                    DispatchQueue.main.async {
                        if ok { self.succeed(.volume, "Volume \(percent)%") }
                        else { self.fail(.volume, "Volume Not Changed", "The output didn't confirm the new volume.") }
                    }
                }
            }
            item.state = current == percent ? .on : .off
            menu.addItem(item)
        }
        popUp(menu)
    }

    func alertVolumeMenu() {
        let menu = NSMenu()
        for percent in DisplaySoundState.volumePresets {
            let item = SystemToolMenuItem(title: percent == 0 ? "0% (Silent)" : "\(percent)%") {
                if AudioOutputService.setSystemAlertVolume(percent: Double(percent)) {
                    NSSound.beep()
                    self.slowStates[.alertVolume] = .value("\(percent)%")
                    self.succeed(.alertVolume, "Alert volume \(percent)%")
                } else { self.fail(.alertVolume, "Alert Volume Not Changed", "macOS refused the change.") }
            }
            item.state = slowStates[.alertVolume]?.text == "\(percent)%" ? .on : .off
            menu.addItem(item)
        }
        popUp(menu)
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

    // MARK: - Battery & Energy

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
        let apps = ProcessTools.regularApps()
        if apps.isEmpty { menu.addItem(header("No other apps are open")) }
        for app in apps {
            let item = SystemToolMenuItem(title: app.localizedName ?? app.bundleIdentifier ?? "App") {
                if awake.start(for: app) { self.succeed(.awakeWhileApp, "Awake until \(app.localizedName ?? "the app") quits") }
                else { self.fail(.awakeWhileApp, "Didn't Start", "macOS refused the power assertion, or the app already quit.") }
            }
            item.image = app.icon.map { icon in let copy = icon.copy() as? NSImage ?? icon; copy.size = NSSize(width: 16, height: 16); return copy }
            menu.addItem(item)
        }
        popUp(menu)
    }

    func showAwakeReasons() {
        runInBackground(.awakeReasons, { try SystemToolsCommand.runChecked("/usr/bin/pmset", ["-g", "assertions"]).stdout }) { text in
            let assertions = PowerTools.parseAssertions(text)
            guard !assertions.isEmpty else { self.succeed(.awakeReasons, "Nothing is keeping the Mac awake"); return }
            self.processReview = ProcessReview(tool: .awakeReasons, title: "Keeping the Mac Awake", rows: assertions.map {
                .init(id: $0.id, pid: $0.pid, command: $0.process,
                      detail: "\(PowerTools.assertionKind($0.type)) · \($0.name.isEmpty ? $0.type : $0.name) · PID \($0.pid)")
            })
        }
    }

    // MARK: - Apps & Processes

    private func appMenu(_ apps: [NSRunningApplication], action: @escaping (NSRunningApplication) -> Void) -> NSMenu {
        let menu = NSMenu()
        if apps.isEmpty { menu.addItem(header("No other apps are open")) }
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

    func showTopProcesses(_ order: ProcessTools.Order) {
        let id: SystemToolID = order == .cpu ? .topCPU : .topMemory
        runInBackground(id, { try ProcessTools.samples() }) { samples in
            let top = ProcessTools.top(samples, by: order)
            guard !top.isEmpty else { self.fail(id, "No Processes", "ps returned no processes."); return }
            self.processReview = ProcessReview(tool: id, title: order == .cpu ? "Top CPU" : "Top Memory", rows: top.map {
                .init(id: "\($0.pid)", pid: $0.pid, command: $0.name, detail: ProcessTools.detail($0))
            })
        }
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
            if result.systemEventsFailed { lines.insert("Open-at-login apps couldn't be read: allow All of MacOS to control System Events (Privacy & Security › Automation).", at: 0) }
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

    // MARK: - Finder

    func toggleLibraryFolder() {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let hidden = Self.isLibraryHidden()
        runInBackground(.showLibrary, { try SystemToolsCommand.runChecked("/usr/bin/chflags", [hidden ? "nohidden" : "hidden", library]) }) { _ in
            if Self.isLibraryHidden() == hidden { self.fail(.showLibrary, "Library Folder Not Changed", "chflags ran, but the folder's hidden flag didn't change."); return }
            self.succeed(.showLibrary, hidden ? "Library folder shown in Finder" : "Library folder hidden")
        }
    }

    /// The front Finder window's folder, or the desktop with no window open.
    nonisolated static let finderFolderScript = """
    tell application "Finder"
        if (count of Finder windows) > 0 then
            return POSIX path of (target of front Finder window as alias)
        else
            return POSIX path of (desktop as alias)
        end if
    end tell
    """

    nonisolated static let finderSelectionScript = """
    set out to ""
    tell application "Finder"
        repeat with anItem in (get selection)
            set out to out & POSIX path of (anItem as alias) & linefeed
        end repeat
    end tell
    return out
    """

    private func finderFolder(_ id: SystemToolID, then done: @escaping (URL) -> Void) {
        runInBackground(id, { try SystemToolsCommand.runChecked("/usr/bin/osascript", ["-e", Self.finderFolderScript]).stdout }) { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { self.fail(id, "No Finder Folder", "Finder didn't report a folder."); return }
            done(URL(fileURLWithPath: trimmed, isDirectory: true))
        }
    }

    func copyFinderSelection() {
        guard !running.contains(.copyFinderPath) else { return }
        running.insert(.copyFinderPath)
        Task.detached(priority: .userInitiated) {
            let outcome = Swift.Result { try SystemToolsCommand.runChecked("/usr/bin/osascript", ["-e", Self.finderSelectionScript]).stdout }
            await MainActor.run {
                self.running.remove(.copyFinderPath)
                switch outcome {
                case .success(let text):
                    let paths = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
                    guard !paths.isEmpty else { self.fail(.copyFinderPath, "Nothing Selected", "Select files or folders in Finder first."); return }
                    self.copy(.copyFinderPath, paths.joined(separator: "\n"),
                              message: paths.count == 1 ? "Copied \(Self.preview(paths[0]))" : "Copied \(paths.count) paths")
                case .failure(let error):
                    self.fail(.copyFinderPath, "Path Not Copied", self.appleEventsMessage(error, app: "Finder"))
                }
            }
        }
    }

    func newTextFileInFinder() {
        finderFolder(.newTextFile) { folder in
            let url = FileTools.freeName("untitled", ext: "txt", in: folder) { FileManager.default.fileExists(atPath: $0.path) }
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                self.fail(.newTextFile, "File Not Created", "\(folder.lastPathComponent) doesn't accept new files."); return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self.succeed(.newTextFile, "Created \(url.lastPathComponent) in \(folder.lastPathComponent)")
        }
    }

    func openTerminalInFinder() {
        finderFolder(.terminalHere) { folder in
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                self.fail(.terminalHere, "Terminal Not Found", "Terminal isn't installed."); return
            }
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                DispatchQueue.main.async {
                    if app != nil { self.succeed(.terminalHere, "Terminal opened in \(folder.lastPathComponent)") }
                    else { self.fail(.terminalHere, "Terminal Didn't Open", error?.localizedDescription ?? "macOS didn't open Terminal.") }
                }
            }
        }
    }

    // MARK: - Disk & Storage

    func ejectDiskMenu() {
        let volumes = DiskTools.volumes().filter(\.isEjectable)
        guard !volumes.isEmpty else { succeed(.ejectDisk, "No disks to eject"); return }
        let menu = NSMenu()
        for volume in volumes {
            let item = SystemToolMenuItem(title: "\(volume.name) — \(SystemStatus.size(volume.available)) free of \(SystemStatus.size(volume.total))") {
                self.runInBackground(.ejectDisk, { try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url) }) { _ in
                    self.succeed(.ejectDisk, "Ejected \(volume.name)")
                }
            }
            item.image = (NSWorkspace.shared.icon(forFile: volume.url.path).copy() as? NSImage).map { $0.size = NSSize(width: 16, height: 16); return $0 }
            menu.addItem(item)
        }
        popUp(menu)
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

    func backUpNow() {
        if slowStates[.backupNow]?.tone == .success { showBackupStatus(); return }
        runInBackground(.backupNow, { () -> Void in
            let destinations = try SystemToolsCommand.run("/usr/bin/tmutil", ["destinationinfo"])
            guard DiskTools.hasDestination(destinations) else {
                throw SystemToolError.invalidInput("Time Machine has no backup disk. Set one up in System Settings › General › Time Machine.")
            }
            try SystemToolsCommand.runChecked("/usr/bin/tmutil", ["startbackup"])
        }) { _ in
            self.succeed(.backupNow, "Time Machine backup started")
            self.refreshSlowStates()
        }
    }

    func showBackupStatus() {
        runInBackground(.backupStatus, { () -> [String] in
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
            self.info(.backupStatus, title: "Time Machine", lines: lines, extra: ("Time Machine Settings…", { self.openPane(.backupStatus, .timeMachine) }))
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

    // MARK: - Files

    func findDuplicates() {
        let menu = NSMenu()
        for (title, bytes) in [("Files over 100 KB…", Int64(100_000)), ("Files over 1 MB…", 1_000_000), ("Files over 10 MB…", 10_000_000)] {
            menu.addItem(SystemToolMenuItem(title: title) { self.scanDuplicates(minimum: bytes) })
        }
        popUp(menu)
    }

    private func scanDuplicates(minimum: Int64) {
        guard let folder = pickFolder(message: "Choose a folder to search for identical files. ~/Library, hidden items and package contents are skipped.") else { return }
        toast = "Looking for duplicates in \(folder.lastPathComponent)…"
        runInBackground(.duplicates, { () -> (items: [CleanupCandidate], preselected: Set<String>, groups: Int, wasted: Int64) in
            let groups = FileTools.duplicateGroups(FileTools.sizedFiles(in: folder, minimumBytes: minimum)) { try FileTools.sha256Hex(fileAt: $0) }
            let rows = FileTools.duplicateCandidates(groups)
            return (rows.items, rows.preselected, groups.count, groups.reduce(0) { $0 + FileTools.wasted($1) })
        }) { result in
            guard !result.items.isEmpty else { self.succeed(.duplicates, "No duplicates over \(SystemStatus.size(minimum)) in \(folder.lastPathComponent)"); return }
            self.cleanupReview = CleanupReview(tool: .duplicates, title: "\(result.groups) Sets of Duplicates in \(folder.lastPathComponent)",
                                               detail: "Same size and SHA-256. In each set the oldest copy is unchecked and stays; checked copies (\(SystemStatus.size(result.wasted))) move to the Trash.",
                                               candidates: result.items, selected: result.preselected)
        }
    }

    func scanFolderSizes() {
        guard let folder = pickFolder(message: "Choose a folder; AOM adds up what each item in it takes on disk.") else { return }
        toast = "Measuring \(folder.lastPathComponent)…"
        runInBackground(.folderSizes, { FileTools.folderSizes(in: folder) }) { sizes in
            guard !sizes.isEmpty else { self.succeed(.folderSizes, "\(folder.lastPathComponent) is empty or unreadable"); return }
            let total = sizes.reduce(0) { $0 + $1.size }
            let items = sizes.prefix(200).map {
                CleanupCandidate(url: folder.appendingPathComponent($0.name), size: $0.size,
                                 note: "\($0.files) file\($0.files == 1 ? "" : "s") · \(total > 0 ? Int((Double($0.size) / Double(total) * 100).rounded()) : 0)% of the folder")
            }
            self.lastResult = ToolResult(tool: .folderSizes, message: "\(folder.lastPathComponent): \(SystemStatus.size(total))", succeeded: true, date: Date())
            self.cleanupReview = CleanupReview(tool: .folderSizes, title: "\(folder.lastPathComponent) · \(SystemStatus.size(total))",
                                               detail: "Biggest first, measured as allocated space (packages included). Use Show in Finder to look inside; nothing is changed here.",
                                               candidates: Array(items), selected: [], allowsTrash: false)
        }
    }

    // MARK: - Network

    func showWiFiDetails() {
        guard let details = NetworkTools.wifiDetails() else { fail(.wifiDetails, "No Wi-Fi", "This Mac has no Wi-Fi interface."); return }
        info(.wifiDetails, title: "Wi-Fi", lines: details.lines, extra: ("Wi-Fi Settings…", { self.openPane(.wifiDetails, .wifi) }))
    }

    func fetchPublicIP() {
        guard !running.contains(.publicIP) else { return }
        running.insert(.publicIP)
        Task {
            defer { running.remove(.publicIP) }
            do { let address = try await NetworkTools.publicIP(); copy(.publicIP, address, message: "Public IP \(address) copied") }
            catch { fail(.publicIP, "Public IP Not Found", error.localizedDescription) }
        }
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

    func showDNSServers() {
        runInBackground(.dnsServers, { try SystemToolsCommand.runChecked("/usr/sbin/scutil", ["--dns"]).stdout }) { text in
            let servers = NetworkTools.parseDNSServers(text)
            guard !servers.isEmpty else { self.fail(.dnsServers, "No DNS Servers", "macOS reported no DNS servers; the Mac may be offline."); return }
            self.copy(.dnsServers, servers.joined(separator: "\n"), message: "DNS: \(servers.prefix(3).joined(separator: ", ")) (copied)")
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

    func showListeningPorts() {
        runInBackground(.listeningPorts, { try NetworkTools.listeningUsers() }) { users in
            guard !users.isEmpty else { self.succeed(.listeningPorts, "Nothing you can see is listening"); return }
            self.processReview = ProcessReview(tool: .listeningPorts, title: "Listening Ports", rows: users.map {
                .init(id: $0.id, pid: $0.pid, command: $0.command, detail: "PID \($0.pid) · \($0.proto) \($0.name)")
            })
        }
    }

    // MARK: - System Info

    func showAboutMac() {
        runInBackground(.aboutMac, { SystemInfo.overview() }) { overview in
            self.info(.aboutMac, title: "This Mac", lines: overview.lines, extra: ("About Settings…", { self.openPane(.aboutMac, .about) }))
        }
    }

    func showBootReasons() {
        var lines: [String] = []
        if let seconds = SystemStatus.secondsSinceBoot() {
            let since = Date().addingTimeInterval(-seconds).formatted(date: .abbreviated, time: .shortened)
            lines.append("Up \(SystemStatus.uptimeText(seconds)), since \(since)")
        }
        for (label, key) in [("Last shutdown", "kern.shutdownreason"), ("Last wake", "kern.wakereason")] {
            guard let raw = SystemInfo.sysctlString(key) else { lines.append("\(label): not recorded on this Mac"); continue }
            lines.append("\(label): " + (SystemInfo.explainReason(raw).map { "\($0) (\(raw))" } ?? raw))
        }
        info(.bootReasons, title: "Restart & Wake", lines: lines)
    }

    func settingsPaneMenu() {
        let menu = NSMenu()
        for (index, section) in SystemInfo.Pane.menuSections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for pane in section { menu.addItem(SystemToolMenuItem(title: pane.title) { self.openPane(.settingsPane, pane) }) }
        }
        popUp(menu)
    }
}
