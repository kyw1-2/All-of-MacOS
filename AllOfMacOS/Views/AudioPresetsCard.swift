import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// 3.3.3 (parity S06): named Magic Boost presets for the output (`bundleID`
/// nil) or one app. The mixer panel shows the output's presets under its
/// Magic Boost switch (`MasterBoostControls`, `.segmented`); the Audio page
/// puts a `.menu` next to every Magic Boost button, the output row's and each
/// app row's.
struct AudioBoostPresetPicker: View {
    enum Style {
        /// Four segments and an ⓘ with the chosen preset's summary, under a switch.
        case segmented
        /// A borderless pop-up `menuWidth` wide, next to a Magic Boost button in a row.
        case menu
    }

    /// The `.menu` style's width, so rows with and without it keep their columns.
    static let menuWidth: CGFloat = AOMSpace.x12 + AOMSpace.x6

    let bundleID: String?
    var style: Style
    @State private var selection: String

    init(bundleID: String? = nil, style: Style = .segmented) {
        self.bundleID = bundleID
        self.style = style
        _selection = State(initialValue: AudioBoostPreset.storedID(bundleID: bundleID))
    }

    private var preset: AudioBoostPreset { AudioBoostPreset.preset(id: selection) }
    private var accessibilityName: String {
        bundleID == nil ? "Magic Boost preset for the output" : "Magic Boost preset for this app"
    }

    var body: some View {
        Group {
            switch style {
            case .segmented:
                HStack(spacing: AOMSpace.x2) {
                    picker
                        .pickerStyle(.segmented)
                        .fixedSize()
                    AOMInfoButton("\(preset.name): \(preset.summary)", topic: "Magic Boost presets")
                }
            case .menu:
                Menu {
                    picker.pickerStyle(.inline)
                } label: {
                    Text(preset.name)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                // Quiet like the row's other glyphs; the switch beside it shows on/off.
                .tint(AOMColor.textSecondary)
                .fixedSize()
                .frame(width: Self.menuWidth, alignment: .leading)
                .accessibilityLabel(accessibilityName)
                .accessibilityValue(preset.name)
            }
        }
        .controlSize(.small)
        .help("Magic Boost preset: \(preset.name). \(preset.summary)")
        .onChange(of: selection) { _, id in
            if #available(macOS 14.2, *) {
                AppAudioEngine.shared.setBoostPreset(id, bundleID: bundleID)
            } else {
                AudioBoostPreset.store(id, bundleID: bundleID)
            }
        }
    }

    private var picker: some View {
        Picker("Boost preset", selection: $selection) {
            ForEach(AudioBoostPreset.all) { preset in
                Text(preset.name).tag(preset.id)
            }
        }
        .labelsHidden()
        .accessibilityLabel(accessibilityName)
    }
}

/// 3.3.3 (parity S04): an EQ curve per output device, switched with the
/// output, and the import of AutoEQ "ParametricEQ.txt" files the user
/// chooses (AOM ships no measurement data). A page section after the
/// System Devices card on the Audio page (`.section`), compact rows after
/// `EQSection` in the mixer panel (`.panel`).
struct HeadphoneEQCard: View {
    enum Style {
        /// Title above an opaque card of setting rows (Audio page).
        case section
        /// Small heading and compact controls (mixer panel).
        case panel
    }

    static let help = "Give each output its own EQ curve. It switches in when that output plays and out when another does. Import an AutoEQ ParametricEQ.txt to fit a measured curve to the 10 bands."

    var style: Style
    @State private var devices: [AudioOutputDevice] = []
    @State private var deviceUID = ""
    @State private var names: [String] = []
    @State private var assigned = ""
    @State private var message: String?

