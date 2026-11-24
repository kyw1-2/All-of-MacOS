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
    /// 7.11: whole minutes left on a timed Keep Awake (nil: off or until turned off).
    @Published var keepAwakeMinutesLeft: Int?
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
        set(\.keepAwakeMinutesLeft, awake.isActive ? awake.endsAt.map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded(.up))) } : nil)
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
    /// 7.8 (ME-02): the person's own quick commands and how many a row.
    @ObservedObject private var menuStore = AOMStatusMenuStore.shared

    /// 7.0: drawn by the craft panel (Control Center 26): live sessions on
    /// top, tinted tiles, labelled quick actions with More for the rest,
    /// the launcher bar and the utility row.
    var body: some View {
        AOMMenuBarCraftPanel(
            isEngineRunning: model.engineOn,
            liveSessions: liveSessions,
            toggles: tiles,
            quickActions: menuStore.panelCommands().map { command in
                AOMMenuBarCraftPanel.QuickAction(id: command.id, title: command.title, symbol: command.symbol) {
                    actions.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { command.run() }
                }
            },
            quickPerRow: AOMStatusMenuLayout.clampedPerRow(menuStore.layout.panelPerRow),
            launcherShortcutText: AOMLauncherShortcut.isRegistered ? AOMLauncherShortcut.current.displayString : nil,
            onToggleMaster: model.toggleEngine,
            onOpenLauncher: {
                actions.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { actions.openLauncher() }
            },
            onOpenMainWindow: { actions.close(); actions.openWindow() },
            onOpenSettings: { actions.close(); actions.openSettings() },
            onShowClassicMenu: actions.showAllCommands,
            onEditMenu: {
                actions.close()
                DispatchQueue.main.async { AOMMenuEditorNavigation.open() }
            },
            accessory: battery.power?.percent != nil ? AnyView(batteryRow) : nil,
            onCommand: { command in
                // A capture or a window starts after the panel is gone.
                if command.closesPanel {
                    actions.close()
                    // The panel is ordered out at once; one frame later it is off screen.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { command.run() }
                } else {
                    command.run()
                    model.refresh()
                }
            },
            onResize: actions.resized)
        .aomButtonDefaults()
        .onAppear { model.refresh(); battery.refreshBattery() }
        .onChange(of: model.hasActiveSessions) { _, _ in DispatchQueue.main.async { actions.resized() } }
        .onReceive(Timer.publish(every: 1, tolerance: 0.2, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
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
            // 7.11 (spec §3): Capture is a menu only — opening it captures nothing.
            .init(id: "capture", title: "Capture", subtitle: "Area · Window · Full Screen", symbol: "camera.viewfinder",
                  tint: AOMModule.capture.hue, isOn: false, onToggle: nil, menu: AOMFeatureMenus.capture()),
            .init(id: "snap", title: "Drag to Snap", subtitle: !model.engineOn ? "AOM paused" : model.snapping ? "On" : "Off",
                  symbol: "rectangle.split.2x2", tint: AOMModule.tiling.hue, isOn: model.snapping && model.engineOn,
                  onToggle: { if model.engineOn { model.toggleSnapping() } }),
            .init(id: "clip", title: "Clipboard", subtitle: model.clipboardOn ? "Saving copies" : "Paused",
                  symbol: "doc.on.clipboard", tint: AOMModule.clipboard.hue, isOn: model.clipboardOn, onToggle: model.toggleClipboard,
                  menu: AOMFeatureMenus.clipboard()),
        ]
        if #available(macOS 14.2, *) {
            tiles.append(.init(id: "audio", title: "App Audio", subtitle: model.appAudio ? "Per-app volume" : "Off",
                               symbol: "speaker.wave.2", tint: AOMModule.audio.hue, isOn: model.appAudio, onToggle: model.toggleAppAudio))
        }
        tiles += [
            .init(id: "awake", title: "Keep Awake",
                  subtitle: model.keepAwake ? (model.keepAwakeMinutesLeft.map { "\($0) min left" } ?? "Until turned off") : "Off",
                  symbol: "cup.and.saucer", tint: AOMModule.focus.hue, isOn: model.keepAwake, onToggle: model.toggleKeepAwake,
                  menu: AOMFeatureMenus.keepAwake(), menuNote: model.keepAwake ? (model.keepAwakeMinutesLeft.map { "\($0) min left" } ?? "Until turned off") : nil),
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
                // Below 80 % macOS can only charge to 80 %: say so (review 7.11).
                Button("Hold Here") { battery.holdHere { GestureHUD.shared.show(title: "Battery", detail: $0) } }
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

}

