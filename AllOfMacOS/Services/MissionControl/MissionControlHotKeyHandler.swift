import Foundation
import AppKit
import Carbon

/// Intercepts single-key shortcuts while Mission Control is open (Mission Control Plus parity).
/// Supported actions on the window whose thumbnail is under the cursor:
/// - 'W': Close window
/// - 'Shift+W': Close all windows of the application
/// - 'M': Minimize window
/// - 'H': Hide application
///
/// 3.3.3: the window is the one behind the thumbnail (`MissionControlWindows`:
/// its app and title, never a guess). Until 3.3.2 the system-wide hit-test
/// found Mission Control's own surface (or AOM's ✕ panel), ⇧W asked that
/// process to quit, and nothing checked AOM's pause. Now the keys act only
/// with the hotkeys setting on, AOM on and not paused, the screen unlocked,
/// never on AOM's own windows and never on an app AOM is paused for; a key
/// that does nothing reaches Mission Control as usual.
@MainActor
final class MissionControlHotKeyHandler {
    static let shared = MissionControlHotKeyHandler()

    static let enabledKey = "AOMMissionControlHotkeys"

    private var eventMonitor: Any?

    init() {}

    /// The hotkeys setting, read where it is written (Settings write the key).
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func start() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, MissionControlOverlayService.shared.isMissionControlActive else {
                return event
            }
            if self.handleKey(event) {
                return nil // Suppress event if consumed
            }
            return event
        }
    }

    func stop() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Global-key entry from KeyboardMonitor's session event tap — the only
    /// path that sees W/M/H while Mission Control (and therefore the Dock)
    /// owns keyboard focus.
    @discardableResult
    func handleGlobalKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        // ANSI W=13, M=46, H=4.
        guard [13, 46, 4].contains(keyCode),
              modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        let isShift = modifiers.contains(.shift)
        let cursor = NSEvent.mouseLocation
        return act(character: keyCode == 13 ? "w" : keyCode == 46 ? "m" : "h",
                   shift: isShift, cursor: cursor)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let cursor = NSEvent.mouseLocation
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return false }
        let isShift = event.modifierFlags.contains(.shift)
        return act(character: chars, shift: isShift, cursor: cursor)
    }

    private func act(character: String, shift isShift: Bool, cursor: CGPoint) -> Bool {
        guard ["w", "m", "h"].contains(character), Self.isEnabled, AutomationGate.isOn,
              !TriggerSuppression.shared.isPaused, !ScreenLock.isLocked,
              let thumbnail = MissionControlWindows.thumbnail(at: cursor),
              let target = MissionControlWindows.window(for: thumbnail),
              target.pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              !TriggerSuppression.shared.isPaused(forApp: app.bundleIdentifier) else { return false }
        switch character {
        case "w":
            // ⇧W closes every window of the app with its close buttons (each
            // may ask to save); it never quits the app.
            if isShift { return MissionControlWindows.closeAllWindows(of: target.pid) > 0 }
            return MissionControlWindows.close(target.element)
        case "m":
            AXUIElementSetMessagingTimeout(target.element, 0.5)
            return AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        case "h":
            return app.hide()
        default:
            return false
        }
    }
}
