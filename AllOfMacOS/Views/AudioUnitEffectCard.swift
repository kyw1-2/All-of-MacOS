import AppKit
import CoreAudioKit
import SwiftUI

/// 3.3.3 (parity S03): an Audio Unit effect on every output's master chain
/// (after the apps are mixed, before Magic Boost and the limiter). Not placed
/// yet: insert it after `HeadphoneEQCard` in the mixer panel
/// (AppAudioMixer.swift) and in the Audio workspace (AudioWorkspaceView.swift).
struct AudioUnitEffectCard: View {
    @State private var effects: [AudioUnitEffectHost.Choice] = []
    @State private var selection = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Audio Unit Effect", systemImage: "waveform.path.ecg")
                .font(.system(size: 12, weight: .semibold))
            HStack {
                Picker("Effect", selection: $selection) {
                    Text("None").tag("")
                    ForEach(effects, id: \.key) { effect in Text(effect.name).tag(effect.key) }
                }
                .controlSize(.small)
                .frame(maxWidth: 260)
                .accessibilityLabel("Audio Unit effect for every output")
                Button("Edit…") { AudioUnitEffectEditor.shared.show() }
                    .controlSize(.small)
                    .disabled(selection.isEmpty)
                    .help("Open the effect's controls; the settings apply to every output when the window closes")
            }
            Text(message ?? "Runs on every output after the apps are mixed, before Magic Boost and the limiter.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
