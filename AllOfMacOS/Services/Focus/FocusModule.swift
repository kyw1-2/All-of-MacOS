import AppKit

/// 3.4 scaffold for Focus (sessions, distraction hiding, idle-app quitter). The module's agent replaces this body;
/// `AOMProductivityModules` calls these two entry points.
@MainActor
enum FocusModule {
    /// Called once at launch (never in UI previews or unit tests).
    static func start() {}

    /// Starts a focus session with the saved length, or ends the running one.
    static func toggleSession() {}

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] { [] }
}
