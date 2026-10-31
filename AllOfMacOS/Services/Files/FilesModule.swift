import AppKit

/// 3.4 scaffold for Files (Open/Save dialog helper, drop shelf, recent files). The module's agent replaces this body;
/// `AOMProductivityModules` calls these two entry points.
@MainActor
enum FilesModule {
    /// Called once at launch (never in UI previews or unit tests).
    static func start() {}

    /// Shows the drop shelf (hotkey, menus, Workspace).
    static func showShelf() {}

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] { [] }
}
