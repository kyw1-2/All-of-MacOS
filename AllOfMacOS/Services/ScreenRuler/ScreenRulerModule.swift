import AppKit

/// Screen Ruler: PixelSnap-style measuring on every display. ⇧⌘7 (Settings ›
/// Shortcuts › Measure Screen), the status menu and the Capture page call
/// `measure()`; the overlay and its keys live in `ScreenRulerOverlayController`.
@MainActor
enum ScreenRulerModule {
    /// Called once at launch (never in UI previews or unit tests). The ruler
    /// runs only while measuring and its hotkey belongs to `CaptureShortcuts`,
    /// so nothing starts here: an idle ruler holds no monitor, timer or image.
    static func start() {}

    /// Set while the displays are being captured, so a second press waits.
    private(set) static var isStarting = false

    /// Starts measuring on every display, or ends the session already on
    /// screen (the hotkey toggles).
    static func measure() {
        if let active = ScreenRulerOverlayController.active {
            active.finish()
            return
        }
        guard !isStarting else { return }
        // Isolated previews and tests never photograph the real screen.
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        guard !SelectionOverlayController.isActive else {
            GestureHUD.shared.show(title: "Capture In Progress", detail: "Finish or cancel the current capture first.")
            return
        }
        guard ScreenCaptureService.hasPermission else {
            ScreenCaptureService.requestPermission()
            GestureHUD.shared.show(title: "Screen Recording Needed",
                                   detail: "Measuring reads the screen. Allow All of MacOS in System Settings › Privacy & Security › \(AOMPermission.screenRecording.title), then try again.")
            return
        }
        isStarting = true
        let options = ScreenRulerSettings().options
        var scales: [CGDirectDisplayID: CGFloat] = [:]
        for screen in NSScreen.screens { scales[screen.displayID] = screen.backingScaleFactor }
        Task { @MainActor in
            defer { isStarting = false }
            do {
                let frames = try await ScreenRulerCapture.captureDisplays(scales: scales)
                try ScreenRulerOverlayController(frames: frames, options: options).present()
            } catch {
                GestureHUD.shared.show(title: "Screen Ruler Failed", detail: error.localizedDescription)
            }
        }
    }

    /// This module's items in the status menu's Productivity section.
    static func statusMenuItems() -> [NSMenuItem] {
        let item = QuickAccessMenuAction.item("Measure Screen", symbol: "ruler") {
            MainActor.assumeIsolated { measure() }
        }
        if let shortcut = CaptureShortcuts.shared.shortcut(for: .measureScreen) {
            applyShortcut(shortcut, to: item)
        }
        item.toolTip = "Measure distances and sizes on screen"
        return [item]
    }

    /// Shows the Settings › Shortcuts binding next to the menu item (letters
    /// and digits only, like the Capture menu).
    static func applyShortcut(_ shortcut: KeyboardShortcut, to item: NSMenuItem) {
        let key = keyCodeToString(shortcut.keyCode)
        guard key.count == 1 else { return }
        item.keyEquivalent = key.lowercased()
        item.keyEquivalentModifierMask = shortcut.modifiers.intersection([.command, .option, .control, .shift])
    }
}
