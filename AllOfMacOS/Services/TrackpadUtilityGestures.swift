import AppKit
import ApplicationServices

/// The one thing the Dock pinch needs from an app: the polite quit request and
/// enough state to tell whether it took effect. `NSRunningApplication`
/// conforms; tests substitute a fake so no real app is ever asked to quit.
/// There is deliberately no force-terminate requirement here.
protocol PoliteQuitTarget: AnyObject {
    var localizedName: String? { get }
    var isTerminated: Bool { get }
    @discardableResult func terminate() -> Bool
}

extension NSRunningApplication: PoliteQuitTarget {}

/// Swish's two-finger utility gestures:
///
/// - **Space switching**: with two fingers on the trackpad and the pointer in
///   the menu-bar band at the top of any screen, a horizontal swipe switches
///   to the previous/next Space (macOS direction: fingers right → the Space
///   on the left, exactly like the system three-finger swipe).
/// - **Dock quit**: a two-finger pinch-in while the pointer hovers a Dock
///   icon asks that app to quit — the same request as its Quit menu item. It
///   is never escalated to a forced termination (see `politeQuit`).
///
/// Fed from TrackpadMonitor's touch stream — two-finger frames only, so the
/// three-finger window gestures and normal scrolling stay untouched. Both
/// gestures obey the same pause check as every trigger (`AutomationGate`).
@MainActor
final class TrackpadUtilityGestures: ObservableObject {
    static let shared = TrackpadUtilityGestures()

    nonisolated static let spacesEnabledKey = "AOMTopBarSpaceSwipe"
    nonisolated static let dockQuitEnabledKey = "AOMDockPinchQuit"
    /// Frames from one device arrive at 60 Hz or more while fingers rest on
    /// it; a longer silence means the gesture's device was lifted, slept or
    /// disconnected without a final empty frame.
    nonisolated static let deviceSilence: Double = 0.25

