import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A compact mixer keeps the frequent controls visible; devices and the full
/// equalizer have their own destinations instead of extending one long page.
struct AudioWorkspaceView: View {
    @ObservedObject private var service = AppAudioMixerService.shared
    @State private var searchText = ""
    @AppStorage("AOMAudioWorkspaceSection") private var section = "Mixer"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AOMSpace.m) {
                Picker("Audio section", selection: $section) {
                    Text("Mixer").tag("Mixer")
                    Text("Devices").tag("Devices")
                    Text("Effects").tag("Effects")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer(minLength: 4)
                if service.isSupported {
                    Toggle("App Audio", isOn: $service.soundEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                        .help(service.soundEnabled ? "Disable app audio processing" : "Enable app audio processing")
                }
                Menu {
                    Button("Reconnect Audio") { service.reconnectAll() }
                    Button("Audio Recording Permission…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 26, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Audio options")
                .help("Audio recovery and permission options")
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, AOMSpace.l)
            .padding(.top, AOMSpace.m)
            .padding(.bottom, AOMSpace.xs)
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: AOMSpace.m) {
                    notices
                    switch section {
                    case "Devices": devicesContent
                    case "Effects": effectsContent
                    default: mixerContent
                    }
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, AOMSpace.l)
                .padding(.top, AOMSpace.m)
                .padding(.bottom, AOMSpace.l)
                .frame(maxWidth: .infinity)
            }
            .id(section)
        }
        .background(AOMTheme.workspace)
        .onAppear { service.beginMetering(); service.refresh() }
        .onDisappear { service.endMetering() }
    }

    @ViewBuilder private var notices: some View {
        if !service.soundEnabled {
            AOMNotice(.warning, "App audio is off", detail: "Audio plays directly; your app and effect settings are saved.") {
                Button("Enable") { service.soundEnabled = true }.buttonStyle(AOMTintedButtonStyle())
            }
        }
        if service.competingMixer != nil && service.soundEnabled {
            AOMNotice(.warning, "SoundSource is also running", detail: "Two mixers can compete for the same audio.") {
                Button("Quit SoundSource & Reconnect") { service.quitCompetingMixer() }
            }
        }
        if let error = service.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(AOMType.caption).foregroundStyle(AOMTheme.warning)
        }
    }

    private var mixerContent: some View {
        VStack(alignment: .leading, spacing: AOMSpace.m) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    MasterOutputCard(compact: true, boxed: false).frame(minWidth: 320, maxWidth: .infinity)
                    Rectangle().fill(AOMTheme.divider).frame(width: 0.5).padding(.vertical, 16)
                    mixerBoost.frame(minWidth: 320, maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    MasterOutputCard(compact: true, boxed: false)
                    AOMDivider().padding(.horizontal, 14)
                    mixerBoost
                }
            }
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: AOMRadius.card))
            .overlay(RoundedRectangle(cornerRadius: AOMRadius.card).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
            HStack(alignment: .center, spacing: AOMSpace.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Applications").font(AOMType.headline)
                    Text("Adjust volume and boost. Open Details for routing and EQ.")
                        .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                }
                Spacer(minLength: AOMSpace.s)
                TextField("Filter apps…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, idealWidth: 160, maxWidth: 200)
                    .accessibilityLabel("Filter applications")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Clear application filter")
                        .accessibilityLabel("Clear application filter")
                }
                Button { pickAndAddApplication() } label: { Label("Add App", systemImage: "plus") }
                Button { service.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh applications").accessibilityLabel("Refresh applications")
            }
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("\(filteredApps.count) of \(service.apps.count) applications")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
            }
            if filteredApps.isEmpty {
                VStack(spacing: AOMSpace.s) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
                    Text(service.isSupported ? (searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No audio applications found" : "No applications match “\(searchText)”")
                         : "Per-app audio requires macOS 14.2 or newer")
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear Filter") { searchText = "" }
                    } else if service.isSupported {
                        Button("Add an Application") { pickAndAddApplication() }
                    }
                }
                .frame(maxWidth: .infinity).padding(AOMSpace.xl)
                .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: AOMRadius.card))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredApps) { app in
                        SoundSourceAppCard(app: app,
                            onGain: { service.setGain($0, bundleID: app.bundleID) },
                            onMute: { service.toggleMute(bundleID: app.bundleID) },
                            onRouteChange: { service.setOutputRoute(uid: $0, bundleID: app.bundleID) },
                            onMagicBoostToggle: { service.toggleMagicBoost(bundleID: app.bundleID) })
                        if app.id != filteredApps.last?.id { AOMDivider().padding(.leading, 54) }
                    }
                }
                .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: AOMRadius.card))
                .clipShape(RoundedRectangle(cornerRadius: AOMRadius.card))
                .overlay(RoundedRectangle(cornerRadius: AOMRadius.card).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
            }
        }
    }

    private var mixerBoost: some View {
        VStack(alignment: .leading, spacing: AOMSpace.s) {
            Text("Output Boost").font(AOMType.headline)
            MasterBoostControls(service: service)
            Button(service.eqEnabled ? "Equalizer: \(service.eqPreset)" : "Equalizer: Off") { section = "Effects" }
                .buttonStyle(.link).help("Open output effects")
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var boostCard: some View {
        VStack(alignment: .leading, spacing: AOMSpace.s) {
            Text("Output Boost").font(AOMType.headline)
            MasterBoostControls(service: service)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: AOMRadius.card))
        .overlay(RoundedRectangle(cornerRadius: AOMRadius.card).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
    }

    private var devicesContent: some View {
        VStack(alignment: .leading, spacing: AOMSpace.m) {
            Text("System Devices").font(AOMType.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: AOMSpace.m)], spacing: AOMSpace.m) {
                MasterOutputCard()
                MasterInputCard()
                MasterAlertCard()
            }
            VStack(alignment: .leading, spacing: AOMSpace.s) {
                Text("AirPlay").font(AOMType.headline)
                AirPlayProcessingControls(service: service)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: AOMRadius.card))
        }
    }

    private var effectsContent: some View {
        VStack(alignment: .leading, spacing: AOMSpace.m) {
            boostCard
            VStack(alignment: .leading, spacing: AOMSpace.s) {
                Text("Master Equalizer").font(AOMType.headline)
                Text("Applies to managed application audio after each app’s EQ.")
                    .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                MasterStudioEQCard(service: service)
            }
        }
    }

    private var filteredApps: [AppAudioState] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return service.apps }
        return service.apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
    }

    private func pickAndAddApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        service.addCustomApp(url: url)
    }
}

