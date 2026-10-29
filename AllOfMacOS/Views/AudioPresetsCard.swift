import AppKit
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
