import AppKit
import SwiftUI

// AOM 6.0 menu bar panel. A click on AOM's menu bar icon used to open a
// long NSMenu (capture modes, a Clipboard header, toggles with checkmarks
// and a "More" submenu holding most of the app). 6.0 opens a small panel
// instead, the way Control Center, Bartender and iStat Menus do: the app's
// state and master switch on top, the switches people flip as tiles, the
// everyday actions as one row of buttons, and the window and Settings at
// the bottom. Every command of the old menu is still one click away —
// "All Commands" (and ⌥-click or right-click on the icon) opens it.

/// What the panel needs from the app delegate.
struct AOMMenuBarPanelActions {
    var openWindow: () -> Void
    var openSettings: () -> Void
    var showAllCommands: () -> Void
    var quit: () -> Void
    var close: () -> Void
    /// 6.5: the launcher bar at the top of the panel.
    var openLauncher: () -> Void = { MainActor.assumeIsolated { AOMLauncherController.shared.show() } }
    /// 6.8: the panel's height changed (a session row came or went).
    var resized: () -> Void = {}
}

@MainActor
final class AOMMenuBarPanelModel: ObservableObject {
    @Published var engineOn = true
    @Published var snapping = false
    @Published var clipboardOn = true
    @Published var appAudio = false
    @Published var keepAwake = false
    @Published var hud = true
    @Published var focusRunning = false
    @Published var micMuted = false
    /// 6.7: sessions that are running now, shown as rows with their control.
    @Published var recording = false
    @Published var keepAwakeRemaining: String?
    let appState: AppState?

    init(appState: AppState?) {
        self.appState = appState
        refresh()
    }

    /// 6.7 (report A5): polled once a second while the panel is open, so a
    /// focus session that ends or a mic muted elsewhere shows at once. Only
    /// values that changed are published.
    func refresh() {
        set(\.engineOn, appState?.globalEnabled ?? true)
        set(\.snapping, appState?.currentPreset.snappingEnabled ?? false)
        set(\.clipboardOn, !ClipboardStore.shared.paused)
        if #available(macOS 14.2, *) { set(\.appAudio, AppAudioEngine.shared.isEnabled) }
        let awake = KeepAwakeService.shared
        set(\.keepAwake, awake.isActive)
        set(\.keepAwakeRemaining, awake.isActive ? awake.remainingDescription : nil)
        set(\.hud, UserDefaults.standard.object(forKey: "AOMHUDEnabled") as? Bool ?? true)
        set(\.focusRunning, FocusModule.isSessionActive)
        set(\.micMuted, MicMuteController.shared.isMuted)
        set(\.recording, ScreenRecordingService.shared.isRecording)
    }

    private func set<Value: Equatable>(_ key: ReferenceWritableKeyPath<AOMMenuBarPanelModel, Value>, _ value: Value) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    func stopRecording() {
        Task { _ = try? await ScreenRecordingService.shared.stopRecording(); refresh() }
    }

    /// Anything running that the panel lists on top.
    var hasActiveSessions: Bool { focusRunning || micMuted || recording || keepAwake }

    func toggleEngine() { appState?.toggleGlobalEnabled(); refresh() }
    func toggleSnapping() {
        if let appState { appState.setSnappingEnabled(!appState.currentPreset.snappingEnabled) }
        refresh()
    }
    func toggleClipboard() { ClipboardStore.shared.paused.toggle(); refresh() }
    func toggleAppAudio() {
        if #available(macOS 14.2, *) { AppAudioEngine.shared.isEnabled.toggle() }
        refresh()
    }
    func toggleKeepAwake() {
        let service = KeepAwakeService.shared
        if service.isActive { service.stop() } else { service.start(minutes: nil, keepDisplay: false) }
        refresh()
    }
    func toggleHUD() {
        UserDefaults.standard.set(!hud, forKey: "AOMHUDEnabled")
        refresh()
    }
    func endFocus() { FocusModule.toggleSession(); refresh() }
    func toggleMic() { MicMuteModule.toggleMute(); refresh() }
}