// MARK: - Master Output Card

private struct MasterOutputCard: View {
    var compact = false
    var boxed = true
    @State private var devices: [AudioOutputDevice] = []
    @State private var isSwitchingOutput = false
    @State private var volume: Double = 50
    @State private var balance: Float = 0
    @State private var isMuted = false
    @State private var canAdjustVolume = false
    @State private var canAdjustBalance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.14))
                        .frame(width: 28, height: 28)
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }
                Text("Output Device")
                    .font(AOMType.headline)
                    .foregroundStyle(AOMTheme.text)
                Spacer()

                Picker("Output device", selection: Binding(
                    get: { currentUID },
                    set: { uid in
                        // SwiftUI re-syncs a picker whenever its items change. A
                        // device that reconnects (AirPlay comes back with a fresh
                        // UID) used to fire this setter on its own and push the
                        // system default onto that device, which stalls every
                        // other app's playback. Only a real user change counts.
                        guard !isSwitchingOutput, uid != currentUID, !uid.isEmpty else { return }
                        guard let device = devices.first(where: { $0.uid == uid }) else { return }
                        isSwitchingOutput = true
                        AudioOutputService.shared.select(name: device.name, uid: device.uid) { _ in
                            isSwitchingOutput = false
                            refresh()
                        }
                    })) {
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 160)
            }

            // Volume Slider & Mute
            HStack(spacing: 10) {
                Button {
                    AudioOutputService.shared.toggleOutputMute { _ in refresh() }
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : (volume > 50 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"))
                        .foregroundStyle(isMuted ? Color.red : Color.accentColor)
                        .font(.system(size: 14))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMuted ? "Unmute output" : "Mute output")
                .help(isMuted ? "Unmute output" : "Mute output")

                Slider(value: Binding(get: { volume }, set: { newValue in
                    volume = newValue
                    isMuted = false
                    AudioOutputService.shared.setVolume(percent: newValue) { _ in }
                }), in: 0...100, step: 1)
                .controlSize(.small)
                .disabled(!canAdjustVolume)
                .accessibilityLabel("Output volume")
                .accessibilityValue("\(Int(volume.rounded())) percent")
                .help(canAdjustVolume ? "Output volume" : "This output does not support volume control")

                Text(canAdjustVolume ? "\(Int(volume))%" : "—")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 38, alignment: .trailing)
            }

            // Balance stays on the Devices page; the mixer keeps volume in view.
            if !compact {
            HStack(spacing: 8) {
                Text("L").font(.system(size: 9, weight: .bold)).foregroundStyle(AOMTheme.textTertiary)
                Slider(value: Binding(get: { Double(balance) }, set: { newValue in
                    balance = Float(newValue)
                    AudioOutputService.setBalance(balance)
                }), in: -1...1, step: 0.05)
                .controlSize(.mini)
                .disabled(!canAdjustBalance)
                .accessibilityLabel("Output balance")
                .accessibilityValue(balance == 0 ? "Center" : "\(Int(abs(balance) * 100)) percent \(balance < 0 ? "left" : "right")")
                .help(canAdjustBalance ? "Adjust stereo balance" : "This output does not support balance control")
                Text("R").font(.system(size: 9, weight: .bold)).foregroundStyle(AOMTheme.textTertiary)
                
                Button("Center") {
                    balance = 0
                    AudioOutputService.setBalance(0)
                }
                .disabled(!canAdjustBalance)
                .font(.system(size: 9, weight: .medium))
                .buttonStyle(.borderless)
                .foregroundStyle(AOMTheme.textTertiary)
            }
            }
        }
        .padding(14)
        .background(boxed ? AOMTheme.card : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth).opacity(boxed ? 1 : 0))
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
        volume = Double(AudioOutputService.currentVolume() ?? 0) * 100
        canAdjustVolume = AudioOutputService.canAdjustOutputVolume()
        canAdjustBalance = AudioOutputService.canAdjustBalance()
        balance = AudioOutputService.currentBalance()
        isMuted = AudioOutputService.isOutputMuted()
    }
}

