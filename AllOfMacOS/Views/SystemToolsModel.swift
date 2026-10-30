import AppKit
import CoreWLAN
import IOBluetooth
import UniformTypeIdentifiers

/// A tile's live state, shown as a small pill.
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

    /// A cleanup scan waiting for the user's review.
    struct CleanupReview: Identifiable {
        let id = UUID()
        let tool: SystemToolID
        let title: String
        let detail: String
        let candidates: [CleanupCandidate]
        var selected: Set<String>
    }

    /// Processes that hold a port or a file, with Quit.
    struct ProcessReview: Identifiable {
        let id = UUID()
        let tool: SystemToolID
        let title: String
        var rows: [Row]
        struct Row: Identifiable, Hashable { let id: String; let pid: pid_t; let command: String; let detail: String }
    }

    static let favoritesKey = "AOMSystemToolsFavorites"
    static let recentKey = "AOMSystemToolsRecent"
    nonisolated static let recentLimit = 6

    @Published private(set) var states: [SystemToolID: SystemToolState] = [:]
    @Published private(set) var running: Set<SystemToolID> = []
    @Published private(set) var favorites: [SystemToolID]
    @Published private(set) var recent: [SystemToolID]
    @Published private(set) var lastResult: ToolResult?
    @Published var toast: String?
    @Published var cleanupReview: CleanupReview?
    @Published var processReview: ProcessReview?

    private let service = MacMagicSystemToolService.shared
    private let preferences: SystemPreferenceStore = CFPreferenceStore()
    private let defaults: UserDefaults
    private var refreshTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = (defaults.stringArray(forKey: Self.favoritesKey) ?? []).compactMap(SystemToolID.init(rawValue:))
        recent = (defaults.stringArray(forKey: Self.recentKey) ?? []).compactMap(SystemToolID.init(rawValue:))
    }

    // MARK: - Lifecycle

    func appear() {
        refreshStates()
        guard refreshTimer == nil else { return }
        // Other apps and System Settings change these too; a slow poll keeps
        // the pills honest without observers on every domain.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStates() }
        }
    }

    func disappear() {
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
        var next: [SystemToolID: SystemToolState] = [:]
        let style = preferences.value("AppleInterfaceStyle", domain: CFPreferenceStore.globalDomain) as? String
        next[.darkMode] = SystemToolState(style?.caseInsensitiveCompare("Dark") == .orderedSame)
        let awake = KeepAwakeService.shared
        next[.keepAwake] = awake.isActive ? .on(awake.endsAt.map { "Until " + $0.formatted(date: .omitted, time: .shortened) } ?? "On") : .off()
        let finder = UserDefaults(suiteName: SystemTweak.finder)
        next[.hidden] = SystemToolState(MacMagicSystemToolService.finderFlag("AppleShowAllFiles", in: finder, default: false))
        next[.desktop] = SystemToolState(MacMagicSystemToolService.finderFlag("CreateDesktop", in: finder, default: true))
        next[.dockAutoHide] = SystemToolState(SystemTweak.bool(preferences.value("autohide", domain: SystemTweak.dock)) ?? false)
        if let wifi = CWWiFiClient.shared().interface() { next[.wifi] = SystemToolState(wifi.powerOn()) } else { next[.wifi] = .value("None") }
        next[.muteSound] = AudioOutputService.isOutputMuted() ? .on("Muted") : .off()
        next[.muteMic] = AudioOutputService.isInputMuted() ? .on("Muted") : .off()
        next[.keyboardClean] = KeyboardCleaningLock.shared.isActive ? .on("Locked") : .off()
        let tweaks: [(SystemToolID, SystemTweak)] = [(.extensions, .showAllExtensions), (.pathbar, .pathBar), (.statusbar, .statusBar),
                                                     (.posixtitle, .fullPathInTitle), (.dockactive, .dockActiveAppsOnly),
                                                     (.dockdelay, .dockInstantAutoHide), (.dockrecents, .dockRecentApps),
                                                     (.shotshadow, .screenshotShadows)]
        for (id, tweak) in tweaks { next[id] = SystemToolState(tweak.isOn(in: preferences) ?? false) }
        next[.shotformat] = .value((SystemTweak.screenshotFormat.currentString(in: preferences) ?? "png").uppercased())
        next[.shotfolder] = .value(URL(fileURLWithPath: SystemTweak.screenshotFolder.currentString(in: preferences) ?? "~/Desktop").lastPathComponent)
        if next != states { states = next }
    }

    /// System changes land a moment after the command returns (Finder
    /// relaunching, System Events applying the appearance).
    private func refreshSoon() {
        refreshStates()
        for delay in [0.6, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refreshStates() }
        }
    }

    // MARK: - Reporting

    private func succeed(_ id: SystemToolID, _ message: String) {
        lastResult = ToolResult(tool: id, message: message, succeeded: true, date: Date())
        toast = message
        refreshSoon()
    }

    /// Failures that need reading stay on screen until dismissed.
    private func fail(_ id: SystemToolID, _ title: String, _ message: String) {
        lastResult = ToolResult(tool: id, message: "\(title): \(message)", succeeded: false, date: Date())
        refreshSoon()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func fail(_ id: SystemToolID, _ error: Error) {
        fail(id, "\(SystemToolCatalog.info(id).title.replacingOccurrences(of: "…", with: "")) Didn't Finish", error.localizedDescription)
    }

    /// Long jobs run off the main thread, show a spinner on their tile and
    /// can't be started twice.
    private func runInBackground<T>(_ id: SystemToolID, _ work: @escaping () throws -> T,
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
    private func runAction(_ id: SystemToolID, _ type: ActionType, configure: (inout ActionParameters) -> Void = { _ in },
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
                      failure: "macOS refused the change. Allow All of MacOS to control System Events in System Settings › Privacy & Security › Automation.")
        case .keepAwake: keepAwakeMenu()
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
        case .dockAutoHide:
            let wasOn = states[.dockAutoHide] == .on()
            runAction(id, .toggleDockAutoHide, success: wasOn ? "Dock always shown" : "Dock hides automatically",
                      failure: "Allow All of MacOS to control System Events in System Settings › Privacy & Security › Automation.")
        case .wifi:
            let wasOn = states[.wifi] == .on()
            runAction(id, .setWiFiPower, success: wasOn ? "Wi-Fi off" : "Wi-Fi on", failure: "macOS didn't change the Wi-Fi power.")
        case .muteSound:
            let wasMuted = AudioOutputService.isOutputMuted()
            runAction(id, .muteVolume, success: wasMuted ? "Sound on" : "Sound muted", failure: "The current output has no mute or volume control.")
        case .muteMic:
            let wasMuted = AudioOutputService.isInputMuted()
            runAction(id, .toggleMuteMicrophone, success: wasMuted ? "Microphone on" : "Microphone muted",
                      failure: "The default microphone has no software mute switch.")
        case .bluetooth: bluetoothMenu()
        case .focus:
            runAction(id, .toggleDoNotDisturb, success: "Focus shortcut ran",
                      failure: "Create a shortcut named “Toggle Focus” in the Shortcuts app with one Set Focus action, then try again.")
        case .keyboardClean: lockKeyboard()
        // Power & Session
        case .lockScreen: runAction(id, .lockScreen, success: nil, failure: "The screen could not be locked.")
        case .sleep: runAction(id, .sleepComputer, success: nil, failure: "pmset could not put the Mac to sleep.")
        case .sleepDisplays: runAction(id, .sleepDisplay, success: nil, failure: "pmset could not turn the displays off.")
        case .screenSaver: runAction(id, .startScreenSaver, success: nil, failure: "The screen saver could not be started.")
        case .restart: session(id, .restart, title: "Restart the Mac?", button: "Restart")
        case .shutDown: session(id, .shutDown, title: "Shut down the Mac?", button: "Shut Down")
        case .logOut:
            // The action asks first itself (destructive actions confirm).
            runAction(id, .logOut, success: nil, failure: "The log-out was cancelled or refused.")
        case .quitAll: quitAllApps()
        case .hideOthers: runAction(id, .hideOtherApps, success: "Other apps hidden", failure: "Other apps could not be hidden.")
        case .ejectAll: runAction(id, .ejectAllDisks, success: "Disks ejected (or none to eject)", failure: "A disk could not be ejected; a file on it may be open.")
        // Finder & Dock
        case .finder: Task { await service.restartFinder(); succeed(id, "Finder restarted") }
        case .extensions: toggleTweak(id, .showAllExtensions, on: "File extensions shown", off: "File extensions as Finder decides")
        case .pathbar: toggleTweak(id, .pathBar, on: "Path bar shown", off: "Path bar hidden")
        case .statusbar: toggleTweak(id, .statusBar, on: "Status bar shown", off: "Status bar hidden")
        case .posixtitle: toggleTweak(id, .fullPathInTitle, on: "Full path in Finder titles", off: "Folder names in Finder titles")
        case .dockactive: toggleTweak(id, .dockActiveAppsOnly, on: "Dock shows only open apps", off: "Dock shows kept apps")
        case .dockdelay: toggleTweak(id, .dockInstantAutoHide, on: "Hidden Dock appears instantly", off: "Dock delay back to default")
        case .dockrecents: toggleTweak(id, .dockRecentApps, on: "Recent apps in the Dock", off: "No recent apps in the Dock")
        case .restartDock:
            runInBackground(id, { try SystemToolsCommand.restartProcesses(["Dock"]) }) { _ in self.succeed(id, "Dock restarted") }
        // Screenshots
        case .shotshadow: toggleTweak(id, .screenshotShadows, on: "Window screenshots keep their shadow", off: "Window screenshots without shadow")
        case .shotformat: screenshotFormatMenu()
        case .shotfolder: chooseScreenshotFolder()
        // Maintenance
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
        case .freeMemory:
            administrator(id, title: "Purge the Disk Cache?",
                          message: "`purge` empties the file cache macOS keeps in memory. Apps may feel slower for a moment while it refills; it doesn't free memory apps are using.",
                          button: "Purge…", commands: [.init(path: "/usr/sbin/purge", arguments: [])],
                          success: "Disk cache purged")
        // Cleanup
        case .cache: clearCaches()
        case .dsstore: eraseDSStore()
        case .trash: confirmEmptyTrash()
        case .uninstall: uninstallApp()
        case .largeFiles: largeFilesMenu()
        case .oldDownloads: oldDownloadsMenu()
        case .devJunk:
            let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
            runInBackground(id, { CleanupTools.developerJunk(library: library) }) { items in
                self.review(id, title: "Xcode Junk", detail: "Xcode rebuilds or downloads these again when needed. Archives are not listed.",
                            items: items, preselect: true, empty: "No Xcode build data or caches found")
            }
        // Files, PDF & Media
        case .pdfmerge: mergePDFs()
        case .pdfcompress: compressPDF()
        case .imageconvert: convertImage()
        case .videoconvert: convertVideo()
        case .qr: makeQR()
        case .rename: batchRename()
        case .lockFiles:
            setFlag(id, verbs: ("Lock", "Unlock"), done: ("Locked", "Unlocked")) { try self.service.setFileLocked(url: $0, locked: $1) }
        case .hideFiles:
            setFlag(id, verbs: ("Hide", "Show"), done: ("Hidden", "Shown")) { try self.service.setFileHidden(url: $0, hidden: $1) }
        case .whoLocks: whatIsUsingFile()
        case .fileHash: hashFile()
        // Text & Developer
        case .formatJSON:
            clipboardMenu(id, [("Pretty Print", DevTextTools.prettyJSON), ("Minify", DevTextTools.minifiedJSON)])
        case .base64:
            clipboardMenu(id, [("Encode", { DevTextTools.base64Encode($0) }), ("Decode", DevTextTools.base64Decode)])
        case .urlCode:
            clipboardMenu(id, [TextTransform.urlEncode, .urlDecode].map(transformItem))
        case .changeCase:
            clipboardMenu(id, [TextTransform.uppercase, .lowercase, .titleCase, .sentenceCase, .camelCase, .snakeCase, .kebabCase].map(transformItem))
        case .cleanText:
            clipboardMenu(id, [TextTransform.plainText, .trimWhitespace, .collapseSpaces, .removeLineBreaks, .sortLines, .reverseLines,
                               .removeDuplicateLines].map(transformItem))
        case .textStats:
            guard let text = clipboardText(id) else { return }
            let stats = DevTextTools.stats(text)
            lastResult = ToolResult(tool: id, message: stats.summary, succeeded: true, date: Date())
            toast = stats.summary
        case .uuid: copy(id, UUID().uuidString, message: "UUID copied")
        case .timestamp: unixTime()
        case .pickColor:
            ActionExecutor.executeActions([TriggerAction(actionType: .pickScreenColor, parameters: ActionType.pickScreenColor.defaultParameters)]) { ok in
                DispatchQueue.main.async {
                    // A cancelled sampler is not a failure worth an alert.
                    if ok { self.succeed(id, "Copied \(NSPasteboard.general.string(forType: .string) ?? "the colour")") }
                }
            }
        case .hashText:
            guard let text = clipboardText(id) else { return }
            copy(id, DevTextTools.sha256Hex(text), message: "SHA-256 of the clipboard text copied")
        // Network
        case .dns: flushDNS()
        case .speedTest:
            toast = "Testing the connection (about 20 s)…"
            runInBackground(id, { try NetworkTools.runSpeedTest() }) { self.succeed(id, $0.summary) }
        case .portLookup: portLookup()
        case .copyIP:
            guard let address = SystemStatus.preferredAddress(SystemStatus.ipv4Addresses()) else {
                fail(id, "No IP Address", "No network interface has an IPv4 address right now."); return
            }
            copy(id, address.address, message: "Copied \(address.address) (\(address.interface))")
        }
    }

    // MARK: - Toggles

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
            menu.addItem(SystemToolMenuItem(title: "Lock for \(seconds < 60 ? "\(seconds) Seconds" : "\(seconds / 60) Minute\(seconds == 60 ? "" : "s")")") {
                do {
                    try lock.start(seconds: seconds)
                    self.lastResult = ToolResult(tool: .keyboardClean, message: "Keyboard locked for \(seconds) s", succeeded: true, date: Date())
                    self.refreshStates()
                    // The pill flips back when the lock ends by itself.
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds) + .milliseconds(700)) { self.refreshStates() }
                } catch { self.fail(.keyboardClean, "Keyboard Not Locked", error.localizedDescription) }
            })
        }
        popUp(menu)
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where macOS saves screenshots."
        if let current = tweak.currentString(in: preferences) { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try tweak.setFolder(url, in: preferences); applyTweak(.shotfolder, tweak, message: "Screenshots save to \(url.lastPathComponent)") }
        catch { fail(.shotfolder, "Folder Not Changed", error.localizedDescription) }
    }

    // MARK: - Power & Session

    private func confirm(_ title: String, _ message: String, button: String, destructive: Bool = true) -> Bool {
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
        guard confirm(title, "Apps are asked to quit; any app with unsaved changes can still stop it. Needs Automation for System Events.",
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

    // MARK: - Maintenance

    private func administrator(_ id: SystemToolID, title: String, message: String, button: String,
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

    // MARK: - Cleanup

    private func review(_ id: SystemToolID, title: String, detail: String, items: [CleanupCandidate], preselect: Bool, empty: String) {
        guard !items.isEmpty else { succeed(id, empty); return }
        cleanupReview = CleanupReview(tool: id, title: title, detail: detail, candidates: items,
                                      selected: preselect ? Set(items.map(\.id)) : [])
    }

    /// Called by the review sheet's Move to Trash button.
    func trashSelected(_ review: CleanupReview) {
        let chosen = review.candidates.filter { review.selected.contains($0.id) }
        cleanupReview = nil
        guard !chosen.isEmpty else { return }
        runInBackground(review.tool, { CleanupTools.moveToTrash(chosen) }) { outcome in
            if outcome.failures.isEmpty { self.succeed(review.tool, outcome.summary) }
            else { self.fail(review.tool, "Some Items Stayed", outcome.summary) }
        }
    }

    private func uninstallApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Review"
        panel.message = "Choose an app. You'll see it with its leftovers before anything moves to the Trash."
        guard panel.runModal() == .OK, let app = panel.url else { return }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        runInBackground(.uninstall, { try CleanupTools.uninstallPlan(for: app, library: library) }) { plan in
            self.review(.uninstall, title: "Uninstall \(app.deletingPathExtension().lastPathComponent)",
                        detail: "The app and the files it left in ~/Library. Uncheck anything you want to keep; everything goes to the Trash, so Put Back works.",
                        items: plan, preselect: true, empty: "Nothing to remove")
        }
    }

    private func largeFilesMenu() {
        let menu = NSMenu()
        for (title, bytes) in [("Over 100 MB…", Int64(100_000_000)), ("Over 500 MB…", 500_000_000), ("Over 1 GB…", 1_000_000_000), ("Over 5 GB…", 5_000_000_000)] {
            menu.addItem(SystemToolMenuItem(title: title) { self.scanLargeFiles(minimum: bytes) })
        }
        popUp(menu)
    }

    private func scanLargeFiles(minimum: Int64) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan. ~/Library and hidden items are skipped."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        toast = "Scanning \(folder.lastPathComponent)…"
        runInBackground(.largeFiles, { CleanupTools.largeFiles(in: folder, minimumBytes: minimum) }) { items in
            self.review(.largeFiles, title: "Files over \(SystemStatus.size(minimum)) in \(folder.lastPathComponent)",
                        detail: "Largest first. Check the files you no longer need; they go to the Trash.",
                        items: items, preselect: false, empty: "No files over \(SystemStatus.size(minimum)) in \(folder.lastPathComponent)")
        }
    }

    private func oldDownloadsMenu() {
        let menu = NSMenu()
        for days in [30, 90, 180, 365] {
            menu.addItem(SystemToolMenuItem(title: "Untouched for \(days) Days…") { self.scanDownloads(days: days) })
        }
        popUp(menu)
    }

    private func scanDownloads(days: Int) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        runInBackground(.oldDownloads, { CleanupTools.oldDownloads(in: downloads, days: days) }) { items in
            self.review(.oldDownloads, title: "Downloads untouched for \(days) days",
                        detail: "Not added, changed or opened for \(days) days. Check what can go; it moves to the Trash.",
                        items: items, preselect: false, empty: "Nothing in Downloads is older than \(days) days")
        }
    }

    private func clearCaches() {
        guard confirm("Clear Caches?", "Everything in ~/Library/Caches except All of MacOS's own cache is deleted permanently. Apps rebuild their caches, so some may start slower once.",
                      button: "Clear Caches") else { return }
        runInBackground(.cache, { try MacMagicSystemToolService.shared.clearDiskCache() }) { freed in
            self.succeed(.cache, "Freed \(SystemStatus.size(freed))")
        }
    }

    private func eraseDSStore() {
        guard let folder = pickFolder(message: "Choose a folder; .DS_Store files inside it and its subfolders are deleted.") else { return }
        Task {
            do { let count = try await service.eraseDSStoreFiles(in: folder); succeed(.dsstore, "\(count) .DS_Store removed") }
            catch { fail(.dsstore, error) }
        }
    }

    private func confirmEmptyTrash() {
        guard confirm("Empty Trash?", "Items in your Trash will be permanently deleted.", button: "Empty Trash") else { return }
        Task {
            do {
                let result = try await service.forceEmptyTrash()
                if result.succeeded { succeed(.trash, result.summary) } else { fail(.trash, "Trash Not Fully Emptied", result.summary) }
            } catch { fail(.trash, "Trash Not Emptied", error.localizedDescription) }
        }
    }

    // MARK: - Files, PDF & Media

    private func mergePDFs() {
        guard let urls = pickFiles(types: [UTType.pdf], multiple: true, message: "Choose two or more PDFs; they're merged in name order."),
              urls.count >= 2 else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "Merged.pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try service.combinePDFs(urls: urls, to: destination); succeed(.pdfmerge, "Merged \(urls.count) PDFs") }
        catch { fail(.pdfmerge, error) }
    }

    private func compressPDF() {
        guard let url = pickFiles(types: [UTType.pdf], multiple: false)?.first else { return }
        let destination = url.deletingPathExtension().appendingPathExtension("compressed.pdf")
        runInBackground(.pdfcompress, { try MacMagicSystemToolService.shared.compressPDF(url: url, to: destination) }) { _ in
            let original = CleanupTools.allocatedSize(url), compressed = CleanupTools.allocatedSize(destination)
            self.succeed(.pdfcompress, "Compressed: \(SystemStatus.size(original)) → \(SystemStatus.size(compressed))")
        }
    }

    private func convertImage() {
        guard let url = pickFiles(types: [UTType.image], multiple: false)?.first else { return }
        let menu = NSMenu()
        for format in MacMagicSystemToolService.ImageFormat.allCases {
            menu.addItem(SystemToolMenuItem(title: "→ \(format.rawValue.uppercased())") {
                do { let output = try self.service.convertImage(url: url, to: format); self.succeed(.imageconvert, "Saved \(output.lastPathComponent)") }
                catch { self.fail(.imageconvert, error) }
            })
        }
        popUp(menu)
    }

    private func convertVideo() {
        guard let url = pickFiles(types: [UTType.movie, UTType.mpeg4Movie], multiple: false)?.first else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-converted.mp4"
        guard panel.runModal() == .OK, let destination = panel.url,
              destination.standardizedFileURL != url.standardizedFileURL else { return }
        guard !running.contains(.videoconvert) else { return }
        running.insert(.videoconvert)
        Task {
            defer { running.remove(.videoconvert) }
            do { try await service.convertVideo(url: url, to: destination); succeed(.videoconvert, "Video converted") }
            catch { fail(.videoconvert, error) }
        }
    }

    private func makeQR() {
        guard let text = promptText("QR Code", "Text or link to encode:", placeholder: "https://…"), !text.isEmpty else { return }
        guard let image = service.generateQRCode(text: text) else { fail(.qr, "QR Code Not Made", "The text is too long for a QR code."); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = "QR.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fail(.qr, "QR Code Not Saved", "The image could not be encoded as PNG."); return
        }
        do { try png.write(to: url); succeed(.qr, "QR saved") } catch { fail(.qr, error) }
    }

    private func batchRename() {
        guard let urls = pickFiles(types: [.item], multiple: true, message: "Choose the files to rename."), !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(urls.count) File\(urls.count == 1 ? "" : "s")"
        alert.informativeText = "Replaces text in each name (extensions stay). {n} in the replacement becomes 1, 2, 3…"
        let find = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        find.placeholderString = "Find"
        let replace = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        replace.placeholderString = "Replace with"
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        stack.addSubview(find); stack.addSubview(replace)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = find
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !find.stringValue.isEmpty || replace.stringValue.contains("{n}") else {
            fail(.rename, "Nothing to Rename", "Type the text to find, or use {n} in the replacement."); return
        }
        do {
            let renamed = try service.batchRename(urls: urls, pattern: find.stringValue, replacement: replace.stringValue)
            succeed(.rename, "Renamed \(renamed.count) file\(renamed.count == 1 ? "" : "s")")
        } catch { fail(.rename, "Files Not Renamed", "No file was renamed: \(error.localizedDescription)") }
    }

    private func setFlag(_ id: SystemToolID, verbs: (on: String, off: String), done: (on: String, off: String),
                         apply: @escaping (URL, Bool) throws -> Void) {
        guard let urls = pickFiles(types: [.item], multiple: true, directories: true), !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "\(verbs.on) or \(verbs.off) \(urls.count) Item\(urls.count == 1 ? "" : "s")?"
        alert.addButton(withTitle: verbs.on)
        alert.addButton(withTitle: verbs.off)
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        let enable = answer == .alertFirstButtonReturn
        var failures: [String] = []
        for url in urls {
            do { try apply(url, enable) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        let changed = urls.count - failures.count
        if failures.isEmpty { succeed(id, "\(enable ? done.on : done.off) \(changed) item\(changed == 1 ? "" : "s")") }
        else { fail(id, "Not Every Item Changed", "\(changed) changed. " + failures.prefix(3).joined(separator: "; ")) }
    }

    private func whatIsUsingFile() {
        guard let url = pickFiles(types: [.item], multiple: false, directories: true,
                                  message: "Choose a file, folder or disk to see which processes have it open.")?.first else { return }
        Task {
            guard !running.contains(.whoLocks) else { return }
            running.insert(.whoLocks)
            defer { running.remove(.whoLocks) }
            do {
                let users = try await service.findProcessesLockingFile(at: url)
                if users.isEmpty { succeed(.whoLocks, "Nothing has \(url.lastPathComponent) open"); return }
                processReview = ProcessReview(tool: .whoLocks, title: "Using \(url.lastPathComponent)", rows: users.map {
                    .init(id: $0.id, pid: $0.pid, command: $0.command, detail: "PID \($0.pid) · \($0.user) · fd \($0.fileDescriptor)")
                })
            } catch { fail(.whoLocks, error) }
        }
    }

    private func hashFile() {
        guard let url = pickFiles(types: [.item], multiple: false)?.first else { return }
        let expected = DevTextTools.expectedHash(in: NSPasteboard.general.string(forType: .string))
        toast = "Hashing \(url.lastPathComponent)…"
        runInBackground(.fileHash, { try DevTextTools.sha256Hex(fileAt: url) }) { hash in
            if let expected {
                // Keep the hash the user pasted; just say whether it matches.
                if expected == hash { self.succeed(.fileHash, "SHA-256 matches the clipboard ✓") }
                else { self.fail(.fileHash, "SHA-256 Doesn't Match", "\(url.lastPathComponent) is \(hash), not the \(expected) on the clipboard.") }
            } else {
                self.copy(.fileHash, hash, message: "SHA-256 copied: \(hash.prefix(16))…")
            }
        }
    }

    // MARK: - Text & Developer

    private func transformItem(_ transform: TextTransform) -> (String, (String) throws -> String) {
        (transform.title, { transform.apply($0) })
    }

    private func clipboardText(_ id: SystemToolID) -> String? {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            fail(id, "No Text on the Clipboard", "Copy some text first, then run \(SystemToolCatalog.info(id).title) again.")
            return nil
        }
        return text
    }

    private func clipboardMenu(_ id: SystemToolID, _ items: [(String, (String) throws -> String)]) {
        let menu = NSMenu()
        for (title, transform) in items {
            menu.addItem(SystemToolMenuItem(title: title) {
                guard let text = self.clipboardText(id) else { return }
                do {
                    let result = try transform(text)
                    self.copy(id, result, message: "\(title): \(Self.preview(result))")
                } catch { self.fail(id, "Clipboard Not Changed", error.localizedDescription) }
            })
        }
        popUp(menu)
    }

    /// One line, at most 48 characters, for toasts and the last-result line.
    static func preview(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ⏎ ").trimmingCharacters(in: .whitespaces)
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    private func copy(_ id: SystemToolID, _ text: String, message: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            fail(id, "Clipboard Not Changed", "macOS didn't accept the new clipboard text."); return
        }
        succeed(id, message)
    }

    private func unixTime() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if let stamp = DevTextTools.timestamp(from: text) {
            let local = stamp.date.formatted(date: .abbreviated, time: .standard)
            copy(.timestamp, DevTextTools.iso8601(stamp.date), message: "\(text.trimmingCharacters(in: .whitespacesAndNewlines)) = \(local); ISO 8601 copied")
        } else {
            let now = DevTextTools.unixSeconds(Date())
            copy(.timestamp, now, message: "Current Unix time \(now) copied")
        }
    }

    // MARK: - Network

    /// Success only when every step exited 0; a standard user can't restart
    /// the DNS resolver, so the administrator prompt is offered (audit F09).
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

    private func portLookup() {
        guard let text = promptText("What's Using a Port", "Port number (1–65535):", placeholder: "8080") else { return }
        guard let port = NetworkTools.port(from: text) else {
            fail(.portLookup, "Not a Port", "“\(text)” isn't a port number from 1 to 65535."); return
        }
        runInBackground(.portLookup, { try NetworkTools.users(ofPort: port) }) { users in
            guard !users.isEmpty else { self.succeed(.portLookup, "Nothing you can see is using port \(port)"); return }
            self.processReview = ProcessReview(tool: .portLookup, title: "Port \(port)", rows: users.map {
                .init(id: $0.id, pid: $0.pid, command: $0.command,
                      detail: "PID \($0.pid) · \($0.proto) \($0.name)\($0.state.isEmpty ? "" : " · \($0.state)")")
            })
        }
    }

    /// Called by the process sheet's Quit button.
    func quitProcess(_ row: ProcessReview.Row) {
        let tool = processReview?.tool ?? .portLookup
        guard confirm("Quit \(row.command)?", "Process \(row.pid) is asked to quit. Unsaved work in it may be lost.", button: "Quit") else { return }
        do {
            try NetworkTools.quit(pid: row.pid)
            processReview?.rows.removeAll { $0.pid == row.pid }
            if processReview?.rows.isEmpty == true { processReview = nil }
            succeed(tool, "Asked \(row.command) to quit")
        } catch { fail(tool, "Not Quit", error.localizedDescription) }
    }

    // MARK: - Panels

    private func popUp(_ menu: NSMenu) {
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func promptText(_ title: String, _ message: String, placeholder: String) -> String? {
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

    private func pickFiles(types: [UTType], multiple: Bool, directories: Bool = false, message: String? = nil) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    private func pickFolder(message: String) -> URL? {
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
