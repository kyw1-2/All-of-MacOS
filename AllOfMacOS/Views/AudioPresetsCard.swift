import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// 3.3.3 (parity S06): named Magic Boost presets for the output (`bundleID`
/// nil) or one app. Not placed yet (the Views owner places it): under the
/// Magic Boost toggle in `MasterBoostControls` (AppAudioMixer.swift) for the
/// output, and next to an app row's Magic Boost switch for that app.
struct AudioBoostPresetPicker: View {
    let bundleID: String?
    @State private var selection: String

    init(bundleID: String? = nil) {
        self.bundleID = bundleID
        _selection = State(initialValue: AudioBoostPreset.storedID(bundleID: bundleID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Boost preset", selection: $selection) {
                ForEach(AudioBoostPreset.all) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(bundleID == nil ? "Magic Boost preset for the output" : "Magic Boost preset for this app")
            .onChange(of: selection) { _, id in
                if #available(macOS 14.2, *) {
                    AppAudioEngine.shared.setBoostPreset(id, bundleID: bundleID)
                } else {
                    AudioBoostPreset.store(id, bundleID: bundleID)
                }
            }
            Text(AudioBoostPreset.preset(id: selection).summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 3.3.3 (parity S04): an EQ curve per output device, switched with the
/// output, and the import of AutoEQ "ParametricEQ.txt" files the user
/// chooses (AOM ships no measurement data). Not placed yet: insert it after
/// `EQSection` in AppAudioMixer.swift's mixer panel, and in the Audio
/// workspace's EQ area (AudioWorkspaceView.swift).
struct HeadphoneEQCard: View {
    @State private var devices: [AudioOutputDevice] = []
    @State private var deviceUID = ""
    @State private var names: [String] = []
    @State private var assigned = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Headphone EQ", systemImage: "headphones")
                .font(.system(size: 12, weight: .semibold))
            HStack {
                Picker("Output", selection: $deviceUID) {
                    ForEach(devices) { device in Text(device.name).tag(device.uid) }
                }
                .controlSize(.small)
                .frame(maxWidth: 220)
                .accessibilityLabel("Output device")
                Picker("Curve", selection: $assigned) {
                    Text("None").tag("")
                    ForEach(names, id: \.self) { name in Text(name).tag(name) }
                }
                .controlSize(.small)
                .frame(maxWidth: 220)
                .accessibilityLabel("EQ curve for this output")
            }
            HStack(spacing: 8) {
                Button("Import AutoEQ File…") { importFile() }
                    .controlSize(.small)
                    .help("Choose a ParametricEQ.txt from AutoEQ; it is fitted to AOM's 10-band EQ and used for this output")
                if !assigned.isEmpty, AudioDeviceEQ.userPresets()[assigned] != nil {
                    Button("Delete Curve", role: .destructive) {
                        AudioDeviceEQ.deletePreset(name: assigned)
                        if #available(macOS 14.2, *) { AppAudioEngine.shared.updateEffects() }
                        reload()
                    }
                    .controlSize(.small)
                }
            }
            Text(message ?? "The curve follows the output: it switches in when this device plays and out when another does.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: reload)
        .onChange(of: deviceUID) { _, _ in assigned = AudioDeviceEQ.assignment(uid: deviceUID) ?? "" }
        .onChange(of: assigned) { _, name in apply(name.isEmpty ? nil : name) }
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
