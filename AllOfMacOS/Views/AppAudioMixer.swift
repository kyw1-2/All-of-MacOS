import AppKit
import CoreAudio
import SwiftUI

/// Per-app audio mixer (SoundSource-lite): a floating panel listing every app
/// producing audio, with gain and mute per app. Backed by AppAudioEngine's
/// process taps on macOS 14.2+; older systems see an explanatory empty state.
@MainActor
final class AppAudioMixerService: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppAudioMixerService()

    @Published private(set) var apps: [AppAudioState] = []
    @Published private(set) var airPlayBypassed = false
    @Published private(set) var airPlayProcessingActive = false
    @Published private(set) var airPlayPreparing = false
    @Published var airPlayProcessingEnabled: Bool {
        didSet {
            guard airPlayProcessingEnabled != oldValue else { return }
            if #available(macOS 14.2, *) {
                AppAudioEngine.shared.setAirPlayProcessingEnabled(airPlayProcessingEnabled)
            }
            refresh()
        }
    }
    @Published var stableAirPlayDynamics: Bool {
        didSet {
            guard stableAirPlayDynamics != oldValue else { return }
            UserDefaults.standard.set(stableAirPlayDynamics, forKey: AppAudioRenderBus.stableDynamicsKey)
            SharedOutputRenderer.shared.setAirPlayStableDynamics(stableAirPlayDynamics)
            refresh()
        }
    }
    let meters = AppAudioMeters()
    private var meterClients = 0
    private var reloadScheduled = false
    @Published var soundEnabled: Bool {
        didSet {
            guard soundEnabled != oldValue else { return }
            if #available(macOS 14.2, *) {
                AppAudioEngine.shared.isEnabled = soundEnabled
            }
            refresh()
        }
    }
    @Published var allAppsBoostEnabled: Bool {
        didSet {
            guard allAppsBoostEnabled != oldValue else { return }
            UserDefaults.standard.set(allAppsBoostEnabled, forKey: "AOMAudioMasterBoostEnabled")
            applyEQ()
        }
    }
    /// Favourites stay at the top of the list in the order they were added
    /// (SoundSource), even while silent.
    @Published private(set) var favorites: [String] = UserDefaults.standard.stringArray(forKey: "AOMAudioFavorites") ?? []
    /// Also list running apps that have not played audio recently.
    @Published var showAllApps: Bool = UserDefaults.standard.bool(forKey: "AOMAudioShowAllApps") {
        didSet { UserDefaults.standard.set(showAllApps, forKey: "AOMAudioShowAllApps") }
    }
    @Published private(set) var airPlayRecovering = false
    /// Apps that played within the last minute stay listed (SoundSource).
    private var lastActive: [String: Date] = [:]
    private var timedMutes: [String: DispatchWorkItem] = [:]
    @Published private(set) var timedMuteEnds: [String: Date] = [:]
    @Published var eqGains: [Float] = AudioEQ.presets["Flat"]!
    @Published var eqEnabled: Bool {
        didSet {
            UserDefaults.standard.set(eqEnabled, forKey: "AOMAudioEQEnabled")
            applyEQ()
        }
    }
    @Published var eqPreset: String = "Flat" {
        didSet {
            if let gains = AudioEQ.presets[eqPreset] { eqGains = gains }
            UserDefaults.standard.set(eqPreset, forKey: "AOMAudioEQPreset")
            UserDefaults.standard.set(eqGains.map(Double.init), forKey: "AOMAudioEQGains")
            applyEQ()
        }
    }
    @Published private(set) var isShowing = false
    private var panel: NSPanel?
    private var monitor: Any?
    private var refreshTimer: Timer?
    private var audioObserver: NSObjectProtocol?
    @Published private(set) var lastError: String?
    @Published private(set) var competingMixer: NSRunningApplication?
    private var muteSnapshot: [String: Bool]?

    var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private override init() {
        _soundEnabled = Published(initialValue: {
            if #available(macOS 14.2, *) {
                return AppAudioEngine.shared.isEnabled
            }
            return true
        }())
        _airPlayProcessingEnabled = Published(initialValue:
            UserDefaults.standard.object(forKey: "AOMAudioAirPlayProcessingEnabled") as? Bool ?? true)
        _stableAirPlayDynamics = Published(initialValue: AppAudioRenderBus.stableDynamicsEnabled())
        _allAppsBoostEnabled = Published(initialValue: UserDefaults.standard.bool(forKey: "AOMAudioMasterBoostEnabled"))
        _eqEnabled = Published(initialValue: UserDefaults.standard.object(forKey: "AOMAudioEQEnabled") as? Bool ?? false)
        let preset = UserDefaults.standard.string(forKey: "AOMAudioEQPreset")
        _eqPreset = Published(initialValue: preset ?? "Flat")
        if let preset, let gains = AudioEQ.presets[preset] {
            _eqGains = Published(initialValue: gains)
        }
        if preset == "Custom", let saved = UserDefaults.standard.array(forKey: "AOMAudioEQGains") as? [Double] {
            _eqGains = Published(initialValue: AudioEQ(gains: saved.map(Float.init)).gains)
        }
        super.init()
        audioObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("AOMAudioAppsChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if #available(macOS 14.2, *) {
                    if let self, !self.previewShowsMixer, self.soundEnabled != AppAudioEngine.shared.isEnabled {
                        self.soundEnabled = AppAudioEngine.shared.isEnabled
                    }
                    // The HAL safety fuse can disable only HomePod effects
                    // from the output queue; keep the switch in sync with
                    // the actual audio route without retriggering teardown.
                    if let self, !self.previewShowsMixer,
                       self.airPlayProcessingEnabled != AppAudioEngine.airPlayProcessingEnabled {
                        self.airPlayProcessingEnabled = AppAudioEngine.airPlayProcessingEnabled
                    }
                }
                self?.requestReload()
            }
        }
        // Isolated UI previews only (a no-op otherwise); see AudioCapturePreviewHooks.
        AudioCapturePreviewHooks.start()
        // `--aom-preview-mixer`: open the panel with the app list showing (the
        // engine itself never taps audio in a preview).
        if PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-mixer") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    self?.previewShowsMixer = true
                    self?.soundEnabled = true
                    self?.showAllApps = true
                    self?.showPanel()
                }
            }
        }
    }

    /// Isolated previews: keep the panel's list showing although the
    /// engine never runs in a preview.
    private var previewShowsMixer = false

    func refresh() {
        guard isSupported, #available(macOS 14.2, *) else { return }
        AppAudioEngine.shared.requestSync()
        requestReload()
    }

    private func requestReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reloadApps()
        }
    }

    private func reloadApps() {
        guard #available(macOS 14.2, *) else { return }
        let engine = AppAudioEngine.shared
        let updated = engine.runningAudioApps()
        if apps != updated { apps = updated }
        let competitor = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.rogueamoeba.soundsource" }
        if competingMixer?.processIdentifier != competitor?.processIdentifier { competingMixer = competitor }
        let error = updated.compactMap(\.error).first
        if lastError != error { lastError = error }
        if airPlayBypassed != engine.airPlayBypassed { airPlayBypassed = engine.airPlayBypassed }
        if airPlayProcessingActive != engine.airPlayProcessingActive { airPlayProcessingActive = engine.airPlayProcessingActive }
        if airPlayPreparing != engine.airPlayPreparing { airPlayPreparing = engine.airPlayPreparing }
        if airPlayRecovering != engine.airPlayRecovering { airPlayRecovering = engine.airPlayRecovering }
        let now = Date()
        for app in updated where app.isPlaying { lastActive[app.bundleID] = now }
    }

    // MARK: SoundSource-style application list

    func isFavorite(_ bundleID: String) -> Bool { favorites.contains(bundleID) }

    func toggleFavorite(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        if let index = favorites.firstIndex(of: bundleID) { favorites.remove(at: index) }
        else { favorites.append(bundleID) }
        UserDefaults.standard.set(favorites, forKey: "AOMAudioFavorites")
        if #available(macOS 14.2, *), isFavorite(bundleID) { AppAudioEngine.shared.addCustomApp(bundleID: bundleID) }
        refresh()
    }

    func moveFavorite(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        UserDefaults.standard.set(favorites, forKey: "AOMAudioFavorites")
    }

    /// Recently played within 60 s, still playing, or carrying settings.
    func isActive(_ app: AppAudioState, now: Date = Date()) -> Bool {
        if app.isPlaying || app.tapped && app.peakLevel > 0 { return true }
        if let last = lastActive[app.bundleID], now.timeIntervalSince(last) < 60 { return true }
        return false
    }

    func hasCustomSettings(_ app: AppAudioState) -> Bool {
        abs(app.gain - 1) > 0.001 || app.muted || app.outputDeviceUID != nil || app.magicBoost ||
            app.overdrive > 1.0001 || app.balance != 0 || appEQEnabled(app.bundleID)
    }

    /// Favourites first (in their order), then apps playing or adjusted,
    /// then — only when asked — everything else that is running.
    func listedApps(matching query: String = "") -> (favorites: [AppAudioState], active: [AppAudioState], other: [AppAudioState]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = trimmed.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
        var seen = Set<String>()
        var favoriteRows: [AppAudioState] = []
        for bundleID in favorites {
            if let app = pool.first(where: { $0.bundleID == bundleID }), seen.insert(app.id).inserted { favoriteRows.append(app) }
        }
        let rest = pool.filter { !seen.contains($0.id) }
        let now = Date()
        let active = rest.filter { isActive($0, now: now) || hasCustomSettings($0) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        let activeIDs = Set(active.map(\.id))
        let other = (showAllApps || !trimmed.isEmpty) ? rest.filter { !activeIDs.contains($0.id) } : []
        return (favoriteRows, active, other)
    }

    // MARK: Volume Overdrive and Timed Mute

    func overdrive(_ bundleID: String) -> Float { AppAudioPreferences.overdrive(bundleID: bundleID) }

    func setOverdrive(_ value: Float, bundleID: String) {
        guard #available(macOS 14.2, *), AppAudioPreferences.setOverdrive(value, bundleID: bundleID) else { return }
        objectWillChange.send()
        AppAudioEngine.shared.updateEffects()
        requestReload()
    }

    // MARK: Balance

    /// Per-app stereo balance, -1 (left) … +1 (right); 0 removes the setting.
    func setBalance(_ value: Float, bundleID: String) {
        guard #available(macOS 14.2, *), AppAudioEngine.shared.setBalance(value, bundleID: bundleID) else { return }
        objectWillChange.send()
        requestReload()
    }

    /// SoundSource's Timed Mute: silence an app for a while (ads), then fade
    /// it back in over about a second.
    func timedMute(bundleID: String, seconds: TimeInterval) {
        guard #available(macOS 14.2, *), !bundleID.isEmpty, seconds > 0 else { return }
        timedMutes[bundleID]?.cancel()
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "AOMAudioMute_\(bundleID)") { _ = toggleMute(bundleID: bundleID) }
        timedMuteEnds[bundleID] = Date().addingTimeInterval(seconds)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endTimedMute(bundleID: bundleID) }
        }
        timedMutes[bundleID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func cancelTimedMute(bundleID: String) {
        guard timedMutes[bundleID] != nil else { return }
        timedMutes.removeValue(forKey: bundleID)?.cancel()
        endTimedMute(bundleID: bundleID)
    }

    private func endTimedMute(bundleID: String) {
        guard #available(macOS 14.2, *) else { return }
        timedMutes.removeValue(forKey: bundleID)
        timedMuteEnds.removeValue(forKey: bundleID)
        let target = AppAudioEngine.storedGain(bundleID: bundleID)
        // Fade in: start silent, unmute, then step back to the saved volume.
        _ = AppAudioPreferences.setGain(0, bundleID: bundleID)
        if UserDefaults.standard.bool(forKey: "AOMAudioMute_\(bundleID)") { _ = toggleMute(bundleID: bundleID) }
        for step in 1...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.setGain(target * Float(step) / 10, bundleID: bundleID) }
            }
        }
    }

    func refreshMeters() {
        guard #available(macOS 14.2, *) else { return }
        var levels: [pid_t: Float] = [:]
        for app in apps where app.tapped {
            let level = AppAudioEngine.shared.level(pid: app.pid)
            levels[app.pid] = (max(0, min(1, level)) * 100).rounded() / 100
        }
        if meters.levels != levels { meters.levels = levels }
    }

    func beginMetering() {
        meterClients += 1
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeters() }
        }
        timer.tolerance = 0.02
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func endMetering() {
        meterClients = max(0, meterClients - 1)
        guard meterClients == 0 else { return }
        refreshTimer?.invalidate(); refreshTimer = nil
        if !meters.levels.isEmpty { meters.levels = [:] }
    }

    func reconnect(pid: pid_t) {
        guard #available(macOS 14.2, *), pid > 0 else { return }
        AppAudioEngine.shared.retry(pid: pid)
        reloadApps()
    }
    func reconnectAll() {
        guard #available(macOS 14.2, *) else { return }
        AppAudioEngine.shared.retryAll()
        reloadApps()
    }

    func quitCompetingMixer() {
        guard let app = competingMixer else { return }
        guard app.terminate() else { lastError = "SoundSource could not quit. Turn off its audio processing before reconnecting AOM."; return }
        Task { @MainActor in
            for _ in 0..<20 {
                if app.isTerminated { reconnectAll(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            lastError = "SoundSource is still running. Finish quitting it, then reconnect audio."
        }
    }

    func perform(_ action: TriggerAction) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        if action.actionType == .toggleMuteAllApps {
            if let saved = muteSnapshot {
                for (bundle, muted) in saved { UserDefaults.standard.set(muted, forKey: "AOMAudioMute_\(bundle)") }
                muteSnapshot = nil
            } else {
                let currentApps = AppAudioEngine.shared.runningAudioApps()
                muteSnapshot = Dictionary(currentApps.filter { !$0.bundleID.isEmpty }.map { ($0.bundleID, $0.muted) }, uniquingKeysWith: { first, _ in first })
                for bundle in muteSnapshot?.keys ?? Dictionary<String, Bool>().keys {
                    UserDefaults.standard.set(true, forKey: "AOMAudioMute_\(bundle)")
                }
            }
            refresh()
            return lastError == nil
        }
        let specified = action.parameters.targetApplicationBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let bundleID = specified.isEmpty ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : specified,
              !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return false }
        let engine = AppAudioEngine.shared
        engine.addCustomApp(bundleID: bundleID)
        let defaults = UserDefaults.standard
        let muteKey = "AOMAudioMute_\(bundleID)"
        switch action.actionType {
        case .setAppVolume:
            let value = action.parameters.levelPercent ?? 100
            guard value.isFinite, (0...400).contains(value) else { return false }
            // Up to 100 % is volume; above is Volume Overdrive (SoundSource).
            _ = AppAudioPreferences.setGain(Float(min(value, 100) / 100), bundleID: bundleID)
            _ = AppAudioPreferences.setOverdrive(Float(max(value, 100) / 100), bundleID: bundleID)
            engine.updateEffects()
        case .setAppAudioOutput:
            let uid = action.parameters.audioOutputUID ?? ""
            engine.setRoute(uid: uid.isEmpty ? nil : uid, bundleID: bundleID)
        default: defaults.set(!defaults.bool(forKey: muteKey), forKey: muteKey)
        }
        for app in engine.runningAudioApps() where app.bundleID == bundleID && app.pid > 0 {
            if !engine.setGain(AppAudioEngine.storedGain(bundleID: bundleID), muted: defaults.bool(forKey: muteKey), pid: app.pid) {
                reloadApps(); return false
            }
        }
        refresh()
        return !apps.contains { $0.bundleID == bundleID && $0.error != nil }
    }

    func start() { refresh() }

    /// Applies app effects and the shared output effects without resetting playback.
    func applyEQ() {
        guard #available(macOS 14.2, *) else { return }
        AppAudioEngine.shared.updateEffects()
        requestReload()
    }

    func appEQGains(_ bundleID: String) -> [Float] {
        let values = UserDefaults.standard.array(forKey: "AOMAudioAppEQGains_\(bundleID)") as? [Double] ?? []
        return AudioEQ(gains: values.map(Float.init)).gains
    }
    func appEQEnabled(_ bundleID: String) -> Bool {
        UserDefaults.standard.bool(forKey: "AOMAudioAppEQEnabled_\(bundleID)")
    }
    func appEQPreset(_ bundleID: String) -> String {
        UserDefaults.standard.string(forKey: "AOMAudioAppEQPreset_\(bundleID)") ?? "Flat"
    }
    func setAppEQEnabled(_ enabled: Bool, bundleID: String) {
        objectWillChange.send()
        UserDefaults.standard.set(enabled, forKey: "AOMAudioAppEQEnabled_\(bundleID)")
        applyEQ()
    }
    func setAppEQPreset(_ preset: String, bundleID: String) {
        guard let gains = AudioEQ.presets[preset] else { return }
        saveAppEQ(gains, preset: preset, bundleID: bundleID)
    }
    func setAppBand(_ index: Int, gain: Float, bundleID: String) {
        guard (0..<10).contains(index), gain.isFinite else { return }
        var gains = appEQGains(bundleID)
        gains[index] = min(12, max(-12, gain))
        saveAppEQ(gains, preset: "Custom", bundleID: bundleID)
    }
    private func saveAppEQ(_ gains: [Float], preset: String, bundleID: String) {
        objectWillChange.send()
        let d = UserDefaults.standard
        d.set(gains.map(Double.init), forKey: "AOMAudioAppEQGains_\(bundleID)")
        d.set(preset, forKey: "AOMAudioAppEQPreset_\(bundleID)")
        d.set(true, forKey: "AOMAudioAppEQEnabled_\(bundleID)")
        applyEQ()
    }

    func setBand(_ index: Int, gain: Float) {
        guard (0..<10).contains(index), gain.isFinite else { return }
        eqGains[index] = min(max(gain, -12), 12)
        eqPreset = "Custom"
    }

    func showPanel() {
        guard panel == nil else { panel?.orderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
                            styleMask: [.titled, .nonactivatingPanel, .closable, .resizable],
                            backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 520, height: 620)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: AppAudioMixerView(service: self))
        if let screen = NSScreen.main {
            let size = CGSize(width: 640, height: 700)
            let frame = NSRect(origin: screen.visibleFrame.origin, size: size)
                .offsetBy(dx: screen.visibleFrame.width - size.width - 24,
                          dy: (screen.visibleFrame.height - size.height) / 2)
            panel.setFrame(frame, display: false)
        }
        self.panel = panel
        isShowing = true
        panel.orderFrontRegardless()
        refresh()
        beginMetering()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShowing, event.keyCode == 53 else { return event }
            self.hide()
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) { hide() }

    func hide() {
        if isShowing { endMetering() }
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panel?.orderOut(nil)
        panel = nil
        isShowing = false
    }

    /// Keep the intended app identity even when rows refresh during a drag.
    func setGain(_ gain: Float, bundleID: String) {
        guard #available(macOS 14.2, *), bundleID != Bundle.main.bundleIdentifier,
              AppAudioPreferences.setGain(gain, bundleID: bundleID) else { return }
        AppAudioEngine.shared.refreshGainAndMute(bundleID: bundleID)
        requestReload()
    }

    @discardableResult
    func toggleMute(bundleID: String) -> Bool {
        guard #available(macOS 14.2, *), bundleID != Bundle.main.bundleIdentifier,
              AppAudioPreferences.toggleMute(bundleID: bundleID) != nil else { return false }
        AppAudioEngine.shared.refreshGainAndMute(bundleID: bundleID)
        reloadApps()
        return true
    }

    /// Audit action: toggle the frontmost app's audio mute.
    func toggleMuteFront() {
        guard isSupported, let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        _ = toggleMute(bundleID: bundleID)
    }

    func setOutputRoute(uid: String?, bundleID: String) {
        guard #available(macOS 14.2, *) else { return }
        AppAudioEngine.shared.setRoute(uid: uid, bundleID: bundleID)
        refresh()
    }

    func toggleMagicBoost(bundleID: String) {
        guard #available(macOS 14.2, *) else { return }
        let current = UserDefaults.standard.bool(forKey: "AOMAudioMagicBoost_\(bundleID)")
        AppAudioEngine.shared.setMagicBoost(!current, bundleID: bundleID)
        refresh()
    }

    /// Back to SoundSource's defaults for one app: volume 100 %, no Volume
    /// Overdrive, balance centred, Magic Boost and the app's equalizer off.
    /// The output route stays (it's where, not how, the app plays).
    func resetEffects(bundleID: String, magicBoost: Bool) {
        guard !bundleID.isEmpty else { return }
        setGain(1, bundleID: bundleID)
        setOverdrive(1, bundleID: bundleID)
        setBalance(0, bundleID: bundleID)
        if magicBoost { toggleMagicBoost(bundleID: bundleID) }
        setAppEQEnabled(false, bundleID: bundleID)
    }

    func addCustomApp(url: URL) {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        if #available(macOS 14.2, *) {
            AppAudioEngine.shared.addCustomApp(bundleID: bundleID)
            refresh()
        }
    }
}

