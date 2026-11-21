import AppKit

/// Text Actions (3.4): a PopClip-style bar of actions over the text selected
/// in any app. `AOMProductivityModules` calls these entry points; the
/// Show Text Actions shortcut calls `showForCurrentSelection()`.
@MainActor
enum TextActionsModule {
    /// Called once at launch (never in UI previews or unit tests). Installs
    /// the selection monitor only while the master switch is on.
    static func start() {
        TextActionsController.shared.moduleOn = true
        TextActionsController.shared.start()
    }

    /// 7.3: the module switch — the selection monitors come off.
    static func stop() {
        TextActionsController.shared.moduleOn = false
    }

    /// Shows the action bar for the current selection (the shortcut).
    static func showForCurrentSelection() {
        guard AOMModuleSwitches.shared.allows(.textActions) else { return }
        TextActionsController.shared.showForCurrentSelection()
    }

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] {
        TextActionsController.shared.statusMenuItems()
    }
}
