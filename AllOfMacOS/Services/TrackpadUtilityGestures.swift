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
/// - **Dock and menu-bar gestures** (3.3.2, Swish 1.13): taps, double taps,
///   tap and hold, swipes and pinch out over a Dock icon or the menu bar; see
///   `SwishDockMenuBarGestures.swift`. One pure state machine
///   (`UtilityGestureRecognizer`) classifies every two-finger touch, and the
///   Dock icon under the pointer is looked up once per gesture, when it
///   engages — never per frame.
///
/// Fed from TrackpadMonitor's touch stream — two-finger frames only, so the
/// three-finger window gestures and normal scrolling stay untouched. Every
/// gesture obeys the same pause check as every trigger (`AutomationGate`),
/// the screen lock and Swish's hold-still cancel.
@MainActor
final class TrackpadUtilityGestures: ObservableObject {
    static let shared = TrackpadUtilityGestures()

    nonisolated static let spacesEnabledKey = "AOMTopBarSpaceSwipe"
    nonisolated static let dockQuitEnabledKey = "AOMDockPinchQuit"
    /// Swish's Dock gestures (tap and hold, swipes, double tap, pinch out). Default on.
    nonisolated static let dockGesturesKey = "AOMDockGestures"
    /// Swish's menu-bar gestures (tap and hold, double tap, swipes up and down, ⌘ swipes). Default on.
    nonisolated static let menuBarGesturesKey = "AOMMenuBarGestures"
    /// Frames from one device arrive at 60 Hz or more while fingers rest on
    /// it; a longer silence means the gesture's device was lifted, slept or
    /// disconnected without a final empty frame.
    nonisolated static let deviceSilence: Double = 0.25
    /// How soon a second menu-bar swipe down (or up) counts as "twice".
    nonisolated static let repeatWindow: Double = 1.0
    /// How far (points) the pointer may move between the taps of a double tap.
    nonisolated static let doubleTapDistance: CGFloat = 8