@MainActor
final class AppAudioMeters: ObservableObject {
    @Published var levels: [pid_t: Float] = [:]
}

struct AppAudioLevelMeter: View {
    /// The meter's longest length under an app's name (no design token covers it).
    static let maxWidth: CGFloat = 100

    let pid: pid_t
    @ObservedObject private var meters = AppAudioMixerService.shared.meters
    var body: some View {
        let level = meters.levels[pid] ?? 0
        ProgressView(value: Double(level), total: 1)
            .tint(level > 0.95 ? AOMColor.warning : AOMColor.success)
            .frame(maxWidth: Self.maxWidth)
            .accessibilityLabel("Application audio level")
    }
}

private struct AppAudioMixerView: View {
    @ObservedObject var service: AppAudioMixerService
    /// Natural height of the output and effect controls. They keep the top of
    /// the panel and scroll only when the panel is too short for them and the
    /// app list's minimum together.
    @State private var controlsHeight: CGFloat = 0
    @AppStorage("AOMAudioMixerShowsOutputEffects") private var showsOutputEffects = false
    @State private var filter = ""
    /// The filter takes focus only when clicked (HIG Focus: don't move focus
    /// without people's interaction), not when the panel opens.
    @FocusState private var filterFocused: Bool
    private static let appListMinimum = AOMSize.rowStandard * 5

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("App Audio").font(AOMFont.bodyEmphasis)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: AOMSpace.x2)
                if service.isSupported {
                    // The title beside it names the switch; VoiceOver hears the page's words.
                    Toggle("App audio", isOn: $service.soundEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(service.soundEnabled ? "Turn off app audio processing" : "Turn on app audio processing")
                        .accessibilityLabel("App audio processing")
                }
                Button { service.hide() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Close the mixer")
                    .accessibilityLabel("Close mixer")
            }
            .padding(AOMSpace.x3)
            if !service.soundEnabled {
                // Off is a state, in the Audio page's words, with one way back.
                AOMEmptyState("App audio is off", systemImage: "speaker.slash",
                              message: "Apps play directly. Your app and effect settings are kept.") {
                    Button("Turn On App Audio") { service.soundEnabled = true }
                        .aomPrimaryButton()
                }
            } else {
                ScrollView {
                    controls
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: MixerControlsHeightKey.self, value: proxy.size.height)
                        })
                }
                .frame(maxHeight: controlsHeight > 0 ? controlsHeight : nil)
                .layoutPriority(1)
                .onPreferenceChange(MixerControlsHeightKey.self) { controlsHeight = $0 }
                Divider()
                appList
                    .frame(minHeight: Self.appListMinimum)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            if let competitor = service.competingMixer {
                AOMNotice(.warning, "SoundSource is also changing app audio",
                          detail: "Two per-app mixers on the same audio fight each other. Quit \(competitor.localizedName ?? "SoundSource") to use AOM's, or turn App Audio off.") {
                    Button("Quit SoundSource") { service.quitCompetingMixer() }
                }
                .padding(AOMSpace.x3)
            }
            if let error = service.lastError {
                AOMNotice(.error, "Some app audio isn't processed", detail: error) {
                    Button("Reconnect Audio") { service.reconnectAll() }
                }
                .padding(AOMSpace.x3)
            }
            MixerOutputSection()
            // SoundSource keeps the output's effects folded under the output
            // so the applications get the room; 3.4 does the same.
            Button {
                withAnimation(AOMMotion.standard) { showsOutputEffects.toggle() }
            } label: {
                HStack(spacing: AOMSpace.x2) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(showsOutputEffects ? 90 : 0))
                        .foregroundStyle(AOMColor.textSecondary)
                    Text("Output effects").font(AOMFont.bodyEmphasis)
                    Text(outputEffectsSummary).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AOMSpace.x3)
                .frame(minHeight: AOMSize.rowStandard)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Output effects")
            .accessibilityValue(showsOutputEffects ? "Expanded" : "Collapsed")
            .help("HomePod / AirPlay effects, Magic Boost, equalizer, Headphone EQ and an Audio Unit effect for the output")
            if showsOutputEffects {
                Divider()
                AirPlayProcessingControls(service: service)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AOMSpace.x3)
                Divider()
                MasterBoostControls(service: service)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AOMSpace.x3)
                Divider()
                EQSection(service: service)
                // 3.3.3: per-output curves and the Audio Unit effect follow the equalizer.
                Divider()
                HeadphoneEQCard(style: .panel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AOMSpace.x3)
                Divider()
                AudioUnitEffectCard(style: .panel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AOMSpace.x3)
            }
        }
    }

    private var outputEffectsSummary: String {
        var on: [String] = []
        if service.allAppsBoostEnabled { on.append("Magic Boost") }
        if service.eqEnabled { on.append("EQ \(service.eqPreset)") }
        if service.airPlayProcessingActive { on.append("HomePod") }
        return on.isEmpty ? "None on" : on.joined(separator: " · ")
    }

    // MARK: Applications (SoundSource: favourites, then what played recently)

    @ViewBuilder private var appList: some View {
        let lists = service.listedApps(matching: filter)
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                Text("Applications").font(AOMFont.bodyEmphasis).accessibilityAddTraits(.isHeader)
                Spacer(minLength: AOMSpace.x2)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                    .focused($filterFocused)
                    .onAppear { DispatchQueue.main.async { filterFocused = false } }
                    .accessibilityLabel("Filter applications")
                Toggle("Show All", isOn: $service.showAllApps)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Also list open apps that haven't played audio in the last minute")
                Button { addApp() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add an app that isn't open, to set it up before it plays")
                    .accessibilityLabel("Add App")
            }
            .padding(.horizontal, AOMSpace.x3)
            .padding(.vertical, AOMSpace.x2)
            if service.apps.isEmpty || (lists.favorites.isEmpty && lists.active.isEmpty && lists.other.isEmpty) {
                AOMEmptyState(!service.isSupported ? "Per-app audio isn't available"
                                : filter.isEmpty ? "No app is playing audio" : "No app matches “\(filter)”",
                              systemImage: "waveform",
                              message: !service.isSupported ? "Per-app audio needs macOS 14.2 or newer."
                                : "Apps appear here while they play and for a minute after. Show All lists every open app.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        group("Favorites", lists.favorites)
                        group(lists.favorites.isEmpty ? nil : "Recently Active", lists.active)
                        group("Other Apps", lists.other)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String?, _ apps: [AppAudioState]) -> some View {
        if !apps.isEmpty {
            if let title {
                Text(title)
                    .font(AOMFont.caption.weight(.semibold))
                    .foregroundStyle(AOMColor.textSecondary)
                    .padding(.horizontal, AOMSpace.x3)
                    .padding(.top, AOMSpace.x2)
                    .padding(.bottom, AOMSpace.x0_5)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(apps) { app in
                MixerAppRow(service: service, app: app)
                if app.id != apps.last?.id { AOMRowDivider(inset: AOMSpace.rowSymbolInset, trailingInset: 0) }
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app to set up its volume, boost and output before it plays."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        service.addCustomApp(url: url)
    }
}

/// The mixer panel's measured control height (see `AppAudioMixerView`).
private struct MixerControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Output Magic Boost, as in SoundSource: one switch, no strength levels.
/// It listens 12 ms ahead to raise quiet passages without overdriving loud
/// ones; app boosts run first and are independent.
struct MasterBoostControls: View {
    @ObservedObject var service: AppAudioMixerService

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                Toggle(isOn: $service.allAppsBoostEnabled) {
                    Label("Magic Boost", systemImage: "sparkles")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(AOMTheme.indigo)
                .accessibilityLabel("Magic Boost for the output")
                .help("Richer, fuller sound: quiet passages are raised while loud audio is kept from overdriving")
                Text(service.allAppsBoostEnabled
                     ? "Listening ahead on each output to lift quiet passages without distortion."
                     : "Lifts quiet passages on every output without overdriving loud audio.")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 3.3.3: the output's preset, under its switch and off with it.
            AudioBoostPresetPicker(bundleID: nil)
                .disabled(!service.allAppsBoostEnabled)
        }
        .disabled(!service.isSupported)
    }
}

/// Master surface: the current output device, its volume and mute — the
/// SoundSource header row. Uses AudioOutputService, which exists on every
/// supported macOS version (no 14.2 gate).
struct MixerOutputSection: View {
    @State private var devices: [AudioOutputDevice] = []
    @State private var volume: Double = 50
    @State private var muted = false
    @State private var isSwitchingOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                Text("Output").aomSectionCaps()
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: AOMSpace.x2)
                Picker("Output device", selection: Binding(
                    get: { currentUID },
                    set: { uid in
                        // This picker drives the machine-wide default output, and
                        // SwiftUI re-syncs a picker on its own whenever its items
                        // change. AirPlay reconnects with a fresh UID, which made
                        // the control snap to it and push every other app's audio
                        // onto AirPlay — the video-stalling default that survives
                        // quitting AOM. Only a real user choice may act.
                        guard !isSwitchingOutput, uid != currentUID, !uid.isEmpty,
                              let device = devices.first(where: { $0.uid == uid }) else { return }
                        isSwitchingOutput = true
                        AudioOutputService.shared.select(name: device.name, uid: device.uid, completion: { _ in
                            isSwitchingOutput = false
                            refresh()
                        })
                    })) {
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                // Capped like the Headphone EQ pickers below; long names truncate.
                .frame(maxWidth: AOMSize.tileMin)
            }
            HStack(spacing: AOMSpace.x2) {
                Button {
                    AudioOutputService.shared.adjustVolume(percentagePoints: -5, completion: { _ in refresh() })
                } label: { Image(systemName: "speaker.minus") }
                    .buttonStyle(.plain)
                    .help("Volume down 5%")
                    .accessibilityLabel("Volume down")
                Slider(value: Binding(get: { volume }, set: { newValue in
                    volume = newValue
                    AudioOutputService.shared.setVolume(percent: newValue, completion: { _ in })
                }), in: 0...100, step: 1)
                    .controlSize(.small)
                    .accessibilityLabel("Output volume")
                    .accessibilityValue("\(Int(volume)) percent")
                Button {
                    AudioOutputService.shared.adjustVolume(percentagePoints: 5, completion: { _ in refresh() })
                } label: { Image(systemName: "speaker.plus") }
                    .buttonStyle(.plain)
                    .help("Volume up 5%")
                    .accessibilityLabel("Volume up")
                Text("\(Int(volume))%")
                    .font(AOMFont.caption.monospacedDigit())
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMRowControlMetrics.valueWidth, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, AOMSpace.x3)
        .padding(.bottom, AOMSpace.x3)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private var currentUID: String {
        guard let id = AudioOutputService.currentDeviceID(),
              let current = devices.first(where: { $0.id == id }) else { return "" }
        return current.uid
    }

    private func refresh() {
        devices = AudioOutputService.devices()
        volume = Double(AudioOutputService.currentVolume() ?? 0.5) * 100
        muted = false
    }
}

/// SoundSource-style 10-band EQ: vertical sliders, presets, on/off.
struct EQSection: View {
    @ObservedObject var service: AppAudioMixerService

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x2) {
                Text("Equalizer").aomSectionCaps()
                    .accessibilityAddTraits(.isHeader)
                // A switch like the panel's other on/off controls; the
                // heading beside it is its visible label.
                Toggle("Equalizer", isOn: $service.eqEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Applies to every app you've adjusted")
                Spacer(minLength: AOMSpace.x2)
                Picker("Equalizer preset", selection: $service.eqPreset) {
                    ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                    if service.eqPreset == "Custom" { Text("Custom").tag("Custom") }
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
            AudioEqualizerControls(gains: service.eqGains, enabled: service.eqEnabled) {
                service.setBand($0, gain: $1)
            }
        }
        .padding(AOMSpace.x3)
    }

    static func label(_ band: Int) -> String {
        let hz = AudioEQ.bandFrequencies[band]
        return hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}

/// One application in the mixer panel, SoundSource-style: icon and name with
/// its live level, mute, volume (up to 100 %, Volume Overdrive beyond in the
/// effects), Magic Boost, the output it plays to, and its effects (Volume
/// Overdrive, balance, equalizer, Magic Boost preset, timed mute) folded
/// under the chevron. Every control calls what the Audio page calls, so
/// the two always agree.
struct MixerAppRow: View {
    @ObservedObject var service: AppAudioMixerService
    let app: AppAudioState
    @State private var gain: Float
    @State private var balance: Float
    @State private var expanded = false

    init(service: AppAudioMixerService, app: AppAudioState) {
        self.service = service
        self.app = app
        _gain = State(initialValue: min(max(app.gain, 0), 1))
        _balance = State(initialValue: AudioBalance.clamp(app.balance))
    }

    private var hasBundle: Bool { !app.bundleID.isEmpty && !app.bundleID.hasPrefix("pid-") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AOMSpace.x2) {
                icon
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    HStack(spacing: AOMSpace.x1) {
                        Text(app.name).font(AOMFont.callout.weight(.medium)).lineLimit(1)
                        if service.isFavorite(app.bundleID) {
                            Image(systemName: "star.fill").imageScale(.small).foregroundStyle(AOMColor.warning)
                                .accessibilityLabel("Favorite")
                        }
                        if let ends = service.timedMuteEnds[app.bundleID] {
                            Text("muted until \(ends.formatted(date: .omitted, time: .shortened))")
                                .font(AOMFont.caption).foregroundStyle(AOMColor.warningText).lineLimit(1)
                        }
                    }
                    activityLine
                }
                .frame(minWidth: 110, alignment: .leading)
                .layoutPriority(1)
                Spacer(minLength: AOMSpace.x1)
                Button { service.toggleMute(bundleID: app.bundleID) } label: {
                    Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(app.muted ? AOMColor.danger : AOMColor.textSecondary)
                        .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasBundle)
                .help(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                .accessibilityLabel(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                Slider(value: Binding(get: { Double(gain) }, set: { newValue in
                    gain = Float(newValue)
                    service.setGain(gain, bundleID: app.bundleID)
                }), in: 0...1)
                    .frame(width: AOMRowControlMetrics.sliderWidth)
                    .controlSize(.small)
                    .disabled(!hasBundle)
                    .accessibilityLabel("Volume for \(app.name)")
                    .accessibilityValue("\(Int((gain * app.overdrive * 100).rounded())) percent")
                Text("\(Int((gain * app.overdrive * 100).rounded()))%")
                    .font(AOMFont.caption.monospacedDigit())
                    .foregroundStyle(app.overdrive > 1.0001 ? AOMColor.warningText : AOMColor.textSecondary)
                    .frame(width: AOMRowControlMetrics.valueWidth, alignment: .trailing)
                    .help(app.overdrive > 1.0001 ? "Volume Overdrive \(Int((app.overdrive * 100).rounded()))%" : "Volume")
                    .accessibilityHidden(true)
                Button { service.toggleMagicBoost(bundleID: app.bundleID) } label: {
                    Image(systemName: app.magicBoost ? "sparkles" : "sparkle")
                        .foregroundStyle(app.magicBoost ? AOMTheme.indigo : AOMColor.textSecondary)
                        .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasBundle)
                .help(app.magicBoost ? "Turn off Magic Boost for \(app.name)" : "Magic Boost: lift quiet passages of \(app.name)")
                .accessibilityLabel("Magic Boost for \(app.name)")
                .accessibilityValue(app.magicBoost ? "On" : "Off")
                outputMenu
                Button { withAnimation(AOMMotion.standard) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AOMColor.textSecondary)
                        .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasBundle)
                .help(expanded ? "Hide effects" : "Effects: Volume Overdrive, balance, equalizer, timed mute")
                .accessibilityLabel("Effects for \(app.name)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x1)
            .frame(minHeight: AOMSize.rowDetail)
            .contentShape(Rectangle())
            .contextMenu { contextMenu }
            if expanded { effects }
        }
        .onChange(of: app.gain) { _, value in gain = min(max(value, 0), 1) }
        .onChange(of: app.balance) { _, value in balance = AudioBalance.clamp(value) }
    }

    @ViewBuilder private var icon: some View {
        if let image = app.icon {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(width: AOMIcon.row, height: AOMIcon.row)
                .opacity(app.isPlaying || app.tapped ? 1 : 0.6)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed").frame(width: AOMIcon.row, height: AOMIcon.row).accessibilityHidden(true)
        }
    }

    /// The live level while AOM processes the app; otherwise what it's doing
    /// (SoundSource's outlined meter for "made noise in the last minute").
    @ViewBuilder private var activityLine: some View {
        if app.tapped {
            AppAudioLevelMeter(pid: app.pid)
        } else if let error = app.error {
            Text(error).font(AOMFont.caption).foregroundStyle(AOMColor.warningText).lineLimit(1).help(error)
        } else if app.isPlaying {
            Label("Playing", systemImage: "waveform").font(AOMFont.caption).foregroundStyle(AOMColor.successText)
        } else if app.pid <= 0 {
            Text("Not open · settings kept").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
        } else if service.isActive(app) {
            Capsule().strokeBorder(AOMColor.textTertiary, lineWidth: 1)
                .frame(width: AppAudioLevelMeter.maxWidth, height: 5)
                .help("Played in the last minute")
                .accessibilityLabel("Played in the last minute")
        } else {
            Text("Silent").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
        }
    }

    // MARK: Output (SoundSource: per-app output redirection)

    private var routeName: String {
        guard let uid = app.outputDeviceUID else { return "System Output" }
        return AudioOutputService.devices().first(where: { $0.uid == uid })?.name ?? "Disconnected device"
    }

    /// AirPlay outputs take one app only through AOM's buffered HomePod
    /// sender; with HomePod / AirPlay effects off they can't be chosen here
    /// (the app would silently stay on the Mac's output).
    private var outputMenu: some View {
        let devices = AudioOutputService.devices()
        let current = app.outputDeviceUID
        return Menu {
            Toggle("System Output (Follows the Mac)", isOn: Binding(get: { current == nil }, set: { on in
                if on, current != nil { service.setOutputRoute(uid: nil, bundleID: app.bundleID) }
            }))
            if let current, !devices.contains(where: { $0.uid == current }) {
                Text("Chosen output is disconnected; using System Output")
            }
            Divider()
            ForEach(devices) { device in
                let airPlay = AudioOutputRestore.transportType(of: device.id) == kAudioDeviceTransportTypeAirPlay
                Toggle(device.name, isOn: Binding(get: { current == device.uid }, set: { on in
                    if on, current != device.uid { service.setOutputRoute(uid: device.uid, bundleID: app.bundleID) }
                }))
                .disabled(airPlay && !service.airPlayProcessingEnabled)
            }
            if !service.airPlayProcessingEnabled, devices.contains(where: { AudioOutputRestore.transportType(of: $0.id) == kAudioDeviceTransportTypeAirPlay }) {
                Divider()
                Text("AirPlay needs HomePod / AirPlay effects (Output effects)")
            }
        } label: {
            Image(systemName: current == nil ? "hifispeaker" : "hifispeaker.fill")
                .foregroundStyle(current == nil ? AOMColor.textSecondary : AOMColor.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: AOMIcon.hitArea, height: AOMIcon.hitArea)
        .disabled(!hasBundle)
        .help("Plays to: \(routeName)")
        .accessibilityLabel("Output for \(app.name)")
        .accessibilityValue(routeName)
    }

    // MARK: Effects

    private var effects: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            effectRow("Volume Overdrive") {
                Slider(value: Binding(get: { Double(app.overdrive) },
                                      set: { service.setOverdrive(Float($0), bundleID: app.bundleID) }),
                       in: 1...Double(AudioVolumeOverdrive.maximum), step: 0.05)
                    .controlSize(.small)
                    .frame(width: AOMRowControlMetrics.sliderWidth)
                    .accessibilityLabel("Volume Overdrive for \(app.name)")
                    .accessibilityValue("\(Int((app.overdrive * 100).rounded())) percent")
                    .help("Up to 400%, limited so loud audio never clips")
                Text("\(Int((app.overdrive * 100).rounded()))%")
                    .font(AOMFont.caption.monospacedDigit()).foregroundStyle(AOMColor.textSecondary)
            }
            effectRow("Balance") {
                Text("L").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).accessibilityHidden(true)
                Slider(value: Binding(get: { Double(balance) }, set: { newValue in
                    balance = AudioBalance.stepped(Float(newValue))
                    service.setBalance(balance, bundleID: app.bundleID)
                }), in: -1...1, step: 0.01)
                    .controlSize(.small)
                    .frame(width: AOMRowControlMetrics.sliderWidth)
                    .accessibilityLabel("Balance for \(app.name)")
                    .accessibilityValue(AudioBalance.spokenValue(balance))
                Text("R").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).accessibilityHidden(true)
                Button("Center") { balance = 0; service.setBalance(0, bundleID: app.bundleID) }
                    .controlSize(.small)
                    .disabled(balance == 0)
            }
            effectRow("Magic Boost") {
                Toggle("Magic Boost for \(app.name)", isOn: Binding(get: { app.magicBoost },
                                                                   set: { _ in service.toggleMagicBoost(bundleID: app.bundleID) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                AudioBoostPresetPicker(bundleID: app.bundleID, style: .menu)
                    .disabled(!app.magicBoost)
            }
            effectRow("Equalizer") {
                Toggle("Equalizer for \(app.name)", isOn: Binding(get: { service.appEQEnabled(app.bundleID) },
                                                                  set: { service.setAppEQEnabled($0, bundleID: app.bundleID) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Picker("Equalizer preset for \(app.name)", selection: Binding(
                    get: { service.appEQPreset(app.bundleID) },
                    set: { service.setAppEQPreset($0, bundleID: app.bundleID) })) {
                    ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                    if service.appEQPreset(app.bundleID) == "Custom" { Text("Custom").tag("Custom") }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .disabled(!service.appEQEnabled(app.bundleID))
            }
            HStack(spacing: AOMSpace.x2) {
                Menu("Timed Mute") { timedMuteItems }
                    .controlSize(.small).fixedSize()
                Button(service.isFavorite(app.bundleID) ? "Unfavorite" : "Favorite",
                       systemImage: service.isFavorite(app.bundleID) ? "star.fill" : "star") {
                    service.toggleFavorite(app.bundleID)
                }
                .controlSize(.small)
                Spacer(minLength: AOMSpace.x2)
                Button("Reset") { resetEffects() }
                    .controlSize(.small)
                    .help("Volume 100%, no overdrive, balance centered, Magic Boost and equalizer off")
            }
            if let error = app.error {
                HStack(spacing: AOMSpace.x2) {
                    Label(error, systemImage: "exclamationmark.triangle").font(AOMFont.caption).foregroundStyle(AOMColor.warningText)
                    Spacer(minLength: AOMSpace.x2)
                    Button("Reconnect") { service.reconnect(pid: app.pid) }.controlSize(.small)
                        .disabled(app.pid <= 0 || !service.soundEnabled)
                }
            }
        }
        .padding(.leading, AOMSpace.rowSymbolInset)
        .padding(.trailing, AOMSpace.rowInset)
        .padding(.bottom, AOMSpace.x3)
    }

    private func effectRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Text(title)
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: 112, alignment: .leading)
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var timedMuteItems: some View {
        Button("30 Seconds") { service.timedMute(bundleID: app.bundleID, seconds: 30) }
        Button("1 Minute") { service.timedMute(bundleID: app.bundleID, seconds: 60) }
        Button("2 Minutes") { service.timedMute(bundleID: app.bundleID, seconds: 120) }
        Button("5 Minutes") { service.timedMute(bundleID: app.bundleID, seconds: 300) }
        if service.timedMuteEnds[app.bundleID] != nil {
            Divider()
            Button("End Timed Mute") { service.cancelTimedMute(bundleID: app.bundleID) }
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button(app.muted ? "Unmute" : "Mute") { service.toggleMute(bundleID: app.bundleID) }
        Menu("Timed Mute") { timedMuteItems }
        Button(service.isFavorite(app.bundleID) ? "Remove from Favorites" : "Add to Favorites") {
            service.toggleFavorite(app.bundleID)
        }
        Divider()
        Button("Reset Effects") { resetEffects() }
        Button("Reconnect") { service.reconnect(pid: app.pid) }.disabled(app.pid <= 0 || !service.soundEnabled)
    }

    private func resetEffects() {
        gain = 1
        balance = 0
        service.resetEffects(bundleID: app.bundleID, magicBoost: app.magicBoost)
    }
}

/// Controls describe audible behavior; transport mechanics stay out of the UI.
/// The mixer panel shows a labelled switch over its status line; the Audio
/// page passes its label column's width (`labelWidth`) so the name sits in
/// that column and the status lines up under the switch.
struct AirPlayProcessingControls: View {
    @ObservedObject var service: AppAudioMixerService
    /// The Audio page's label column; nil in the mixer panel.
    var labelWidth: CGFloat?

    var body: some View {
        if let labelWidth {
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                HStack(spacing: AOMSpace.x3) {
                    Text("HomePod effects")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                        .frame(width: labelWidth, alignment: .leading)
                        .accessibilityHidden(true)
                    toggle.labelsHidden()
                    Spacer(minLength: 0)
                }
                stableDynamicsToggle
                    .padding(.leading, labelWidth + AOMSpace.x3)
                status
                    .padding(.leading, labelWidth + AOMSpace.x3)
            }
        } else {
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                toggle
                stableDynamicsToggle
                status
            }
        }
    }

    private var toggle: some View {
        Toggle("HomePod / AirPlay effects", isOn: $service.airPlayProcessingEnabled)
            .toggleStyle(.switch).controlSize(.small)
            .disabled(!service.soundEnabled)
    }

    private var stableDynamicsToggle: some View {
        Toggle("Stable AirPlay dynamics (reduce crackling)", isOn: $service.stableAirPlayDynamics)
            .toggleStyle(.switch).controlSize(.small)
            .disabled(!service.soundEnabled || !service.airPlayProcessingEnabled)
    }

    private var status: some View {
        Group {
            if !service.soundEnabled {
                Text("Audio processing off — settings saved")
            } else if service.airPlayPreparing {
                Label("Connecting — current audio continues", systemImage: "airplay.audio")
            } else if service.airPlayProcessingActive {
                Label(service.stableAirPlayDynamics
                      ? "App volume and EQ → HomePod; output-wide Magic Boost bypassed for stability"
                      : "App volume, EQ and boost → HomePod", systemImage: "airplay.audio")
            } else {
                Text(service.airPlayProcessingEnabled
                     ? "Apply app volume, EQ and boost to Mac audio sent to HomePod. Buffered playback adds latency."
                     : (UserDefaults.standard.string(forKey: AppAudioEngine.airPlaySafetyReasonKey)
                        ?? "Direct playback: effects and app volume are bypassed on AirPlay."))
            }
        }
        .font(AOMFont.caption)
        .foregroundStyle(AOMColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}