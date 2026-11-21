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
    /// 6.10: the battery line (AlDente's menu bar controls).
    @ObservedObject private var battery = HardwareCareModel.shared

    /// 6.8 (6.7 report §5): the first three quick actions of the user's own
    /// Workspace order (Customize Workspace), labelled — not a fixed six.
    @ObservedObject private var layout = AOMWorkspaceLayout.shared

    /// 7.0: drawn by the craft panel (Control Center 26): live sessions on
    /// top, tinted tiles, labelled quick actions with More for the rest,
    /// the launcher bar and the utility row.
    var body: some View {
        AOMMenuBarCraftPanel(
            isEngineRunning: model.engineOn,
            liveSessions: liveSessions,
            toggles: tiles,
            quickActions: layout.visibleQuickActions.map { kind in
                AOMMenuBarCraftPanel.QuickAction(id: kind.id, title: kind.title, symbol: kind.symbol) {
                    actions.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { kind.run() }
                }
            },
            launcherShortcutText: AOMLauncherShortcut.isRegistered ? AOMLauncherShortcut.current.displayString : nil,
            onToggleMaster: model.toggleEngine,
            onOpenLauncher: {
                actions.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { actions.openLauncher() }
            },
            onOpenMainWindow: { actions.close(); actions.openWindow() },
            onOpenSettings: { actions.close(); actions.openSettings() },
            onShowClassicMenu: actions.showAllCommands,
            accessory: battery.power?.percent != nil ? AnyView(batteryRow) : nil)
        .aomButtonDefaults()
        .onAppear { model.refresh(); battery.refreshBattery() }
        .onChange(of: model.hasActiveSessions) { _, _ in DispatchQueue.main.async { actions.resized() } }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    private var liveSessions: [AOMMenuBarCraftPanel.LiveSession] {
        var sessions: [AOMMenuBarCraftPanel.LiveSession] = []
        if model.recording {
            sessions.append(.init(id: "rec", symbol: "record.circle", title: "Recording the screen", detail: "Stops and saves the clip",
                                  tint: AOMColor.recording, stopLabel: "Stop", onStop: model.stopRecording))
        }
        if model.keepAwake {
            sessions.append(.init(id: "awake", symbol: "cup.and.saucer.fill", title: "Keep Awake",
                                  detail: model.keepAwakeRemaining ?? "Until turned off", tint: AOMModule.focus.hue,
                                  stopLabel: "Turn Off", onStop: model.toggleKeepAwake))
        }
        if model.focusRunning {
            sessions.append(.init(id: "focus", symbol: "timer", title: "Focus session", detail: "Running",
                                  tint: AOMModule.focus.hue, stopLabel: "End", onStop: model.endFocus))
        }
        if model.micMuted {
            sessions.append(.init(id: "mic", symbol: "mic.slash.fill", title: "Microphone muted", detail: "Every app hears silence",
                                  tint: AOMColor.recording, stopLabel: "Unmute", onStop: model.toggleMic))
        }
        return sessions
    }

    private var tiles: [AOMMenuBarCraftPanel.ToggleTile] {
        var tiles: [AOMMenuBarCraftPanel.ToggleTile] = [
            .init(id: "snap", title: "Drag to Snap", subtitle: !model.engineOn ? "AOM paused" : model.snapping ? "On" : "Off",
                  symbol: "rectangle.split.2x2", tint: AOMModule.tiling.hue, isOn: model.snapping && model.engineOn,
                  onToggle: { if model.engineOn { model.toggleSnapping() } }),
            .init(id: "clip", title: "Clipboard", subtitle: model.clipboardOn ? "Saving copies" : "Paused",
                  symbol: "doc.on.clipboard", tint: AOMModule.clipboard.hue, isOn: model.clipboardOn, onToggle: model.toggleClipboard),
        ]
        if #available(macOS 14.2, *) {
            tiles.append(.init(id: "audio", title: "App Audio", subtitle: model.appAudio ? "Per-app volume" : "Off",
                               symbol: "speaker.wave.2", tint: AOMModule.audio.hue, isOn: model.appAudio, onToggle: model.toggleAppAudio))
        }
        tiles += [
            .init(id: "awake", title: "Keep Awake", subtitle: model.keepAwake ? (model.keepAwakeRemaining ?? "On") : "Off",
                  symbol: "cup.and.saucer", tint: AOMModule.focus.hue, isOn: model.keepAwake, onToggle: model.toggleKeepAwake),
            .init(id: "hud", title: "Gesture HUD", subtitle: model.hud ? "On" : "Off", symbol: "rectangle.on.rectangle",
                  tint: AOMModule.automation.hue, isOn: model.hud, onToggle: model.toggleHUD),
            .init(id: "mic", title: "Mute Mic", subtitle: model.micMuted ? "Muted" : "Live",
                  symbol: model.micMuted ? "mic.slash.fill" : "mic", tint: AOMColor.recording, isOn: model.micMuted,
                  onToggle: model.toggleMic),
        ]
        return tiles
    }

    private var batteryRow: some View {
        let power = battery.power
        return HStack(spacing: AOMSpace.x2) {
            Image(systemName: power?.isCharging == true ? "battery.100percent.bolt" : "battery.75percent")
                .foregroundStyle(battery.dischargeTarget != nil ? AOMColor.warning : AOMColor.success)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(power?.percent.map { "Battery \($0)%" } ?? "Battery").font(AOMFont.body.weight(.medium))
                Text(BatteryCareSection.stateLine(power: power, limit: battery.nativeLimit, discharging: battery.dischargeTarget,
                                                  topUp: battery.topUpRestore != nil))
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Hold Here") { battery.holdHere() }
                Button("Top Up to 100%") { battery.topUp() }.disabled(!battery.canTopUp)
                Divider()
                ForEach(HardwareCareModel.limits, id: \.self) { limit in
                    Button { battery.setLimit(limit) } label: {
                        Text("Limit \(limit)%" + (battery.nativeLimit == limit ? "  ✓" : ""))
                    }
                }
                Button("No Limit") { battery.setLimit(nil) }
                Divider()
                if battery.dischargeTarget != nil {
                    Button("Stop Discharge") { battery.stopDischarge() }
                } else {
                    ForEach([80, 60], id: \.self) { target in
                        Button("Discharge to \(target)%") { battery.discharge(to: target) }
                    }
                }
            } label: { Text(battery.nativeLimit.map { "\($0)%" } ?? "No limit").font(AOMFont.caption) }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5)
        .frame(height: 40)
        .background(AOMColor.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
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

}