    /// Test seams.
    var switchSpace: (Bool) -> Void = { toLeft in
        ActionExecutor.executeAction(TriggerAction(actionType: toLeft ? .switchSpaceLeft : .switchSpaceRight))
    }
    var quitApplication: (NSRunningApplication) -> Void = { app in
        TrackpadUtilityGestures.politeQuit(app)
    }
    var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Test seam for the Dock icon under the pointer (a real AX lookup).
    var dockApp: () -> NSRunningApplication? = { TrackpadUtilityGestures.shared.dockAppUnderCursor() }
    /// Test seam for the menu-bar band check.
    var cursorInTopBand: (CGPoint) -> Bool = { TrackpadUtilityGestures.cursorInTopBand($0) }
    /// Test seam: the "not inside our own app" guard (host-app test runs
    /// would otherwise depend on whatever happens to be frontmost).
    var isOutsideOwnApp: () -> Bool = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
    }
    /// The shared pause check (master switch, timed/indefinite pause, per-app
    /// pause, held modifiers, palm rejection). Injectable for tests.
    var isAllowed: () -> Bool = { AutomationGate.allows(.trackpad) }

    private var twoFingerStart: (centroid: CGPoint, spread: CGFloat)?
    private var spaceFired = false
    private var dockQuitFired = false
    private var lastFireAt: TimeInterval = 0
    /// The trackpad the current gesture started on, and when it last spoke.
    private var gestureDevice: UInt64?
    private var lastDeviceFrameAt: Double = 0

    var spacesEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.spacesEnabledKey) as? Bool ?? true
    }
    var dockQuitEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.dockQuitEnabledKey) as? Bool ?? true
    }
    /// Injectable so tests are not at the mercy of the session's lock state
    /// (a headless or locked session reports locked, which would swallow every
    /// gesture). Defaults to the real screen-lock probe.
    var isScreenLocked: () -> Bool = { ScreenLock.isLocked }
    /// True when anything that reads the two-finger stream is on — the utility
    /// gestures or the title-bar snap — so the trackpad hardware stays up even
    /// without trackpad triggers. While AOM is switched off nothing may act on
    /// the stream, so the hardware is released too.
    var anyLayerEnabled: Bool {
        guard AutomationGate.isOn else { return false }
        return spacesEnabled || dockQuitEnabled
            || (UserDefaults.standard.object(forKey: TitleBarWindowSnap.enabledKey) as? Bool ?? false)
    }

    /// Entry: every touch frame. Two fingers begin a gesture, any other count
    /// ends it (fires nothing). `device` keeps one gesture on one trackpad
    /// when several are connected.
    func observe(points: [TouchPoint], timestamp: Double, device: UInt64 = 0) {
        // Spatial gestures (top band, Dock) are global — no frontmost guard —
        // but they pause with the rest of AOM.
        guard !isScreenLocked(), isAllowed() else {
            reset(); return
        }
        if let owner = gestureDevice, owner != device {
            // Another trackpad: ignore it while the gesture's own device is
            // live, so a resting thumb on the second pad cannot end or bend it.
            guard timestamp - lastDeviceFrameAt > Self.deviceSilence else { return }
            reset()
        }
        if gestureDevice == device { lastDeviceFrameAt = timestamp }
        guard points.count == 2 else {
            // 0 or 1 finger ends; 3+ belongs to the window gesture layer.
            if points.count != 3 { reset() }
            return
        }
        if gestureDevice == nil { gestureDevice = device; lastDeviceFrameAt = timestamp }
        let centroid = Self.centroid(points)
        let spread = Self.spread(points)
        if twoFingerStart == nil {
            twoFingerStart = (centroid, spread)
            spaceFired = false
            dockQuitFired = false
        }
        guard let start = twoFingerStart else { return }

        // Pinch-in over the Dock quits the hovered app — checked first so a
        // pinch near the top edge over the Dock (rare) does the obvious thing.
        if dockQuitEnabled, !dockQuitFired, start.spread > 0.08,
           spread / start.spread < 0.62, let app = dockApp() {
            dockQuitFired = true
            lastFireAt = timestamp
            quitApplication(app)
            return
        }

        // Horizontal swipe in the top band switches Spaces.
        guard spacesEnabled, !spaceFired else { return }
        let cursor = cursorLocation()
        guard cursorInTopBand(cursor) else { return }
        let dx = centroid.x - start.centroid.x
        let dy = abs(centroid.y - start.centroid.y)
        // ~14% of the pad horizontally, mostly flat, no recent fire. A clock
        // that went backwards (a replayed or different time base) is not a
        // recent fire.
        let sinceLastFire = timestamp - lastFireAt
        guard abs(dx) > 0.14, abs(dx) > dy * 1.6, sinceLastFire > 0.35 || sinceLastFire < 0 else { return }
        spaceFired = true
        lastFireAt = timestamp
        // macOS direction: fingers right reveals the Space on the left.
        switchSpace(dx > 0)
        // A long drag can chain: rebase so the opposite direction can fire too.
        twoFingerStart = (centroid, start.spread)
        spaceFired = false
    }

    private func reset() {
        twoFingerStart = nil
        spaceFired = false
        dockQuitFired = false
        gestureDevice = nil
    }

    /// Asks `app` to quit and never escalates.
    ///
    /// `terminate()` is the same request as Quit in the app's own menu: the
    /// app may ask to save, show a sheet or decline, and that answer belongs
    /// to the user. Until 3.3.0 a 1.5 s timer then called `forceTerminate()`,
    /// which killed apps that were only waiting on a "Save changes?" sheet and
    /// lost the unsaved work (Apple: force termination does not give the app a
    /// chance to save). Now, if the app is still running after `gracePeriod`,
    /// the HUD says so and points at Force Quit, which stays a separate,
    /// confirmed action.
    static func politeQuit(_ app: PoliteQuitTarget,
                           gracePeriod: TimeInterval = 3,
                           report: @escaping (_ title: String, _ detail: String) -> Void = { title, detail in
                               GestureHUD.shared.show(title: title, detail: detail)
                           },
                           after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
                               DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                           }) {
        let name = app.localizedName ?? "The app"
        guard !app.isTerminated else { return }
        guard app.terminate() else {
            report("Could Not Ask \(name) to Quit", "macOS did not deliver the quit request. Nothing was closed.")
            return
        }
        after(gracePeriod) { [weak app] in
            guard let app, !app.isTerminated else { return }
            report("\(name) Is Still Open",
                   "It may be asking to save changes. AOM never forces an app to quit; use Force Quit (⌥⌘⎋) if it is not responding.")
        }
    }

    /// The menu-bar band: the top 6 pt of any screen's frame (the menu bar
    /// itself is 24-37 pt; Swish uses the very top so ordinary scrolling near
    /// the top of a window never trips it).
    static func cursorInTopBand(_ point: CGPoint, screens: [NSRect] = NSScreen.screens.map(\.frame)) -> Bool {
        screens.contains { screen in
            guard screen.contains(point) else { return false }
            let top = screen.maxY
            return point.y > top - 12
        }
    }

    /// The Dock icon under the cursor, resolved through the Dock's AX tree,
    /// returning the running application it represents.
    func dockAppUnderCursor() -> NSRunningApplication? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first != nil else { return nil }
        // The Dock only exposes its tiles while it is the hit app; ask the
        // system-wide element at the pointer and walk up to a dock item.
        let systemWide = AXUIElementCreateSystemWide()
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let point = cursorLocation()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(top - point.y), &hit) == .success,
              let hit else { return nil }
        var current = hit
        for _ in 0..<16 {
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role) == .success else { return nil }
            if (role as? String) == "AXDockItem" {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(current, kAXTitleAttribute as CFString, &title)
                guard let name = title as? String, !name.isEmpty else { return nil }
                // Running apps expose a menu bar-less window list; match name.
                return NSWorkspace.shared.runningApplications.first {
                    $0.localizedName == name && $0.activationPolicy == .regular && !$0.isTerminated
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    private static func centroid(_ points: [TouchPoint]) -> CGPoint {
        CGPoint(x: CGFloat(points.map(\.x).reduce(0, +) / 2),
                y: CGFloat(points.map(\.y).reduce(0, +) / 2))
    }

    private static func spread(_ points: [TouchPoint]) -> CGFloat {
        guard points.count == 2 else { return 0 }
        return hypot(CGFloat(points[0].x - points[1].x), CGFloat(points[0].y - points[1].y))
    }
}
