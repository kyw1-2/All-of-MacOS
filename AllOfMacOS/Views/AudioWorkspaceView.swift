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
    @State private var expandedOutput = true
    /// Confirmations for the page and its rows (design-3.4.0 b.5).
    @StateObject private var toast = AOMToastModel()
    /// When the apps were last re-read on selecting the page.
    @State private var refreshClock = AOMRefreshClock()
    private static let refreshInterval: TimeInterval = 5
    /// D17/D18: the mixer on the left, the selected app's effects in a
    /// trailing inspector when the page has room for both.
    @AppStorage("AOMAudioInspector") private var showsInspector = true
    @State private var inspectorFits = false
    @State private var selectedBundleID: String?

    private var inspectorShown: Bool { showsInspector && inspectorFits && service.isSupported }

    /// Every app the list shows, in its order (favorites, active, other, hidden).
    private var listedApps: [AppAudioState] {
        let lists = service.listedApps(matching: searchText)
        return lists.favorites + lists.active + lists.other + service.hiddenListed(matching: searchText)
    }

    private var selectedApp: AppAudioState? {
        guard let id = selectedBundleID else { return nil }
        return listedApps.first { $0.bundleID == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            AOMPage {
                header
                notices
                devicesCard
                // The microphone mute section sits under the input device it
                // mutes (drawn by its module).
                applicationsCard
                MicMuteSection()
                // Output-wide effects follow the devices (and the output
                // equalizer inside them), before the per-app list.
                HeadphoneEQCard()
                AudioUnitEffectCard()
            }
            if inspectorShown {
                AOMDivider(axis: .vertical)
                audioInspector
                    .frame(width: AOMSize.inspectorIdeal)
                    .frame(maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Inspector")
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateInspectorFits(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in updateInspectorFits(width) }
            }
        }
        .onChange(of: listedApps.map(\.bundleID)) { _, ids in reconcileSelection(ids) }
        .onAppear { reconcileSelection(listedApps.map(\.bundleID)) }
        .aomPage("Audio")
        .aomPageToolbar {
            toolbarContent
            AOMToolbarSearchItem(text: $searchText, prompt: "Filter Apps")
        }
        .environmentObject(toast)
        .aomToast(toast)
        // Levels are metered while Audio is the selected page and on screen.
        // The apps are re-read too, unless that happened in the last few seconds.
        .aomOnPageVisibilityChange { visible in
            guard visible else { service.endMetering(); return }
            service.beginMetering()
            if refreshClock.remaining(of: Self.refreshInterval) == 0 {
                refreshClock.mark()
                service.refresh()
            }
        }
    }

    // MARK: Inspector (D18)

    /// The mixer keeps at least this much beside the inspector.
    private static let mixerMinimum: CGFloat = 600

    private func updateInspectorFits(_ width: CGFloat) {
        let fits = AOMWorkbenchPolicy.sideBySide(
            available: width, minimum: Self.mixerMinimum + AOMSize.inspectorIdeal + AOMWorkbenchPolicy.dividerAllowance,
            current: inspectorFits)
        if fits != inspectorFits { inspectorFits = fits }
    }

    /// The selected app stays while it is listed; the filter never moves it
    /// to another app (D05). Without a filter the first listed app is shown.
    private func reconcileSelection(_ ids: [String]) {
        let next = AOMStableSelection.reconcile(selectedBundleID, visible: ids.filter { !$0.isEmpty },
                                                autoSelectFirst: searchText.trimmingCharacters(in: .whitespaces).isEmpty)
        if next != selectedBundleID { selectedBundleID = next }
    }

    private var audioInspector: some View {
        AOMInspector {
            if let app = selectedApp {
                AOMInspectorSection(app.name, showsDivider: false) {
                    AOMInspectorRow("Status", text: app.muted ? "Muted" : (app.isPlaying ? "Playing" : "Silent"))
                    AOMInspectorRow("Volume", text: "\(Int((min(max(app.gain, 0), 1) * app.overdrive * 100).rounded()))%")
                    AOMInspectorRow("Magic Boost", text: app.magicBoost ? "On" : "Off")
                    AOMInspectorRow("Output", text: app.outputDeviceUID == nil ? "System Default" : "Routed to its own output")
                    if let ends = service.timedMuteEnds[app.bundleID] {
                        AOMInspectorRow("Muted until", text: ends.formatted(date: .omitted, time: .shortened))
                    }
                }
                AOMInspectorSection("Effects") {
                    ApplicationAudioEffects(app: app, stacked: true)
                        .id(app.bundleID)
                }
            } else {
                AOMInspectorSection("Effects", showsDivider: false) {
                    Text(listedApps.isEmpty ? "Apps appear here while they play."
                                            : "Select an app to adjust its effects and output.")
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Header (d.9)

    /// The page's one status: what App Audio is doing, one line of context and
    /// its master switch. Off is a state, not a warning (e.6).
    private var header: some View {
        AOMPageHeader(headerTitle, subtitle: subtitle,
                      help: "App Audio sends each app through AOM, so every app gets its own volume, Magic Boost and equalizer. Turned off, audio plays directly and every setting is kept.",
                      active: service.isSupported && service.soundEnabled) {
            if service.isSupported {
                Toggle("App Audio", isOn: $service.soundEnabled)
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
        ToolbarItemGroup(placement: .automatic) {
            Button {
                service.showPanel()
            } label: {
                Label("Floating Mixer", systemImage: "slider.horizontal.3")
            }
            .help("Open the floating per-app audio mixer panel")
            Button {
                withAnimation(AOMMotion.panel) { showsInspector.toggle() }
            } label: {
                Label(showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(showsInspector ? "Hide the selected app's effects (⌥⌘I)"
                                 : "Show the selected app's effects beside the mixer when the window has room (⌥⌘I)")
            Menu {
                Button("Add Application…", systemImage: "plus") { pickAndAddApplication() }
                Toggle("Show All Running Apps", isOn: $service.showAllApps)
                Divider()
                Button("Reconnect Audio", systemImage: "arrow.clockwise") {
                    service.reconnectAll()
                    toast.show("Reconnecting audio", tone: .info)
                }
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
        let total = lists.favorites.count + lists.active.count + lists.other.count + service.hiddenListed(matching: searchText).count
        return AOMSectionCard("Applications", symbol: "square.grid.2x2", detail: total > 0 ? "\(total)" : nil, contentPadding: 0,
                              accessory: {
            HStack(spacing: AOMSpace.x2) {
                Toggle("Show All Apps", isOn: $service.showAllApps)
                    .toggleStyle(.checkbox)
                    .font(AOMFont.callout)
                    .help("Show all running applications even when silent")
                Button { pickAndAddApplication() } label: { Label("Add…", systemImage: "plus") }
                    .help("Choose an application to add to your favorites")
            }
        }) {
            // In-card empty states (design-3.4.0 b.6): one sentence, one action.
            if !service.isSupported {
                AOMInlineEmpty(symbol: "exclamationmark.triangle",
                               message: "Per-app volume and effects need macOS 14.2 or newer. The system devices above work on this Mac.")
            } else if total == 0 {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    AOMInlineEmpty(symbol: "magnifyingglass", message: "No application matches “\(searchText)”.",
                                   actionTitle: "Clear Filter") { searchText = "" }
                } else {
                    AOMInlineEmpty(symbol: "waveform",
                                   message: "No app is playing audio. Apps appear here while they play and for a minute afterwards.",
                                   actionTitle: "Show All Running Apps") { service.showAllApps = true }
                }
            } else {
                VStack(spacing: 0) {
                    section("Favorites", lists.favorites)
                    section(lists.favorites.isEmpty ? nil : "Playing & adjusted", lists.active)
                    section("Other running apps", lists.other)
                    section("Hidden", service.hiddenListed(matching: searchText))
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
                    .padding(.bottom, AOMSpace.x1)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(rows) { app in
                ApplicationAudioRow(app: app, isSelected: selectedBundleID == app.bundleID, inspectorShown: inspectorShown,
                                    onSelect: { selectedBundleID = app.bundleID })
                if app.id != rows.last?.id { AOMRowDivider(inset: AOMSpace.rowSymbolInset) }
            }
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
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            toast.show("Couldn't add “\(url.deletingPathExtension().lastPathComponent)” because it has no bundle identifier",
                       tone: .danger)
            return
        }
        service.addCustomApp(url: url)
        if !service.isFavorite(bundleID) { service.toggleFavorite(bundleID) }
        toast.show("Added \(url.deletingPathExtension().lastPathComponent) to Favorites")
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
    static let sliderMinWidth: CGFloat = 140
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
    /// One device or app row: row insets, 8 pt above and below, at least one
    /// standard row tall (3.3.5 had 4 pt).
    func audioRowPadding() -> some View {
        padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x2)
            .frame(minHeight: AOMSize.rowStandard)
    }

    /// A row's volume slider.
    func audioRowSlider() -> some View {
        controlSize(.regular)
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
    @Environment(\.scenePhase) private var scenePhase
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
            .help(canAdjustVolume ? "Output volume" : "Fixed-volume output: set the level on the device")
            RowValue(text: canAdjustVolume ? "\(Int(volume.rounded()))%" : "—")
            MagicBoostButton(isOn: service.allAppsBoostEnabled, label: "Magic Boost for the output") {
                service.allAppsBoostEnabled.toggle()
            }
            .disabled(!service.isSupported)
            // The output's Magic Boost preset, next to its switch like
            // every app row's; off while the output boost is off.
            AudioBoostPresetPicker(bundleID: nil, style: .menu)
                .disabled(!service.isSupported || !service.allAppsBoostEnabled)
            DisclosureButton(expanded: $expanded, label: "Output effects")
        }
        .audioRowPadding()
        .contentShape(Rectangle())
        // b.4: every row has its actions in a context menu too.
        .contextMenu {
            Button(isMuted ? "Unmute Output" : "Mute Output") {
                AudioOutputService.shared.toggleOutputMute { _ in refresh() }
            }
            Button(expanded ? "Hide Output Effects" : "Show Output Effects") {
                withAnimation(AOMMotion.panel) { expanded.toggle() }
            }
            Divider()
            Button("Sound Settings…") { AudioSystemSettings.openSound() }
        }
        .aomVisibleTask(id: scenePhase) {
            guard scenePhase == .active else { return }
            refresh()
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try Task.checkCancellation()
                    refresh()
                }
            } catch { /* Hidden or inactive audio controls stop polling hardware. */ }
        }
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
                RowValue(text: canAdjustBalance ? AudioBalance.shortLabel(balance) : "—")
                    .accessibilityHidden(true)
                    .help(canAdjustBalance ? "" : "This output has no left and right volume (HomePod and AirPlay have one)")
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
    @Environment(\.scenePhase) private var scenePhase
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
                .labelsHidden().fixedSize()
            }
            Spacer(minLength: AOMSpace.x2)
            MuteButton(symbol: isMuted ? "mic.slash.fill" : "mic.fill", muted: isMuted) {
                if let next = AudioOutputService.toggleInputMute() { isMuted = next }
            }
            .disabled(!canMute)
            .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
            .help(canMute ? (isMuted ? "Unmute microphone" : "Mute microphone") : "This input has no mute control")
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
        .contentShape(Rectangle())
        .contextMenu {
            if canMute {
                Button(isMuted ? "Unmute Microphone" : "Mute Microphone") {
                    if let next = AudioOutputService.toggleInputMute() { isMuted = next }
                }
                Divider()
            }
            Button("Sound Settings…") { AudioSystemSettings.openSound() }
        }
        .aomVisibleTask(id: scenePhase) {
            guard scenePhase == .active else { return }
            refresh()
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try Task.checkCancellation()
                    refresh()
                }
            } catch { /* Hidden or inactive audio controls stop polling hardware. */ }
        }
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
    /// Set once the person moves the slider or mutes, so a late read of the
    /// system value never jumps the slider back.
    @State private var adjusted = false
    /// False until the system value has been read: the controls are
    /// disabled and the slider and figure hidden (keeping their space), so
    /// the row never shows a guessed level.
    @State private var loaded = false

    var body: some View {
        HStack(spacing: AOMSpace.x3) {
            HStack(spacing: AOMSpace.x2) {
                DeviceGlyph(symbol: "bell")
                DeviceTitle("Sound effects")
            }
            .help("Alerts and notification sounds")
            Spacer(minLength: AOMSpace.x2)
            MuteButton(symbol: isMuted ? "bell.slash.fill" : "bell.fill", muted: isMuted) { toggleMute() }
            .accessibilityLabel(isMuted ? "Unmute system alerts" : "Mute system alerts")
            .help(isMuted ? "Unmute system alerts" : "Mute system alerts")
            .disabled(!loaded)
            Slider(value: Binding(get: { volume }, set: { newValue in
                adjusted = true
                volume = newValue
                isMuted = newValue == 0
                if newValue > 0 { previousVolume = newValue }
                AudioOutputService.setSystemAlertVolumeLater(percent: newValue)
            }), in: 0...100)
            .audioRowSlider()
            .disabled(!loaded)
            .opacity(loaded ? 1 : 0)
            .overlay { if !loaded { ProgressView().controlSize(.small) } }
            .accessibilityLabel("System alert volume")
            .accessibilityValue(loaded ? "\(Int(volume.rounded())) percent" : "Reading")
            RowValue(text: loaded ? "\(Int(volume.rounded()))%" : "")
            BoostColumnsPlaceholder()
        }
        .audioRowPadding()
        .contentShape(Rectangle())
        .contextMenu {
            Button(isMuted ? "Unmute System Alerts" : "Mute System Alerts") { toggleMute() }
                .disabled(!loaded)
            Divider()
            Button("Sound Settings…") { AudioSystemSettings.openSound() }
        }
        // Off the main thread: with no stored value the read is AppleScript.
        .task {
            adjusted = false
            let percent = await AudioOutputService.loadSystemAlertVolumePercent()
            defer { loaded = true }
            guard !adjusted else { return }
            // Nil (the script failed): the 65 % default, as before.
            volume = percent ?? 65
            isMuted = volume == 0
            if volume > 0 { previousVolume = volume }
        }
    }

    private func toggleMute() {
        adjusted = true
        if !isMuted, volume > 0 { previousVolume = volume }
        let target = isMuted ? previousVolume : 0
        AudioOutputService.setSystemAlertVolumeLater(percent: target)
        volume = target
        isMuted = target == 0
    }
}

/// Opens System Settings › Sound (the context-menu way to the system pane).
private enum AudioSystemSettings {
    static func openSound() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
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
    @EnvironmentObject private var toast: AOMToastModel
    @Environment(\.undoManager) private var undoManager
    let app: AppAudioState
    /// D18: the app shown in the page's inspector, and whether the inspector
    /// is on screen (then the chevron selects instead of expanding).
    var isSelected = false
    var inspectorShown = false
    var onSelect: () -> Void = {}
    @State private var gain: Float
    @State private var expanded = false

    init(app: AppAudioState, isSelected: Bool = false, inspectorShown: Bool = false, onSelect: @escaping () -> Void = {}) {
        self.app = app
        self.isSelected = isSelected
        self.inspectorShown = inspectorShown
        self.onSelect = onSelect
        _gain = State(initialValue: min(max(app.gain, 0), 1))
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
                // 7.0: SoundSource's single track — volume to the 100 % detent,
                // Volume Overdrive in amber up to 400 %.
                AOMOverdriveSlider(value: Binding(get: { Double(gain) * Double(app.overdrive) }, set: { setCombinedVolume($0) }),
                                   isMuted: app.muted)
                .frame(height: 18)
                .frame(minWidth: AudioRowMetrics.sliderMinWidth, maxWidth: AudioRowMetrics.sliderMaxWidth)
                .disabled(app.bundleID.isEmpty)
                .accessibilityLabel("Volume for \(app.name)")
                RowValue(text: volumeLabel, tint: app.overdrive > 1.0001 ? AOMCraftColor.overdriveAmber : AOMColor.textSecondary)
                    .help(app.overdrive > 1.0001 ? "Volume Overdrive \(Int((app.overdrive * 100).rounded()))%" : "Volume")
                MagicBoostButton(isOn: app.magicBoost, label: "Magic Boost for \(app.name)") {
                    service.toggleMagicBoost(bundleID: app.bundleID)
                }
                // This app's Magic Boost preset, next to its switch.
                AudioBoostPresetPicker(bundleID: app.bundleID, style: .menu)
                    .disabled(!app.magicBoost || app.bundleID.isEmpty)
                if inspectorShown {
                    // D18: the effects are in the inspector; this shows them there.
                    Button(action: onSelect) {
                        Image(systemName: "sidebar.trailing")
                            .foregroundStyle(isSelected ? AOMColor.accent : AOMColor.textSecondary)
                            .frame(width: AudioRowMetrics.buttonWidth, height: AudioRowMetrics.buttonHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Effects for \(app.name) in the inspector")
                    .help("Show \(app.name)'s effects in the inspector")
                } else {
                    DisclosureButton(expanded: $expanded, label: "Effects for \(app.name)")
                }
            }
            .audioRowPadding()
            .contentShape(Rectangle())
            .background {
                if inspectorShown && isSelected {
                    RoundedRectangle(cornerRadius: AOMCraftRadius.row, style: .continuous)
                        .fill(AOMColor.accent.opacity(0.10))
                }
            }
            .aomCalmHover(radius: AOMCraftRadius.row)
            // Clicking a row (or a control on it) makes it the inspected app.
            .simultaneousGesture(TapGesture().onEnded { if inspectorShown { onSelect() } })
            .contextMenu { contextMenu }
            .accessibilityAddTraits(inspectorShown && isSelected ? .isSelected : [])

            if expanded && !inspectorShown { ApplicationAudioEffects(app: app) }
        }
        .onChange(of: app.gain) { _, value in gain = min(max(value, 0), 1) }
    }

    /// 0…4 split as "Set App Volume" does: volume up to 1, overdrive beyond (5 % steps).
    private func setCombinedVolume(_ value: Double) {
        gain = service.setVolume(value, bundleID: app.bundleID)
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
        Button(service.isHidden(app.bundleID) ? "Show in List" : "Hide from List",
               systemImage: service.isHidden(app.bundleID) ? "eye" : "eye.slash") {
            service.toggleHidden(app.bundleID)
            toast.show(service.isHidden(app.bundleID) ? "\(app.name) hidden; Show All lists it under Hidden" : "\(app.name) shown", tone: .info)
        }
        Menu("Timed Mute") { timedMuteItems }
        Divider()
        Button("Reset Effects") {
            ApplicationAudioEffects.reset(app, service: service, undoManager: undoManager, toast: toast)
        }
        if app.pid > 0 && service.soundEnabled {
            Button("Reconnect") { reconnect() }
        }
    }

    private func reconnect() {
        service.reconnect(pid: app.pid)
        toast.show("Reconnecting \(app.name)", tone: .info)
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

// MARK: - Application effects (inline and in the inspector)

/// One app's effects: Volume Overdrive, balance, equalizer, output, timed
/// mute, favorite and reset. Drawn under the app's row (label column beside
/// the controls) or in the page's inspector (D18: labels above, controls the
/// inspector's width). The audio engine and its lifecycle are unchanged.
private struct ApplicationAudioEffects: View {
    @ObservedObject private var service = AppAudioMixerService.shared
    @EnvironmentObject private var toast: AOMToastModel
    @Environment(\.undoManager) private var undoManager
    let app: AppAudioState
    var stacked = false
    @State private var balance: Float
    @State private var showEQ = false
    @State private var availableOutputs: [AudioOutputDevice] = []

    init(app: AppAudioState, stacked: Bool = false) {
        self.app = app
        self.stacked = stacked
        _balance = State(initialValue: AudioBalance.clamp(app.balance))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: stacked ? AOMSpace.x3 : AOMSpace.x2) {
            row("Volume Overdrive") {
                Slider(value: Binding(get: { Double(app.overdrive) },
                                      set: { service.setOverdrive(Float($0), bundleID: app.bundleID) }),
                       in: 1...Double(AudioVolumeOverdrive.maximum), step: 0.05)
                .controlSize(.small)
                .frame(width: sliderWidth)
                .frame(maxWidth: stacked ? .infinity : nil)
                .accessibilityLabel("Volume Overdrive for \(app.name)")
                .accessibilityValue("\(Int((app.overdrive * 100).rounded())) percent")
                .help("Up to 400%, limited so loud audio never clips")
                RowValue(text: "\(Int((app.overdrive * 100).rounded()))%")
                if !stacked { Spacer(minLength: 0) }
            }
            row("Balance") {
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
                .frame(width: sliderWidth)
                .frame(maxWidth: stacked ? .infinity : nil)
                RowValue(text: AudioBalance.shortLabel(balance))
                    .accessibilityHidden(true)
                Button("Center") { centerBalance() }
                    .controlSize(.small)
                    .disabled(balance == 0)
                    .accessibilityLabel("Center balance for \(app.name)")
                    .help("Equal left and right")
                if !stacked { Spacer(minLength: 0) }
            }
            row("Equalizer") {
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
            row("Output") {
                Picker("Output for \(app.name)", selection: Binding(
                    get: { app.outputDeviceUID ?? "" },
                    set: { service.setOutputRoute(uid: $0.isEmpty ? nil : $0, bundleID: app.bundleID) })) {
                    Text("System Default").tag("")
                    if let uid = app.outputDeviceUID, !availableOutputs.contains(where: { $0.uid == uid }) {
                        Text("Disconnected — using default").tag(uid)
                    }
                    ForEach(availableOutputs) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().controlSize(.small)
                .fixedSize(horizontal: !stacked, vertical: false)
                Spacer(minLength: AOMSpace.x2)
                if !stacked { commands }
            }
            if stacked {
                HStack(spacing: AOMSpace.x2) { commands; Spacer(minLength: 0) }
            }
            if let error = app.error {
                HStack(spacing: AOMSpace.x2) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: AOMSpace.x2)
                    Button("Reconnect") {
                        service.reconnect(pid: app.pid)
                        toast.show("Reconnecting \(app.name)", tone: .info)
                    }
                    .controlSize(.small)
                    .disabled(app.pid <= 0 || !service.soundEnabled)
                }
            } else if service.soundEnabled {
                Text(app.processingStatus)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, stacked ? 0 : AOMSpace.rowSymbolInset)
        .padding(.trailing, stacked ? 0 : AOMSpace.rowInset)
        .padding(.bottom, stacked ? 0 : AOMSpace.x3)
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
        // The output list is read once when the effects appear (as before,
        // when a row expanded), not polled.
        .onAppear { availableOutputs = AudioOutputService.devices() }
        .onChange(of: app.bundleID) { _, _ in availableOutputs = AudioOutputService.devices() }
        .onChange(of: app.balance) { _, value in balance = AudioBalance.clamp(value) }
    }

    private var sliderWidth: CGFloat? { stacked ? nil : AOMRowControlMetrics.sliderWidth }

    /// A label and its controls: beside each other under a row, the label
    /// above them in the inspector.
    @ViewBuilder private func row<Controls: View>(_ label: String, @ViewBuilder _ controls: () -> Controls) -> some View {
        let built = controls()
        if stacked {
            VStack(alignment: .leading, spacing: AOMSpace.x1) {
                Text(label).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).accessibilityHidden(true)
                HStack(spacing: AOMSpace.x2) { built }
            }
        } else {
            HStack(spacing: AOMSpace.x3) {
                PanelLabel(label)
                built
            }
        }
    }

    @ViewBuilder private var commands: some View {
        Menu("Timed Mute") {
            Button("30 Seconds") { service.timedMute(bundleID: app.bundleID, seconds: 30) }
            Button("1 Minute") { service.timedMute(bundleID: app.bundleID, seconds: 60) }
            Button("2 Minutes") { service.timedMute(bundleID: app.bundleID, seconds: 120) }
            if service.timedMuteEnds[app.bundleID] != nil {
                Divider()
                Button("End Timed Mute") { service.cancelTimedMute(bundleID: app.bundleID) }
            }
        }
        .controlSize(.small).fixedSize()
        Button(service.isFavorite(app.bundleID) ? "Unfavorite" : "Favorite",
               systemImage: service.isFavorite(app.bundleID) ? "star.fill" : "star") {
            service.toggleFavorite(app.bundleID)
        }
        .controlSize(.small)
        Button("Reset") { Self.reset(app, service: service, undoManager: undoManager, toast: toast) }
            .controlSize(.small)
            .help("Volume 100%, balance centered, no overdrive, boost or equalizer")
    }

    private func centerBalance() {
        balance = 0
        service.setBalance(0, bundleID: app.bundleID)
    }

    /// Reset is one undoable step (design-3.4.0 b.4): the toast offers Undo
    /// and Edit › Undo Reset Effects brings every value back. The values to
    /// restore come from the app's stored state, so the row, its context
    /// menu and the inspector share one implementation.
    @MainActor
    static func reset(_ app: AppAudioState, service: AppAudioMixerService, undoManager: UndoManager?, toast: AOMToastModel) {
        let bundleID = app.bundleID
        let before = (gain: min(max(app.gain, 0), 1), overdrive: app.overdrive, balance: AudioBalance.clamp(app.balance),
                      boost: app.magicBoost, eq: service.appEQEnabled(bundleID))
        let apply: @MainActor () -> Void = {
            service.setGain(1, bundleID: bundleID)
            service.setOverdrive(1, bundleID: bundleID)
            service.setBalance(0, bundleID: bundleID)
            if service.apps.first(where: { $0.bundleID == bundleID })?.magicBoost == true {
                service.toggleMagicBoost(bundleID: bundleID)
            }
            service.setAppEQEnabled(false, bundleID: bundleID)
        }
        let revert: @MainActor () -> Void = {
            service.setGain(before.gain, bundleID: bundleID)
            service.setOverdrive(before.overdrive, bundleID: bundleID)
            service.setBalance(before.balance, bundleID: bundleID)
            if (service.apps.first(where: { $0.bundleID == bundleID })?.magicBoost ?? false) != before.boost {
                service.toggleMagicBoost(bundleID: bundleID)
            }
            service.setAppEQEnabled(before.eq, bundleID: bundleID)
        }
        AOMUndo.perform("Reset Effects", undoManager: undoManager, perform: apply, revert: revert)
        toast.show("Reset effects for \(app.name)", action: {
            if undoManager?.canUndo == true { undoManager?.undo() } else { revert() }
        })
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
                Button("Done", action: onDone).keyboardShortcut(.defaultAction).buttonStyle(AOMPrimaryButtonStyle()).aomPrimaryButton()
            }
            AudioEqualizerControls(gains: gains, enabled: enabled, onChange: onBand)
            Text("Boosted bands lower the overall level first so loud passages stay clean; Magic Boost restores loudness.")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
        }
        .padding(AOMSpace.x4)
        .frame(minWidth: Self.width, idealWidth: Self.width)
    }
}
