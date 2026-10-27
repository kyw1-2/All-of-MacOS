import SwiftUI

/// Settings rows for the Hyper key, key remapping and wheel reversal. Each
/// change is applied at once through `InputRemapService`.
struct HyperKeyRow: View {
    @State private var enabled = InputRemapSettings.hyperEnabled
    @State private var source = InputRemapSettings.hyperSource
    @State private var tapEscape = InputRemapSettings.hyperTapEscape

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubRowShell(icon: "command.square.fill", tint: .orange, title: "Hyper Key",
                        subtitle: "Hold the key for ⌃⌥⇧⌘ — a modifier no app uses, for your own shortcuts",
                        onLabelTap: { enabled.toggle() }) {
                Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Hyper Key")
            }
            if enabled {
                HubRowShell(icon: "keyboard", tint: .orange, title: "Hyper Key Is", subtitle: "") {
                    Picker("", selection: $source) {
                        ForEach(HIDKey.hyperSources) { Text($0.title).tag($0.usage) }
                    }.labelsHidden().frame(width: 170)
                }
                HubRowShell(icon: "escape", tint: .orange, title: "Tap Alone for Escape",
                            subtitle: "A quick press without another key sends Escape",
                            onLabelTap: { tapEscape.toggle() }) {
                    Toggle("", isOn: $tapEscape).labelsHidden().toggleStyle(.switch).controlSize(.small)
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
            HubRowShell(icon: "arrow.left.arrow.right.square", tint: .blue, title: "Remap Keys",
                        subtitle: remaps.isEmpty ? "Turn one key into another on every keyboard while AOM runs"
                                                 : "\(remaps.count) remapped key\(remaps.count == 1 ? "" : "s"); removed when AOM quits") {
                Button("Add") { remaps.append(KeyRemap(from: 0x39, to: 0x29)) }
                    .controlSize(.small)
                    .disabled(remaps.count >= 32)
            }
            ForEach($remaps) { $remap in
                HStack(spacing: 8) {
                    Picker("From", selection: $remap.from) {
                        ForEach(HIDKey.catalog) { Text($0.title).tag($0.usage) }
                    }.labelsHidden().frame(width: 170)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    Picker("To", selection: $remap.to) {
                        ForEach(HIDKey.catalog) { Text($0.title).tag($0.usage) }
                    }.labelsHidden().frame(width: 170)
                    Spacer()
                    Button {
                        remaps.removeAll { $0.id == remap.id }
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(HIDKey.title(remap.from)) remap")
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
            }
            if remaps.contains(where: { InputRemapSettings.hyperEnabled && $0.from == InputRemapSettings.hyperSource }) {
                Text("The Hyper key takes precedence over a remap of the same key.")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 6)
            }
        }
        .onChange(of: remaps) { _, value in InputRemapSettings.remaps = value; InputRemapService.shared.apply() }
    }
}

struct ReverseWheelRow: View {
    @State private var enabled = InputRemapSettings.reverseMouseWheel

    var body: some View {
        HubRowShell(icon: "computermouse", tint: .teal, title: "Reverse Mouse Wheel",
                    subtitle: "Flip a wheel mouse only; the trackpad keeps natural scrolling",
                    onLabelTap: { enabled.toggle() }) {
            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("Reverse Mouse Wheel")
        }
        .onChange(of: enabled) { _, value in InputRemapSettings.reverseMouseWheel = value; InputRemapService.shared.apply() }
    }
}