    /// Test seams.
    var switchSpace: (Bool) -> Void = { toLeft in
        ActionExecutor.executeAction(TriggerAction(actionType: toLeft ? .switchSpaceLeft : .switchSpaceRight))
    }
    var quitApplication: (NSRunningApplication) -> Void = { app in
        TrackpadUtilityGestures.politeQuit(app)
    }
    var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Test seam for the Dock icon under the pointer (a window-server check,
    /// then at most one Accessibility hit-test).
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
    /// Test seam for the hold-still cancel time (seconds, 0 = off).
    var holdCancelSeconds: () -> Double = { TitleBarWindowSnap.holdCancelSeconds() }
    /// Test seam for every app, window and display the Dock and menu-bar
    /// gestures touch.
    var desktop: GestureDesktop = SystemGestureDesktop.shared
    /// Test seams: the modifier keys (⇧ secondary, ⌘ screen), the window
    /// under the pointer (window server: layer and owner), the HUD line and
    /// the haptic those gestures give.
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var windowUnderPointer: (CGPoint) -> (layer: Int, pid: pid_t)? = { DockLookup.windowUnder($0) }
    var announce: (_ title: String, _ detail: String?) -> Void = { title, detail in
        TrackpadUtilityGestures.showHUD(title, detail)
    }
    var haptic: () -> Void = { TrackpadUtilityGestures.tapHaptic() }

    /// The default `announce`: a short HUD line.
    static func showHUD(_ title: String, _ detail: String?) {
        GestureHUD.shared.show(title: title, detail: detail)
    }

    /// The default `haptic`: the title-bar snap's haptic setting applies.
    static func tapHaptic() {
        let on = UserDefaults.standard.object(forKey: TitleBarWindowSnap.hapticKey) as? Bool ?? true
        _ = GestureHaptics.shared.feedback(enabled: on)
    }

    private var twoFingerStart: (centroid: CGPoint, spread: CGFloat)?
    private var lastFireAt: TimeInterval = 0
    /// The trackpad the current gesture started on, and when it last spoke.
    private var gestureDevice: UInt64?
    private var lastDeviceFrameAt: Double = 0
    /// Taps, holds, swipes, pinches and Swish's hold-still cancel (2 s without
    /// moving spends the touch: a hand left on the menu bar or a Dock icon
    /// never switches a Space or quits an app).
    private var recognizer = UtilityGestureRecognizer()

    /// Where this touch acts, decided once, at its first gesture.
    private enum Place {
        case menuBar(CGPoint)
        case dock(NSRunningApplication)
        case nowhere
    }
    private var place: Place?
    /// Per touch: the app walk and the window walk being chained, and the
    /// window switcher this touch opened or scrolled.
    private var appWalk: AppCycle?
    private var windowWalk: WindowCycle?
    private var switcherOpened = false
    private var switcherScrolled = false
    /// Across touches: the first tap of a possible double tap, the last
    /// menu-bar swipe down and up ("twice"), and what AOM minimized (settable
    /// so tests start from an empty stack).
    private var lastTap: (at: Double, mouse: CGPoint)?
    private var lastMenuBarMinimize: Double?
    private var lastMenuBarRestore: Double?
    var minimized = MinimizedWindowStack()
    /// Menu-bar window moves (unsnap, ⌘ display moves) still running.
    private var moving = false

    var spacesEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.spacesEnabledKey) as? Bool ?? true
    }
    var dockQuitEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.dockQuitEnabledKey) as? Bool ?? true
    }
    var dockGesturesEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.dockGesturesKey) as? Bool ?? true
    }
    var menuBarGesturesEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.menuBarGesturesKey) as? Bool ?? true
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
        return spacesEnabled || dockQuitEnabled || dockGesturesEnabled || menuBarGesturesEnabled
            || (UserDefaults.standard.object(forKey: TitleBarWindowSnap.enabledKey) as? Bool ?? false)
    }

    /// Entry: every touch frame. Two fingers begin a gesture, any other count
    /// ends it. `device` keeps one gesture on one trackpad when several are
    /// connected.
    func observe(points: [TouchPoint], timestamp: Double, device: UInt64 = 0) {
        // One finger moving the pointer, with no gesture under way, has
        // nothing to end: skip the pause and lock checks (an IPC each).
        if points.count < 2, gestureDevice == nil, !recognizer.isTouching { return }
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
            // Read before the lift reaches the recognizer, which forgets it.
            let spent = recognizer.isSpent
            // A lift can finish a tap, a double tap or a tap and hold.
            if let event = recognizer.feed(points, at: timestamp) { handle(event, at: timestamp) }
            if points.count >= 3 {
                // A third finger is no Space swipe, as on a title bar.
                spaceArmed = nil
                spaceCancelled = true
            } else if let toLeft = spaceArmed, !spent, spacesEnabled {
                // 3.3.2: the Space switches when the fingers lift, so resting
                // them still for the hold-cancel time after swiping cancels
                // it (Swish), not only resting before the swipe.
                spaceArmed = nil
                let sinceLastFire = timestamp - lastFireAt
                if sinceLastFire > Self.spaceRefireInterval || sinceLastFire < 0 {
                    lastFireAt = timestamp
                    switchSpace(toLeft)
                }
            }
            // 0 or 1 finger ends; 3+ belongs to the window gesture layer.
            if points.count != 3 { endTouch() }
            return
        }
        if gestureDevice == nil { gestureDevice = device; lastDeviceFrameAt = timestamp }
        let centroid = Self.centroid(points)
        let spread = Self.spread(points)
        if twoFingerStart == nil {
            twoFingerStart = (centroid, spread)
            spaceArmed = nil
            spaceCancelled = false
            topBandOverWindow = nil
            recognizer.tuning.holdCancel = holdCancelSeconds()
        }
        if let event = recognizer.feed(points, at: timestamp) { handle(event, at: timestamp) }
        guard let start = twoFingerStart else { return }

        // Fingers resting without moving for the hold-cancel time (Swish: 2 s)
        // end this gesture until they lift: a hand left on the menu bar or a
        // Dock icon never switches a Space or quits an app.
        guard !recognizer.isSpent else { spaceArmed = nil; return }
        armSpaceSwipe(centroid: centroid, start: start.centroid)
    }

    /// The Space the top-band swipe will switch to when the fingers lift
    /// (true: the one on the left), nil while none is armed.
    private var spaceArmed: Bool?
    /// A third finger joined this touch: it switches no Space.
    private var spaceCancelled = false
    /// Whether an ordinary window lies under the band at the pointer, asked
    /// of the window server once per touch (nil: not asked yet).
    private var topBandOverWindow: Bool?
    /// How far (pad units) the fingers travel sideways to arm the Space swipe.
    nonisolated static let spaceSwipeDistance: CGFloat = 0.14
    /// Two Space switches from separate touches at least this far apart.
    nonisolated static let spaceRefireInterval: Double = 0.2

    /// The top-band Space swipe: about 14 % of the pad sideways and mostly
    /// flat arms it, the direction follows the fingers, and back near where
    /// they landed it disarms. The switch itself happens on lift (`observe`).
    private func armSpaceSwipe(centroid: CGPoint, start: CGPoint) {
        guard spacesEnabled, !spaceCancelled else { return }
        let cursor = cursorLocation()
        guard cursorInTopBand(cursor) else { return }
        let dx = centroid.x - start.x
        let dy = abs(centroid.y - start.y)
        if abs(dx) > Self.spaceSwipeDistance, abs(dx) > dy * 1.6 {
            // With the menu-bar gestures on, a swipe after tap and hold
            // switches apps and a ⌘ swipe moves the snapped windows instead.
            if menuBarGesturesEnabled, recognizer.isHeld || modifierFlags().contains(.command) {
                spaceArmed = nil
                return
            }
            // An ordinary window under the band (the menu bar hidden, a
            // full-screen app, a display without a menu bar) is the title-bar
            // snap's, as in `resolvePlace` (3.3.2 review: the Space switched
            // while the snap previewed a half on the same swipe).
            if topBandOverWindow == nil {
                // Resolved as the menu bar already: no window there.
                if case .menuBar? = place { topBandOverWindow = false }
                else { topBandOverWindow = windowUnderPointer(cursor)?.layer == 0 }
            }
            guard topBandOverWindow == false else { return }
            // macOS direction: fingers right reveals the Space on the left.
            spaceArmed = dx > 0
        } else if abs(dx) < Self.spaceSwipeDistance / 2 {
            // Back near where the fingers landed: lifting switches nothing.
            spaceArmed = nil
        }
    }

    /// The fingers lifted: a scrolled window switcher takes its selection
    /// (the ⌘-Tab grammar), and this touch's state goes.
    private func endTouch() {
        if switcherScrolled, desktop.switcherIsShowing { desktop.confirmSwitcher() }
        twoFingerStart = nil
        spaceArmed = nil
        spaceCancelled = false
        topBandOverWindow = nil
        gestureDevice = nil
        place = nil
        appWalk = nil
        windowWalk = nil
        switcherOpened = false
        switcherScrolled = false
    }

    /// Paused, locked or handed to another trackpad: drop the touch and any
    /// tap waiting for its second half, without acting.
    private func reset() {
        switcherScrolled = false
        endTouch()
        recognizer.reset()
        lastTap = nil
    }

    // MARK: Gestures

    private func handle(_ event: UtilityGestureRecognizer.Event, at timestamp: Double) {
        switch event {
        case .tap:
            lastTap = (timestamp, cursorLocation())
        case .doubleTap:
            let mouse = cursorLocation()
            defer { lastTap = nil }
            guard let first = lastTap,
                  hypot(first.mouse.x - mouse.x, first.mouse.y - mouse.y) <= Self.doubleTapDistance else { return }
            switch resolvePlace(dockFirst: false) {
            case .menuBar(let point): if menuBarGesturesEnabled { unsnapWindows(from: point) }
            case .dock(let app): if dockGesturesEnabled, mayAct(on: app) { dockDoubleTap(app.processIdentifier) }
            case .nowhere: break
            }
        case .holdBegan:
            // Swish answers a tap and hold with a haptic, only where it means something.
            switch resolvePlace(dockFirst: false) {
            case .menuBar: if menuBarGesturesEnabled { haptic() }
            case .dock(let app): if dockGesturesEnabled, mayAct(on: app) { haptic() }
            case .nowhere: break
            }
        case .holdReleased:
            switch resolvePlace(dockFirst: false) {
            case .menuBar:
                guard menuBarGesturesEnabled else { return }
                log("Menu-bar gesture: window switcher")
                if !desktop.switcherIsShowing { desktop.showSwitcher() }
            case .dock(let app):
                guard dockGesturesEnabled, mayAct(on: app) else { return }
                activateFrontWindow(of: app.processIdentifier)
            case .nowhere: break
            }
        case .swipe(let direction, let held, _):
            switch resolvePlace(dockFirst: false) {
            case .menuBar(let point):
                if menuBarGesturesEnabled { menuBarSwipe(direction, held: held, at: point, timestamp: timestamp) }
            case .dock(let app):
                if dockGesturesEnabled, mayAct(on: app) { dockSwipe(direction, pid: app.processIdentifier) }
            case .nowhere: break
            }
        case .pinchIn:
            // The Dock first, as before 3.3.2: a pinch near the top edge over
            // the Dock (rare) does the obvious thing.
            guard dockQuitEnabled, case .dock(let app) = resolvePlace(dockFirst: true) else { return }
            lastFireAt = timestamp
            quitApplication(app)
        case .pinchOut:
            guard dockGesturesEnabled, case .dock(let app) = resolvePlace(dockFirst: true), mayAct(on: app) else { return }
            let pid = app.processIdentifier
            log("Dock gesture: new window in \(desktop.appName(pid) ?? "app")")
            desktop.activate(pid)
            if desktop.postNewWindow(to: pid) { haptic() } else {
                announce("Could Not Send ⌘N", "AOM needs permission to post keyboard events (Privacy & Security › Accessibility).")
            }
        case .holdCancelled:
            // An armed top-band Space swipe says it will not switch.
            if spaceArmed != nil { announce("Cancelled", nil) }
            if case .some(.nowhere) = place { return }
            if place != nil { log("Utility gesture cancelled: fingers held still") }
        }
    }

    /// The menu bar or the Dock icon under the pointer, looked up once per
    /// touch at its first gesture. The top band is plain geometry; the Dock
    /// costs a window-server check and at most one Accessibility hit-test. A
    /// pinch asks the Dock first (as the Dock pinch always did).
    private func resolvePlace(dockFirst: Bool) -> Place {
        if let place { return place }
        let cursor = cursorLocation()
        let dockOn = dockQuitEnabled || dockGesturesEnabled
        let resolved: Place
        if dockFirst, dockOn, let app = dockApp() {
            resolved = .dock(app)
        } else if cursorInTopBand(cursor), windowUnderPointer(cursor)?.layer != 0 {
            // An ordinary window under the band (the menu bar hidden, a
            // window's title bar at the very top) is the title-bar snap's.
            resolved = .menuBar(cursor)
        } else if !dockFirst, dockOn, let app = dockApp() {
            resolved = .dock(app)
        } else {
            resolved = .nowhere
        }
        place = resolved
        return resolved
    }

    /// Never AOM itself (its windows belong to the user's work in AOM), never
    /// an app that is gone, never an app AOM is paused for, even while
    /// another app is in front (3.3.2 review).
    private func mayAct(on app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier && !app.isTerminated
            && !TriggerSuppression.shared.isPaused(forApp: app.bundleIdentifier)
    }

    private func log(_ message: String) {
        GestureLog.shared.logFromAnyThread(message, level: .action)
    }

    // MARK: Menu bar

    private func menuBarSwipe(_ direction: UtilityGestureRecognizer.Direction, held: Bool, at point: CGPoint,
                              timestamp: Double) {
        let flags = modifierFlags()
        if flags.contains(.command) {
            moveSnappedWindows(toward: direction, from: point)
            return
        }
        if held {
            if direction.isHorizontal { switchApp(previous: direction == .left) } else { scrollSwitcher(down: direction == .down) }
            return
        }
        switch direction {
        case .down:
            let twice = lastMenuBarMinimize.map { timestamp >= $0 && timestamp - $0 <= Self.repeatWindow } ?? false
            lastMenuBarMinimize = timestamp
            minimizeWindows(from: point, everyScreen: twice || flags.contains(.shift))
        case .up:
            let twice = lastMenuBarRestore.map { timestamp >= $0 && timestamp - $0 <= Self.repeatWindow } ?? false
            lastMenuBarRestore = timestamp
            unminimizeWindows(from: point, everyScreen: twice || flags.contains(.shift))
        case .left, .right:
            break // The Space swipe (`observe`).
        }
    }

    /// Swish: "Swipe down to minimize all windows. Once for the current
    /// screen, twice or with the secondary modifier for all." One batch per swipe.
    private func minimizeWindows(from point: CGPoint, everyScreen: Bool) {
        let screens = desktop.screens()
        let frames = screens.map(\.frame)
        let here = desktop.screenIndex(containing: point)
        var done: [(window: GestureWindow, screen: CGRect?)] = []
        for (window, frame) in desktop.visibleWindows() {
            let index = WindowGeometry.screenIndex(for: frame, screens: frames)
            guard everyScreen || (index != nil && index == here) else { continue }
            if desktop.setMinimized(window, true) { done.append((window, index.map { frames[$0] })) }
        }
        minimized.push(done, source: .menuBar)
        log("Menu-bar gesture: minimized \(done.count) window(s)\(everyScreen ? " on every display" : "")")
        if done.isEmpty {
            announce("No Windows to Minimize", everyScreen ? nil : "Swipe down again for every display.")
        } else {
            haptic()
            announce("Minimized \(Self.count(done.count, "Window"))", everyScreen ? "Every display" : "This display")
        }
    }

    /// Swish: "Swipe up to unminimize all windows. Once for the current
    /// screen, twice or with the secondary modifier for all." The windows the
    /// swipe down minimized, newest batch first.
    private func unminimizeWindows(from point: CGPoint, everyScreen: Bool) {
        let screens = desktop.screens()
        let here = desktop.screenIndex(containing: point).map { screens[$0].frame }
        let windows = minimized.takeMenuBarBatch(on: everyScreen ? nil : here) { [desktop] in desktop.isMinimized($0) }
        let restored = windows.filter { desktop.setMinimized($0, false) }
        log("Menu-bar gesture: unminimized \(restored.count) window(s)")
        if restored.isEmpty {
            announce("Nothing to Unminimize", everyScreen ? "No windows minimized from the menu bar."
                     : "Swipe up again for every display.")
        } else {
            haptic()
            announce("Restored \(Self.count(restored.count, "Window"))", nil)
        }
    }

    /// Swish: "Double tap to unsnap all windows on the current screen. Use
    /// the secondary modifier for all screens." Only windows the title-bar
    /// snap placed and that still sit where it put them.
    private func unsnapWindows(from point: CGPoint) {
        guard !moving else { return }
        let everyScreen = modifierFlags().contains(.shift)
        let frames = desktop.screens().map(\.frame)
        let here = desktop.screenIndex(containing: point)
        var moves: [WindowMove] = []
        for (window, frame) in desktop.visibleWindows() {
            guard everyScreen || WindowGeometry.screenIndex(for: frame, screens: frames) == here,
                  let original = desktop.unsnapFrame(for: window, current: frame) else { continue }
            moves.append(WindowMove(window: window, to: original, anchorIn: nil))
        }
        log("Menu-bar gesture: unsnap \(moves.count) window(s)")
        guard !moves.isEmpty else {
            announce("No Snapped Windows", everyScreen ? nil : "Only windows AOM snapped on this display are put back.")
            return
        }
        haptic()
        run(moves) { [weak self] moved in
            self?.announce("Unsnapped \(Self.count(moved, "Window"))", nil)
        }
    }

    /// Swish: "Swipe [with the screen modifier] to move all snapped windows
    /// to the next screen in that direction", each keeping its cell.
    private func moveSnappedWindows(toward direction: UtilityGestureRecognizer.Direction, from point: CGPoint) {
        guard !moving else { return }
        let screens = desktop.screens()
        let frames = screens.map(\.frame)
        let way = SwishSnap.Direction(direction)
        guard let here = desktop.screenIndex(containing: point) else { return }
        guard let there = SwishSnap.screenIndex(toward: way, from: frames[here], screens: frames) else {
            announce("No Display \(SwishSnap.arrow(way))", nil)
            return
        }
        let margin = desktop.snapMargin
        let grid = desktop.snapGrid
        let almost = desktop.snapAlmost
        let destination = desktop.snapArea(screens[there].visible)
        let source = desktop.snapArea(screens[here].visible)
        let anchor = margin > 0 ? destination.insetBy(dx: margin, dy: margin) : destination
        var moves: [WindowMove] = []
        for (window, frame) in desktop.visibleWindows() where WindowGeometry.screenIndex(for: frame, screens: frames) == here {
            guard let place = desktop.snappedPlace(for: window, current: frame)
                    ?? SwishSnap.place(of: frame, visible: source, margin: margin, grid: grid, almost: almost) else { continue }
            let target = SwishSnap.targetFrame(place: place, visible: destination, margin: margin)
            moves.append(WindowMove(window: window, to: target, anchorIn: anchor) { [weak self] actual in
                self?.desktop.recordDisplayMove(of: window, from: frame, to: actual, place: place)
            })
        }
        log("Menu-bar gesture: move \(moves.count) snapped window(s) to the display \(SwishSnap.arrow(way))")
        guard !moves.isEmpty else {
            announce("No Snapped Windows", "Snap windows on this display first.")
            return
        }
        haptic()
        run(moves) { [weak self] moved in
            self?.announce("Moved \(Self.count(moved, "Window"))", "To the display \(SwishSnap.arrow(way))")
        }
    }

    /// Swish: "Tap, hold and … swipe left/right to directly activate the
    /// previous/next app." Chains within the touch.
    private func switchApp(previous: Bool) {
        if appWalk == nil { appWalk = desktop.appCycle() }
        guard let pid = appWalk?.step(previous: previous), !desktop.isFrontmost(pid) else {
            announce("No Other App", nil)
            return
        }
        log("Menu-bar gesture: \(previous ? "previous" : "next") app")
        if desktop.activate(pid) {
            haptic()
            announce(desktop.appName(pid) ?? "App", previous ? "Previous app" : "Next app")
        }
    }

    /// Swish: "Tap, hold and scroll to invoke the ⌘-tab app switcher": the
    /// first scroll opens the window switcher, the next ones move through it,
    /// and lifting takes the selection.
    private func scrollSwitcher(down: Bool) {
        if !switcherOpened, !desktop.switcherIsShowing {
            switcherOpened = true
            log("Menu-bar gesture: window switcher")
            desktop.showSwitcher()
            haptic()
            return
        }
        switcherOpened = true
        if desktop.scrollSwitcher(by: down ? 1 : -1) { switcherScrolled = true }
    }

    // MARK: Dock

    private func dockSwipe(_ direction: UtilityGestureRecognizer.Direction, pid: pid_t) {
        let all = modifierFlags().contains(.shift)
        switch direction {
        // Swish: "Swipe left or right to activate and chain windows of an app
        // in forward or backward order."
        case .left, .right: cycleWindows(of: pid, forward: direction == .left)
        case .down: minimizeWindows(of: pid, all: all)
        case .up: unminimizeWindows(of: pid, all: all)
        }
    }

    /// Swish: "Tap and hold to activate … an app's frontmost window."
    private func activateFrontWindow(of pid: pid_t) {
        let open = desktop.windows(of: pid).filter { !desktop.isMinimized($0) }
        let front = desktop.focusedWindow(of: pid).flatMap { focused in open.first { $0 == focused } } ?? open.first
        log("Dock gesture: activate \(desktop.appName(pid) ?? "app")")
        if let front { desktop.raise(front) }
        if desktop.activate(pid) { haptic() }
    }

    /// The first swipe on an app in the background brings it forward with its
    /// front window; each further swipe steps to the next (left) or previous
    /// (right) window and raises it.
    private func cycleWindows(of pid: pid_t, forward: Bool) {
        if windowWalk?.pid != pid {
            let open = desktop.windows(of: pid).filter { !desktop.isMinimized($0) }
            guard !open.isEmpty else {
                desktop.activate(pid)
                announce("No Open Windows", desktop.appName(pid))
                return
            }
            windowWalk = WindowCycle(pid: pid, windows: open)
            if !desktop.isFrontmost(pid), let first = windowWalk?.current {
                focus(first)
                return
            }
        }
        guard let next = windowWalk?.step(forward: forward) else { return }
        focus(next)
    }

    private func focus(_ window: GestureWindow) {
        log("Dock gesture: raise a window of \(desktop.appName(window.pid) ?? "app")")
        desktop.raise(window)
        desktop.activate(window.pid)
        haptic()
    }

    /// Swish: "Swipe down to minimize the frontmost window. Use the secondary
    /// modifier to minimize all windows."
    private func minimizeWindows(of pid: pid_t, all: Bool) {
        let open = desktop.windows(of: pid).filter { !desktop.isMinimized($0) }
        guard !open.isEmpty else {
            announce("No Windows to Minimize", desktop.appName(pid))
            return
        }
        let front = desktop.focusedWindow(of: pid).flatMap { focused in open.first { $0 == focused } } ?? open[0]
        var done: [(window: GestureWindow, screen: CGRect?)] = []
        for window in all ? open : [front] where desktop.setMinimized(window, true) {
            done.append((window, nil))
        }
        minimized.push(done, source: .dock)
        log("Dock gesture: minimized \(done.count) window(s) of \(desktop.appName(pid) ?? "app")")
        if !done.isEmpty { haptic() }
    }

    /// Swish: "Swipe up to unminimize and chain the last window. Use the
    /// secondary modifier to unminimize all windows." The window AOM minimized
    /// last comes first; otherwise one the app has minimized. Each further
    /// swipe up in the touch brings back the next.
    private func unminimizeWindows(of pid: pid_t, all: Bool) {
        let isMinimized: (GestureWindow) -> Bool = { [desktop] in desktop.isMinimized($0) }
        var targets: [GestureWindow]
        if all {
            let remembered = minimized.takeAll(of: pid, isMinimized: isMinimized)
            targets = remembered + desktop.windows(of: pid).filter { isMinimized($0) && !remembered.contains($0) }
        } else if let newest = minimized.takeNewest(of: pid, isMinimized: isMinimized) {
            targets = [newest]
        } else {
            targets = desktop.windows(of: pid).first(where: isMinimized).map { [$0] } ?? []
        }
        guard !targets.isEmpty else {
            announce("No Minimized Windows", desktop.appName(pid))
            return
        }
        let restored = targets.filter { desktop.setMinimized($0, false) }
        log("Dock gesture: unminimized \(restored.count) window(s) of \(desktop.appName(pid) ?? "app")")
        if let last = restored.first { focus(last) }
    }

    /// Swish: "Double tap to hide all windows of an application. Use the
    /// secondary modifier to hide all other apps." (A two-finger tap is also
    /// a right-click when Tap to click is on, so the Dock's menu may open too.)
    private func dockDoubleTap(_ pid: pid_t) {
        let others = modifierFlags().contains(.shift)
        log("Dock gesture: hide \(others ? "other apps" : desktop.appName(pid) ?? "app")")
        if others ? desktop.hideOthers(keeping: pid) : desktop.hide(pid) { haptic() }
    }

    // MARK: Window moves

    private struct WindowMove {
        let window: GestureWindow
        let to: CGRect
        let anchorIn: CGRect?
        var done: ((CGRect) -> Void)? = nil
    }

    /// One window after the other, each through the same commit as a title-bar
    /// snap; stops when AOM is paused half-way.
    private func run(_ moves: [WindowMove], completion: @escaping (Int) -> Void) {
        moving = true
        var moved = 0
        func step(_ index: Int) {
            guard index < moves.count, isAllowed() else {
                moving = false
                completion(moved)
                return
            }
            let move = moves[index]
            desktop.move(move.window, to: move.to, anchorIn: move.anchorIn) { actual in
                if let actual {
                    moved += 1
                    move.done?(actual)
                }
                step(index + 1)
            }
        }
        step(0)
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    // MARK: Quit

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

    /// The menu-bar band: the top 12 pt of any screen's frame (the menu bar
    /// itself is 24-37 pt; Swish uses the very top so ordinary scrolling near
    /// the top of a window never trips it).
    static func cursorInTopBand(_ point: CGPoint, screens: [NSRect] = NSScreen.screens.map(\.frame)) -> Bool {
        screens.contains { screen in
            guard screen.contains(point) else { return false }
            let top = screen.maxY
            return point.y > top - 12
        }
    }

    /// The Dock icon under the cursor, resolved through the Dock's AX tree and
    /// matched by bundle URL, bundle identifier, then name
    /// (`DockItemMatcher`), returning the running application it represents.
    func dockAppUnderCursor() -> NSRunningApplication? {
        DockLookup.app(at: cursorLocation())
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

extension SwishSnap.Direction {
    /// A utility-gesture swipe as a title-bar direction (the display picker
    /// works in Accessibility coordinates, where up is towards smaller y).
    init(_ direction: UtilityGestureRecognizer.Direction) {
        switch direction {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        }
    }
}
