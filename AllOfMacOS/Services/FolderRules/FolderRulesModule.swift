import AppKit

/// 3.4 scaffold for Folder Rules (Hazel-style folder automation). The module's agent replaces this body;
/// `AOMProductivityModules` calls these two entry points.
@MainActor
enum FolderRulesModule {
    /// Called once at launch (never in UI previews or unit tests).
    static func start() {}

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] { [] }
}
