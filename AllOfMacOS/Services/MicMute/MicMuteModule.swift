import AppKit

/// The microphone mute helper's entry points (3.4 scaffold signatures, kept):
/// `AOMProductivityModules` calls `start()` at launch and collects
/// `statusMenuItems()`; the `toggleMicMute` hotkey and Workspace's Mute
/// Microphone quick action call `toggleMute()`. The work is in
/// `MicMuteController`; the settings are `MicMuteSection` on the Audio page.
@MainActor
enum MicMuteModule {
    /// Called once at launch (never in UI previews or unit tests). Installs
    /// only what the saved settings need (key monitor for push-to-talk, the
    /// launch observer for auto-mute, device listeners for the indicator).
    static func start() {
        MicMuteController.shared.moduleOn = true
        MicMuteController.shared.start()
    }

    /// 7.3: the module switch — push-to-talk's key monitors, the auto-mute
    /// launch observer and the device listeners come off. The microphone
    /// stays as it is: turning the module off never unmutes or mutes it.
    static func stop() {
        MicMuteController.shared.moduleOn = false
    }

    /// Mutes or unmutes the default microphone and shows the HUD.
    static func toggleMute() {
        guard AOMModuleSwitches.shared.allows(.micMute) else { return }
        MicMuteController.shared.toggle()
    }

    /// "Mute Microphone", checked while the microphone is muted.
    static func statusMenuItems() -> [NSMenuItem] {
        [MicMuteController.shared.statusMenuItem()]
    }
}
