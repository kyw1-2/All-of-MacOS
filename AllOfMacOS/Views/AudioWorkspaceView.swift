import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Audio, arranged like SoundSource's one window: the system devices on top
/// (output, input, sound effects), the applications below. Frequent controls
/// — volume, mute, Magic Boost, routing — sit on each row; effects (Volume
/// Overdrive, equalizer, timed mute) open in place. Toolbar: the App Audio
/// switch, the application filter and recovery options.
struct AudioWorkspaceView: View {
    @ObservedObject private var service = AppAudioMixerService.shared
    @State private var searchText = ""
    @State private var expandedOutput = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AOMSpace.m) {
                notices
                devicesCard
                applicationsCard
            }
            .frame(maxWidth: AOMSize.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, AOMSpace.l)
            .padding(.vertical, AOMSpace.m)
            .frame(maxWidth: .infinity)
        }
        .aomScrollEdge()
        .aomPage("Audio", subtitle: subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter Apps")
        .toolbar { toolbarContent }
        .onAppear { service.beginMetering(); service.refresh() }
        .onDisappear { service.endMetering() }
    }

    private var subtitle: String {
        guard service.isSupported else { return "Per-app audio needs macOS 14.2 or newer" }
        guard service.soundEnabled else { return "App audio off — playing directly" }
        var parts: [String] = []
        let playing = service.apps.filter(\.isPlaying).count
        parts.append(playing == 1 ? "1 app playing" : "\(playing) apps playing")
        if service.allAppsBoostEnabled { parts.append("Magic Boost") }
        if service.eqEnabled { parts.append("EQ \(service.eqPreset)") }
        if service.airPlayProcessingActive { parts.append("HomePod effects") }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            if service.isSupported {
                HStack(spacing: 6) {
                    Text("App Audio").font(AOMType.caption.weight(.medium)).foregroundStyle(AOMTheme.textSecondary)
                    Toggle("App Audio", isOn: $service.soundEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 6)
                .help(service.soundEnabled ? "Turn off app audio processing" : "Turn on app audio processing")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("App audio processing")
            }
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Add Application…", systemImage: "plus") { pickAndAddApplication() }
                Toggle("Show All Running Apps", isOn: $service.showAllApps)
                Divider()
                Button("Reconnect Audio", systemImage: "arrow.clockwise") { service.reconnectAll() }
                Button("Screen & System Audio Recording…", systemImage: "lock.shield") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Open Mixer Panel", systemImage: "slider.horizontal.3") { service.showPanel() }
            } label: {
                Label("Audio Options", systemImage: "ellipsis.circle")
            }
            .help("Applications, recovery and permissions")
        }
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        if !service.soundEnabled {
            AOMNotice(.warning, "App audio is off", detail: "Audio plays directly; your app and effect settings are saved.") {
                Button("Turn On") { service.soundEnabled = true }.aomPrimaryButton().controlSize(.small)
            }
        }
        if service.competingMixer != nil && service.soundEnabled {
            AOMNotice(.warning, "SoundSource is also running", detail: "Two mixers can compete for the same audio.") {
                Button("Quit SoundSource & Reconnect") { service.quitCompetingMixer() }.controlSize(.small)
            }
        }
        if service.airPlayRecovering {
            AOMNotice(.info, "Reconnecting HomePod", detail: "Playback continues natively until the receiver answers again.")
        }
        if let error = service.lastError, !service.airPlayRecovering {
            AOMNotice(.warning, "Audio needs attention", detail: error) {
                Button("Reconnect") { service.reconnectAll() }.controlSize(.small)
            }
        }
    }

    // MARK: System devices

    private var devicesCard: some View {
        AOMSectionCard("System Devices", symbol: "speaker.wave.2", contentPadding: 0) {
            VStack(spacing: 0) {
                OutputDeviceRow(expanded: $expandedOutput)
                if expandedOutput {
                    OutputEffectsPanel(service: service)
                        .transition(.opacity)
                }
                AOMDivider().padding(.leading, 54)
                InputDeviceRow()
                AOMDivider().padding(.leading, 54)
                SoundEffectsRow()
            }
            .animation(AOMMotion.panel, value: expandedOutput)
        }
    }

    // MARK: Applications

    private var applicationsCard: some View {
        let lists = service.listedApps(matching: searchText)
        let total = lists.favorites.count + lists.active.count + lists.other.count
        return AOMSectionCard("Applications", symbol: "square.grid.2x2", detail: total > 0 ? "\(total)" : nil, contentPadding: 0,
                              accessory: {
            Button { pickAndAddApplication() } label: { Label("Add", systemImage: "plus") }
                .controlSize(.small)
                .help("Add an application to your favourites")
        }) {
            if !service.isSupported {
                emptyState("Per-app audio needs macOS 14.2 or newer", symbol: "exclamationmark.triangle")
            } else if total == 0 {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    emptyState("No applications match “\(searchText)”", symbol: "magnifyingglass") {
                        Button("Clear Filter") { searchText = "" }
                    }
                } else {
                    emptyState("No app is playing audio", symbol: "waveform",
                               detail: "Apps appear here while they play and for a minute afterwards. Star an app to keep it listed.") {
                        Button("Show All Running Apps") { service.showAllApps = true }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    section("Favorites", lists.favorites)
                    section(lists.favorites.isEmpty ? nil : "Playing & Adjusted", lists.active)
                    section("Other Running Apps", lists.other)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String?, _ rows: [AppAudioState]) -> some View {
        if !rows.isEmpty {
            if let title {
                HStack {
                    Text(title).font(AOMType.caption.weight(.semibold)).foregroundStyle(AOMTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, AOMSpace.m)
                .padding(.top, AOMSpace.s)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            }
            ForEach(rows) { app in
                ApplicationAudioRow(app: app)
                if app.id != rows.last?.id { AOMDivider().padding(.leading, 54) }
            }
        }
    }

    private func emptyState<Actions: View>(_ title: String, symbol: String, detail: String? = nil,
                                           @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        VStack(spacing: AOMSpace.xs) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(AOMType.headline)
            if let detail {
                Text(detail).font(AOMType.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            actions().controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(AOMSpace.xl)
    }

    private func pickAndAddApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        service.addCustomApp(url: url)
        if !service.isFavorite(bundleID) { service.toggleFavorite(bundleID) }
    }
}

// MARK: - Device rows

/// A leading glyph in a tinted rounded square, the System Settings row icon.
private struct DeviceGlyph: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct OutputDeviceRow: View {
    @Binding var expanded: Bool
    @ObservedObject private var service = AppAudioMixerService.shared
    @State private var devices: [AudioOutputDevice] = []
    @State private var isSwitchingOutput = false
    @State private var volume: Double = 50
    @State private var isMuted = false
    @State private var canAdjustVolume = false

    var body: some View {
        HStack(spacing: AOMSpace.s) {
            DeviceGlyph(symbol: "hifispeaker.fill", tint: .blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Output").font(AOMType.headline)
                Picker("Output device", selection: Binding(
                    get: { currentUID },
                    set: { uid in
                        // Only a real user choice may change the system default:
                        // a reconnecting AirPlay device re-syncs the picker by
                        // itself and must not pull every app onto it.
                        guard !isSwitchingOutput, uid != currentUID, !uid.isEmpty,
                              let device = devices.first(where: { $0.uid == uid }) else { return }
                        isSwitchingOutput = true
                        AudioOutputService.shared.select(name: device.name, uid: device.uid) { _ in
                            isSwitchingOutput = false
                            refresh()
                        }
                    })) {
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .frame(minWidth: 150, alignment: .leading)
            Spacer(minLength: AOMSpace.xs)
            Button {
                AudioOutputService.shared.toggleOutputMute { _ in refresh() }
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(isMuted ? AOMTheme.danger : AOMTheme.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isMuted ? "Unmute output" : "Mute output")
            .help(isMuted ? "Unmute output" : "Mute output")
            Slider(value: Binding(get: { volume }, set: { newValue in
                volume = newValue
                isMuted = false
                AudioOutputService.shared.setVolume(percent: newValue) { _ in }
            }), in: 0...100)
            .controlSize(.small)
            .frame(minWidth: 120, maxWidth: 260)
            .disabled(!canAdjustVolume)
            .accessibilityLabel("Output volume")
            .accessibilityValue("\(Int(volume.rounded())) percent")
            .help(canAdjustVolume ? "Output volume" : "This output does not support volume control")
            Text(canAdjustVolume ? "\(Int(volume.rounded()))%" : "—")
                .font(AOMType.caption.monospacedDigit())
                .foregroundStyle(AOMTheme.textSecondary)
                .frame(width: 38, alignment: .trailing)
            MagicBoostButton(isOn: service.allAppsBoostEnabled, label: "Magic Boost for the output") {
                service.allAppsBoostEnabled.toggle()
            }
            .disabled(!service.isSupported)
            DisclosureButton(expanded: $expanded, label: "Output effects")
        }
        .padding(.horizontal, AOMSpace.m)
        .padding(.vertical, 10)
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
        isMuted = AudioOutputService.isOutputMuted()
    }
}

/// Expanded output controls: equalizer, balance and HomePod effects.
private struct OutputEffectsPanel: View {
    @ObservedObject var service: AppAudioMixerService
    @State private var balance: Float = 0
    @State private var canAdjustBalance = false
    @State private var showEQ = false

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.s) {
            HStack(spacing: AOMSpace.s) {
                Toggle("Equalizer", isOn: $service.eqEnabled).toggleStyle(.switch).controlSize(.small)
                Picker("Output equalizer preset", selection: $service.eqPreset) {
                    ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                    if service.eqPreset == "Custom" { Text("Custom").tag("Custom") }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .disabled(!service.eqEnabled)
                Button("Edit…") { showEQ = true }.controlSize(.small)
                    .accessibilityLabel("Edit the output equalizer")
                Spacer()
            }
            HStack(spacing: AOMSpace.xs) {
                Text("Balance").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary).frame(width: 64, alignment: .leading)
                Text("L").font(.caption2.weight(.semibold)).foregroundStyle(AOMTheme.textTertiary)
                Slider(value: Binding(get: { Double(balance) }, set: { newValue in
                    balance = Float(newValue)
                    AudioOutputService.setBalance(balance)
                }), in: -1...1, step: 0.05)
                .controlSize(.small)
                .frame(maxWidth: 240)
                .disabled(!canAdjustBalance)
                .accessibilityLabel("Output balance")
                .accessibilityValue(balance == 0 ? "Center" : "\(Int(abs(balance) * 100)) percent \(balance < 0 ? "left" : "right")")
                Text("R").font(.caption2.weight(.semibold)).foregroundStyle(AOMTheme.textTertiary)
                Button("Center") { balance = 0; AudioOutputService.setBalance(0) }
                    .controlSize(.small).disabled(!canAdjustBalance || balance == 0)
                Spacer()
            }
            AirPlayProcessingControls(service: service)
        }
        .padding(.horizontal, AOMSpace.m)
        .padding(.leading, 40)
        .padding(.bottom, AOMSpace.s)
        .onAppear {
            canAdjustBalance = AudioOutputService.canAdjustBalance()
            balance = AudioOutputService.currentBalance()
        }
        .sheet(isPresented: $showEQ) {
            EqualizerSheet(title: "Output Equalizer", subtitle: "Applies after each app’s own equalizer",
                           enabled: $service.eqEnabled, preset: $service.eqPreset,
                           gains: service.eqGains, onBand: { service.setBand($0, gain: $1) },
                           onDone: { showEQ = false })
        }
    }
}

private struct InputDeviceRow: View {
    @State private var devices: [AudioOutputDevice] = []
    @State private var volume: Double = 80
    @State private var isMuted = false
    @State private var canAdjustVolume = false
    @State private var canMute = false

    var body: some View {
        HStack(spacing: AOMSpace.s) {
            DeviceGlyph(symbol: "mic.fill", tint: .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Input").font(AOMType.headline)
                Picker("Input device", selection: Binding(
                    get: { currentUID },
                    set: { uid in AudioOutputService.selectInput(uid: uid); refresh() })) {
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
            .frame(minWidth: 150, alignment: .leading)
            Spacer(minLength: AOMSpace.xs)
            Button {
                if let next = AudioOutputService.toggleInputMute() { isMuted = next }
            } label: {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(isMuted ? AOMTheme.danger : AOMTheme.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(!canMute)
            .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
            .help(canMute ? (isMuted ? "Unmute microphone" : "Mute microphone") : "This input does not support mute")
            Slider(value: Binding(get: { volume }, set: { newValue in
                volume = newValue
                if AudioOutputService.setInputVolume(percent: newValue) {
                    isMuted = AudioOutputService.isInputMuted()
                } else { refresh() }
            }), in: 0...100)
            .controlSize(.small)
            .frame(minWidth: 120, maxWidth: 260)
            .disabled(!canAdjustVolume)
            .accessibilityLabel("Microphone input volume")
            .accessibilityValue("\(Int(volume.rounded())) percent")
            Text(canAdjustVolume ? "\(Int(volume.rounded()))%" : "—")
                .font(AOMType.caption.monospacedDigit())
                .foregroundStyle(AOMTheme.textSecondary)
                .frame(width: 38, alignment: .trailing)
            // Keeps the columns aligned with the output row.
            Color.clear.frame(width: 26 + 26 + AOMSpace.s, height: 1)
        }
        .padding(.horizontal, AOMSpace.m)
        .padding(.vertical, 10)
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

private struct SoundEffectsRow: View {
    @State private var volume: Double = 65
    @State private var isMuted = false
    @State private var previousVolume: Double = 65

    var body: some View {
        HStack(spacing: AOMSpace.s) {
            DeviceGlyph(symbol: "bell.fill", tint: .purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sound Effects").font(AOMType.headline)
                Text("Alerts and notification sounds").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
            }
            .frame(minWidth: 150, alignment: .leading)
            Spacer(minLength: AOMSpace.xs)
            Button {
                if !isMuted, volume > 0 { previousVolume = volume }
                let target = isMuted ? previousVolume : 0
                if AudioOutputService.setSystemAlertVolume(percent: target) {
                    volume = target
                    isMuted = target == 0
                }
            } label: {
                Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
                    .foregroundStyle(isMuted ? AOMTheme.danger : AOMTheme.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isMuted ? "Unmute system alerts" : "Mute system alerts")
            Slider(value: Binding(get: { volume }, set: { newValue in
                volume = newValue
                isMuted = newValue == 0
                if newValue > 0 { previousVolume = newValue }
                AudioOutputService.setSystemAlertVolume(percent: newValue)
            }), in: 0...100)
            .controlSize(.small)
            .frame(minWidth: 120, maxWidth: 260)
            .accessibilityLabel("System alert volume")
            .accessibilityValue("\(Int(volume.rounded())) percent")
            Text("\(Int(volume.rounded()))%")
                .font(AOMType.caption.monospacedDigit())
                .foregroundStyle(AOMTheme.textSecondary)
                .frame(width: 38, alignment: .trailing)
            Color.clear.frame(width: 26 + 26 + AOMSpace.s, height: 1)
        }
        .padding(.horizontal, AOMSpace.m)
        .padding(.vertical, 10)
        .onAppear {
            volume = Double(AudioOutputService.currentSystemAlertVolume() ?? 0.65) * 100
            isMuted = volume == 0
            if volume > 0 { previousVolume = volume }
        }
    }
}

// MARK: - Shared row controls

/// SoundSource's Magic Boost button: a sparkle that lights when on.
private struct MagicBoostButton: View {
    let isOn: Bool
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : AOMTheme.textSecondary)
                .frame(width: 26, height: 22)
                .background(isOn ? AnyShapeStyle(Color.indigo.gradient) : AnyShapeStyle(.quaternary.opacity(0.7)),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .help(isOn ? "Magic Boost on — quiet passages are raised without overdriving loud audio" : "Magic Boost")
    }
}

private struct DisclosureButton: View {
    @Binding var expanded: Bool
    let label: String
    var body: some View {
        Button { withAnimation(AOMMotion.panel) { expanded.toggle() } } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .foregroundStyle(AOMTheme.textSecondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .help(expanded ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
    }
}

// MARK: - Application row

private struct ApplicationAudioRow: View {
    @ObservedObject private var service = AppAudioMixerService.shared
    let app: AppAudioState
    @State private var gain: Float
    @State private var balance: Float
    @State private var expanded = false
    @State private var showEQ = false
    @State private var availableOutputs: [AudioOutputDevice] = []

    init(app: AppAudioState) {
        self.app = app
        _gain = State(initialValue: min(max(app.gain, 0), 1))
        _balance = State(initialValue: AudioBalance.clamp(app.balance))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AOMSpace.s) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(app.name).font(AOMType.body.weight(.semibold)).lineLimit(1)
                        if app.isPlaying {
                            Image(systemName: "waveform").font(.caption2).foregroundStyle(AOMTheme.positive)
                                .accessibilityLabel("Playing")
                        }
                    }
                    if app.tapped {
                        AppAudioLevelMeter(pid: app.pid).frame(maxWidth: 110)
                    } else {
                        Text(app.error ?? app.processingStatus)
                            .font(AOMType.micro)
                            .foregroundStyle(app.error == nil ? AOMTheme.textTertiary : AOMTheme.warning)
                            .lineLimit(1)
                            .help(app.error ?? app.processingStatus)
                    }
                }
                .frame(minWidth: 150, alignment: .leading)
                Spacer(minLength: AOMSpace.xs)
                Button { _ = service.toggleMute(bundleID: app.bundleID) } label: {
                    Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(app.muted ? AOMTheme.danger : AOMTheme.textSecondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                .help(service.timedMuteEnds[app.bundleID].map { "Muted until \($0.formatted(date: .omitted, time: .standard))" }
                      ?? (app.muted ? "Unmute" : "Mute"))
                Slider(value: Binding(get: { Double(gain) }, set: {
                    gain = Float($0); service.setGain(gain, bundleID: app.bundleID)
                }), in: 0...1)
                .controlSize(.small)
                .frame(minWidth: 120, maxWidth: 260)
                .accessibilityLabel("Volume for \(app.name)")
                .accessibilityValue("\(Int((gain * 100).rounded())) percent")
                Text(volumeLabel)
                    .font(AOMType.caption.monospacedDigit())
                    .foregroundStyle(app.overdrive > 1.0001 ? AOMTheme.warning : AOMTheme.textSecondary)
                    .frame(width: 38, alignment: .trailing)
                    .help(app.overdrive > 1.0001 ? "Volume Overdrive \(Int((app.overdrive * 100).rounded()))%" : "Volume")
                MagicBoostButton(isOn: app.magicBoost, label: "Magic Boost for \(app.name)") {
                    service.toggleMagicBoost(bundleID: app.bundleID)
                }
                DisclosureButton(expanded: $expanded, label: "Effects for \(app.name)")
            }
            .padding(.horizontal, AOMSpace.m)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contextMenu { contextMenu }

            if expanded { effects }
        }
        .sheet(isPresented: $showEQ) {
            EqualizerSheet(title: "Equalizer", subtitle: app.name,
                           enabled: Binding(get: { service.appEQEnabled(app.bundleID) },
                                            set: { service.setAppEQEnabled($0, bundleID: app.bundleID) }),
                           preset: Binding(get: { service.appEQPreset(app.bundleID) },
                                           set: { service.setAppEQPreset($0, bundleID: app.bundleID) }),
                           gains: service.appEQGains(app.bundleID),
                           onBand: { service.setAppBand($0, gain: $1, bundleID: app.bundleID) },
                           onDone: { showEQ = false })
        }
        .onChange(of: app.gain) { _, value in gain = min(max(value, 0), 1) }
        .onChange(of: app.balance) { _, value in balance = AudioBalance.clamp(value) }
        .onChange(of: expanded) { _, shown in if shown { availableOutputs = AudioOutputService.devices() } }
    }

    private var volumeLabel: String {
        let percent = Int((gain * app.overdrive * 100).rounded())
        return "\(percent)%"
    }

    @ViewBuilder private var contextMenu: some View {
        Button(service.isFavorite(app.bundleID) ? "Remove from Favorites" : "Add to Favorites",
               systemImage: service.isFavorite(app.bundleID) ? "star.slash" : "star") {
            service.toggleFavorite(app.bundleID)
        }
        Menu("Timed Mute") { timedMuteItems }
        Divider()
        Button("Reset Effects") { resetEffects() }
        Button("Reconnect") { service.reconnect(pid: app.pid) }.disabled(app.pid <= 0 || !service.soundEnabled)
    }

    @ViewBuilder private var timedMuteItems: some View {
        Button("30 Seconds") { service.timedMute(bundleID: app.bundleID, seconds: 30) }
        Button("1 Minute") { service.timedMute(bundleID: app.bundleID, seconds: 60) }
        Button("2 Minutes") { service.timedMute(bundleID: app.bundleID, seconds: 120) }
        if service.timedMuteEnds[app.bundleID] != nil {
            Divider()
            Button("End Timed Mute") { service.cancelTimedMute(bundleID: app.bundleID) }
        }
    }

    private var effects: some View {
        VStack(alignment: .leading, spacing: AOMSpace.s) {
            HStack(spacing: AOMSpace.s) {
                Text("Volume Overdrive").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 112, alignment: .leading)
                Slider(value: Binding(get: { Double(app.overdrive) },
                                      set: { service.setOverdrive(Float($0), bundleID: app.bundleID) }),
                       in: 1...Double(AudioVolumeOverdrive.maximum), step: 0.05)
                .controlSize(.small)
                .frame(maxWidth: 240)
                .accessibilityLabel("Volume Overdrive for \(app.name)")
                .accessibilityValue("\(Int((app.overdrive * 100).rounded())) percent")
                Text("\(Int((app.overdrive * 100).rounded()))%")
                    .font(AOMType.caption.monospacedDigit())
                    .foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 40, alignment: .trailing)
                Text("Up to 400 %, limited so loud audio never clips")
                    .font(AOMType.micro).foregroundStyle(AOMTheme.textTertiary)
                Spacer()
            }
            HStack(spacing: AOMSpace.s) {
                Text("Balance").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 112, alignment: .leading)
                HStack(spacing: AOMSpace.xs) {
                    Text("L").font(.caption2.weight(.semibold)).foregroundStyle(AOMTheme.textTertiary)
                        .accessibilityHidden(true)
                    Slider(value: Binding(get: { Double(balance) }, set: { newValue in
                        balance = AudioBalance.stepped(Float(newValue))
                        service.setBalance(balance, bundleID: app.bundleID)
                    }), in: -1...1, step: 0.01)
                    .controlSize(.small)
                    .accessibilityLabel("Balance for \(app.name)")
                    .accessibilityValue(AudioBalance.spokenValue(balance))
                    .accessibilityAction(named: "Center") { centerBalance() }
                    Text("R").font(.caption2.weight(.semibold)).foregroundStyle(AOMTheme.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: 240)
                Text(AudioBalance.shortLabel(balance))
                    .font(AOMType.caption.monospacedDigit())
                    .foregroundStyle(AOMTheme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
                Button("Center") { centerBalance() }
                    .controlSize(.small)
                    .disabled(balance == 0)
                    .accessibilityLabel("Center balance for \(app.name)")
                    .help("Equal left and right")
                Spacer()
            }
            HStack(spacing: AOMSpace.s) {
                Text("Equalizer").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 112, alignment: .leading)
                Toggle("Equalizer for \(app.name)", isOn: Binding(get: { service.appEQEnabled(app.bundleID) },
                                                                    set: { service.setAppEQEnabled($0, bundleID: app.bundleID) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                Picker("Equalizer preset for \(app.name)", selection: Binding(
                    get: { service.appEQPreset(app.bundleID) },
                    set: { service.setAppEQPreset($0, bundleID: app.bundleID) })) {
                    ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                    if service.appEQPreset(app.bundleID) == "Custom" { Text("Custom").tag("Custom") }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                Button("Edit…") { showEQ = true }.controlSize(.small)
                Spacer()
            }
            HStack(spacing: AOMSpace.s) {
                Text("Output").font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 112, alignment: .leading)
                Picker("Output for \(app.name)", selection: Binding(
                    get: { app.outputDeviceUID ?? "" },
                    set: { service.setOutputRoute(uid: $0.isEmpty ? nil : $0, bundleID: app.bundleID) })) {
                    Text("System Default").tag("")
                    if let uid = app.outputDeviceUID, !availableOutputs.contains(where: { $0.uid == uid }) {
                        Text("Disconnected — using default").tag(uid)
                    }
                    ForEach(availableOutputs) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                Spacer()
                Menu("Timed Mute") { timedMuteItems }
                    .controlSize(.small).fixedSize()
                Button(service.isFavorite(app.bundleID) ? "Unfavorite" : "Favorite",
                       systemImage: service.isFavorite(app.bundleID) ? "star.fill" : "star") {
                    service.toggleFavorite(app.bundleID)
                }
                .controlSize(.small)
                Button("Reset") { resetEffects() }.controlSize(.small)
                    .help("Volume 100 %, balance centred, no overdrive, boost or equalizer")
            }
            if let error = app.error {
                HStack(spacing: AOMSpace.xs) {
                    Label(error, systemImage: "exclamationmark.triangle").font(AOMType.caption).foregroundStyle(AOMTheme.warning)
                    Spacer()
                    Button("Reconnect") { service.reconnect(pid: app.pid) }.controlSize(.small)
                        .disabled(app.pid <= 0 || !service.soundEnabled)
                }
            } else {
                Text(app.processingStatus).font(AOMType.micro).foregroundStyle(AOMTheme.textTertiary)
            }
        }
        .padding(.horizontal, AOMSpace.m)
        .padding(.leading, 42)
        .padding(.bottom, AOMSpace.s)
    }

    private func resetEffects() {
        gain = 1
        service.setGain(1, bundleID: app.bundleID)
        service.setOverdrive(1, bundleID: app.bundleID)
        centerBalance()
        if app.magicBoost { service.toggleMagicBoost(bundleID: app.bundleID) }
        service.setAppEQEnabled(false, bundleID: app.bundleID)
    }

    private func centerBalance() {
        balance = 0
        service.setBalance(0, bundleID: app.bundleID)
    }

    @ViewBuilder private var appIcon: some View {
        if let icon = app.icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 15))
                .foregroundStyle(AOMTheme.textSecondary).frame(width: 28, height: 28)
                .background(AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Equalizer sheet

/// The 10-band equalizer in a focused sheet (SoundSource's EQ popover).
private struct EqualizerSheet: View {
    let title: String
    let subtitle: String
    @Binding var enabled: Bool
    @Binding var preset: String
    let gains: [Float]
    let onBand: (Int, Float) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AOMType.title3)
                    Text(subtitle).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
                }
                Spacer()
                Toggle("Enabled", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
                Picker("Preset", selection: $preset) {
                    ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                    if preset == "Custom" { Text("Custom").tag("Custom") }
                }
                .controlSize(.small).fixedSize()
                Button("Flat") { preset = "Flat" }.controlSize(.small)
                Button("Done", action: onDone).keyboardShortcut(.defaultAction).aomPrimaryButton()
            }
            AudioEqualizerControls(gains: gains, enabled: enabled, onChange: onBand)
            Text("Boosted bands lower the overall level first so loud passages stay clean; Magic Boost restores loudness.")
                .font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary)
        }
        .padding(AOMSpace.l)
        .frame(minWidth: 780, idealWidth: 800)
    }
}
