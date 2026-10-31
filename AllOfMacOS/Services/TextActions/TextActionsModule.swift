import AppKit

/// 3.4 scaffold for Text Actions (PopClip-style selection bar). The module's agent replaces this body;
/// `AOMProductivityModules` calls these two entry points.
@MainActor
enum TextActionsModule {
    /// Called once at launch (never in UI previews or unit tests).
    static func start() {}

    /// Shows the action bar for the current selection (hotkey).
    static func showForCurrentSelection() {}

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] { [] }
}
