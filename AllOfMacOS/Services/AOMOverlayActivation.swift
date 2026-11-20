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

    /// 6.8: a capture starts without touching AOM's windows, so AOM itself
    /// can be captured (the user asked for it) and nothing vanishes when the
    /// shortcut is pressed. Only a Dock reopen is held off meanwhile.
    static func beginCapture() {
        MainActor.assumeIsolated { suppressReopenUntil = Date().addingTimeInterval(3) }
    }

    /// Pure: in a front-to-back window list (CGWindowList order) of the
    /// windows above ours, the normal-layer window of another app that sits
    /// directly above it — the last one listed.
    static func windowDirectlyAbove(in above: [[String: Any]], ownPID: pid_t) -> CGWindowID? {
        above.last { info in
            (info[kCGWindowLayer as String] as? Int) == 0 && (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID
        }.flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    /// The other app's window directly above `window` now, if any.
    static func windowDirectlyAbove(_ window: NSWindow) -> CGWindowID? {
        guard window.windowNumber > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements],
                                                    CGWindowID(window.windowNumber)) as? [[String: Any]] else { return nil }
        return windowDirectlyAbove(in: list, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Hides the main window immediately for screen captures so it does not
    /// obstruct the desktop or appear inside captured frames. 6.8: no longer
    /// used by captures (see `beginCapture`); kept for explicit callers.
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
    ///
    /// 6.8: activation also raises a main window that was open *behind*
    /// other apps ("the main window pops up"). When AOM was not the active
    /// app, the window goes back directly under the window that covered it.
    static func activateForOverlay() {
        MainActor.assumeIsolated {
            let window = mainWindow
            let wasVisible = window?.isVisible ?? false
            let coveredBy = (wasVisible && !NSApp.isActive) ? window.flatMap(windowDirectlyAbove) : nil
            suppressReopenUntil = Date().addingTimeInterval(3)
            NSApp.activate(ignoringOtherApps: true)
            guard let window else { return }
            putBack(window, wasVisible: wasVisible, coveredBy: coveredBy)
            // SwiftUI can re-order the window on the next display cycle.
            DispatchQueue.main.async { putBack(window, wasVisible: wasVisible, coveredBy: coveredBy) }
        }
    }

    @MainActor
    private static func putBack(_ window: NSWindow, wasVisible: Bool, coveredBy: CGWindowID?) {
        if shouldRestoreHiddenMainWindow(wasVisible: wasVisible, isVisibleNow: window.isVisible) {
            window.orderOut(nil)
        } else if let coveredBy, window.isVisible, !window.isKeyWindow {
            window.order(.below, relativeTo: Int(coveredBy))
        }
    }
}
