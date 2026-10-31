import AppKit

/// 3.4 scaffold for Screen Ruler (PixelSnap-style on-screen measuring). The module's agent replaces this body;
/// `AOMProductivityModules` calls these two entry points.
@MainActor
enum ScreenRulerModule {
    /// Called once at launch (never in UI previews or unit tests).
    static func start() {}

    /// Starts measuring on the display under the pointer (hotkey, menus, Capture page).
    static func measure() {}

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] { [] }
}