struct AOMMenuBarPanel: View {
    @ObservedObject var model: AOMMenuBarPanelModel
    let actions: AOMMenuBarPanelActions

    /// 6.8 (6.7 report §5): the first three quick actions of the user's own
    /// Workspace order (Customize Workspace), labelled — not a fixed six.
    @ObservedObject private var layout = AOMWorkspaceLayout.shared
    private var quickKinds: [WorkspaceQuickActionKind] { Array(layout.visibleQuickActions.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            header
            launcherBar
            if model.hasActiveSessions { urgent }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: AOMSpace.x2), GridItem(.flexible(), spacing: AOMSpace.x2)],
                      spacing: AOMSpace.x2) {
                tile("Drag to Snap", "rectangle.split.2x2", AOMModule.tiling.hue, on: model.snapping,
                     enabled: model.engineOn, model.toggleSnapping)
                tile("Clipboard", "doc.on.clipboard", AOMModule.clipboard.hue, on: model.clipboardOn,
                     model.toggleClipboard)
                if #available(macOS 14.2, *) {
                    tile("App Audio", "speaker.wave.2", AOMModule.audio.hue, on: model.appAudio, model.toggleAppAudio)
                }
                tile("Keep Awake", "cup.and.saucer", AOMModule.focus.hue, on: model.keepAwake, model.toggleKeepAwake)
                tile("Gesture HUD", "rectangle.on.rectangle", AOMModule.automation.hue, on: model.hud, model.toggleHUD)
                // 6.5: the sixth tile closes the grid's gap.
                tile("Mute Mic", model.micMuted ? "mic.slash.fill" : "mic", AOMColor.recording, on: model.micMuted,
                     model.toggleMic)
            }
            if !quickKinds.isEmpty {
                HStack(spacing: AOMSpace.x1) {
                    ForEach(quickKinds) { kind in
                        AOMMenuBarQuickButton(kind: kind) {
                            actions.close()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { kind.run() }
                        }
                    }
                }
            }
            Divider().opacity(0.6)
            footer
        }
        .padding(AOMSpace.x3 + 2)
        .frame(width: 356)
        .aomButtonDefaults()
        // 6.8: its own surface; the panel no longer borrows NSPopover's chrome.
        .aomFloatingSurface(.panel, radius: 18, inWindow: false)
        .onAppear { model.refresh() }
        .onChange(of: model.hasActiveSessions) { _, _ in DispatchQueue.main.async { actions.resized() } }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    /// Raycast's search bar as the panel's first row: ⌘K from anywhere.
    private var launcherBar: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
        return Button {
            actions.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { actions.openLauncher() }
        } label: {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AOMColor.accent)
                // 6.7: it opens the launcher; it is not a field to type in here.
                Text("Open Launcher…")
                    .font(AOMFont.body)
                    .foregroundStyle(AOMColor.text)
                Text("Kill Apps, Uninstall, Sound …")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if AOMLauncherShortcut.isRegistered {
                    HStack(spacing: 3) { ForEach(AOMLauncherShortcut.current.keycaps, id: \.self) { AOMKeycap(text: $0) } }
                }
            }
            .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5)
            .frame(height: 36)
            .background(Color.primary.opacity(0.06), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(AOMLauncherShortcut.isRegistered ? "The launcher — \(AOMLauncherShortcut.current.displayString) from any app"
                                                : "The launcher (no global key is registered; set one in Settings › Shortcuts)")
        .accessibilityLabel("Open Launcher")
    }

    private var header: some View {
        HStack(spacing: AOMSpace.x2 + AOMSpace.x0_5) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 30, height: 30)
                .opacity(model.engineOn ? 1 : 0.6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("All of MacOS").font(AOMFont.bodyEmphasis)
                HStack(spacing: AOMSpace.x1) {
                    Circle().fill(model.engineOn ? AOMColor.success : AOMColor.paused)
                        .frame(width: AOMIcon.dot, height: AOMIcon.dot)
                    Text(model.engineOn ? "Running" : "Paused")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
            }
            Spacer(minLength: AOMSpace.x1)
            Toggle("AOM", isOn: Binding(get: { model.engineOn }, set: { _ in model.toggleEngine() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.engineOn ? "Pause AOM" : "Resume AOM")
                .accessibilityLabel("AOM running")
        }
    }

    @ViewBuilder private var urgent: some View {
        VStack(spacing: AOMSpace.x1) {
            if model.recording {
                urgentRow("record.circle", "Recording the screen", tint: AOMColor.recording, button: "Stop", model.stopRecording)
            }
            if model.keepAwake {
                urgentRow("cup.and.saucer.fill", "Keep Awake \(model.keepAwakeRemaining ?? "on")", tint: AOMModule.focus.hue,
                          button: "Turn Off", model.toggleKeepAwake)
            }
            if model.focusRunning {
                urgentRow("timer", "Focus session running", tint: AOMModule.focus.hue, button: "End", model.endFocus)
            }
            if model.micMuted {
                urgentRow("mic.slash.fill", "Microphone is muted", tint: AOMColor.recording, button: "Unmute", model.toggleMic)
            }
        }
    }

    private func urgentRow(_ symbol: String, _ title: String, tint: Color, button: String,
                           _ run: @escaping () -> Void) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
            Text(title).font(AOMFont.body.weight(.medium))
            Spacer()
            Button(button, action: run).controlSize(.small)
        }
        .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5)
        .frame(height: 36)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: AOMRadius.well + 2, style: .continuous))
    }

    private func tile(_ title: String, _ symbol: String, _ hue: Color, on: Bool, enabled: Bool = true,
                      _ toggle: @escaping () -> Void) -> some View {
        AOMMenuBarTile(title: title, symbol: symbol, hue: hue, on: on, enabled: enabled, toggle: toggle)
    }

    private var footer: some View {
        HStack(spacing: AOMSpace.x2) {
            Button("Open All of MacOS") { actions.close(); actions.openWindow() }
                .buttonStyle(AOMPrimaryButtonStyle())
            Button { actions.close(); actions.openSettings() } label: { Image(systemName: "gearshape") }
                .help("Settings…")
                .accessibilityLabel("Settings")
            Spacer()
            // 6.7: Quit lives in the full menu (and ⌘Q), not next to Settings.
            Button { actions.showAllCommands() } label: { Image(systemName: "ellipsis") }
                .help("All commands and Quit — the full menu (also ⌥-click the icon)")
                .accessibilityLabel("All commands and Quit")
        }
        .controlSize(.small)
    }
}

