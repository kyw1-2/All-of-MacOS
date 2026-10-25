import AppKit
import SwiftUI

/// Per-app audio mixer (SoundSource-lite): a floating panel listing every app
/// producing audio, with gain and mute per app. Backed by AppAudioEngine's
/// process taps on macOS 14.2+; older systems see an explanatory empty state.
@MainActor
final class AppAudioMixerService: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppAudioMixerService()

    @Published private(set) var apps: [AppAudioState] = []
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
    @Published var allAppsBoostLevel: Int {
        didSet {
            guard allAppsBoostLevel != oldValue else { return }
            allAppsBoostLevel = min(3, max(1, allAppsBoostLevel))
            UserDefaults.standard.set(allAppsBoostLevel, forKey: "AOMAudioMasterBoostLevel")
            applyEQ()
        }
    }
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
        _allAppsBoostEnabled = Published(initialValue: UserDefaults.standard.bool(forKey: "AOMAudioMasterBoostEnabled"))
        let savedBoostLevel = UserDefaults.standard.object(forKey: "AOMAudioMasterBoostLevel") as? Int ?? 2
        _allAppsBoostLevel = Published(initialValue: min(3, max(1, savedBoostLevel)))
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
                    self?.soundEnabled = AppAudioEngine.shared.isEnabled
                }
                self?.reloadApps()
            }
        }
    }

    func refresh() {
        guard isSupported, #available(macOS 14.2, *) else { return }
        AppAudioEngine.shared.syncActiveProcesses()
        reloadApps()
    }

    private func reloadApps() {
        guard #available(macOS 14.2, *) else { return }
        apps = AppAudioEngine.shared.runningAudioApps()
        competingMixer = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.rogueamoeba.soundsource" }
        lastError = apps.compactMap(\.error).first
    }

    func refreshMeters() {
        guard #available(macOS 14.2, *) else { return }
        var updated = apps
        for index in updated.indices { updated[index].peakLevel = AppAudioEngine.shared.level(pid: updated[index].pid) }
        if updated != apps { apps = updated }
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
                refresh()
                muteSnapshot = Dictionary(apps.filter { !$0.bundleID.isEmpty }.map { ($0.bundleID, $0.muted) }, uniquingKeysWith: { first, _ in first })
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
        let gainKey = "AOMAudioGain_\(bundleID)", muteKey = "AOMAudioMute_\(bundleID)"
        switch action.actionType {
        case .setAppVolume:
            let value = action.parameters.levelPercent ?? 100
            guard value.isFinite, (0...200).contains(value) else { return false }
            defaults.set(value / 100, forKey: gainKey)
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
        reloadApps()
    }

    func appBoostLevel(_ bundleID: String) -> Int {
        let saved = UserDefaults.standard.object(forKey: "AOMAudioBoostLevel_\(bundleID)") as? Int ?? 2
        return min(3, max(1, saved))
    }

    func setAppBoostLevel(_ level: Int, bundleID: String) {
        guard !bundleID.isEmpty else { return }
        let value = min(3, max(1, level))
        guard appBoostLevel(bundleID) != value else { return }
        objectWillChange.send()
        UserDefaults.standard.set(value, forKey: "AOMAudioBoostLevel_\(bundleID)")
        applyEQ()
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeters() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShowing, event.keyCode == 53 else { return event }
            self.hide()
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) { hide() }

    func hide() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panel?.orderOut(nil)
        panel = nil
        isShowing = false
    }

    /// Per-app gain: starts the tap session lazily on first adjustment.
    func setGain(_ gain: Float, pid: pid_t) {
        guard #available(macOS 14.2, *) else { return }
        if let app = apps.first(where: { $0.pid == pid }), pid <= 0 {
            UserDefaults.standard.set(Double(Mixer.clamp(gain)), forKey: "AOMAudioGain_\(app.bundleID)")
        } else {
            let muted = AppAudioEngine.shared.session(pid: pid)?.muted ?? apps.first(where: { $0.pid == pid })?.muted ?? false
            _ = AppAudioEngine.shared.setGain(gain, muted: muted, pid: pid)
        }
        reloadApps()
    }

    /// Toggle per-app mute; the tap session persists so unmuting restores gain.
    func toggleMute(pid: pid_t) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        let current = AppAudioEngine.shared.session(pid: pid)
        let app = AppAudioEngine.shared.runningAudioApps().first(where: { $0.pid == pid })
        let isCurrentlyMuted = current?.muted ?? app?.muted ?? false
        let muted = !isCurrentlyMuted
        let gain = current?.gain ?? app?.gain ?? 1.0
        if pid <= 0, let app {
            UserDefaults.standard.set(muted, forKey: "AOMAudioMute_\(app.bundleID)")
            reloadApps()
            return true
        }
        let ok = AppAudioEngine.shared.setGain(gain, muted: muted, pid: pid)
        reloadApps()
        return ok
    }

    /// Audit action: toggle the frontmost app's audio mute.
    func toggleMuteFront() {
        guard isSupported, let front = NSWorkspace.shared.frontmostApplication else { return }
        _ = toggleMute(pid: front.processIdentifier)
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
                Divider()
                MasterBoostControls(service: service)
                    .padding(12)
                Divider()
                if let error = service.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).padding(8)
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
                                            onGain: { service.setGain($0, pid: app.pid) },
                                            onMute: { service.toggleMute(pid: app.pid) })
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

/// Output effects remain independent from each application's boost setting.
struct MasterBoostControls: View {
    @ObservedObject var service: AppAudioMixerService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    service.allAppsBoostEnabled.toggle()
                } label: {
                    Label("Boost All Apps", systemImage: service.allAppsBoostEnabled ? "sparkles" : "waveform")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(service.allAppsBoostEnabled ? Color.indigo : Color.secondary)
                .accessibilityValue(service.allAppsBoostEnabled ? "On" : "Off")
                .help("Enhance quiet audio across all managed applications")
                Spacer(minLength: 8)
                Picker("Output boost strength", selection: $service.allAppsBoostLevel) {
                    Text("Low").tag(1)
                    Text("Medium").tag(2)
                    Text("High").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 220)
                .disabled(!service.allAppsBoostEnabled)
            }
            Text(service.allAppsBoostEnabled
                 ? "Boosts the mixed audio from all managed apps. Individual app effects remain independent."
                 : "Raise quiet passages with adaptive compression. Keep each app’s own boost settings.")
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
                Slider(value: Binding(get: { volume }, set: { newValue in
                    volume = newValue
                    AudioOutputService.shared.setVolume(percent: newValue, completion: { _ in })
                }), in: 0...100, step: 1)
                    .controlSize(.small)
                Button {
                    AudioOutputService.shared.adjustVolume(percentagePoints: 5, completion: { _ in refresh() })
                } label: { Image(systemName: "speaker.plus") }
                    .buttonStyle(.plain)
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
        _gain = State(initialValue: min(max(app.gain, 0), 2))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(app.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 8)
            Button { onMute() } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(app.muted ? .red : .secondary)
            }.buttonStyle(.plain).help(app.muted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(gain) }, set: { newValue in
                gain = Float(newValue)
                onGain(gain)
            }), in: 0...2, step: 0.05)
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
            gain = min(max(newGain, 0), 2)
        }
    }
}
