import AppKit
import CoreAudioKit
import SwiftUI

/// 3.3.3 (parity S03): an Audio Unit effect on every output's master chain
/// (after the apps are mixed, before Magic Boost and the limiter). A page
/// section after Headphone EQ on the Audio page (`.section`), compact rows
/// after `HeadphoneEQCard` in the mixer panel (`.panel`).
struct AudioUnitEffectCard: View {
    enum Style {
        /// Title above an opaque card with one setting row (Audio page).
        case section
        /// Small heading and compact controls (mixer panel).
        case panel
    }

    static let help = "Runs on every output after the apps are mixed, before Magic Boost and the limiter. Edit… opens the effect's own controls; every output gets the change when that window closes."

    var style: Style
    @State private var effects: [AudioUnitEffectHost.Choice] = []
    @State private var selection = ""
    @State private var message: String?

    init(style: Style = .section) {
        self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .section:
                AOMSection("Audio Unit Effect", help: Self.help, footer: message) {
                    AOMSettingRow("Effect", symbol: "waveform.path.ecg") { controls(compact: false) }
                }
            case .panel:
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    HStack(spacing: AOMSpace.x1) {
                        Text("Audio Unit Effect")
                            .font(AOMFont.caption.weight(.semibold))
                            .foregroundStyle(AOMColor.textSecondary)
                            .accessibilityAddTraits(.isHeader)
                        AOMInfoButton(Self.help, topic: "Audio Unit effects")
                    }
                    controls(compact: true)
                    if let message {
                        Text(message)
                            .font(AOMFont.caption)
                            .foregroundStyle(AOMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .controlSize(.small)
            }
        }
        .onAppear {
            effects = AudioUnitEffectHost.installedEffects()
            selection = SharedOutputRenderer.shared.masterEffect?.key ?? ""
        }
        .onChange(of: selection) { _, key in
            let choice = effects.first { $0.key == key }
            guard choice?.key != SharedOutputRenderer.shared.masterEffect?.key else { return }
            if SharedOutputRenderer.shared.setMasterEffect(choice) {
                message = nil
                if #available(macOS 14.2, *) { AppAudioEngine.shared.requestSync() }
            } else {
                message = "\(choice?.name ?? "The effect") could not be loaded."
                selection = SharedOutputRenderer.shared.masterEffect?.key ?? ""
            }
        }
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Picker("Effect", selection: $selection) {
                Text("None").tag("")
                ForEach(effects, id: \.key) { effect in Text(effect.name).tag(effect.key) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: compact ? AOMSize.tileMin : nil)
            .accessibilityLabel("Audio Unit effect for every output")
            Button("Edit…") { AudioUnitEffectEditor.shared.show() }
                .controlSize(.small)
                .disabled(selection.isEmpty)
                .help("Open the effect's controls; the settings apply to every output when the window closes")
        }
    }
}

/// The effect's generic editor (CoreAudioKit). It edits the default
/// output's instance; closing the window saves the state and gives the
/// other outputs instances with it.
@MainActor
final class AudioUnitEffectEditor: NSObject, NSWindowDelegate {
    static let shared = AudioUnitEffectEditor()
    private var window: NSWindow?
    private var editing: AudioUnitEffectHost?

    func show() {
        guard let host = SharedOutputRenderer.shared.masterEffectForEditing() else { NSSound.beep(); return }
        window?.close()
        let view = AUGenericView(audioUnit: host.audioUnit)
        view.showsExpertParameters = true
        let size = NSSize(width: max(360, view.frame.width), height: max(120, view.frame.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = host.choice.name
        window.contentView = view
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        editing = host
    }

    func windowWillClose(_ notification: Notification) {
        if let editing { SharedOutputRenderer.shared.saveMasterEffectState(from: editing) }
        editing = nil
        window = nil
    }
}
