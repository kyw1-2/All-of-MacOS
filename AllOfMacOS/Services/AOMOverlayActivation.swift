import AppKit

/// Activation policy for overlay and capture flows.
///
/// `NSApp.activate(ignoringOtherApps:)` is what makes AOM's main window pop in
/// front of a screenshot or a quick-access card: the SwiftUI `WindowGroup`
/// keeps its window alive after `windowShouldClose` only orders it out, and an
/// activation can order that hidden window front again — the same mechanism the
/// Control-Tab switcher already works around.
enum AOMOverlayActivation {
    /// Pure decision: a window that was hidden before activation must not be
    /// left visible after it. A window that was already visible on purpose is
    /// left alone for general overlays.
    static func shouldRestoreHiddenMainWindow(wasVisible: Bool, isVisibleNow: Bool) -> Bool {
        !wasVisible && isVisibleNow
    }

    private static weak var registeredMainWindow: NSWindow?

    /// `AppDelegate` registers the window it manages so the guard never guesses.
    static func registerMainWindow(_ window: NSWindow?) {
        registeredMainWindow = window
    }

    /// The window a capture or overlay must never raise.
    static var mainWindow: NSWindow? {
        if let window = registeredMainWindow { return window }
        return NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
    }

    /// Reopen (`applicationShouldHandleReopen`) must not resurrect the main
    /// window while a capture or overlay is on screen — that is the other half
    /// of the same symptom, and it fires when macOS treats the activation as a
    /// reopen request.
    private static var suppressReopenUntil: Date = .distantPast

    /// A visible floating-or-higher panel means one of our overlays is up.
    static var isOverlayVisible: Bool {
        MainActor.assumeIsolated {
            NSApp.windows.contains {
                $0 is NSPanel && $0.isVisible && $0.level.rawValue >= NSWindow.Level.floating.rawValue
            }
        }
    }

    /// Pure decision for the reopen handler so it can be tested.
    static func shouldShowMainWindowOnReopen(hasVisibleWindows: Bool, overlayVisible: Bool,
                                             suppressUntil: Date, now: Date = Date()) -> Bool {
        !hasVisibleWindows && !overlayVisible && now >= suppressUntil
    }

    /// Called by the reopen handler; never raises the main window mid-capture.
    static func shouldHandleReopen(hasVisibleWindows: Bool) -> Bool {
        shouldShowMainWindowOnReopen(hasVisibleWindows: hasVisibleWindows,
                                     overlayVisible: isOverlayVisible,
                                     suppressUntil: suppressReopenUntil)
    }

    /// Hides the main window immediately for screen captures so it does not
    /// obstruct the desktop or appear inside captured frames.
    static func hideMainWindow() {
        MainActor.assumeIsolated {
            suppressReopenUntil = Date().addingTimeInterval(3)
            let nonPanels = NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain }
            for w in nonPanels {
                if w.isVisible {
                    w.orderOut(nil)
                }
            }
            if let window = mainWindow, window.isVisible {
                window.orderOut(nil)
            }
            CATransaction.flush()
        }
    }

    /// Activate for a general overlay flow (clipboard, annotation, hud) without
    /// bringing up a main window that was previously hidden.
    /// If the main window was already visible on screen, it is left untouched.
    static func activateForOverlay() {
        MainActor.assumeIsolated {
            let window = mainWindow
            let wasVisible = window?.isVisible ?? false
            suppressReopenUntil = Date().addingTimeInterval(3)
            NSApp.activate(ignoringOtherApps: true)
            guard let window else { return }
            if shouldRestoreHiddenMainWindow(wasVisible: wasVisible, isVisibleNow: window.isVisible) {
                window.orderOut(nil)
            }
            // SwiftUI can re-order the window on the next display cycle.
            DispatchQueue.main.async {
                if shouldRestoreHiddenMainWindow(wasVisible: wasVisible, isVisibleNow: window.isVisible) {
                    window.orderOut(nil)
                }
            }
        }
    }
}
