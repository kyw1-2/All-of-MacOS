import AppKit
import CoreAudio

/// The default microphone as the mute helper sees it. The real one goes
/// through `AudioOutputService` (its mute switch, or volume 0 for inputs
/// without one); tests pass a fake.
protocol MicMuteHardware {
    func deviceID() -> AudioDeviceID?
    func deviceName() -> String?
    func isMuted() -> Bool
    /// Mute or unmute; true when the device now reads `muted`.
    func setMuted(_ muted: Bool) -> Bool
    func canMute() -> Bool
}

struct CoreAudioMicHardware: MicMuteHardware {
    func deviceID() -> AudioDeviceID? { AudioOutputService.defaultInputDeviceID() }

    func deviceName() -> String? {
        guard let id = deviceID() else { return nil }
        let name = AudioOutputService.string(id, kAudioObjectPropertyName)
        return name.isEmpty ? nil : name
    }

    func isMuted() -> Bool { AudioOutputService.isInputMuted() }

    func setMuted(_ muted: Bool) -> Bool {
        if AudioOutputService.isInputMuted() == muted { return true }
        guard let now = AudioOutputService.toggleInputMute() else { return false }
        return now == muted && AudioOutputService.isInputMuted() == muted
    }

    func canMute() -> Bool { AudioOutputService.canMuteInput() }
}

/// Shows what just happened to the microphone outside AOM's window.
@MainActor
protocol MicMuteHUDPresenting: AnyObject {
    func show(muted: Bool, title: String, detail: String?)
    func showFailure(title: String, detail: String)
}

/// SoundSource-style meeting helpers for the default microphone: the
/// toggle hotkey (a "cough button"), push-to-talk, a HUD on every change,
/// an optional menu bar indicator while muted, and auto-mute when chosen
/// apps open. Idle costs nothing: listeners and the key monitor exist only
/// while a setting that needs them is on.
@MainActor
final class MicMuteController: ObservableObject {
    static let shared = MicMuteController(hardware: CoreAudioMicHardware(), defaults: .standard, hud: nil, usesSystemHUD: true)

    enum Keys {
        static let showHUD = "AOMMicMuteShowHUD"
        static let menuBarIndicator = "AOMMicMuteMenuBarIndicator"
        static let pushToTalk = "AOMMicMutePushToTalk"
        static let pushToTalkKey = "AOMMicMutePushToTalkKey"
        static let autoMute = "AOMMicMuteAutoMute"
        static let autoMuteApps = "AOMMicMuteAutoMuteApps"
    }

    struct AutoMuteApp: Codable, Equatable, Hashable, Identifiable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    @Published private(set) var isMuted: Bool
    @Published private(set) var isTalking = false
    @Published private(set) var deviceName: String? = nil
    @Published private(set) var canMute: Bool
    @Published private(set) var lastFailure: String? = nil

