import AppKit
import SwiftUI

/// The 3.4 modules' entry points in one place, so app launch, the status menu
/// and Workspace reach every module the same way. Each module owns its
/// `…Module` type (start, status-menu items) in its own folder and publishes
/// its live summary on `AOMModuleStatusBoard`.
@MainActor
enum AOMProductivityModules {
    /// Called once at launch; never in isolated UI previews or unit tests.
    static func start() {
        FolderRulesModule.start()
        TextActionsModule.start()
        FilesModule.start()
        FocusModule.start()
        ScreenRulerModule.start()
        MicMuteModule.start()
        ClickHintsModule.start()
        // Per-app input sources (Settings › General) and the palette's
        // hold-⌘ sheet and link rules: each starts only when turned on.
        AppInputSourcesModule.start()
        PaletteModule.start()
    }

    /// The status menu's Productivity items, built fresh for each click.
    static func statusMenuItems() -> [NSMenuItem] {
        FocusModule.statusMenuItems()
            + ScreenRulerModule.statusMenuItems()
            + FilesModule.statusMenuItems()
            + TextActionsModule.statusMenuItems()
            + ClickHintsModule.statusMenuItems()
            + FolderRulesModule.statusMenuItems()
            + MicMuteModule.statusMenuItems()
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
