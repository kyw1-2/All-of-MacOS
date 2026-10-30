import AppKit

/// Isolated UI previews of the 3.3.3 audio and capture pages. Everything here
/// is behind `PresetManager.isUIPreview` (`--aom-ui-preview <temp dir>`), so a
/// normal launch never runs it.
///
/// - `--aom-preview-capture-options` opens Settings › Capture › All Capture
///   Options once Settings is on screen (with `--aom-preview-settings
///   --aom-preview-settings-pane capture`).
/// - `--aom-preview-capture-section <id>` opens Capture Options scrolled to
///   one section (`CaptureSettingsView.Section` raw values, e.g. `recording`).
@MainActor
enum AudioCapturePreviewHooks {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    private static var started = false
    /// The poll at which the Settings window was first seen on screen.
    private static var settingsSeenAt: Int?

    /// The Capture Options section to scroll to, if a preview asked for one.
    static var captureSection: String? {
        guard PresetManager.isUIPreview, let index = arguments.firstIndex(of: "--aom-preview-capture-section"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Called by `AppAudioMixerService`, the first object of this slice that
    /// every window creates (the sidebar's Audio badge observes it).
    static func start() {
        guard PresetManager.isUIPreview, !started else { return }
        started = true
        if arguments.contains("--aom-preview-capture-options") { requestCaptureOptions(poll: 0) }
    }

    /// Settings opens a moment after the main window. The request goes out
    /// only once Settings has been on screen for a second (asking earlier can
    /// keep the window from opening), and repeats every half second until the
    /// sheet shows, for at most 30 seconds.
    private static func requestCaptureOptions(poll: Int) {
        guard poll < 60, !NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) else { return }
        if settingsSeenAt == nil, NSApp.windows.contains(where: { $0.isVisible && isSettingsWindow($0) }) {
            settingsSeenAt = poll
        }
        if let seen = settingsSeenAt, poll >= seen + 2 {
            NotificationCenter.default.post(name: .aomOpenCaptureOptions, object: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { requestCaptureOptions(poll: poll + 1) }
        }
    }

    /// SwiftUI's Settings scene window (its identifier and frame autosave name).
    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        let name = "com_apple_SwiftUI_Settings_window"
        return window.identifier?.rawValue == name || window.frameAutosaveName == name
    }
}