/// A switch as a Control Center tile: its glyph in a circle that fills
/// with the tool's hue when on, the name, and On/Off.
private struct AOMMenuBarTile: View {
    let title: String
    let symbol: String
    let hue: Color
    let on: Bool
    var enabled = true
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Color.white : AOMColor.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(on ? hue : AOMColor.track, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(AOMFont.callout.weight(.medium)).foregroundStyle(AOMColor.text).lineLimit(1)
                    Text(on ? "On" : "Off").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: 46)
            // 6.5: an On tile glows faintly in its tool's hue (Control Center).
            .background {
                let shape = RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
                shape.fill(on ? hue.opacity(0.14) : (hovering ? AOMColor.rowHover : AOMColor.surface.opacity(0.6)))
                    .overlay(shape.strokeBorder(on ? hue.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 0.75))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// One pinned action: its icon over its name (Control Center's buttons).
private struct AOMMenuBarQuickButton: View {
    let kind: WorkspaceQuickActionKind
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            VStack(spacing: 3) {
                AOMAppIcon(AOMIdentity(symbol: kind.symbol, color: kind.module.hue), size: 26)
                Text(kind.title).font(.system(size: 10, weight: .medium)).foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(hovering ? AOMColor.rowHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: AOMRadius.well + 2, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(kind.shortcut.map { "\(kind.title) (\($0))" } ?? kind.title)
        .accessibilityLabel(kind.title)
    }
}
