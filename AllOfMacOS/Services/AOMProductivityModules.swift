import AppKit
import SwiftUI

/// The 3.4 modules' entry points in one place, so app launch, the status menu
/// and Workspace reach every module the same way. Each module owns its
/// `…Module` type (start, status-menu items) in its own folder and publishes
/// its live summary on `AOMModuleStatusBoard`.
@MainActor
enum AOMProductivityModules {
    /// Called once at launch; never in isolated UI previews or unit tests.
    /// 7.3: through the module switches — a module turned off in
    /// Settings › Modules doesn't start; the launcher always does.
    static func start() {
        AOMModuleSwitches.shared.startAll()
    }

    /// The status menu's Productivity items, built fresh for each click —
    /// only the modules that are on (7.3).
    static func statusMenuItems() -> [NSMenuItem] {
        let on = AOMModuleSwitches.shared
        return (on.isOn(.focus) ? FocusModule.statusMenuItems() : [])
            + (on.isOn(.screenRuler) ? ScreenRulerModule.statusMenuItems() : [])
            + (on.isOn(.files) ? FilesModule.statusMenuItems() : [])
            + (on.isOn(.textActions) ? TextActionsModule.statusMenuItems() : [])
            + (on.isOn(.clickHints) ? ClickHintsModule.statusMenuItems() : [])
            + (on.isOn(.folderRules) ? FolderRulesModule.statusMenuItems() : [])
            + (on.isOn(.micMute) ? MicMuteModule.statusMenuItems() : [])
    }
}

/// A fixed, testable priority policy: only an *active* session or an
/// already-muted microphone merits a top-level productivity shortcut. Other
/// tools remain available through More, never hidden or disabled.
enum AOMMenuBarPriority {
    enum ActiveTool: Equatable { case focusSession, mutedMicrophone }

    static func visibleTools(focusRunning: Bool, microphoneMuted: Bool) -> [ActiveTool] {
        var tools: [ActiveTool] = []
        if focusRunning { tools.append(.focusSession) }
        if microphoneMuted { tools.append(.mutedMicrophone) }
        return tools
    }
}

/// Menu-bar utilities populate only when the user opens More › Productivity
/// Tools. The delegate is retained by its singleton; NSMenu.delegate is weak.
/// This keeps the everyday menu click independent of Folder Rules, Files,
/// Text Actions, Click Hints, screen ruler and microphone hardware queries.
@MainActor
final class AOMProductivityMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = AOMProductivityMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = AOMProductivityModules.statusMenuItems()
        if items.isEmpty {
            let empty = NSMenuItem(title: "No Productivity Tools", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for item in items { menu.addItem(item) }
    }
}

/// A module's live summary for its Workspace tile and sidebar badge. The
/// module writes it; views only read it. Every value is real state.
@MainActor
final class AOMModuleStatus: ObservableObject {
    let module: AOMModule
    /// The module is switched on; nil when it has no master switch.
    @Published var isOn: Bool?
    /// The tile's large figure and its unit ("3" "rules"); nil shows On or Off.
    @Published var count: Int?
    @Published var unit: String
    /// One line of status ("Watching Downloads and Desktop").
    @Published var detail: String
    /// Something to fix, shown in the warning tone instead of `detail`.
    @Published var attention: String?
    /// Turns the module on or off from the tile's switch; nil hides the switch.
    var setOn: ((Bool) -> Void)?

    init(module: AOMModule, isOn: Bool? = nil, count: Int? = nil, unit: String = "", detail: String) {
        self.module = module
        self.isOn = isOn
        self.count = count
        self.unit = unit
        self.detail = detail
    }
}

@MainActor
enum AOMModuleStatusBoard {
    static let folderRules = AOMModuleStatus(module: .folderRules, isOn: false, detail: "No rules yet")
    static let textActions = AOMModuleStatus(module: .textActions, isOn: false, detail: "Off")
    static let files = AOMModuleStatus(module: .files, detail: "Dialog shortcuts and a drop shelf")
    static let focus = AOMModuleStatus(module: .focus, detail: "No session running")

    static var all: [AOMModuleStatus] { [folderRules, textActions, files, focus] }

    static func status(for module: AOMModule) -> AOMModuleStatus? {
        switch module {
        case .folderRules: return folderRules
        case .textActions: return textActions
        case .files: return files
        case .focus: return focus
        default: return nil
        }
    }
}
