import AppKit

/// 3.4 scaffold for Microphone mute HUD and hotkey. The module's agent replaces this body;
/// `AOMProductivityModules` calls these two entry points.
@MainActor
enum MicMuteModule {
    /// Called once at launch (never in UI previews or unit tests).
    static func start() {}

    /// Mutes or unmutes the default microphone and shows the HUD.
    static func toggleMute() {}

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] { [] }
}
