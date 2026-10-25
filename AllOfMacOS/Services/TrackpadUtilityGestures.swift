import AppKit
import ApplicationServices

/// Swish's two-finger utility gestures:
///
/// - **Space switching**: with two fingers on the trackpad and the pointer in
///   the menu-bar band at the top of any screen, a horizontal swipe switches
///   to the previous/next Space (macOS direction: fingers right → the Space
///   on the left, exactly like the system three-finger swipe).
/// - **Dock quit**: a two-finger pinch-in while the pointer hovers a Dock
///   icon quits that app (cooperative terminate, forced if it ignores us).
///
/// Fed from TrackpadMonitor's touch stream — two-finger frames only, so the
/// three-finger window gestures and normal scrolling stay untouched.
@MainActor
final class TrackpadUtilityGestures: ObservableObject {
    static let shared = TrackpadUtilityGestures()

    static let spacesEnabledKey = "AOMTopBarSpaceSwipe"
    static let dockQuitEnabledKey = "AOMDockPinchQuit"

    /// Test seams.
    var switchSpace: (Bool) -> Void = { toLeft in
        ActionExecutor.executeAction(TriggerAction(actionType: toLeft ? .switchSpaceLeft : .switchSpaceRight))
    }
    var quitApplication: (NSRunningApplication) -> Void = { app in
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !app.isTerminated { app.forceTerminate() }
        }
    }
    var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Test seam for the menu-bar band check.
    var cursorInTopBand: (CGPoint) -> Bool = { TrackpadUtilityGestures.cursorInTopBand($0) }
    /// Test seam: the "not inside our own app" guard (host-app test runs
    /// would otherwise depend on whatever happens to be frontmost).
    var isOutsideOwnApp: () -> Bool = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private var twoFingerStart: (centroid: CGPoint, spread: CGFloat)?
    private var spaceFired = false
    private var dockQuitFired = false
    private var lastFireAt: TimeInterval = 0

    var spacesEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.spacesEnabledKey) as? Bool ?? true
    }
    var dockQuitEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.dockQuitEnabledKey) as? Bool ?? true
    }
    /// True when any utility gesture can fire — the trackpad hardware must
    /// stay up for these even without trackpad triggers.
    var anyLayerEnabled: Bool { spacesEnabled || dockQuitEnabled }

    /// Entry: every touch frame. Two fingers begin a gesture, any other count
    /// ends it (fires nothing).
    func observe(points: [TouchPoint], timestamp: Double) {
        // Spatial gestures (top band, Dock) are global — no frontmost guard.
        guard !ScreenLock.isLocked else {
            reset(); return
        }
        guard points.count == 2 else {
            // 0 or 1 finger ends; 3+ belongs to the window gesture layer.
            if points.count != 3 { reset() }
            return
        }
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
           spread / start.spread < 0.62, dockAppUnderCursor() != nil {
            dockQuitFired = true
            lastFireAt = timestamp
            if let app = dockAppUnderCursor() { quitApplication(app) }
            return
        }

        // Horizontal swipe in the top band switches Spaces.
        guard spacesEnabled, !spaceFired else { return }
        let cursor = cursorLocation()
        guard cursorInTopBand(cursor) else { return }
        let dx = centroid.x - start.centroid.x
        let dy = abs(centroid.y - start.centroid.y)
        // ~14% of the pad horizontally, mostly flat, no recent fire.
        guard abs(dx) > 0.14, abs(dx) > dy * 1.6, timestamp - lastFireAt > 0.35 else { return }
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
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
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
