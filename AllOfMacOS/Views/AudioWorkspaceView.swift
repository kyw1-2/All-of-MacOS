import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Audio, arranged like SoundSource's one window: the system devices on top
/// (output, input, sound effects), the applications below. Frequent controls
/// — volume, mute, Magic Boost, routing — sit on each one-line row; effects
/// (Volume Overdrive, equalizer, timed mute) open in place. The header holds
/// the App Audio switch; the toolbar the application filter and recovery
/// options.
struct AudioWorkspaceView: View {
    @ObservedObject private var service = AppAudioMixerService.shared
    @State private var searchText = ""
    @State private var expandedOutput = false

    var body: some View {
        AOMPage {
            header
            notices
            devicesCard
            // 3.3.3: output-wide effects follow the devices (and the output
            // equalizer inside them), before the per-app list.
            HeadphoneEQCard()
            AudioUnitEffectCard()
            applicationsCard
        }
        .aomPage("Audio")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter Apps")
        .toolbar { toolbarContent }
        .onAppear { service.beginMetering(); service.refresh() }
        .onDisappear { service.endMetering() }
    }

    // MARK: Header (d.9)

    /// The page's one status: what App Audio is doing, one line of context and
    /// its master switch. Off is a state, not a warning (e.6).
    private var header: some View {
        AOMPageHeader(headerTitle, module: .audio, subtitle: subtitle,
                      help: "App Audio sends each app through AOM, so every app gets its own volume, Magic Boost and equalizer. Turned off, audio plays directly and every setting is kept.",
                      active: service.isSupported && service.soundEnabled) {
            if service.isSupported {
                Toggle("App Audio", isOn: $service.soundEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(service.soundEnabled ? "Turn off app audio processing" : "Turn on app audio processing")
                    .accessibilityLabel("App audio processing")
            }
        }
    }

    private var headerTitle: String {
        guard service.isSupported else { return "Per-app audio isn't available" }
        return service.soundEnabled ? "App audio is on" : "App audio is off"
    }

    /// One line, in the Workspace tile's words.
    private var subtitle: String {
        guard service.isSupported else { return "Per-app audio needs macOS 14.2 or newer" }
        guard service.soundEnabled else { return "Apps play directly · settings kept" }
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

    /// Only what needs a decision; App Audio being off is the header's status.
    @ViewBuilder private var notices: some View {
        if service.competingMixer != nil && service.soundEnabled {
            AOMNotice(.warning, "SoundSource is also running", detail: "Two mixers can compete for the same audio.") {
                Button("Quit SoundSource & Reconnect") { service.quitCompetingMixer() }
            }
        }
        if service.airPlayRecovering {
            AOMNotice(.info, "Reconnecting HomePod", detail: "Playback continues natively until the receiver answers again.")
        }
        if let error = service.lastError, !service.airPlayRecovering {
            AOMNotice(.warning, "Audio needs attention", detail: error) {
                Button("Reconnect") { service.reconnectAll() }
            }
        }
    }

    // MARK: System devices

    private var devicesCard: some View {
        AOMSectionCard("System devices", symbol: "speaker.wave.2", contentPadding: 0) {
            VStack(spacing: 0) {
                OutputDeviceRow(expanded: $expandedOutput)
                if expandedOutput {
                    OutputEffectsPanel(service: service)
                        .transition(.opacity)
                }
                AOMRowDivider(inset: AOMSpace.rowSymbolInset)
                InputDeviceRow()
                AOMRowDivider(inset: AOMSpace.rowSymbolInset)
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
            Button { pickAndAddApplication() } label: { Label("Add…", systemImage: "plus") }
                .controlSize(.small)
                .help("Choose an application to add to your favorites")
        }) {
            if !service.isSupported {
                emptyState("App controls need macOS 14.2", symbol: "exclamationmark.triangle",
                           message: "The system devices above work on this Mac; per-app volume and effects need macOS 14.2 or newer.")
            } else if total == 0 {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    emptyState("No applications match “\(searchText)”", symbol: "magnifyingglass",
                               message: "Try another app name or bundle identifier.") {
                        Button("Clear Filter") { searchText = "" }
                    }
                } else {
                    emptyState("No app is playing audio", symbol: "waveform",
                               message: "Apps appear here while they play and for a minute afterwards. Add an app to keep it listed.") {
                        Button("Show All Running Apps") { service.showAllApps = true }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    section("Favorites", lists.favorites)
                    section(lists.favorites.isEmpty ? nil : "Playing & adjusted", lists.active)
                    section("Other running apps", lists.other)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String?, _ rows: [AppAudioState]) -> some View {
        if !rows.isEmpty {
            if let title {
                Text(title)
                    .aomSectionCaps()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AOMSpace.rowInset)
                    .padding(.top, AOMSpace.x3)
                    .padding(.bottom, AOMSpace.x0_5)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(rows) { app in
                ApplicationAudioRow(app: app)
                if app.id != rows.last?.id { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
            }
        }
    }

    /// The card's empty states: the shared `AOMEmptyState`, as on Clipboard and Insights.
    private func emptyState<Actions: View>(_ title: String, symbol: String, message: String,
                                           @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        AOMEmptyState(title, systemImage: symbol, message: message, actions: actions)
            .padding(.vertical, AOMSpace.x6)
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

// MARK: - Row metrics

/// Sizes the device and application rows share, so every row's trailing
/// controls line up. No design token covers them.
private enum AudioRowMetrics {
    /// Mute, Magic Boost and disclosure buttons: the icon-button hit width
    /// and a small control's height, so rows stay one control tall.
    static let buttonWidth = AOMIcon.hitArea
    static let buttonHeight: CGFloat = 22
    /// A row's volume slider grows between these widths.
    static let sliderMinWidth: CGFloat = 120
    static let sliderMaxWidth: CGFloat = 260
    /// Output and Input share one title width, so their device pickers line up.
    static let deviceTitleWidth = AOMSpace.x12
    /// An app's name column never narrows below this.
    static let nameMinWidth: CGFloat = 150
    /// The label column of an expanded row's settings ("Volume Overdrive" fits).
    static let panelLabelWidth: CGFloat = 112
    /// Magic Boost, its preset and the disclosure on the output and app rows.
    /// The input and sound-effect rows leave this much empty, so all sliders
    /// end in one column.
    static let boostColumnsWidth = buttonWidth * 2 + AudioBoostPresetPicker.menuWidth + AOMSpace.x3 * 2
}

private extension View {
    /// One device or app row: 12 pt insets, 8 pt above and below, at least 36 pt tall.
    func audioRowPadding() -> some View {
        padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x2)
            .frame(minHeight: AOMSize.rowStandard)
    }

    /// A row's volume slider.
    func audioRowSlider() -> some View {
        controlSize(.small)
            .frame(minWidth: AudioRowMetrics.sliderMinWidth, maxWidth: AudioRowMetrics.sliderMaxWidth)
    }
}

// MARK: - Device rows

/// A row's leading symbol: 20 pt and monochrome, like every settings row.
private struct DeviceGlyph: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(AOMFont.body)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(AOMColor.textSecondary)
            .frame(width: AOMIcon.row, height: AOMIcon.row)
            .accessibilityHidden(true)
    }
}

/// A device row's title, on the same line as its picker.
private struct DeviceTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(AOMFont.body)
            .foregroundStyle(AOMColor.text)
            .fixedSize()
            .frame(minWidth: AudioRowMetrics.deviceTitleWidth, alignment: .leading)
    }
}

/// The value after a row slider ("100%", "40% L").
private struct RowValue: View {
    let text: String
    var tint: Color = AOMColor.textSecondary
    var body: some View {
        Text(text)
            .font(AOMFont.caption.monospacedDigit())
            .foregroundStyle(tint)
            .lineLimit(1)
            .frame(width: AOMRowControlMetrics.valueWidth, alignment: .trailing)
    }
}

/// A row's mute button: the glyph turns red with a slash while muted.
private struct MuteButton: View {
    let symbol: String
    let muted: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(muted ? AOMColor.danger : AOMColor.textSecondary)
                .frame(width: AudioRowMetrics.buttonWidth, height: AudioRowMetrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

/// Keeps a row without Magic Boost aligned with the rows that have it.
private struct BoostColumnsPlaceholder: View {
    var body: some View {
        Color.clear
            .frame(width: AudioRowMetrics.boostColumnsWidth, height: 1)
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
        HStack(spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x2) {
                DeviceGlyph(symbol: "hifispeaker")
                DeviceTitle("Output")
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
            Spacer(minLength: AOMSpace.x2)
            MuteButton(symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", muted: isMuted) {
                AudioOutputService.shared.toggleOutputMute { _ in refresh() }
            }
            .accessibilityLabel(isMuted ? "Unmute output" : "Mute output")
            .help(isMuted ? "Unmute output" : "Mute output")
            Slider(value: Binding(get: { volume }, set: { newValue in
                volume = newValue
                isMuted = false
                AudioOutputService.shared.setVolume(percent: newValue) { _ in }
            }), in: 0...100)
            .audioRowSlider()
            .disabled(!canAdjustVolume)
            .accessibilityLabel("Output volume")
            .accessibilityValue("\(Int(volume.rounded())) percent")
            .help(canAdjustVolume ? "Output volume" : "This output does not support volume control")
            RowValue(text: canAdjustVolume ? "\(Int(volume.rounded()))%" : "—")
            MagicBoostButton(isOn: service.allAppsBoostEnabled, label: "Magic Boost for the output") {
                service.allAppsBoostEnabled.toggle()
            }
            .disabled(!service.isSupported)
            // 3.3.3: the output's Magic Boost preset, next to its switch like
            // every app row's; off while the output boost is off.
            AudioBoostPresetPicker(bundleID: nil, style: .menu)
                .disabled(!service.isSupported || !service.allAppsBoostEnabled)
            DisclosureButton(expanded: $expanded, label: "Output effects")
        }
        .audioRowPadding()
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

/// The label column of an expanded row's settings. The controls carry their
/// own accessibility labels, so VoiceOver skips this one.
private struct PanelLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(AOMFont.caption)
            .foregroundStyle(AOMColor.textSecondary)
            .lineLimit(1)
            .frame(width: AudioRowMetrics.panelLabelWidth, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// "L" and "R" at the ends of a balance slider.
private struct BalanceEnd: View {
    let side: String
    init(_ side: String) { self.side = side }
    var body: some View {
        Text(side)
            .font(AOMFont.badge.weight(.semibold))
            .foregroundStyle(AOMColor.textTertiary)
            .accessibilityHidden(true)
    }
}

/// Expanded output controls: equalizer, balance and HomePod effects, in the
/// same label column as an app's effects.
private struct OutputEffectsPanel: View {
    @ObservedObject var service: AppAudioMixerService
    @State private var balance: Float = 0
    @State private var canAdjustBalance = false
    @State private var showEQ = false

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x3) {
                PanelLabel("Equalizer")
                Toggle("Equalizer", isOn: $service.eqEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                Picker("Output equalizer preset", selection: $service.eqPreset) {
                    ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                    if service.eqPreset == "Custom" { Text("Custom").tag("Custom") }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .disabled(!service.eqEnabled)
                Button("Edit…") { showEQ = true }.controlSize(.small)
                    .accessibilityLabel("Edit the output equalizer")
                Spacer(minLength: 0)
            }
            HStack(spacing: AOMSpace.x3) {
                PanelLabel("Balance")
                HStack(spacing: AOMSpace.x1) {
                    BalanceEnd("L")
                    Slider(value: Binding(get: { Double(balance) }, set: { newValue in
                        balance = Float(newValue)
                        AudioOutputService.setBalance(balance)
                    }), in: -1...1, step: 0.05)
                    .controlSize(.small)
                    .accessibilityLabel("Output balance")
                    .accessibilityValue(balance == 0 ? "Center" : "\(Int(abs(balance) * 100)) percent \(balance < 0 ? "left" : "right")")
                    BalanceEnd("R")
                }
                .frame(width: AOMRowControlMetrics.sliderWidth)
                .disabled(!canAdjustBalance)
                RowValue(text: AudioBalance.shortLabel(balance))
                    .accessibilityHidden(true)
                Button("Center") { balance = 0; AudioOutputService.setBalance(0) }
                    .controlSize(.small).disabled(!canAdjustBalance || balance == 0)
                Spacer(minLength: 0)
            }
            AirPlayProcessingControls(service: service, labelWidth: AudioRowMetrics.panelLabelWidth)
        }
        .padding(.leading, AOMSpace.rowSymbolInset)
        .padding(.trailing, AOMSpace.rowInset)
        .padding(.bottom, AOMSpace.x3)
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
        HStack(spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x2) {
                DeviceGlyph(symbol: "mic")
                DeviceTitle("Input")
                Picker("Input device", selection: Binding(
                    get: { currentUID },
                    set: { uid in AudioOutputService.selectInput(uid: uid); refresh() })) {
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
            Spacer(minLength: AOMSpace.x2)
            MuteButton(symbol: isMuted ? "mic.slash.fill" : "mic.fill", muted: isMuted) {
                if let next = AudioOutputService.toggleInputMute() { isMuted = next }
            }
            .disabled(!canMute)
            .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
            .help(canMute ? (isMuted ? "Unmute microphone" : "Mute microphone") : "This input does not support mute")
            Slider(value: Binding(get: { volume }, set: { newValue in
                volume = newValue
                if AudioOutputService.setInputVolume(percent: newValue) {
                    isMuted = AudioOutputService.isInputMuted()
                } else { refresh() }
            }), in: 0...100)
            .audioRowSlider()
            .disabled(!canAdjustVolume)
            .accessibilityLabel("Microphone input volume")
            .accessibilityValue("\(Int(volume.rounded())) percent")
            RowValue(text: canAdjustVolume ? "\(Int(volume.rounded()))%" : "—")
            BoostColumnsPlaceholder()
        }
        .audioRowPadding()
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
        HStack(spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x2) {
                DeviceGlyph(symbol: "bell")
                DeviceTitle("Sound effects")
            }
            .help("Alerts and notification sounds")
            Spacer(minLength: AOMSpace.x2)
            MuteButton(symbol: isMuted ? "bell.slash.fill" : "bell.fill", muted: isMuted) {
                if !isMuted, volume > 0 { previousVolume = volume }
                let target = isMuted ? previousVolume : 0
                if AudioOutputService.setSystemAlertVolume(percent: target) {
                    volume = target
                    isMuted = target == 0
                }
            }
            .accessibilityLabel(isMuted ? "Unmute system alerts" : "Mute system alerts")
            .help(isMuted ? "Unmute system alerts" : "Mute system alerts")
            Slider(value: Binding(get: { volume }, set: { newValue in
                volume = newValue
                isMuted = newValue == 0
                if newValue > 0 { previousVolume = newValue }
                AudioOutputService.setSystemAlertVolume(percent: newValue)
            }), in: 0...100)
            .audioRowSlider()
            .accessibilityLabel("System alert volume")
            .accessibilityValue("\(Int(volume.rounded())) percent")
            RowValue(text: "\(Int(volume.rounded()))%")
            BoostColumnsPlaceholder()
        }
        .audioRowPadding()
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
        let shape = RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(AOMFont.callout.weight(.semibold))
                .foregroundStyle(isOn ? AOMTheme.onAccent(AOMTheme.indigo) : AOMColor.textSecondary)
                .frame(width: AudioRowMetrics.buttonWidth, height: AudioRowMetrics.buttonHeight)
                .background(isOn ? AOMTheme.indigo : AOMColor.track, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .help(isOn ? "Magic Boost on — quiet passages are raised without overdriving loud audio" : "Magic Boost")
    }
}

/// The trailing disclosure, drawn like `AOMDisclosureRows`: a chevron that
/// turns down while the row's effects are open.
private struct DisclosureButton: View {
    @Binding var expanded: Bool
    let label: String
    var body: some View {
        Button { withAnimation(AOMMotion.panel) { expanded.toggle() } } label: {
            Image(systemName: "chevron.right")
                .font(AOMFont.caption.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(AOMColor.textSecondary)
                .frame(width: AudioRowMetrics.buttonWidth, height: AudioRowMetrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .help(expanded ? "Hide \(sentenceLabel)" : "Show \(sentenceLabel)")
    }

    /// "Effects for Safari" → "effects for Safari": only the first letter is
    /// lowered, so app names keep their capitals.
    private var sentenceLabel: String { label.prefix(1).lowercased() + label.dropFirst() }
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
            HStack(spacing: AOMSpace.x3) {
                HStack(spacing: AOMSpace.x2) {
                    appIcon
                    VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                        HStack(spacing: AOMSpace.x1) {
                            Text(app.name).font(AOMFont.bodyEmphasis).lineLimit(1)
                            if app.isPlaying {
                                Image(systemName: "waveform").font(AOMFont.badge).foregroundStyle(AOMColor.success)
                                    .accessibilityLabel("Playing")
                            }
                        }
                        detailLine
                    }
                    .frame(minWidth: AudioRowMetrics.nameMinWidth, alignment: .leading)
                }
                Spacer(minLength: AOMSpace.x2)
                MuteButton(symbol: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", muted: app.muted) {
                    _ = service.toggleMute(bundleID: app.bundleID)
                }
                .accessibilityLabel(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                .help(service.timedMuteEnds[app.bundleID].map { "Muted until \($0.formatted(date: .omitted, time: .standard))" }
                      ?? (app.muted ? "Unmute" : "Mute"))
                Slider(value: Binding(get: { Double(gain) }, set: {
                    gain = Float($0); service.setGain(gain, bundleID: app.bundleID)
                }), in: 0...1)
                .audioRowSlider()
                .accessibilityLabel("Volume for \(app.name)")
                .accessibilityValue("\(Int((gain * 100).rounded())) percent")
                RowValue(text: volumeLabel, tint: app.overdrive > 1.0001 ? AOMColor.warningText : AOMColor.textSecondary)
                    .help(app.overdrive > 1.0001 ? "Volume Overdrive \(Int((app.overdrive * 100).rounded()))%" : "Volume")
                MagicBoostButton(isOn: app.magicBoost, label: "Magic Boost for \(app.name)") {
                    service.toggleMagicBoost(bundleID: app.bundleID)
                }
                // 3.3.3: this app's Magic Boost preset, next to its switch.
                AudioBoostPresetPicker(bundleID: app.bundleID, style: .menu)
                    .disabled(!app.magicBoost || app.bundleID.isEmpty)
                DisclosureButton(expanded: $expanded, label: "Effects for \(app.name)")
            }
            .audioRowPadding()
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

    /// Under the name: the live level while AOM processes the app, otherwise
    /// its status. While App Audio is off the page header already says so,
    /// so only an error is shown then.
    @ViewBuilder private var detailLine: some View {
        if app.tapped {
            AppAudioLevelMeter(pid: app.pid)
        } else if let error = app.error {
            Text(error)
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.warningText)
                .lineLimit(1)
                .help(error)
        } else if service.soundEnabled {
            Text(app.processingStatus)
                .font(AOMFont.caption)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
                .help(app.processingStatus)
        }
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

    /// The app's effects, one label column wide, under its name.
    private var effects: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x3) {
                PanelLabel("Volume Overdrive")
                Slider(value: Binding(get: { Double(app.overdrive) },
                                      set: { service.setOverdrive(Float($0), bundleID: app.bundleID) }),
                       in: 1...Double(AudioVolumeOverdrive.maximum), step: 0.05)
                .controlSize(.small)
                .frame(width: AOMRowControlMetrics.sliderWidth)
                .accessibilityLabel("Volume Overdrive for \(app.name)")
                .accessibilityValue("\(Int((app.overdrive * 100).rounded())) percent")
                .help("Up to 400%, limited so loud audio never clips")
                RowValue(text: "\(Int((app.overdrive * 100).rounded()))%")
                Spacer(minLength: 0)
            }
            HStack(spacing: AOMSpace.x3) {
                PanelLabel("Balance")
                HStack(spacing: AOMSpace.x1) {
                    BalanceEnd("L")
                    Slider(value: Binding(get: { Double(balance) }, set: { newValue in
                        balance = AudioBalance.stepped(Float(newValue))
                        service.setBalance(balance, bundleID: app.bundleID)
                    }), in: -1...1, step: 0.01)
                    .controlSize(.small)
                    .accessibilityLabel("Balance for \(app.name)")
                    .accessibilityValue(AudioBalance.spokenValue(balance))
                    .accessibilityAction(named: "Center") { centerBalance() }
                    BalanceEnd("R")
                }
                .frame(width: AOMRowControlMetrics.sliderWidth)
                RowValue(text: AudioBalance.shortLabel(balance))
                    .accessibilityHidden(true)
                Button("Center") { centerBalance() }
                    .controlSize(.small)
                    .disabled(balance == 0)
                    .accessibilityLabel("Center balance for \(app.name)")
                    .help("Equal left and right")
                Spacer(minLength: 0)
            }
            HStack(spacing: AOMSpace.x3) {
                PanelLabel("Equalizer")
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
                    .accessibilityLabel("Edit the equalizer for \(app.name)")
                Spacer(minLength: 0)
            }
            HStack(spacing: AOMSpace.x3) {
                PanelLabel("Output")
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
                Spacer(minLength: AOMSpace.x2)
                Menu("Timed Mute") { timedMuteItems }
                    .controlSize(.small).fixedSize()
                Button(service.isFavorite(app.bundleID) ? "Unfavorite" : "Favorite",
                       systemImage: service.isFavorite(app.bundleID) ? "star.fill" : "star") {
                    service.toggleFavorite(app.bundleID)
                }
                .controlSize(.small)
                Button("Reset") { resetEffects() }.controlSize(.small)
                    .help("Volume 100%, balance centered, no overdrive, boost or equalizer")
            }
            if let error = app.error {
                HStack(spacing: AOMSpace.x2) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.warningText)
                    Spacer(minLength: AOMSpace.x2)
                    Button("Reconnect") { service.reconnect(pid: app.pid) }.controlSize(.small)
                        .disabled(app.pid <= 0 || !service.soundEnabled)
                }
            } else if service.soundEnabled {
                Text(app.processingStatus)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
            }
        }
        .padding(.leading, AOMSpace.rowSymbolInset)
        .padding(.trailing, AOMSpace.rowInset)
        .padding(.bottom, AOMSpace.x3)
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

    /// The app's icon in the 20 pt row-symbol column, so app names start
    /// where the device titles do.
    @ViewBuilder private var appIcon: some View {
        if let icon = app.icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                .frame(width: AOMIcon.row, height: AOMIcon.row)
                .accessibilityHidden(true)
        } else {
            DeviceGlyph(symbol: "app.dashed")
        }
    }
}

// MARK: - Equalizer sheet

/// The 10-band equalizer in a focused sheet (SoundSource's EQ popover).
private struct EqualizerSheet: View {
    /// Wide enough for the header controls; the ten bands need less.
    private static let width: CGFloat = 640

    let title: String
    let subtitle: String
    @Binding var enabled: Bool
    @Binding var preset: String
    let gains: [Float]
    let onBand: (Int, Float) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text(title).font(AOMFont.pageStatus)
                    Text(subtitle).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
                Spacer(minLength: AOMSpace.x3)
                Toggle("Enabled", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
                Picker("Preset", selection: $preset) {
                    ForEach(Array(AudioEQ.presets.keys.sorted()), id: \.self) { Text($0).tag($0) }
                    if preset == "Custom" { Text("Custom").tag("Custom") }
                }
                .controlSize(.small).fixedSize()
                Button("Flat") { preset = "Flat" }.controlSize(.small)
                    .help("Set every band to 0 dB")
                Button("Done", action: onDone).keyboardShortcut(.defaultAction).aomPrimaryButton()
            }
            AudioEqualizerControls(gains: gains, enabled: enabled, onChange: onBand)
            Text("Boosted bands lower the overall level first so loud passages stay clean; Magic Boost restores loudness.")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
        }
        .padding(AOMSpace.x4)
        .frame(minWidth: Self.width, idealWidth: Self.width)
    }
}
