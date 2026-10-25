import Foundation
import AppKit
import Carbon

/// Intercepts single-key shortcuts while Mission Control is open (Mission Control Plus parity).
/// Supported actions on window/tile under cursor:
/// - 'W': Close window
/// - 'Shift+W': Close all windows of the application
/// - 'M': Minimize window
/// - 'H': Hide application
@MainActor
final class MissionControlHotKeyHandler {
    static let shared = MissionControlHotKeyHandler()

    private var eventMonitor: Any?

    init() {}

    func start() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, MissionControlConfiguration.shared.enableHotkeys,
                  MissionControlOverlayService.shared.isMissionControlActive else {
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

    private func handleKey(_ event: NSEvent) -> Bool {
        let cursor = NSEvent.mouseLocation
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return false }
        let isShift = event.modifierFlags.contains(.shift)

        switch chars {
        case "w":
            if isShift {
                // Close all windows of the app under cursor
                if let target = WindowManager.shared.captureTarget(atMousePoint: cursor),
                   let app = NSRunningApplication(processIdentifier: target.pid) {
                    app.terminate()
                    return true
                }
            } else {
                // Close single window under cursor
                if let target = WindowManager.shared.captureTarget(atMousePoint: cursor) {
                    WindowManager.shared.execute(.closeWindow, target: target, completion: { _ in })
                    return true
                }
            }
        case "m":
            // Minimize window under cursor
            if let target = WindowManager.shared.captureTarget(atMousePoint: cursor) {
                WindowManager.shared.execute(.minimizeWindow, target: target, completion: { _ in })
                return true
            }
        case "h":
            // Hide application under cursor
            if let target = WindowManager.shared.captureTarget(atMousePoint: cursor),
               let app = NSRunningApplication(processIdentifier: target.pid) {
                app.hide()
                return true
            }
        default:
            break
        }
        return false
    }
}