// MARK: - Master Input Card

private struct MasterInputCard: View {
    @State private var devices: [AudioOutputDevice] = []
    @State private var volume: Double = 80
    @State private var isMuted = false
    @State private var canAdjustVolume = false
    @State private var canMute = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.14))
                        .frame(width: 28, height: 28)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }
                Text("Input Device")
                    .font(AOMType.headline)
                    .foregroundStyle(AOMTheme.text)
                Spacer()

                Picker("Input device", selection: Binding(
                    get: { currentUID },
                    set: { uid in
                        AudioOutputService.selectInput(uid: uid)
                        refresh()
                    })) {
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 160)
            }

            // Volume Slider & Mute
            HStack(spacing: 10) {
                Button {
                    if let next = AudioOutputService.toggleInputMute() { isMuted = next }
                } label: {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(isMuted ? Color.red : Color.orange)
                        .font(.system(size: 14))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(!canMute)
                .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
                .help(canMute ? (isMuted ? "Unmute microphone" : "Mute microphone") : "This input does not support mute")

                Slider(value: Binding(get: { volume }, set: { newValue in
                    volume = newValue
                    if AudioOutputService.setInputVolume(percent: newValue) {
                        isMuted = AudioOutputService.isInputMuted()
                    } else { refresh() }
                }), in: 0...100, step: 1)
                .controlSize(.small)
                .disabled(!canAdjustVolume)
                .accessibilityLabel("Microphone input volume")
                .accessibilityValue("\(Int(volume.rounded())) percent")
                .help(canAdjustVolume ? "Microphone input volume" : "This input does not support volume control")

                Text(canAdjustVolume ? "\(Int(volume))%" : "—")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 38, alignment: .trailing)
            }

            // Live Input Peak Meter
            Text(isMuted ? "Microphone muted" : "Microphone input ready")
                .font(.caption).foregroundStyle(AOMTheme.textTertiary)
        }
        .padding(14)
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private var currentUID: String {
        guard let id = AudioOutputService.currentInputDeviceID(),
              let current = devices.first(where: { $0.id == id }) else { return "" }
        return current.uid
    }

    private func refresh() {
        devices = AudioOutputService.inputDevices()
        volume = Double(AudioOutputService.currentInputVolume() ?? 0) * 100
        canAdjustVolume = AudioOutputService.canAdjustInputVolume()
        canMute = AudioOutputService.canMuteInput()
        isMuted = AudioOutputService.isInputMuted()
    }
}

// MARK: - Master Alert Sounds Card

