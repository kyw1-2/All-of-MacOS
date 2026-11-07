import AppKit
import SwiftUI

/// The microphone mute helpers on the Audio page (B places it under the
/// input device): the current state with Mute/Unmute and the hotkey, then
/// the meeting options — HUD, menu bar icon, push-to-talk and auto-mute.
/// Two cards so neither holds more than eight rows (design-3.4.0 b.2).
struct MicMuteSection: View {
    @ObservedObject private var mic = MicMuteController.shared
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
            AOMSection("Microphone mute",
                       help: "One shortcut mutes or unmutes the default microphone in every app at once, like a cough button. AOM uses the microphone's own mute switch, or its input volume when it has none.") {
                stateRow
                shortcutRow
                AOMToggleRow("Show a HUD when the microphone changes", symbol: "rectangle.on.rectangle",
                             help: "A small panel near the bottom of the screen says Muted or On for about a second. It never takes focus.",
                             isOn: $mic.showsHUD)
                AOMToggleRow("Show a menu bar icon while muted", symbol: "menubar.arrow.up.rectangle",
                             help: "A crossed-out microphone sits in the menu bar while the microphone is muted. Click it to unmute.",
                             isOn: $mic.showsMenuBarIndicator)
            }
            AOMSection("Meetings", footer: "Push-to-talk reads only whether the chosen key is down, never what you type.") {
                AOMToggleRow("Push to talk", detail: "Hold a key to talk while muted", symbol: "hand.raised",
                             help: "While the microphone is muted, holding the key opens it; letting go mutes it again. Needs Accessibility, which AOM already uses for gestures.",
                             isOn: $mic.pushToTalkEnabled)
                AOMSettingRow("Key to hold", indent: true) {
                    Picker("Key to hold", selection: $mic.pushToTalkKey) {
                        ForEach(MicPushToTalkKey.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .disabled(!mic.pushToTalkEnabled)
                if mic.pushToTalkEnabled && !accessibilityTrusted {
                    AOMNotice(.warning, "Push to talk needs Accessibility",
                              detail: "Allow All of MacOS in System Settings › Privacy & Security › Accessibility.") {
                        Button("Open Settings…") { openAccessibilitySettings() }
                    }
                    .padding(AOMSpace.x2)
                }
                AOMToggleRow("Mute when these apps open", symbol: "video.badge.checkmark",
                             help: "Join every call muted: when one of these apps opens, AOM mutes the microphone and shows the HUD.",
                             isOn: $mic.autoMuteEnabled)
                ForEach(mic.autoMuteApps) { app in
                    autoMuteRow(app)
                }
                AOMSettingRow(mic.autoMuteApps.isEmpty ? "No apps yet" : "Add another app", indent: true) {
                    Button("Add App…") { chooseApp() }
                }
                .disabled(!mic.autoMuteEnabled)
            }
        }
        .onAppear {
            mic.refreshFromHardware()
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }

    // MARK: Rows

    private var stateRow: some View {
        AOMSettingRow(mic.deviceName ?? "No microphone",
                      detail: mic.canMute ? (mic.isMuted ? "Muted in every app" : "On") : "This microphone can't be muted by apps",
                      symbol: mic.isMuted ? "mic.slash.fill" : "mic.fill") {
            HStack(spacing: AOMSpace.x2) {
                AOMStatusPill(mic.isMuted ? "Muted" : "On", tone: mic.isMuted ? .warning : .success,
                              symbol: mic.isMuted ? "mic.slash" : "mic")
                Button(mic.isMuted ? "Unmute" : "Mute") { mic.toggle() }
                    .disabled(!mic.canMute || mic.deviceName == nil)
                    .help(mic.isMuted ? "Unmutes the microphone" : "Mutes the microphone in every app")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(mic.isMuted ? "Muted" : "On")
    }

    private var shortcutRow: some View {
        AOMSettingRow("Shortcut", detail: shortcut == nil ? "None yet; set one in Settings › Shortcuts" : nil,
                      symbol: "command") {
            HStack(spacing: AOMSpace.x2) {
                if let shortcut { AOMShortcutKeys(shortcut: shortcut) }
                Button(shortcut == nil ? "Set Shortcut…" : "Change…") { openShortcutSettings() }
            }
        }
    }

    private var shortcut: KeyboardShortcut? {
        CaptureShortcuts.shared.shortcut(for: .toggleMicMute)
    }

    private func autoMuteRow(_ app: MicMuteController.AutoMuteApp) -> some View {
        AOMSettingRow(app.name, detail: app.bundleID, indent: true) {
            HStack(spacing: AOMSpace.x2) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: AOMIcon.row, height: AOMIcon.row)
                        .accessibilityHidden(true)
                }
                AOMIconButton("minus.circle", label: "Remove \(app.name)") { mic.removeAutoMuteApp(app) }
            }
        }
        .disabled(!mic.autoMuteEnabled)
        .contextMenu {
            Button("Remove") { mic.removeAutoMuteApp(app) }
        }
    }

    // MARK: Actions

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose the apps you join calls with, such as Zoom or Microsoft Teams."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { _ = mic.addAutoMuteApp(url: url) }
    }

    private func openShortcutSettings() {
        guard !PresetManager.isUIPreview else { return }
        AOMOverlayActivation.activateForOverlay()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.shortcuts.rawValue)
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Isolated UI previews only: the section in a window of its own (the
/// Audio page that shows it belongs to another branch) and the HUD held on
/// screen long enough to capture. Nothing here runs in a normal launch.
@MainActor
enum MicMutePreview {
    private static var window: NSWindow?

    static func runIfRequested() {
        guard PresetManager.isUIPreview else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--aom-preview-micmute"), window == nil {
            let host = NSHostingView(rootView: AOMPage(maxWidth: AOMSize.readableWidth) { MicMuteSection() }
                .frame(width: 760, height: 700))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Microphone Mute (preview)"
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.center()
            window.orderFrontRegardless()
            self.window = window
        }
        if arguments.contains("--aom-preview-mic-hud") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    MicMuteHUDPanel.shared.show(muted: true, title: "Microphone Muted", detail: "MacBook Air Microphone", seconds: 30)
                }
            }
        }
    }
}
