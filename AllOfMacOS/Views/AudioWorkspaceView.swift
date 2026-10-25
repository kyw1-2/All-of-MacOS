import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// System audio controls, independent application effects, and shared output effects.
/// Includes per-app routing, gain, adaptive boost, and ten-band equalizers.
struct AudioWorkspaceView: View {
    @ObservedObject private var service = AppAudioMixerService.shared
    @State private var searchText: String = ""
    @State private var expandedEQPID: pid_t? = nil

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AOMSpace.xl) {
                // MARK: - Master System Surfaces (Output, Input, System Sounds)
                VStack(alignment: .leading, spacing: AOMSpace.s) {
                    Text("SYSTEM AUDIO")
                        .font(AOMType.caption.weight(.semibold))
                        .foregroundStyle(AOMTheme.textSecondary)

                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 280, maximum: 400), spacing: AOMSpace.m)
                    ], spacing: AOMSpace.m) {
                        MasterOutputCard()
                        MasterInputCard()
                        MasterAlertCard()
                    }
                }

                VStack(alignment: .leading, spacing: AOMSpace.s) {
                    Text("OUTPUT EFFECTS")
                        .font(AOMType.caption.weight(.semibold))
                        .foregroundStyle(AOMTheme.textSecondary)
                    MasterBoostControls(service: service)
                        .padding(14)
                        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
                }

                // MARK: - Applications Mixer
                VStack(alignment: .leading, spacing: AOMSpace.s) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("APPLICATIONS")
                                .font(AOMType.caption.weight(.semibold))
                                .foregroundStyle(AOMTheme.textSecondary)
                            Text(service.isSupported ? "Control volume, route output, boost, and EQ per application" : "Per-app audio requires macOS 14.2+")
                                .font(AOMType.caption)
                                .foregroundStyle(AOMTheme.textTertiary)
                        }
                        Spacer()
                        
                        // Search bar
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(AOMTheme.textSecondary)
                            TextField("Filter apps...", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(AOMType.caption)
                                .frame(width: 120)
                            if !searchText.isEmpty {
                                Button { searchText = "" } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        // Add App Button
                        Button {
                            pickAndAddApplication()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Add App")
                            }
                            .font(AOMType.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        // Sound Engine Toggle
                        if service.isSupported {
                            Toggle("", isOn: $service.soundEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .help(service.soundEnabled ? "Disable App Audio Engine" : "Enable App Audio Engine")
                        }

                        // Refresh button
                        Button { service.refresh() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AOMTheme.textSecondary)
                                .padding(6)
                                .background(AOMTheme.cardAlt, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Refresh applications")
                    }

                    if service.airPlayBypassed && service.soundEnabled {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("HomePod / AirPlay · Direct Playback").font(.headline)
                                Text("App volume, mute, EQ and boost are saved but bypassed on this connection. They resume on a local output. Control HomePod volume through macOS or HomePod.")
                                    .font(.callout)
                            }
                        } icon: { Image(systemName: "airplay.audio") }
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !service.soundEnabled {
                        VStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.slash.fill").foregroundStyle(.secondary)
                                Text("App Audio Engine is Disabled").font(AOMType.body.weight(.semibold))
                            }
                            Text("All applications output audio directly through standard macOS output devices without background capture or modification.")
                                .font(AOMType.caption)
                                .foregroundStyle(AOMTheme.textSecondary)
                                .multilineTextAlignment(.center)
                            Button("Enable App Audio") {
                                service.soundEnabled = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else if service.competingMixer != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("SoundSource is also processing audio", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundStyle(.orange)
                            Text("Two per-app audio mixers can compete for the same streams. Use one mixer for volume and routing.")
                                .font(.callout)
                            Button("Quit SoundSource & Reconnect AOM") { service.quitCompetingMixer() }
                        }
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack {
                        Button("Audio Recording Permission…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                        }
                        Button("Reconnect Audio") { service.reconnectAll() }
                        Spacer()
                        Text("Audio controls require Screen & System Audio Recording access.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = service.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(AOMType.caption).foregroundStyle(.red)
                    }
                    if filteredApps.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.system(size: 32))
                                .foregroundStyle(AOMTheme.textTertiary)
                            Text(service.isSupported
                                 ? (searchText.isEmpty ? "No active audio applications found." : "No applications match “\(searchText)”.")
                                 : "Per-app volume and routing requires macOS 14.2 or newer.")
                                .font(AOMType.body)
                                .foregroundStyle(AOMTheme.textSecondary)
                            if service.isSupported && searchText.isEmpty {
                                Button("Add an Application to Mix") { pickAndAddApplication() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
                    } else {
                        VStack(spacing: AOMSpace.s) {
                            ForEach(filteredApps) { app in
                                SoundSourceAppCard(
                                    app: app,
                                    isEQExpanded: expandedEQPID == app.pid,
                                    onToggleEQ: {
                                        expandedEQPID = (expandedEQPID == app.pid) ? nil : app.pid
                                    },
                                    onGain: { service.setGain($0, pid: app.pid) },
                                    onMute: { service.toggleMute(pid: app.pid) },
                                    onRouteChange: { uid in service.setOutputRoute(uid: uid, bundleID: app.bundleID) },
                                    onMagicBoostToggle: { service.toggleMagicBoost(bundleID: app.bundleID) }
                                )
                            }
                        }
                    }
                }

                // MARK: - Master 10-Band Equalizer (Studio Rack)
                VStack(alignment: .leading, spacing: AOMSpace.s) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("10-BAND MASTER EQUALIZER")
                                .font(AOMType.caption.weight(.semibold))
                                .foregroundStyle(AOMTheme.textSecondary)
                            Text("Applies to all managed application audio, after each app’s EQ")
                                .font(AOMType.caption)
                                .foregroundStyle(AOMTheme.textTertiary)
                        }
                        Spacer()
                    }

                    MasterStudioEQCard(service: service)
                }
            }
            .padding(AOMSpace.xl)
        }
        .background(AOMTheme.workspace)
        .onAppear { service.beginMetering(); service.refresh() }
        .onDisappear { service.endMetering() }
    }

    private var filteredApps: [AppAudioState] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return service.apps
        }
        return service.apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
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

                Picker("", selection: Binding(
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

                Slider(value: Binding(get: { volume }, set: { newValue in
                    volume = newValue
                    isMuted = false
                    AudioOutputService.shared.setVolume(percent: newValue) { _ in }
                }), in: 0...100, step: 1)
                .controlSize(.small)
                .disabled(!canAdjustVolume)

                Text(canAdjustVolume ? "\(Int(volume))%" : "—")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 38, alignment: .trailing)
            }

            // Stereo Balance
            HStack(spacing: 8) {
                Text("L").font(.system(size: 9, weight: .bold)).foregroundStyle(AOMTheme.textTertiary)
                Slider(value: Binding(get: { Double(balance) }, set: { newValue in
                    balance = Float(newValue)
                    AudioOutputService.setBalance(balance)
                }), in: -1...1, step: 0.05)
                .controlSize(.mini)
                .disabled(!canAdjustBalance)
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
        .padding(14)
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
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

                Picker("", selection: Binding(
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

                Slider(value: Binding(get: { volume }, set: { newValue in
                    volume = newValue
                    if AudioOutputService.setInputVolume(percent: newValue) {
                        isMuted = AudioOutputService.isInputMuted()
                    } else { refresh() }
                }), in: 0...100, step: 1)
                .controlSize(.small)
                .disabled(!canAdjustVolume)

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

                Slider(value: Binding(get: { volume }, set: { newValue in
                    volume = newValue
                    isMuted = false
                    AudioOutputService.setSystemAlertVolume(percent: newValue)
                }), in: 0...100, step: 1)
                .controlSize(.small)

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

// MARK: - SoundSource Application Audio Card

private struct SoundSourceAppCard: View {
    @ObservedObject private var mixerService = AppAudioMixerService.shared
    let app: AppAudioState
    let isEQExpanded: Bool
    let onToggleEQ: () -> Void
    let onGain: (Float) -> Void
    let onMute: () -> Void
    let onRouteChange: (String?) -> Void
    let onMagicBoostToggle: () -> Void

    @State private var gain: Float
    @State private var availableOutputs: [AudioOutputDevice] = []

    init(
        app: AppAudioState,
        isEQExpanded: Bool,
        onToggleEQ: @escaping () -> Void,
        onGain: @escaping (Float) -> Void,
        onMute: @escaping () -> Void,
        onRouteChange: @escaping (String?) -> Void,
        onMagicBoostToggle: @escaping () -> Void
    ) {
        self.app = app
        self.isEQExpanded = isEQExpanded
        self.onToggleEQ = onToggleEQ
        self.onGain = onGain
        self.onMute = onMute
        self.onRouteChange = onRouteChange
        self.onMagicBoostToggle = onMagicBoostToggle
        _gain = State(initialValue: min(max(app.gain, 0), 2.0))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // App Icon
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AOMTheme.cardAlt)
                            .frame(width: 36, height: 36)
                        Image(systemName: "app.dashed")
                            .font(.system(size: 18))
                            .foregroundStyle(AOMTheme.textSecondary)
                    }
                }

                // App Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(AOMType.body.weight(.semibold))
                            .foregroundStyle(AOMTheme.text)
                            .lineLimit(1)
                        if app.tapped {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                                .help("Audio process tap active")
                        }
                    }
                    if app.tapped {
                        AppAudioLevelMeter(pid: app.pid)
                    }
                    Text(app.error ?? app.processingStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(AOMTheme.textTertiary)
                        .lineLimit(1)
                }
                .frame(minWidth: 120, alignment: .leading)

                Spacer()

                // Output Route Selector
                Picker("", selection: Binding(
                    get: { app.outputDeviceUID ?? "" },
                    set: { uid in onRouteChange(uid.isEmpty ? nil : uid) }
                )) {
                    Text("System Default").tag("")
                    if let uid = app.outputDeviceUID, !availableOutputs.contains(where: { $0.uid == uid }) {
                        Text("Disconnected — using default").tag(uid)
                    }
                    ForEach(availableOutputs) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 140)
                .help("Route output for this application")

            }
            .padding(.horizontal, 14).padding(.top, 10)

            HStack(spacing: 12) {
                // Magic Boost Button
                Button {
                    onMagicBoostToggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Boost")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(app.magicBoost ? Color.white : AOMTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(app.magicBoost ? Color.indigo : AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityValue(app.magicBoost ? "On" : "Off")
                .help("Raise quiet passages with adaptive compression for this app")

                if app.magicBoost {
                    Picker("App boost strength", selection: Binding(
                        get: { mixerService.appBoostLevel(app.bundleID) },
                        set: { mixerService.setAppBoostLevel($0, bundleID: app.bundleID) }
                    )) {
                        Text("Low").tag(1)
                        Text("Medium").tag(2)
                        Text("High").tag(3)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 90)
                }
                Spacer(minLength: 8)

                // Equalizer Toggle
                Button {
                    onToggleEQ()
                } label: {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isEQExpanded ? Color.accentColor : AOMTheme.textSecondary)
                        .padding(5)
                        .background(isEQExpanded ? Color.accentColor.opacity(0.12) : AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Toggle 10-Band EQ for this app")
                Button("Reconnect") { AppAudioMixerService.shared.reconnect(pid: app.pid) }
                    .buttonStyle(.borderless).disabled(app.pid <= 0)
                    .help("Reconnect this app’s audio capture and output")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            HStack(spacing: 12) {
                // Mute Button
                Button {
                    onMute()
                } label: {
                    Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(app.muted ? Color.red : AOMTheme.textSecondary)
                        .font(.system(size: 13))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(app.muted ? "Unmute" : "Mute")

                // Volume Slider (0...200% Overdrive)
                Slider(value: Binding(get: { Double(gain) }, set: { newValue in
                    gain = Float(newValue)
                    onGain(gain)
                }), in: 0...2.0, step: 0.05)
                .frame(minWidth: 100, maxWidth: .infinity)
                .controlSize(.small)

                // Percent / Overdrive Readout
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int((gain * 100).rounded()))%")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(gain > 1.05 ? Color.orange : AOMTheme.text)
                    if gain > 1.05 {
                        Text("+\(Int((20 * log10(gain)).rounded()))dB")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }
                }
                .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Inline 10-Band EQ when expanded
            if isEQExpanded {
                Divider()
                InlineAppEQView(service: AppAudioMixerService.shared, bundleID: app.bundleID)
                    .padding(12)
                    .background(AOMTheme.cardAlt.opacity(0.4))
            }
        }
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
        .onAppear {
            availableOutputs = AudioOutputService.devices()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            availableOutputs = AudioOutputService.devices()
        }
        .onChange(of: app.gain) { _, newGain in
            gain = min(max(newGain, 0), 2.0)
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
                Picker("", selection: Binding(get: { service.appEQPreset(bundleID) }, set: { service.setAppEQPreset($0, bundleID: bundleID) })) {
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
                    Picker("", selection: $service.eqPreset) {
                        ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                        if service.eqPreset == "Custom" { Text("Custom").tag("Custom") }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 150)
                    .disabled(!service.eqEnabled)

                    Button("Zero All") {
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

        }
        .padding(16)
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
    }
}