private struct MasterAlertCard: View {
    @State private var volume: Double = 65
    @State private var isMuted = false
    @State private var previousVolume: Double = 65

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.purple.opacity(0.14))
                        .frame(width: 28, height: 28)
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.purple)
                }
                Text("Sound Effects")
                    .font(AOMType.headline)
                    .foregroundStyle(AOMTheme.text)
                Spacer()
                Text("System Alerts").font(AOMType.caption).foregroundStyle(AOMTheme.textTertiary)
            }

            // Volume Slider & Mute
            HStack(spacing: 10) {
                Button {
                    if !isMuted, volume > 0 { previousVolume = volume }
                    let target = isMuted ? previousVolume : 0
                    if AudioOutputService.setSystemAlertVolume(percent: target) {
                        volume = target
                        isMuted = target == 0
                    }
                } label: {
                    Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
                        .foregroundStyle(isMuted ? Color.red : Color.purple)
                        .font(.system(size: 14))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMuted ? "Unmute system alerts" : "Mute system alerts")
                .help(isMuted ? "Unmute system alerts" : "Mute system alerts")

                Slider(value: Binding(get: { volume }, set: { newValue in
                    volume = newValue
                    isMuted = newValue == 0
                    if newValue > 0 { previousVolume = newValue }
                    AudioOutputService.setSystemAlertVolume(percent: newValue)
                }), in: 0...100, step: 1)
                .controlSize(.small)
                .accessibilityLabel("System alert volume")
                .accessibilityValue("\(Int(volume.rounded())) percent")

                Text("\(Int(volume))%")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 38, alignment: .trailing)
            }

            Text("Controls volume for macOS alert pings and notification chimes")
                .font(.system(size: 10))
                .foregroundStyle(AOMTheme.textTertiary)
        }
        .padding(14)
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
        .onAppear {
            volume = Double(AudioOutputService.currentSystemAlertVolume() ?? 0.65) * 100
            isMuted = volume == 0
            if volume > 0 { previousVolume = volume }
        }
    }
}

// MARK: - Application mixer row

private struct SoundSourceAppCard: View {
    @ObservedObject private var mixerService = AppAudioMixerService.shared
    let app: AppAudioState
    let onGain: (Float) -> Void
    let onMute: () -> Void
    let onRouteChange: (String?) -> Void
    let onMagicBoostToggle: () -> Void
    @State private var gain: Float
    @State private var showDetails = false
    @State private var showEQ = false
    @State private var availableOutputs: [AudioOutputDevice] = []