    @Published var showsHUD: Bool { didSet { defaults.set(showsHUD, forKey: Keys.showHUD) } }
    @Published var showsMenuBarIndicator: Bool {
        didSet { defaults.set(showsMenuBarIndicator, forKey: Keys.menuBarIndicator); configure() }
    }
    @Published var pushToTalkEnabled: Bool {
        didSet { defaults.set(pushToTalkEnabled, forKey: Keys.pushToTalk); configure() }
    }
    @Published var pushToTalkKey: MicPushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey); configure() }
    }
    @Published var autoMuteEnabled: Bool {
        didSet { defaults.set(autoMuteEnabled, forKey: Keys.autoMute); configure() }
    }
    @Published private(set) var autoMuteApps: [AutoMuteApp]

    private let hardware: MicMuteHardware
    private let defaults: UserDefaults
    private let injectedHUD: MicMuteHUDPresenting?
    private let usesSystemHUD: Bool
    /// The HUD panel in the app; the injected one in tests; none otherwise.
    private var hud: MicMuteHUDPresenting? { injectedHUD ?? (usesSystemHUD ? MicMuteHUDPanel.shared : nil) }
    private var machine: MicMuteMachine
    private var tracker: PushToTalkTracker
    private var started = false

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var holdWatchdog: Timer?
    private var launchObserver: NSObjectProtocol?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var listenedDevice: AudioDeviceID?
    private var statusItem: NSStatusItem?

    init(hardware: MicMuteHardware, defaults: UserDefaults, hud: MicMuteHUDPresenting?, usesSystemHUD: Bool = false) {
        self.hardware = hardware
        self.defaults = defaults
        self.injectedHUD = hud
        self.usesSystemHUD = usesSystemHUD
        let muted = hardware.isMuted()
        machine = MicMuteMachine(muted: muted)
        isMuted = muted
        canMute = hardware.canMute()
        deviceName = hardware.deviceName()
        let key = defaults.string(forKey: Keys.pushToTalkKey).flatMap(MicPushToTalkKey.init(rawValue:)) ?? .rightOption
        tracker = PushToTalkTracker(key: key)
        pushToTalkKey = key
        showsHUD = defaults.object(forKey: Keys.showHUD) as? Bool ?? true
        showsMenuBarIndicator = defaults.bool(forKey: Keys.menuBarIndicator)
        pushToTalkEnabled = defaults.bool(forKey: Keys.pushToTalk)
        autoMuteEnabled = defaults.bool(forKey: Keys.autoMute)
        autoMuteApps = defaults.data(forKey: Keys.autoMuteApps).flatMap { try? JSONDecoder().decode([AutoMuteApp].self, from: $0) } ?? []
    }

    /// Called once at launch by `MicMuteModule.start()`.
    func start() {
        guard !started else { return }
        started = true
        refreshFromHardware()
        configure()
    }

    // MARK: - Actions

    /// The toggle hotkey, the status menu item and the Workspace quick action.
    func toggle() {
        reconcile()
        guard hardware.deviceID() != nil else {
            fail("No Microphone", "macOS has no default sound input right now.")
            return
        }
        perform(machine.toggle())
    }

    func setMuted(_ muted: Bool) {
        reconcile()
        perform(machine.set(muted: muted))
    }

    /// Re-reads the device (the Audio page, other apps and Control Center
    /// change it too) before AOM acts on what it believes.
    func refreshFromHardware() {
        reconcile()
        canMute = hardware.canMute()
        deviceName = hardware.deviceName()
        updateIndicator()
    }

    private func reconcile() {
        let effect = machine.observe(hardwareMuted: hardware.isMuted())
        if case .adopt(let muted) = effect {
            isMuted = muted
            isTalking = machine.talking
            updateIndicator()
        }
    }

    private func perform(_ effect: MicMuteMachine.Effect) {
        switch effect {
        case .none:
            break
        case .adopt(let muted):
            isMuted = muted
            isTalking = machine.talking
            updateIndicator()
        case .apply(let muted, let cause):
            guard hardware.setMuted(muted) else {
                let name = hardware.deviceName() ?? "The microphone"
                _ = machine.observe(hardwareMuted: hardware.isMuted())
                isMuted = machine.muted
                isTalking = machine.talking
                updateIndicator()
                fail(muted ? "Microphone Not Muted" : "Microphone Still Muted",
                     "\(name) has no mute switch or input volume AOM can change.")
                return
            }
            lastFailure = nil
            isMuted = muted
            isTalking = machine.talking
            deviceName = hardware.deviceName()
            updateIndicator()
            announce(muted: muted, cause: cause)
        }
    }

    private func announce(muted: Bool, cause: MicMuteMachine.Cause) {
        guard showsHUD, let hud else { return }
        let device = deviceName
        let key = pushToTalkKey.shortTitle
        switch cause {
        case .toggle:
            hud.show(muted: muted, title: muted ? "Microphone Muted" : "Microphone On", detail: device)
        case .talkStarted:
            hud.show(muted: false, title: "Microphone On", detail: "Release \(key) to mute")
        case .talkEnded:
            hud.show(muted: true, title: "Microphone Muted", detail: "Hold \(key) to talk")
        case .autoMute(let app):
            hud.show(muted: true, title: "Microphone Muted", detail: "\(app) opened")
        case .deviceChanged:
            hud.show(muted: true, title: "Microphone Muted", detail: device.map { "\($0) is muted too" })
        }
    }

    private func fail(_ title: String, _ detail: String) {
        lastFailure = detail
        GestureLog.shared.logFromAnyThread("Microphone: \(detail)", level: .error)
        hud?.showFailure(title: title, detail: detail)
    }

    // MARK: - Push-to-talk

    /// One flagsChanged event (from either monitor).
    func handleFlagsChanged(keyCode: UInt16, flags: UInt) {
        guard let transition = tracker.handle(keyCode: keyCode, flags: flags) else { return }
        handle(transition)
    }

    private func handle(_ transition: PushToTalkTracker.Transition) {
        switch transition {
        case .pressed:
            // Pause AOM stops push-to-talk from opening the microphone; a
            // release is always honoured so the microphone never stays open.
            guard AutomationGate.isOn else { return }
            reconcile()
            perform(machine.keyDown())
            if machine.talking { startHoldWatchdog() }
        case .released:
            stopHoldWatchdog()
            perform(machine.keyUp())
        }
    }

    private func startHoldWatchdog() {
        guard holdWatchdog == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let transition = self.tracker.poll(flags: NSEvent.modifierFlags) { self.handle(transition) }
            }
        }
        // A missed release is a backstop, not the normal path (the
        // flagsChanged monitors are), so it may fire up to 50 ms late.
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        holdWatchdog = timer
    }

    private func stopHoldWatchdog() {
        holdWatchdog?.invalidate()
        holdWatchdog = nil
    }

    // MARK: - Auto-mute

    func addAutoMuteApp(url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return false }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        guard !autoMuteApps.contains(where: { $0.bundleID == id }) else { return true }
        autoMuteApps.append(AutoMuteApp(bundleID: id, name: name))
        saveAutoMuteApps()
        return true
    }

    func removeAutoMuteApp(_ app: AutoMuteApp) {
        autoMuteApps.removeAll { $0.bundleID == app.bundleID }
        saveAutoMuteApps()
    }

    private func saveAutoMuteApps() {
        if let data = try? JSONEncoder().encode(autoMuteApps) { defaults.set(data, forKey: Keys.autoMuteApps) }
        configure()
    }

    func appLaunched(bundleID: String?, name: String?) {
        guard autoMuteEnabled, AutomationGate.isOn, let bundleID,
              let app = autoMuteApps.first(where: { $0.bundleID == bundleID }) else { return }
        reconcile()
        perform(machine.autoMute(app: name ?? app.name))
    }

    // MARK: - Listeners and monitors (only while needed)

    /// Installs exactly what the current settings need and removes the rest.
    func configure() {
        guard started else { return }
        if tracker.key != pushToTalkKey {
            if let release = tracker.reset() { handle(release) }
            tracker = PushToTalkTracker(key: pushToTalkKey)
        }
        if pushToTalkEnabled { installKeyMonitors() } else { removeKeyMonitors() }
        if autoMuteEnabled && !autoMuteApps.isEmpty { installLaunchObserver() } else { removeLaunchObserver() }
        if showsMenuBarIndicator || pushToTalkEnabled || autoMuteEnabled { installAudioListeners() } else { removeAudioListeners() }
        updateIndicator()
    }

    private func installKeyMonitors() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let code = event.keyCode, flags = event.modifierFlags.rawValue
            MainActor.assumeIsolated { self?.handleFlagsChanged(keyCode: code, flags: flags) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let code = event.keyCode, flags = event.modifierFlags.rawValue
            MainActor.assumeIsolated { self?.handleFlagsChanged(keyCode: code, flags: flags) }
            return event
        }
    }

    private func removeKeyMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if let release = tracker.reset() { handle(release) }
        stopHoldWatchdog()
    }

    private func installLaunchObserver() {
        guard launchObserver == nil else { return }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier, name = app?.localizedName
            MainActor.assumeIsolated { self?.appLaunched(bundleID: id, name: name) }
        }
    }

    private func removeLaunchObserver() {
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
    }

    private func installAudioListeners() {
        if systemListener == nil {
            var address = AudioOutputService.address(kAudioHardwarePropertyDefaultInputDevice)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.defaultInputChanged() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
                systemListener = block
            }
        }
        listenToDevice(hardware.deviceID())
    }

    private func removeAudioListeners() {
        if let systemListener {
            var address = AudioOutputService.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, systemListener)
        }
        systemListener = nil
        listenToDevice(nil)
    }

    /// Mute and volume of the default input, on every element that has them.
    private func listenToDevice(_ device: AudioDeviceID?) {
        guard device != listenedDevice else { return }
        for (id, address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
        listenedDevice = device
        guard let device else { return }
        for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
            for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
                guard AudioObjectHasProperty(device, &address) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.hardwareChanged() }
                }
                if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
                    deviceListeners.append((device, address, block))
                }
            }
        }
    }

    private func hardwareChanged() {
        perform(machine.observe(hardwareMuted: hardware.isMuted()))
    }

    private func defaultInputChanged() {
        let device = hardware.deviceID()
        listenToDevice(device)
        deviceName = hardware.deviceName()
        canMute = hardware.canMute()
        guard device != nil else { updateIndicator(); return }
        perform(machine.deviceChanged(newDeviceMuted: hardware.isMuted()))
    }

    // MARK: - Menu bar indicator

    private func updateIndicator() {
        let shouldShow = started && showsMenuBarIndicator && isMuted && hardware.deviceID() != nil
        if shouldShow {
            if statusItem == nil { statusItem = makeStatusItem() }
            statusItem?.button?.toolTip = "Microphone muted" + (deviceName.map { " (\($0))" } ?? "")
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("Microphone muted")
        let menu = NSMenu()
        let header = NSMenuItem(title: "Microphone Muted", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(MicMuteMenuItem(title: "Unmute Microphone", symbol: "mic.fill") { MicMuteController.shared.setMuted(false) })
        menu.addItem(.separator())
        menu.addItem(MicMuteMenuItem(title: "Microphone Settings…", symbol: "gearshape") { MicMuteController.openSettings() })
        item.menu = menu
        return item
    }

    /// The Audio page, where `MicMuteSection` lives.
    static func openSettings() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.appState?.selectedMainTab = .audio
        delegate.showMainWindow()
    }

    // MARK: - Status menu

    /// "Mute Microphone", checked while muted (HIG Menus: a checkmark shows
    /// a toggled item's state). Built fresh for each click.
    func statusMenuItem() -> NSMenuItem {
        refreshFromHardware()
        let item = MicMuteMenuItem(title: "Mute Microphone", symbol: "mic.slash") { MicMuteController.shared.toggle() }
        item.state = isMuted ? .on : .off
        if hardware.deviceID() == nil {
            item.isEnabled = false
            item.toolTip = "No microphone is connected"
        } else {
            item.toolTip = (isMuted ? "Unmutes " : "Mutes ") + (deviceName ?? "the microphone")
        }
        return item
    }
}

/// A menu item that runs a closure (the status item and status menu).
@MainActor
final class MicMuteMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String?, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("MicMuteMenuItem is created in code only") }

    @objc private func run() { handler() }
}
