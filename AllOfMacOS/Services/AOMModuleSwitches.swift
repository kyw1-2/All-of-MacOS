import AppKit
import SwiftUI

// AOM 7.3: module switches (DeepSeek design v2 §5, Codex 7.2.3 report p. 7).
//
// 7.2 started nine modules at launch and none could be stopped. A module
// that does background work can now be turned off without a restart: its
// observers, event monitors, timers and panels stop, and every way in — the
// status menu, the launcher, hotkeys, Workspace and automations — goes
// through the same check and says that the module is off, with Settings one
// click away. The launcher (PaletteModule: the ⌥Space panel, Ask AI,
// snippets, Kill Apps) is essential and has no switch. Turning a module
// back on starts it where it was; the saved options inside it are kept.

/// A module that can be turned off.
enum AOMModuleSwitch: String, CaseIterable, Identifiable, Codable {
    case files, folderRules, textActions, focus, micMute, inputSources, screenRuler, clickHints

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .folderRules: return "Folder Rules"
        case .textActions: return "Text Actions"
        case .focus: return "Focus"
        case .micMute: return "Mic Mute"
        case .inputSources: return "Input Sources"
        case .screenRuler: return "Screen Ruler"
        case .clickHints: return "Click Hints"
        }
    }

    var detail: String {
        switch self {
        case .files: return "Open and Save dialog helper, Drop Shelf, shake to open"
        case .folderRules: return "Watches folders and runs their rules"
        case .textActions: return "The bar over selected text"
        case .focus: return "Focus timer, idle-app rules, break reminders"
        case .micMute: return "Mute hotkey, push-to-talk, auto-mute, menu bar dot"
        case .inputSources: return "Per-app input sources and the 한/A badge"
        case .screenRuler: return "Measure on screen"
        case .clickHints: return "Click by typing letters over buttons"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "tray.and.arrow.down"
        case .folderRules: return "folder.badge.gearshape"
        case .textActions: return "text.cursor"
        case .focus: return "timer"
        case .micMute: return "mic.slash"
        case .inputSources: return "keyboard.badge.ellipsis"
        case .screenRuler: return "ruler"
        case .clickHints: return "cursorarrow.click.badge.clock"
        }
    }

    /// Holds background work (observers, timers, event monitors) while on.
    var runsInBackground: Bool { self != .screenRuler && self != .clickHints }
}

@MainActor
final class AOMModuleSwitches: ObservableObject {
    static let shared = AOMModuleSwitches()
    static let key = "AOMModules.v1"

    /// The modules turned off (none by default).
    @Published private(set) var off: Set<AOMModuleSwitch>
    /// How many times each module started and stopped (Settings shows them in debug builds).
    @Published private(set) var counters: [AOMModuleSwitch: (starts: Int, stops: Int)] = [:]
    private var running: Set<AOMModuleSwitch> = []
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        off = Set(stored.compactMap(AOMModuleSwitch.init(rawValue:)))
    }

    func isOn(_ module: AOMModuleSwitch) -> Bool { !off.contains(module) }

    var isRunningForTests: Set<AOMModuleSwitch> { running }

    /// Launch: starts every module that is on (the launcher always).
    func startAll() {
        for module in AOMModuleSwitch.allCases where isOn(module) { start(module) }
        if !PresetManager.isRunningTests { PaletteModule.start() }
    }

    /// Why the module can't be turned off now, or nil.
    func refusal(turningOff module: AOMModuleSwitch) -> String? {
        switch module {
        case .focus where FocusModule.isSessionActive:
            return "A focus session is running. End it first, then turn Focus off."
        default:
            return nil
        }
    }

    /// Turns a module on or off now; false (with why) when it can't be.
    @discardableResult
    func set(_ module: AOMModuleSwitch, on: Bool) -> String? {
        if !on, let refusal = refusal(turningOff: module) { return refusal }
        if on { off.remove(module) } else { off.insert(module) }
        defaults.set(off.map(\.rawValue).sorted(), forKey: Self.key)
        if on { start(module) } else { stop(module) }
        return nil
    }

    private func start(_ module: AOMModuleSwitch) {
        guard !running.contains(module) else { return }
        running.insert(module)
        counters[module, default: (0, 0)].starts += 1
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        switch module {
        case .files: FilesModule.start()
        case .folderRules: FolderRulesModule.start()
        case .textActions: TextActionsModule.start()
        case .focus: FocusModule.start()
        case .micMute: MicMuteModule.start()
        case .inputSources: AppInputSourcesModule.start()
        case .screenRuler: ScreenRulerModule.start()
        case .clickHints: ClickHintsModule.start()
        }
    }

    private func stop(_ module: AOMModuleSwitch) {
        guard running.contains(module) else { return }
        running.remove(module)
        counters[module, default: (0, 0)].stops += 1
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        switch module {
        case .files: FilesModule.stop()
        case .folderRules: FolderRulesModule.stop()
        case .textActions: TextActionsModule.stop()
        case .focus: FocusModule.stop()
        case .micMute: MicMuteModule.stop()
        case .inputSources: AppInputSourcesModule.stop()
        case .screenRuler, .clickHints: break
        }
    }

    /// The shared check every entry point asks. Off: a HUD says so with the
    /// way back, and the caller does nothing.
    func allows(_ module: AOMModuleSwitch) -> Bool {
        guard !isOn(module) else { return true }
        GestureHUD.shared.show(title: "\(module.title) Is Off", detail: "Turn it on in Settings › General › Modules.")
        return false
    }

    /// Opens Settings at the modules list.
    static func openSettings() {
        AppDelegate.current?.openSettingsWindow()
        for delay in [0.05, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.general.rawValue)
            }
        }
    }
}
