import AppKit
import SwiftUI

// AOM 7.11 (spec §3): a feature's own commands, opened by clicking the
// feature itself — in the menu bar panel (click a tile's name, pick a
// command) and from the Workspace card's menu button. One list per feature,
// so both places run the same thing. Nothing runs when the menu opens.

struct AOMFeatureCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// The panel goes first (a capture must not catch the panel), then it runs.
    var closesPanel = false
    let run: @MainActor () -> Void
}

@MainActor
enum AOMFeatureMenus {
    /// Capture → Area / Window / Full Screen. The capture starts only when
    /// one is chosen, never when the menu opens.
    static func capture() -> [AOMFeatureCommand] {
        [
            AOMFeatureCommand(id: "capture.area", title: "Capture Area", symbol: "viewfinder", closesPanel: true) {
                CaptureCoordinator.shared.captureArea()
            },
            AOMFeatureCommand(id: "capture.window", title: "Capture Window", symbol: "macwindow", closesPanel: true) {
                CaptureCoordinator.shared.captureWindowFromPicker()
            },
            AOMFeatureCommand(id: "capture.fullscreen", title: "Capture Full Screen", symbol: "display", closesPanel: true) {
                CaptureCoordinator.shared.captureFullscreen()
            },
        ]
    }

    /// Clipboard → Open History / Pause or Resume Collecting.
    static func clipboard() -> [AOMFeatureCommand] {
        let store = ClipboardStore.shared
        return [
            AOMFeatureCommand(id: "clipboard.open", title: "Open History", symbol: "list.bullet.rectangle", closesPanel: true) {
                ClipboardPanelController.shared.show()
            },
            store.paused
                ? AOMFeatureCommand(id: "clipboard.resume", title: "Resume Collecting", symbol: "play.circle") { store.resume() }
                : AOMFeatureCommand(id: "clipboard.pause", title: "Pause Collecting", symbol: "pause.circle") { store.pause() },
        ]
    }

    /// Keep Awake → 30 Minutes / 1 Hour / Turn Off (while on).
    static func keepAwake() -> [AOMFeatureCommand] {
        let service = KeepAwakeService.shared
        var commands = [
            AOMFeatureCommand(id: "awake.30", title: "30 Minutes", symbol: "clock") {
                _ = service.start(minutes: 30, keepDisplay: false)
            },
            AOMFeatureCommand(id: "awake.60", title: "1 Hour", symbol: "clock.fill") {
                _ = service.start(minutes: 60, keepDisplay: false)
            },
        ]
        if service.isActive {
            commands.append(AOMFeatureCommand(id: "awake.off", title: "Turn Off", symbol: "xmark.circle") { service.stop() })
        }
        return commands
    }

    /// The same commands as menu buttons (Workspace cards).
    @ViewBuilder
    static func menuItems(_ commands: [AOMFeatureCommand]) -> some View {
        ForEach(commands) { command in
            Button { command.run() } label: { Label(command.title, systemImage: command.symbol) }
        }
    }
}
