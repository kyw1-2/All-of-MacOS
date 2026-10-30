import SwiftUI

/// Settings rows for the Hyper key, key remapping and wheel reversal. Each
/// change is applied at once through `InputRemapService`.
struct HyperKeyRow: View {
    @State private var enabled = InputRemapSettings.hyperEnabled
    @State private var source = InputRemapSettings.hyperSource
    @State private var tapEscape = InputRemapSettings.hyperTapEscape

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubRowShell(icon: "command.square.fill", tint: .orange, title: "Hyper key",
                        subtitle: "Hold one key for ⌃⌥⇧⌘ in your own shortcuts",
                        onLabelTap: { enabled.toggle() }) {
                Toggle("", isOn: $enabled).labelsHidden().toggleStyle(AOMRowSwitchStyle())
                    .accessibilityLabel("Hyper key")
            }
            if enabled {
                // Its options, indented under the switch (e.3).
                HubRowShell(icon: "keyboard", tint: .orange, title: "Key", subtitle: "", indent: true) {
                    Picker("", selection: $source) {
                        ForEach(HIDKey.hyperSources) { Text($0.title).tag($0.usage) }
                    }.labelsHidden().controlSize(.small).frame(width: AOMFeatureSize.keyPicker)
                        .accessibilityLabel("Key for the Hyper key")
                }
                HubRowShell(icon: "escape", tint: .orange, title: "Tap alone for Escape",
                            subtitle: "A quick press without another key sends Escape", indent: true,
                            onLabelTap: { tapEscape.toggle() }) {
                    Toggle("", isOn: $tapEscape).labelsHidden().toggleStyle(AOMRowSwitchStyle())
                        .accessibilityLabel("Tap alone for Escape")
                }
            }
        }
        .onChange(of: enabled) { _, value in InputRemapSettings.hyperEnabled = value; InputRemapService.shared.apply() }
        .onChange(of: source) { _, value in InputRemapSettings.hyperSource = value; InputRemapService.shared.apply() }
        .onChange(of: tapEscape) { _, value in InputRemapSettings.hyperTapEscape = value; InputRemapService.shared.apply() }
    }
}

struct KeyRemapRow: View {
    @State private var remaps = InputRemapSettings.remaps

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubRowShell(icon: "arrow.left.arrow.right.square", tint: .blue, title: "Remap keys",
                        subtitle: remaps.isEmpty ? "Turn one key into another on every keyboard while AOM runs"
                                                 : "\(remaps.count) remapped key\(remaps.count == 1 ? "" : "s"); removed when AOM quits") {
                Button("Add") { remaps.append(KeyRemap(from: 0x39, to: 0x29)) }
                    .controlSize(.small)
                    .disabled(remaps.count >= 32)
            }
            ForEach($remaps) { $remap in
                HStack(spacing: AOMSpace.x2) {
                    Picker("From", selection: $remap.from) {
                        ForEach(HIDKey.catalog) { Text($0.title).tag($0.usage) }
                    }.labelsHidden().controlSize(.small).frame(width: AOMFeatureSize.keyPicker)
                    Image(systemName: "arrow.right").foregroundStyle(AOMColor.textSecondary).accessibilityHidden(true)
                    Picker("To", selection: $remap.to) {
                        ForEach(HIDKey.catalog) { Text($0.title).tag($0.usage) }
                    }.labelsHidden().controlSize(.small).frame(width: AOMFeatureSize.keyPicker)
                    Spacer()
                    Button {
                        remaps.removeAll { $0.id == remap.id }
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(AOMColor.textSecondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(HIDKey.title(remap.from)) remap")
                }
                // Indented to the "Remap keys" title, past its 20 pt symbol (e.3).
                .padding(.leading, AOMSpace.rowSymbolInset).padding(.trailing, AOMSpace.rowInset)
                .padding(.vertical, AOMSpace.x1)
            }
            if remaps.contains(where: { InputRemapSettings.hyperEnabled && $0.from == InputRemapSettings.hyperSource }) {
                Label("The Hyper key takes precedence over a remap of the same key.", systemImage: AOMTone.warning.symbol)
                    .font(AOMFont.caption).foregroundStyle(AOMColor.warningText)
                    .padding(.leading, AOMSpace.rowSymbolInset).padding(.trailing, AOMSpace.rowInset)
                    .padding(.bottom, AOMSpace.x2)
            }
        }
        .onChange(of: remaps) { _, value in InputRemapSettings.remaps = value; InputRemapService.shared.apply() }
    }
}

struct ReverseWheelRow: View {
    @State private var enabled = InputRemapSettings.reverseMouseWheel

    var body: some View {
        HubRowShell(icon: "computermouse", tint: .teal, title: "Reverse mouse wheel",
                    subtitle: "Flip a wheel mouse only; the trackpad keeps natural scrolling",
                    onLabelTap: { enabled.toggle() }) {
            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(AOMRowSwitchStyle())
                .accessibilityLabel("Reverse mouse wheel")
        }
        .onChange(of: enabled) { _, value in InputRemapSettings.reverseMouseWheel = value; InputRemapService.shared.apply() }
    }
}