    init(app: AppAudioState, onGain: @escaping (Float) -> Void,
         onMute: @escaping () -> Void, onRouteChange: @escaping (String?) -> Void,
         onMagicBoostToggle: @escaping () -> Void) {
        self.app = app; self.onGain = onGain; self.onMute = onMute
        self.onRouteChange = onRouteChange; self.onMagicBoostToggle = onMagicBoostToggle
        _gain = State(initialValue: min(max(app.gain, 0), 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(AOMType.body.weight(.semibold)).lineLimit(1)
                    Text(app.error ?? app.processingStatus)
                        .font(AOMType.micro)
                        .foregroundStyle(app.error == nil ? AOMTheme.textSecondary : AOMTheme.warning)
                        .lineLimit(1).help(app.error ?? app.processingStatus)
                    if app.tapped { AppAudioLevelMeter(pid: app.pid).frame(maxWidth: 100) }
                }
                .frame(minWidth: 100, idealWidth: 180, maxWidth: 220, alignment: .leading)
                Spacer(minLength: 4)
                Button(action: onMute) {
                    Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(app.muted ? AOMTheme.danger : AOMTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                .help(app.muted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { Double(gain) }, set: { gain = Float($0); onGain(gain) }),
                       in: 0...2, step: 0.05)
                    .controlSize(.small).frame(minWidth: 100, maxWidth: 260)
                    .accessibilityLabel("Volume for \(app.name)")
                    .accessibilityValue("\(Int((gain * 100).rounded())) percent")
                Text("\(Int((gain * 100).rounded()))%")
                    .font(AOMType.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(gain > 1.05 ? AOMTheme.warning : AOMTheme.textSecondary)
                    .frame(width: 40, alignment: .trailing)
                Button(action: onMagicBoostToggle) {
                    Label(app.magicBoost ? "Boost On" : "Boost", systemImage: "sparkles")
                }
                .controlSize(.small).buttonStyle(.bordered)
                .tint(app.magicBoost ? Color.indigo : Color.secondary)
                .accessibilityLabel("Boost \(app.name)")
                .accessibilityValue(app.magicBoost ? "On" : "Off")
                .help("Raise quiet passages for this app")
                Button { showDetails.toggle() } label: {
                    Label("Details", systemImage: showDetails ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Details for \(app.name)")
                .accessibilityValue(showDetails ? "Expanded" : "Collapsed")
                .help(showDetails ? "Hide routing and effects" : "Show routing and effects")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            if showDetails {
                Divider()
                VStack(alignment: .leading, spacing: AOMSpace.s) {
                    HStack(spacing: AOMSpace.s) {
                        Text("Output").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                        Picker("Output for \(app.name)", selection: Binding(
                            get: { app.outputDeviceUID ?? "" }, set: { onRouteChange($0.isEmpty ? nil : $0) })) {
                            Text("System Default").tag("")
                            if let uid = app.outputDeviceUID, !availableOutputs.contains(where: { $0.uid == uid }) {
                                Text("Disconnected — using default").tag(uid)
                            }
                            ForEach(availableOutputs) { Text($0.name).tag($0.uid) }
                        }
                        .labelsHidden().controlSize(.small).frame(maxWidth: 180)
                        if app.magicBoost {
                            Text("Boost").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                            Picker("App boost strength", selection: Binding(
                                get: { mixerService.appBoostLevel(app.bundleID) },
                                set: { mixerService.setAppBoostLevel($0, bundleID: app.bundleID) })) {
                                Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
                            }
                            .labelsHidden().controlSize(.small).frame(width: 100)
                        }
                        Spacer(minLength: 4)
                        Button("Reset Volume") { gain = 1; onGain(1) }
                            .disabled(abs(gain - 1) < 0.001)
                            .help("Reset \(app.name) volume to 100%")
                        Button("Reconnect") { mixerService.reconnect(pid: app.pid) }
                            .disabled(app.pid <= 0 || !mixerService.soundEnabled)
                            .help("Reconnect \(app.name) audio")
                        Button("Equalizer…") { showEQ = true }
                            .accessibilityLabel("Equalizer for \(app.name)")
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(AOMTheme.cardAlt.opacity(0.4))
            }
        }
        .sheet(isPresented: $showEQ) {
            VStack(alignment: .leading, spacing: AOMSpace.m) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Equalizer").font(AOMType.headline)
                        Text(app.name).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                    }
                    Spacer()
                    Button("Done") { showEQ = false }.keyboardShortcut(.cancelAction)
                }
                InlineAppEQView(service: mixerService, bundleID: app.bundleID)
            }
            .padding(AOMSpace.l)
            .frame(minWidth: 760, idealWidth: 800)
        }
        .onAppear { availableOutputs = AudioOutputService.devices() }
        .onChange(of: showDetails) { _, shown in if shown { availableOutputs = AudioOutputService.devices() } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if showDetails { availableOutputs = AudioOutputService.devices() }
        }
        .onChange(of: app.gain) { _, value in gain = min(max(value, 0), 2) }
    }

    @ViewBuilder private var appIcon: some View {
        if let icon = app.icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 16))
                .foregroundStyle(AOMTheme.textSecondary).frame(width: 30, height: 30)
                .background(AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Inline App EQ View

private struct InlineAppEQView: View {
    @ObservedObject var service: AppAudioMixerService
    let bundleID: String

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("EQ", isOn: Binding(get: { service.appEQEnabled(bundleID) },
                                            set: { service.setAppEQEnabled($0, bundleID: bundleID) }))
                    .toggleStyle(.switch).controlSize(.regular)
                Text("Equalizer Preset:").font(.system(size: 13, weight: .semibold)).foregroundStyle(AOMTheme.textSecondary)
                Picker("Application equalizer preset", selection: Binding(get: { service.appEQPreset(bundleID) }, set: { service.setAppEQPreset($0, bundleID: bundleID) })) {
                    ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                    if service.appEQPreset(bundleID) == "Custom" { Text("Custom").tag("Custom") }
                }
                .labelsHidden().controlSize(.small).frame(maxWidth: 140)
                Spacer()
                Button("Reset to Flat") { service.setAppEQPreset("Flat", bundleID: bundleID) }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
            }

            AudioEqualizerControls(gains: service.appEQGains(bundleID), enabled: service.appEQEnabled(bundleID)) {
                service.setAppBand($0, gain: $1, bundleID: bundleID)
            }

        }
    }
}

// MARK: - Master Studio 10-Band EQ Card

private struct MasterStudioEQCard: View {
    @ObservedObject var service: AppAudioMixerService

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle("Enable Equalizer", isOn: $service.eqEnabled)
                    .font(AOMType.body.weight(.medium))
                    .controlSize(.small)
                Spacer()

                HStack(spacing: 8) {
                    Text("Preset:").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                    Picker("Master equalizer preset", selection: $service.eqPreset) {
                        ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                        if service.eqPreset == "Custom" { Text("Custom").tag("Custom") }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 150)
                    .disabled(!service.eqEnabled)

                    Button("Reset to Flat") {
                        service.eqPreset = "Flat"
                    }
                    .font(AOMType.caption)
                    .controlSize(.small)
                    .disabled(!service.eqEnabled)
                }
            }

            Divider()

            AudioEqualizerControls(gains: service.eqGains, enabled: service.eqEnabled) {
                service.setBand($0, gain: $1)
            }
            Text("Boosted EQ bands may lower the overall level to keep loud passages clear.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
    }
}
