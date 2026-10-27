import AppKit
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
                    if let self, self.soundEnabled != AppAudioEngine.shared.isEnabled {
                        self.soundEnabled = AppAudioEngine.shared.isEnabled
                    }
                }
                self?.requestReload()
            }
        }
    }

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
            app.overdrive > 1.0001 || appEQEnabled(app.bundleID)
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
    let pid: pid_t
    @ObservedObject private var meters = AppAudioMixerService.shared.meters
    var body: some View {
        let level = meters.levels[pid] ?? 0
        ProgressView(value: Double(level), total: 1)
            .tint(level > 0.95 ? .orange : .green)
            .frame(maxWidth: 100)
            .accessibilityLabel("Application audio level")
    }
}

private struct AppAudioMixerView: View {
    @ObservedObject var service: AppAudioMixerService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.tint)
                Text("App Audio").font(.system(size: 13, weight: .semibold))
                Spacer()
                if service.isSupported {
                    Toggle("Sound", isOn: $service.soundEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                Button { service.hide() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Close the mixer")
                    .accessibilityLabel("Close mixer")
            }.padding(12)
            if !service.soundEnabled {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("App Audio is Disabled")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Apps output directly through standard macOS audio paths without tap interception.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Enable App Audio") {
                        service.soundEnabled = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)
            } else {
                MixerOutputSection()
                AirPlayProcessingControls(service: service).padding(12)
                Divider()
                MasterBoostControls(service: service)
                    .padding(12)
                Divider()
                if let error = service.lastError {
                    VStack(spacing: 6) {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button("Reconnect Audio") { service.reconnectAll() }.controlSize(.small)
                    }.padding(8)
                }
                EQSection(service: service)
                Divider()
                if service.apps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(service.isSupported ? "No app is playing audio right now."
                                                 : "Per-app audio needs macOS 14.2 or newer.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(service.apps) { app in
                                AppAudioRow(app: app,
                                            onGain: { service.setGain($0, bundleID: app.bundleID) },
                                            onMute: { service.toggleMute(bundleID: app.bundleID) })
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Output Magic Boost, as in SoundSource: one switch, no strength levels.
/// It listens 12 ms ahead to raise quiet passages without overdriving loud
/// ones; app boosts run first and are independent.
struct MasterBoostControls: View {
    @ObservedObject var service: AppAudioMixerService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $service.allAppsBoostEnabled) {
                Label("Magic Boost", systemImage: "sparkles")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.indigo)
            .accessibilityLabel("Magic Boost for the output")
            .help("Richer, fuller sound: quiet passages are raised while loud audio is kept from overdriving")
            Text(service.allAppsBoostEnabled
                 ? "Listening ahead on each output to lift quiet passages without distortion."
                 : "Lifts quiet passages on every output without overdriving loud audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        VStack(spacing: 6) {
            HStack {
                Text("Output").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
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
                .frame(maxWidth: 170)
            }
            HStack {
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
                Button {
                    AudioOutputService.shared.adjustVolume(percentagePoints: 5, completion: { _ in refresh() })
                } label: { Image(systemName: "speaker.plus") }
                    .buttonStyle(.plain)
                    .help("Volume up 5%")
                    .accessibilityLabel("Volume up")
                Text("\(Int(volume))%")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
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
        VStack(spacing: 6) {
            HStack {
                Text("Equalizer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Toggle("", isOn: $service.eqEnabled).labelsHidden().controlSize(.mini)
                    .help("Applies to every app you've adjusted")
                Spacer()
                Picker("", selection: $service.eqPreset) {
                    ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                    if service.eqPreset == "Custom" { Text("Custom").tag("Custom") }
                }
                .labelsHidden().controlSize(.small).frame(maxWidth: 130)
            }
            AudioEqualizerControls(gains: service.eqGains, enabled: service.eqEnabled) {
                service.setBand($0, gain: $1)
            }

        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    static func label(_ band: Int) -> String {
        let hz = AudioEQ.bandFrequencies[band]
        return hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}

struct AppAudioRow: View {
    let app: AppAudioState
    let onGain: (Float) -> Void
    let onMute: () -> Void
    @State private var gain: Float

    init(app: AppAudioState, onGain: @escaping (Float) -> Void, onMute: @escaping () -> Void) {
        self.app = app
        self.onGain = onGain
        self.onMute = onMute
        _gain = State(initialValue: min(max(app.gain, 0), 1))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(app.name).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            Button { onMute() } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(app.muted ? .red : .secondary)
            }.buttonStyle(.plain).help(app.muted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(gain) }, set: { newValue in
                gain = Float(newValue)
                onGain(gain)
            }), in: 0...1, step: 0.01)
                .frame(width: 130)
                .controlSize(.small)
            Text("\(Int((gain * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onMute() }
        .onChange(of: app.gain) { _, newGain in
            gain = min(max(newGain, 0), 1)
        }
    }
}

/// Controls describe audible behavior; transport mechanics stay out of the UI.
struct AirPlayProcessingControls: View {
    @ObservedObject var service: AppAudioMixerService
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("HomePod / AirPlay effects", isOn: $service.airPlayProcessingEnabled)
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!service.soundEnabled)
            if !service.soundEnabled {
                Text("Audio processing off — settings saved")
                    .font(.caption).foregroundStyle(.secondary)
            } else if service.airPlayPreparing {
                Label("Connecting — current audio continues", systemImage: "airplay.audio")
                    .font(.caption).foregroundStyle(.secondary)
            } else if service.airPlayProcessingActive {
                Label("App volume, EQ and boost → HomePod", systemImage: "airplay.audio")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(service.airPlayProcessingEnabled
                     ? "Apply app volume, EQ and boost to Mac audio sent to HomePod. Buffered playback adds latency."
                     : "Direct playback: effects and app volume are bypassed on AirPlay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}