    init(style: Style = .section) {
        self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .section: section
            case .panel: panel
            }
        }
        .onAppear(perform: reload)
        .onChange(of: deviceUID) { _, _ in assigned = AudioDeviceEQ.assignment(uid: deviceUID) ?? "" }
        .onChange(of: assigned) { _, name in apply(name.isEmpty ? nil : name) }
    }

    private var canDelete: Bool { !assigned.isEmpty && AudioDeviceEQ.userPresets()[assigned] != nil }

    private var section: some View {
        AOMSection("Headphone EQ", help: Self.help, footer: message) {
            AOMSettingRow("Output", symbol: "headphones") { outputPicker.frame(maxWidth: AOMSize.tileMin) }
            AOMSettingRow("Curve", symbol: "slider.vertical.3") { curvePicker.frame(maxWidth: AOMSize.tileMin) }
            AOMSettingRow("AutoEQ File", symbol: "doc.text",
                          help: "AutoEQ publishes ParametricEQ.txt files for many headphones. AOM fits the file to its 10-band EQ and uses it for the output above.") {
                HStack(spacing: AOMSpace.x2) {
                    importButton
                    if canDelete { deleteButton }
                }
                .controlSize(.small)
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x1) {
                Text("Headphone EQ")
                    .font(AOMFont.caption.weight(.semibold))
                    .foregroundStyle(AOMColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                AOMInfoButton(Self.help, topic: "Headphone EQ")
            }
            HStack(spacing: AOMSpace.x2) {
                outputPicker.frame(maxWidth: AOMSize.tileMin)
                curvePicker.frame(maxWidth: AOMSize.tileMin)
            }
            HStack(spacing: AOMSpace.x2) {
                importButton
                if canDelete { deleteButton }
            }
            if let message {
                Text(message)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    private var outputPicker: some View {
        Picker("Output", selection: $deviceUID) {
            ForEach(devices) { device in Text(device.name).tag(device.uid) }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Output device")
    }

    private var curvePicker: some View {
        Picker("Curve", selection: $assigned) {
            Text("None").tag("")
            ForEach(names, id: \.self) { name in Text(name).tag(name) }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("EQ curve for this output")
    }

    private var importButton: some View {
        Button("Import AutoEQ File…") { importFile() }
            .help("Choose a ParametricEQ.txt from AutoEQ; it is fitted to AOM's 10-band EQ and used for this output")
    }

    private var deleteButton: some View {
        Button("Delete Curve", role: .destructive) {
            AudioDeviceEQ.deletePreset(name: assigned)
            if #available(macOS 14.2, *) { AppAudioEngine.shared.updateEffects() }
            reload()
        }
        .aomDestructive()
    }

    private func reload() {
        devices = AudioOutputService.devices()
        if deviceUID.isEmpty || !devices.contains(where: { $0.uid == deviceUID }) {
            let current = AudioOutputService.currentDeviceID().map { AudioOutputService.string($0, kAudioDevicePropertyDeviceUID) }
            deviceUID = devices.first(where: { $0.uid == current })?.uid ?? devices.first?.uid ?? ""
        }
        names = AudioDeviceEQ.presetNames()
        assigned = AudioDeviceEQ.assignment(uid: deviceUID) ?? ""
    }

    private func apply(_ name: String?) {
        guard !deviceUID.isEmpty, AudioDeviceEQ.assignment(uid: deviceUID) != name else { return }
        if #available(macOS 14.2, *) { AppAudioEngine.shared.setDeviceEQ(name, uid: deviceUID) }
        else { AudioDeviceEQ.assign(name, uid: deviceUID) }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an AutoEQ ParametricEQ.txt file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try AutoEQImport.importFile(at: url)
            names = AudioDeviceEQ.presetNames()
            assigned = result.name
            apply(result.name)
            message = String(format: "Imported “%@”: within %.1f dB of the file's curve on average (worst %.1f dB)%@.",
                             result.name, result.fit.rmsError, result.fit.maximumError,
                             result.fit.skipped.isEmpty ? "" : "; \(result.fit.skipped.count) unsupported filters skipped")
        } catch {
            message = error.localizedDescription
        }
    }
}
