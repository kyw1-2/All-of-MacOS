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
/// - **3.3.3**: pinch twice on a Dock icon (minimize / unminimize all its
///   windows; a single pinch waits 0.35 s for the second), the Dock's windows
///   handed to the title-bar snap (`chainWindow`), the app's own menu as a
///   Dock icon, the menu bar's parts told apart (`MenuBarSpot`), scroll to
///   top, the macOS app switcher, and gestures on Mission Control thumbnails.
///
/// Fed from TrackpadMonitor's touch stream — two-finger frames only, so the
/// three-finger window gestures and normal scrolling stay untouched. Every
/// gesture obeys the same pause check as every trigger (`AutomationGate`),
/// the screen lock and Swish's hold-still cancel; an action on another app
/// also obeys that app's own pause, checked again right before it runs.
@MainActor
final class TrackpadUtilityGestures: ObservableObject {
    static let shared = TrackpadUtilityGestures()

    nonisolated static let spacesEnabledKey = "AOMTopBarSpaceSwipe"
    nonisolated static let dockQuitEnabledKey = "AOMDockPinchQuit"
    /// Swish's Dock gestures (tap and hold, swipes, double tap, pinch out). Default on.
    nonisolated static let dockGesturesKey = "AOMDockGestures"
    /// Swish's menu-bar gestures (tap and hold, double tap, swipes up and down, ⌘ swipes). Default on.
    nonisolated static let menuBarGesturesKey = "AOMMenuBarGestures"
    /// 3.3.3: Swish's "pinch in twice to minimize all windows" and "pinch out
    /// twice to unminimize all windows" on a Dock icon. Default on; a single
    /// pinch then waits `pinchRepeatWindow` before it quits or opens a window.
    nonisolated static let dockDoublePinchKey = "AOMDockDoublePinch"
    /// 3.3.3: the Dock gestures also work on the frontmost app's own menu (its
    /// name, next to the Apple menu), Swish's Application Menu option. Default off.
    nonisolated static let appMenuGesturesKey = "AOMAppMenuGestures"
    /// 3.3.3: Swish's menubarScrollToTop (an identifier Swish 1.13 never shows
    /// in its settings): a two-finger tap on the empty menu bar scrolls the
    /// front window to the top. Default off.
    nonisolated static let menuBarScrollToTopKey = "AOMMenuBarScrollToTop"
    /// 3.3.3: what tap, hold and scroll on the menu bar opens: "windows" (AOM's
    /// window switcher, as in 3.3.2; the default) or "apps" (the macOS ⌘-Tab
    /// app switcher, as in Swish).
    nonisolated static let menuBarSwitcherKey = "AOMMenuBarSwitcher"
    /// 3.3.3: gestures on a window's thumbnail in Mission Control and App
    /// Exposé (pinch in: close it, twice: quit its app; swipe down: minimize
    /// it). Default off.
    nonisolated static let missionControlGesturesKey = "AOMMissionControlGestures"
    /// The settings 3.3.3 adds here, for the backup list and the settings
    /// areas (`PresetManager`, which this stream does not edit).
    nonisolated static let settingsKeys333 = [dockDoublePinchKey, appMenuGesturesKey, menuBarScrollToTopKey,
                                              menuBarSwitcherKey, missionControlGesturesKey]
    /// Frames from one device arrive at 60 Hz or more while fingers rest on
    /// it; a longer silence means the gesture's device was lifted, slept or
    /// disconnected without a final empty frame.
    nonisolated static let deviceSilence: Double = 0.25
    /// How soon a second menu-bar swipe down (or up) counts as "twice".
    nonisolated static let repeatWindow: Double = 1.0
    /// How far (points) the pointer may move between the taps of a double tap.
    nonisolated static let doubleTapDistance: CGFloat = 8
    /// 3.3.3: how long a Dock pinch (or a Mission Control pinch in) waits for a
    /// second one: the title-bar snap's "twice" window.
    nonisolated static let pinchRepeatWindow: Double = 0.35
    /// The extra wait, once, when the next touch lands during it, so that
    /// touch has time to show whether it is the second pinch.
    nonisolated static let pinchRepeatExtension: Double = 0.15
    /// A waiting pinch runs when its fingers lift; lifting later than this
    /// after the pinch (frame time) takes it back instead.
    nonisolated static let pinchLiftLimit: Double = 2.0
    /// ⌘N goes out this long after the activation, so the new window opens in front.
    nonisolated static let newWindowDelay: Double = 0.15
    /// With nothing heard from the trackpad for this long, the app switcher
    /// AOM holds open is let go without switching (the touch was lost).
    nonisolated static let appSwitcherWatchdog: Double = 0.6

    enum SwitcherMode: String {
        case windows, apps
    }

    /// Test seams.
    var switchSpace: (Bool) -> Void = { toLeft in
        ActionExecutor.executeAction(TriggerAction(actionType: toLeft ? .switchSpaceLeft : .switchSpaceRight))
    }
    /// The quit request. Never under XCTest: a test that forgot its counting
    /// seam must not ask a real app to quit.
    var quitApplication: (NSRunningApplication) -> Void = { app in
        guard !PresetManager.isRunningTests else { return }
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
    /// 3.3.3: every delayed step (the wait for a second pinch, the ⌘N after an
    /// activation, a menu-bar tap's wait for a double tap, the app switcher's
    /// watchdog) goes through here; tests run the work by hand. The work
    /// checks again that it may act when it runs.
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// 3.3.3: whether AOM is paused for an app (its per-app pause). The gate
    /// keys that pause to the frontmost app; everything here that acts on
    /// another app asks about that app too, right before it acts.
    var isAppPaused: (pid_t) -> Bool = { pid in
        TriggerSuppression.shared.isPaused(forApp: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }
    /// 3.3.3: Swish's chain ("Tap and hold to activate and chain an app's
    /// frontmost window. This allows you to apply any window gesture
    /// afterwards"; "Swipe up to unminimize and chain the last window"). Each
    /// time a Dock gesture brings a window forward it is offered here; true
    /// means the title-bar snap took it, and the Dock then lets go of the rest
    /// of the touch so the two never act on the same motion. Wired by the
    /// integration step to `TitleBarWindowSnap.shared.beginChain(window:pid:reason:)`.
    var chainWindow: (GestureWindow) -> Bool = { _ in false }
    /// 3.3.3: the part of the menu bar under a point, and the early start of
    /// that lookup when two fingers land in the top band.
    var menuBarSpot: (CGPoint) -> MenuBarSpot = { MenuBarProbe.spot(at: $0) }
    var prefetchMenuBarSpot: (CGPoint) -> Void = { MenuBarProbe.prefetch(at: $0) }
    /// 3.3.3: the real window behind the Mission Control thumbnail under a
    /// point, nil when Mission Control is not showing or nothing matches.
    var missionControlWindow: (CGPoint) -> GestureWindow? = { TrackpadUtilityGestures.liveMissionControlWindow(at: $0) }
    /// 3.3.3: the clock of the app switcher's watchdog.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// The default `announce`: a short HUD line, unless the On-screen HUD
    /// setting is off (3.3.3, B06: these lines used to show regardless).
    /// Any thread: `GestureHUD` moves to main itself.
    nonisolated static func showHUD(_ title: String, _ detail: String?) {
        guard UserDefaults.standard.object(forKey: "AOMHUDEnabled") as? Bool ?? true else { return }
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
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Where this touch acts, decided once, at its first gesture.
    private enum Place {
        /// The empty menu-bar area (or no answer on which part it is).
        case menuBar(CGPoint)
        /// The frontmost app's own menu: the Dock's gestures for that app.
        case appMenu(NSRunningApplication)
        case dock(NSRunningApplication)
        /// A window's thumbnail in Mission Control or App Exposé.
        case missionControl(GestureWindow)
        /// The title-bar snap took the window this touch brought forward.
        case handedOff
        case nowhere
    }
    private var place: Place?
    /// Per touch: the app walk and the window walk being chained, and the
    /// window switcher this touch opened or scrolled.
    private var appWalk: AppCycle?
    private var windowWalk: WindowCycle?
    private var switcherOpened = false
    private var switcherScrolled = false
    /// The macOS app switcher this touch holds open (a synthetic ⌘ is down).
    private var appSwitcherEngaged = false
    private var lastFrameUptime: TimeInterval = 0
    /// Across touches: the first tap of a possible double tap, the last
    /// menu-bar swipe down and up ("twice"), and what AOM minimized (settable
    /// so tests start from an empty stack).
    private var lastTap: (at: Double, mouse: CGPoint)?
    private var lastMenuBarMinimize: Double?
    private var lastMenuBarRestore: Double?
    var minimized = MinimizedWindowStack()
    /// Menu-bar window moves (unsnap, ⌘ display moves) still running.
    private var moving = false

    /// A pinch waiting for its second half (3.3.3): what it was on, when
    /// (frame time) and what it does if no second pinch comes.
    private enum PinchKind { case pinchIn, pinchOut }
    private enum PinchOrigin { case dock, missionControl }
    private struct PendingPinch {
        let kind: PinchKind
        let origin: PinchOrigin
        let pid: pid_t
        let at: Double
        var token: Int
        var extended = false
        /// The fingers that pinched are still down. While they are, a third
        /// finger or the hold-still cancel takes the pinch back (S02), and it
        /// runs at their lift at the earliest, as a title-bar pinch does.
        var fingersDown = true
        /// The wait for a second pinch ended while the fingers were down.
        var waitOver = false
        let fire: () -> Void
    }
    private var pendingPinch: PendingPinch?
    /// A menu-bar tap waiting to see whether it is a double tap (scroll to top).
    private var pendingScrollToken: Int?
    private var workToken = 0

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
    var dockDoublePinchEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.dockDoublePinchKey) as? Bool ?? true
    }
    var appMenuGesturesEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.appMenuGesturesKey) as? Bool ?? false
    }
    var scrollToTopEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.menuBarScrollToTopKey) as? Bool ?? false
    }
    var menuBarSwitcherMode: SwitcherMode {
        UserDefaults.standard.string(forKey: Self.menuBarSwitcherKey).flatMap(SwitcherMode.init(rawValue:)) ?? .windows
    }
    var missionControlGesturesEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.missionControlGesturesKey) as? Bool ?? false
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
            || missionControlGesturesEnabled
            || (UserDefaults.standard.object(forKey: TitleBarWindowSnap.enabledKey) as? Bool ?? false)
    }

    /// Entry: every touch frame. Two fingers begin a gesture, any other count
    /// ends it. `device` keeps one gesture on one trackpad when several are
    /// connected.
    func observe(points: [TouchPoint], timestamp: Double, device: UInt64 = 0) {
        // One finger moving the pointer, with no gesture under way and no
        // fingers spent, has nothing to end: skip the pause and lock checks
        // (an IPC each).
        if points.count < 2, gestureDevice == nil, !recognizer.isTouching, !recognizer.isWaitingForLift { return }
        // Spatial gestures (top band, Dock) are global — no frontmost guard —
        // but they pause with the rest of AOM.
        guard !isScreenLocked(), isAllowed() else {
            // 3.3.3: what waits for a second pinch or tap goes too, and
            // fingers still down stay spent until they lift, so the remains
            // of the touch cannot act once AOM is back on. Another
            // trackpad's empty frame is no lift of those fingers.
            cancelPending()
            let owner = gestureDevice
            let fingersDown = recognizer.isTouching || recognizer.isWaitingForLift
            reset()
            if !points.isEmpty {
                recognizer.spendUntilLift()
                gestureDevice = device
                lastDeviceFrameAt = timestamp
            } else if fingersDown, let owner, owner != device {
                recognizer.spendUntilLift()
                gestureDevice = owner
            }
            return
        }
        if let owner = gestureDevice, owner != device {
            // Another trackpad: ignore it while the gesture's own device is
            // live, so a resting thumb on the second pad cannot end or bend it.
            guard timestamp - lastDeviceFrameAt > Self.deviceSilence else { return }
            // The gesture's trackpad went quiet without a lift: a pinch its
            // fingers made is taken back, not run.
            takeBackPinchOfThisTouch()
            reset()
        }
        if gestureDevice == device { lastDeviceFrameAt = timestamp }
        if appSwitcherEngaged { lastFrameUptime = now() }
        guard points.count == 2 else {
            // Read before the lift reaches the recognizer, which forgets it.
            let spent = recognizer.isSpent || recognizer.isWaitingForLift
            // A lift can finish a tap, a double tap or a tap and hold.
            if let event = recognizer.feed(points, at: timestamp) { handle(event, at: timestamp) }
            if points.count >= 3 {
                // 3.3.3 (S02): a third finger spends the touch until every
                // finger lifts: no Space swipe, nothing this touch opened is
                // taken, and a pinch it made that still waits is taken back.
                // The device stays the gesture's, so another trackpad's lift
                // cannot free these fingers.
                if gestureDevice == nil { gestureDevice = device; lastDeviceFrameAt = timestamp }
                abandonTouch()
                return
            }
            if let toLeft = spaceArmed, !spent, spacesEnabled {
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
            // A pinch of this touch whose wait is over runs now.
            pinchFingersLifted(at: timestamp)
            endTouch()
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
            if !recognizer.isWaitingForLift { touchLanded() }
        }
        if let event = recognizer.feed(points, at: timestamp) { handle(event, at: timestamp) }
        guard let start = twoFingerStart else { return }

        // Fingers resting without moving for the hold-cancel time (Swish: 2 s)
        // end this gesture until they lift: a hand left on the menu bar or a
        // Dock icon never switches a Space or quits an app. Spent fingers
        // (a third finger came and went) switch nothing either.
        guard !recognizer.isSpent, !recognizer.isWaitingForLift else { spaceArmed = nil; return }
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
            if menuBarGesturesEnabled, recognizer.isHeld || appSwitcherEngaged || modifierFlags().contains(.command) {
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

    /// Two fingers landed (a new touch): a pinch waiting for its second half
    /// gets a little longer to see this touch, and in the top band the
    /// lookup of the menu bar's part starts at once.
    private func touchLanded() {
        extendPendingPinch()
        guard menuBarGesturesEnabled || appMenuGesturesEnabled else { return }
        let cursor = cursorLocation()
        if cursorInTopBand(cursor) { prefetchMenuBarSpot(cursor) }
    }

    /// The fingers lifted: a scrolled window switcher takes its selection
    /// (the ⌘-Tab grammar), as does the app switcher, and this touch's state goes.
    private func endTouch() {
        if switcherScrolled, desktop.switcherIsShowing { desktop.confirmSwitcher() }
        releaseAppSwitcher(commit: true)
        twoFingerStart = nil
        spaceArmed = nil
        spaceCancelled = false
        topBandOverWindow = nil
        // Spent fingers keep their trackpad until they all lift.
        if !recognizer.isWaitingForLift { gestureDevice = nil }
        place = nil
        appWalk = nil
        windowWalk = nil
        switcherOpened = false
        switcherScrolled = false
    }

    /// A third finger, a pause or the hold-still cancel: nothing this touch
    /// did is taken. A window switcher it opened closes without switching,
    /// the app switcher it holds is let go without switching, a pinch it made
    /// that still waits is taken back, and the touch switches no Space.
    private func abandonTouch() {
        cancelSwitchers()
        takeBackPinchOfThisTouch()
        twoFingerStart = nil
        spaceArmed = nil
        spaceCancelled = true
        topBandOverWindow = nil
        place = nil
        appWalk = nil
        windowWalk = nil
    }

    private func cancelSwitchers() {
        if switcherOpened || switcherScrolled, desktop.switcherIsShowing { desktop.cancelSwitcher() }
        switcherOpened = false
        switcherScrolled = false
        releaseAppSwitcher(commit: false)
    }

    /// Paused, locked or handed to another trackpad: drop the touch and any
    /// tap waiting for its second half, without acting. The recognizer goes
    /// first, so spent fingers do not keep the old trackpad as the gesture's.
    private func reset() {
        cancelSwitchers()
        recognizer.reset()
        endTouch()
        lastTap = nil
    }

    /// Forgets the work waiting for a second pinch or tap (tests; a pause).
    func cancelPending() {
        pendingPinch = nil
        pendingScrollToken = nil
    }

    // MARK: Gestures

    private func handle(_ event: UtilityGestureRecognizer.Event, at timestamp: Double) {
        switch event {
        case .tap:
            lastTap = (timestamp, cursorLocation())
            // Swish's menubarScrollToTop (off by default): a tap on the empty
            // menu bar, once no second tap came.
            if menuBarGesturesEnabled, scrollToTopEnabled, cursorInTopBand(cursorLocation()),
               case .menuBar(let point) = resolvePlace(dockFirst: false) {
                scheduleScrollToTop(at: point)
            }
        case .doubleTap:
            pendingScrollToken = nil
            let mouse = cursorLocation()
            defer { lastTap = nil }
            guard let first = lastTap,
                  hypot(first.mouse.x - mouse.x, first.mouse.y - mouse.y) <= Self.doubleTapDistance else { return }
            switch resolvePlace(dockFirst: false) {
            case .menuBar(let point): if menuBarGesturesEnabled { unsnapWindows(from: point) }
            case .dock(let app), .appMenu(let app): if dockGesturesEnabled, mayAct(on: app) { dockDoubleTap(app.processIdentifier) }
            case .missionControl, .handedOff, .nowhere: break
            }
        case .holdBegan:
            // Swish answers a tap and hold with a haptic, only where it means something.
            switch resolvePlace(dockFirst: false) {
            case .menuBar: if menuBarGesturesEnabled { haptic() }
            case .dock(let app), .appMenu(let app): if dockGesturesEnabled, mayAct(on: app) { haptic() }
            case .missionControl, .handedOff, .nowhere: break
            }
        case .holdReleased:
            switch resolvePlace(dockFirst: false) {
            case .menuBar:
                guard menuBarGesturesEnabled else { return }
                log("Menu-bar gesture: window switcher")
                if !desktop.switcherIsShowing { desktop.showSwitcher() }
            case .dock(let app), .appMenu(let app):
                guard dockGesturesEnabled, mayAct(on: app) else { return }
                activateFrontWindow(of: app.processIdentifier)
            case .missionControl, .handedOff, .nowhere: break
            }
        case .swipe(let direction, let held, _):
            switch resolvePlace(dockFirst: false) {
            case .menuBar(let point):
                if menuBarGesturesEnabled { menuBarSwipe(direction, held: held, at: point, timestamp: timestamp) }
            case .dock(let app), .appMenu(let app):
                if dockGesturesEnabled, mayAct(on: app) { dockSwipe(direction, pid: app.processIdentifier) }
            case .missionControl(let window):
                if direction == .down { missionControlMinimize(window) }
            case .handedOff, .nowhere: break
            }
        case .pinchIn:
            // The Dock first, as before 3.3.2: a pinch near the top edge over
            // the Dock (rare) does the obvious thing.
            switch resolvePlace(dockFirst: true) {
            case .dock(let app), .appMenu(let app): dockPinch(.pinchIn, app: app, at: timestamp)
            case .missionControl(let window): missionControlPinchIn(window, at: timestamp)
            case .menuBar, .handedOff, .nowhere: break
            }
        case .pinchOut:
            switch resolvePlace(dockFirst: true) {
            case .dock(let app), .appMenu(let app): dockPinch(.pinchOut, app: app, at: timestamp)
            case .menuBar, .missionControl, .handedOff, .nowhere: break
            }
        case .holdCancelled:
            // An armed top-band Space swipe says it will not switch.
            if spaceArmed != nil { announce("Cancelled", nil) }
            // A switcher this touch opened closes without switching, and a
            // pinch it made that still waits is taken back (3.3.3).
            cancelSwitchers()
            takeBackPinchOfThisTouch()
            if case .some(.nowhere) = place { return }
            if place != nil { log("Utility gesture cancelled: fingers held still") }
        }
    }

    /// The menu bar, the Dock icon or the Mission Control thumbnail under the
    /// pointer, looked up once per touch at its first gesture. The top band
    /// is plain geometry, then one hit-test tells its parts apart; the Dock
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
            resolved = menuBarPlace(at: cursor)
        } else if missionControlGesturesEnabled, let window = missionControlWindow(cursor) {
            resolved = .missionControl(window)
        } else if !dockFirst, dockOn, let app = dockApp() {
            resolved = .dock(app)
        } else {
            resolved = .nowhere
        }
        place = resolved
        return resolved
    }

    /// The top band over no ordinary window (3.3.3, Swish): the empty area
    /// takes the menu-bar gestures; the app's own menu, with the Application
    /// Menu option on, the Dock's for that app; the other menu titles and the
    /// status items take neither (a two-finger tap there is their own
    /// right-click). No answer in time counts as the empty area, as in 3.3.2.
    private func menuBarPlace(at cursor: CGPoint) -> Place {
        // Neither gesture family wants the parts told apart: no hit-test.
        guard menuBarGesturesEnabled || appMenuGesturesEnabled else { return .menuBar(cursor) }
        switch menuBarSpot(cursor) {
        case .empty, .unknown:
            return .menuBar(cursor)
        case .appMenu(let pid):
            guard appMenuGesturesEnabled, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                return .nowhere
            }
            return .appMenu(app)
        case .menuTitle, .statusItem:
            return .nowhere
        }
    }

    /// Never AOM itself (its windows belong to the user's work in AOM), never
    /// an app that is gone, never an app AOM is paused for, even while
    /// another app is in front (3.3.2 review).
    private func mayAct(on app: NSRunningApplication) -> Bool {
        app.processIdentifier != ownPID && !app.isTerminated && !isAppPaused(app.processIdentifier)
    }

    /// The same for a window: never one of AOM's, never one of an app AOM is
    /// paused for (asked right before each Accessibility write, 3.3.3 S04).
    private func mayAct(onWindowOf pid: pid_t) -> Bool {
        pid != ownPID && !isAppPaused(pid)
    }

    /// The gate and the lock again, for work that runs later than its gesture.
    private func allowedNow() -> Bool {
        !isScreenLocked() && isAllowed()
    }

    private func log(_ message: String) {
        GestureLog.shared.logFromAnyThread(message, level: .action)
    }

    // MARK: Menu bar

    private func menuBarSwipe(_ direction: UtilityGestureRecognizer.Direction, held: Bool, at point: CGPoint,
                              timestamp: Double) {
        let flags = modifierFlags()
        // The ⌘ the app switcher holds is AOM's own, not the screen modifier.
        if flags.contains(.command), !appSwitcherEngaged {
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
            guard everyScreen || (index != nil && index == here), mayAct(onWindowOf: window.pid) else { continue }
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
    /// screen, twice or with the secondary modifier for all." 3.3.3 (S06):
    /// every window minimized there, not only the batch AOM minimized last;
    /// AOM's own come first, newest first. Each window's app is asked about
    /// its pause right before its window is restored (S04); a window that is
    /// skipped or fails stays remembered for the next swipe, and the HUD says
    /// how many came back.
    private func unminimizeWindows(from point: CGPoint, everyScreen: Bool) {
        let frames = desktop.screens().map(\.frame)
        let here = desktop.screenIndex(containing: point).map { frames[$0] }
        // No display under the pointer: only "every display" knows its scope
        // (as the swipe down, which minimizes nothing then).
        guard everyScreen || here != nil else {
            announce("Nothing to Unminimize", "Swipe up again for every display.")
            return
        }
        let listed = desktop.minimizedWindows().map { item -> (window: GestureWindow, screen: CGRect?) in
            (item.window, item.frame.flatMap { WindowGeometry.screenIndex(for: $0, screens: frames) }.map { frames[$0] })
        }
        let windows = minimized.planMenuBarRestore(listed: listed, on: everyScreen ? nil : here) { [desktop] in
            desktop.isMinimized($0)
        }
        var restored = 0, skipped = 0, failed = 0
        for window in windows {
            guard mayAct(onWindowOf: window.pid) else { skipped += 1; continue }
            if desktop.setMinimized(window, false) {
                restored += 1
                minimized.forget(window)
            } else {
                failed += 1
            }
        }
        log("Menu-bar gesture: unminimized \(restored) of \(windows.count) window(s)"
            + (skipped + failed > 0 ? " (\(skipped) paused, \(failed) failed)" : ""))
        let problems = [failed > 0 ? "\(Self.count(failed, "window")) could not be restored; swipe up again to retry" : nil,
                        skipped > 0 ? "\(skipped) skipped: AOM is paused for \(skipped == 1 ? "its app" : "their apps")" : nil]
            .compactMap { $0 }.joined(separator: ". ")
        if restored > 0 {
            haptic()
            announce(restored == windows.count ? "Restored \(Self.count(restored, "Window"))"
                     : "Restored \(restored) of \(Self.count(windows.count, "Window"))",
                     problems.isEmpty ? nil : problems + ".")
        } else if !windows.isEmpty {
            announce("Could Not Restore \(Self.count(windows.count, "Window"))", problems + ".")
        } else {
            announce("Nothing to Unminimize", everyScreen ? "No minimized windows on any display."
                     : "Swipe up again for every display.")
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
    /// previous/next app." Chains within the touch; an app AOM is paused for
    /// is passed over (3.3.3).
    private func switchApp(previous: Bool) {
        if appWalk == nil { appWalk = desktop.appCycle() }
        var chosen: pid_t?
        for _ in 0..<max(1, appWalk?.order.count ?? 0) {
            guard let pid = appWalk?.step(previous: previous) else { break }
            if mayAct(onWindowOf: pid) { chosen = pid; break }
        }
        guard let pid = chosen, !desktop.isFrontmost(pid) else {
            announce("No Other App", nil)
            return
        }
        log("Menu-bar gesture: \(previous ? "previous" : "next") app")
        if desktop.activate(pid) {
            haptic()
            announce(desktop.appName(pid) ?? "App", previous ? "Previous app" : "Next app")
        }
    }

    /// Swish: "Tap, hold and scroll to invoke the ⌘-tab app switcher". With
    /// the switcher setting on "apps" (3.3.3) the first scroll holds a
    /// synthetic ⌘ and opens the macOS app switcher, the next ones step
    /// through it, and lifting lets ⌘ go, which takes the selection. Otherwise
    /// (the default, and when the app switcher cannot be held) the first
    /// scroll opens AOM's window switcher, the next ones move through it, and
    /// lifting takes the selection.
    private func scrollSwitcher(down: Bool) {
        if appSwitcherEngaged {
            desktop.stepAppSwitcher(forward: down)
            return
        }
        if menuBarSwitcherMode == .apps, !switcherOpened, desktop.beginAppSwitcher() {
            appSwitcherEngaged = true
            lastFrameUptime = now()
            log("Menu-bar gesture: app switcher")
            haptic()
            armAppSwitcherWatchdog()
            return
        }
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

    /// Lets go of the macOS app switcher this touch holds: lifting takes its
    /// selection; a third finger, a pause or a lost touch closes it.
    private func releaseAppSwitcher(commit: Bool) {
        guard appSwitcherEngaged else { return }
        appSwitcherEngaged = false
        desktop.endAppSwitcher(commit: commit)
    }

    /// The synthetic ⌘ never outlives the touch: when the trackpad goes quiet
    /// (asleep, disconnected, frames lost) it is let go without switching.
    private func armAppSwitcherWatchdog() {
        schedule(Self.appSwitcherWatchdog) { [weak self] in
            guard let self, self.appSwitcherEngaged else { return }
            if self.now() - self.lastFrameUptime >= Self.appSwitcherWatchdog {
                self.log("App switcher let go: the trackpad went quiet")
                self.releaseAppSwitcher(commit: false)
            } else {
                self.armAppSwitcherWatchdog()
            }
        }
    }

    /// Swish's menubarScrollToTop: the tap waits the double-tap time (a
    /// double tap unsnaps instead), then the front window's main scroll area
    /// goes to the top. Checked again when it runs.
    private func scheduleScrollToTop(at point: CGPoint) {
        workToken += 1
        let token = workToken
        pendingScrollToken = token
        let desktop = self.desktop
        schedule(recognizer.tuning.doubleTapWindow) { [weak self] in
            guard let self, self.pendingScrollToken == token else { return }
            self.pendingScrollToken = nil
            guard self.menuBarGesturesEnabled, self.scrollToTopEnabled, self.allowedNow(),
                  let front = desktop.frontmostPID(), self.mayAct(onWindowOf: front) else { return }
            switch desktop.scrollToTop(of: front, pointerX: point.x) {
            case .scrolled:
                self.log("Menu-bar gesture: scrolled \(desktop.appName(front) ?? "the front window") to the top")
                self.haptic()
            case .alreadyAtTop:
                break
            case .noScrollArea:
                self.announce("Nothing to Scroll", "The front window has no scroll area AOM can reach.")
            case .failed:
                self.announce("Could Not Scroll to the Top", desktop.appName(front))
            }
        }
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

    /// Swish: "Tap and hold to activate and chain an app's frontmost window."
    private func activateFrontWindow(of pid: pid_t) {
        let open = desktop.windows(of: pid).filter { !desktop.isMinimized($0) }
        let front = desktop.focusedWindow(of: pid).flatMap { focused in open.first { $0 == focused } } ?? open.first
        log("Dock gesture: activate \(desktop.appName(pid) ?? "app")")
        if let front { desktop.raise(front) }
        if desktop.activate(pid) { haptic() }
        if let front { offerChain(front) }
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
        offerChain(window)
    }

    /// Offers the window a Dock gesture brought forward to the title-bar snap
    /// (`chainWindow`). When it takes it, the rest of this touch is the
    /// snap's: the Dock does nothing more with it.
    private func offerChain(_ window: GestureWindow) {
        guard window.pid != ownPID, chainWindow(window) else { return }
        log("Dock gesture: chained a window of \(desktop.appName(window.pid) ?? "app")")
        if place != nil { place = .handedOff }
    }

    /// Swish: "Swipe down to minimize the frontmost window. Use the secondary
    /// modifier to minimize all windows." (Pinching in twice does the same as
    /// the secondary modifier.)
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
    /// swipe up in the touch brings back the next. (Pinching out twice does
    /// the same as the secondary modifier.)
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
        // 3.3.3: one that would not come back stays remembered for the next swipe.
        let lost = targets.filter { !restored.contains($0) }
        if !lost.isEmpty { minimized.push(lost.map { ($0, nil) }, source: .dock) }
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

    // MARK: Pinch once or twice (3.3.3)

    /// A pinch on a Dock icon (or the app's menu). Swish: "Pinch in to quit an
    /// application", "pinch in twice to minimize all windows", "Pinch out to
    /// open a new tab or window (⌘N)", "pinch out twice to unminimize all
    /// windows". With the double pinch on, the first pinch waits
    /// `pinchRepeatWindow` (as the title-bar pinch in does) so a quit never
    /// runs before a possible second pinch; the second, on the same app,
    /// replaces it. Either way a pinch runs when its fingers lift at the
    /// earliest, so a third finger before that takes it back (S02). S01: the
    /// target app's own pause and AOM itself are refused here and again
    /// right before the quit request.
    private func dockPinch(_ kind: PinchKind, app: NSRunningApplication, at timestamp: Double) {
        guard mayAct(on: app) else { return }
        let pid = app.processIdentifier
        let twiceOn = dockGesturesEnabled && dockDoublePinchEnabled
        if twiceOn, isSecondPinch(kind, origin: .dock, pid: pid, at: timestamp) {
            pendingPinch = nil
            lastFireAt = timestamp
            log("Dock gesture: pinch \(kind == .pinchIn ? "in" : "out") twice on \(desktop.appName(pid) ?? "app")")
            if kind == .pinchIn { minimizeWindows(of: pid, all: true) } else { unminimizeWindows(of: pid, all: true) }
            return
        }
        firePendingPinchNow()
        let quit = quitApplication
        let desktop = self.desktop
        let action: (() -> Void)?
        switch kind {
        case .pinchIn:
            guard dockQuitEnabled || twiceOn else { return }
            action = dockQuitEnabled ? { [weak self] in self?.quitFromDock(app, quit: quit) } : nil
            lastFireAt = timestamp
        case .pinchOut:
            guard dockGesturesEnabled else { return }
            action = { [weak self] in self?.newWindow(in: app, desktop: desktop) }
        }
        guard twiceOn else {
            // No second pinch to wait for: it runs when the fingers lift.
            if let action { holdUntilLift(kind, origin: .dock, pid: pid, at: timestamp, fire: action) }
            return
        }
        schedulePendingPinch(kind, origin: .dock, pid: pid, at: timestamp, fire: action ?? {})
    }

    /// The Dock's quit, when it runs: everything checked again right before
    /// the request (3.3.3, S01) — the setting, AOM's pause, the lock, the
    /// target's own pause, AOM itself.
    private func quitFromDock(_ app: NSRunningApplication, quit: (NSRunningApplication) -> Void) {
        guard dockQuitEnabled, allowedNow(), mayAct(on: app) else {
            log("Dock gesture: no quit for \(app.localizedName ?? "the app"): paused, locked or gone")
            return
        }
        log("Dock gesture: quit \(app.localizedName ?? "app")")
        quit(app)
    }

    /// The Dock's pinch out: activate, then ⌘N a moment later, each step
    /// checked again when it runs (3.3.3, S05).
    private func newWindow(in app: NSRunningApplication, desktop: GestureDesktop) {
        guard dockGesturesEnabled, allowedNow(), mayAct(on: app) else { return }
        let pid = app.processIdentifier
        log("Dock gesture: new window in \(desktop.appName(pid) ?? "app")")
        guard desktop.activate(pid) else { return }
        schedule(Self.newWindowDelay) { [weak self] in
            guard let self, self.dockGesturesEnabled, self.allowedNow(), self.mayAct(on: app) else { return }
            if desktop.postNewWindow(to: pid) {
                self.haptic()
            } else {
                self.announce("Could Not Send ⌘N", "AOM needs permission to post keyboard events (Privacy & Security › Accessibility).")
            }
        }
    }

    /// Whether this pinch is the second half of "pinch twice": the same kind
    /// on the same app, within the window (frame time; the wait itself may
    /// have been stretched once).
    private func isSecondPinch(_ kind: PinchKind, origin: PinchOrigin, pid: pid_t, at timestamp: Double) -> Bool {
        guard let first = pendingPinch, first.kind == kind, first.origin == origin, first.pid == pid,
              timestamp >= first.at else { return false }
        return timestamp - first.at <= Self.pinchRepeatWindow + Self.pinchRepeatExtension
    }

    private func schedulePendingPinch(_ kind: PinchKind, origin: PinchOrigin, pid: pid_t, at timestamp: Double,
                                      fire: @escaping () -> Void) {
        workToken += 1
        let token = workToken
        pendingPinch = PendingPinch(kind: kind, origin: origin, pid: pid, at: timestamp, token: token, fire: fire)
        schedule(Self.pinchRepeatWindow) { [weak self] in self?.firePendingPinch(token: token) }
    }

    /// A pinch with no second one to wait for: it runs when its fingers lift.
    private func holdUntilLift(_ kind: PinchKind, origin: PinchOrigin, pid: pid_t, at timestamp: Double,
                               fire: @escaping () -> Void) {
        workToken += 1
        var waiting = PendingPinch(kind: kind, origin: origin, pid: pid, at: timestamp, token: workToken, fire: fire)
        waiting.extended = true
        waiting.waitOver = true
        pendingPinch = waiting
    }

    private func firePendingPinch(token: Int) {
        guard var waiting = pendingPinch, waiting.token == token else { return }
        // The fingers that pinched are still down: it runs when they lift.
        if waiting.fingersDown {
            waiting.waitOver = true
            pendingPinch = waiting
            return
        }
        pendingPinch = nil
        waiting.fire()
    }

    /// Another pinch elsewhere: the one still waiting runs now instead of
    /// being lost (it checks again that it may), as on a title bar. One whose
    /// fingers AOM never saw lift is taken back instead.
    private func firePendingPinchNow() {
        guard let waiting = pendingPinch else { return }
        pendingPinch = nil
        guard !waiting.fingersDown else { return }
        waiting.fire()
    }

    /// The fingers that pinched lifted (frame time): the pinch runs now if
    /// its wait is over, else when the wait ends. A lift more than
    /// `pinchLiftLimit` after the pinch (the hand stayed down, or the lift
    /// frame was lost) takes the pinch back.
    private func pinchFingersLifted(at timestamp: Double) {
        guard var waiting = pendingPinch, waiting.fingersDown else { return }
        guard timestamp >= waiting.at, timestamp - waiting.at <= Self.pinchLiftLimit else {
            pendingPinch = nil
            log("Utility gesture cancelled: the fingers stayed down after the pinch")
            return
        }
        waiting.fingersDown = false
        if waiting.waitOver {
            pendingPinch = nil
            waiting.fire()
        } else {
            pendingPinch = waiting
        }
    }

    /// A third finger, the hold-still cancel or another trackpad while the
    /// fingers that pinched are still down: the pinch is taken back (S02).
    private func takeBackPinchOfThisTouch() {
        guard pendingPinch?.fingersDown == true else { return }
        pendingPinch = nil
        log("Utility gesture cancelled: the pinch was taken back")
    }

    /// The next touch landed while a pinch waits: it gets `pinchRepeatExtension`
    /// more, once, to show whether it is the second pinch.
    private func extendPendingPinch() {
        guard var waiting = pendingPinch, !waiting.extended, !waiting.fingersDown else { return }
        workToken += 1
        let token = workToken
        waiting.token = token
        waiting.extended = true
        pendingPinch = waiting
        schedule(Self.pinchRepeatWindow + Self.pinchRepeatExtension) { [weak self] in self?.firePendingPinch(token: token) }
    }

    // MARK: Mission Control and App Exposé (3.3.3)

    /// Swish: "Most Window and Snapping gestures also work in Mission Control
    /// & App Exposé." Pinch in on a thumbnail closes that window, after the
    /// wait for a second pinch, which quits its app instead (as on a title
    /// bar) when its fingers lift. Each checked again when it runs.
    private func missionControlPinchIn(_ window: GestureWindow, at timestamp: Double) {
        guard missionControlGesturesEnabled, mayAct(onWindowOf: window.pid) else { return }
        if isSecondPinch(.pinchIn, origin: .missionControl, pid: window.pid, at: timestamp) {
            pendingPinch = nil
            guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
            let quit = quitApplication
            holdUntilLift(.pinchIn, origin: .missionControl, pid: window.pid, at: timestamp) { [weak self] in
                guard let self, self.missionControlGesturesEnabled, self.allowedNow(), self.mayAct(on: app) else { return }
                self.log("Mission Control gesture: quit \(app.localizedName ?? "app")")
                quit(app)
            }
            return
        }
        firePendingPinchNow()
        let desktop = self.desktop
        schedulePendingPinch(.pinchIn, origin: .missionControl, pid: window.pid, at: timestamp) { [weak self] in
            guard let self, self.missionControlGesturesEnabled, self.allowedNow(), self.mayAct(onWindowOf: window.pid) else { return }
            self.log("Mission Control gesture: close a window of \(desktop.appName(window.pid) ?? "app")")
            if desktop.close(window) { self.haptic() } else { self.announce("Could Not Close the Window", nil) }
        }
    }

    /// Swipe down on a thumbnail minimizes that window.
    private func missionControlMinimize(_ window: GestureWindow) {
        guard missionControlGesturesEnabled, mayAct(onWindowOf: window.pid) else { return }
        log("Mission Control gesture: minimize a window of \(desktop.appName(window.pid) ?? "app")")
        if desktop.setMinimized(window, true) {
            minimized.push([(window, nil)], source: .dock)
            haptic()
        }
    }

    /// The default `missionControlWindow`: the thumbnail under the pointer
    /// (bounded hit-test on the process that draws Mission Control) and the
    /// one real window it stands for. Over an ordinary app window (layer 0
    /// of an app that does not draw Mission Control) no Accessibility request
    /// is made at all, so two-finger scrolling costs a window-server check.
    static func liveMissionControlWindow(at point: CGPoint) -> GestureWindow? {
        if let under = DockLookup.windowUnder(point), under.layer == 0,
           !MissionControlWindows.ownerPIDs().contains(under.pid) { return nil }
        guard let thumbnail = MissionControlWindows.thumbnail(at: point),
              let found = MissionControlWindows.window(for: thumbnail) else { return nil }
        return GestureWindow(element: found.element, pid: found.pid)
    }

    // MARK: Window moves

    private struct WindowMove {
        let window: GestureWindow
        let to: CGRect
        let anchorIn: CGRect?
        var done: ((CGRect) -> Void)? = nil
    }

    /// One window after the other, each through the same commit as a title-bar
    /// snap. Each move completes later than its gesture, so before each one
    /// AOM's pause and the lock are checked again (paused half-way: the rest
    /// stays put) and so is the window's own app (3.3.3, S05).
    private func run(_ moves: [WindowMove], completion: @escaping (Int) -> Void) {
        moving = true
        var moved = 0
        func step(_ index: Int) {
            guard index < moves.count, allowedNow() else {
                moving = false
                completion(moved)
                return
            }
            let move = moves[index]
            guard mayAct(onWindowOf: move.window.pid) else { step(index + 1); return }
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
    /// confirmed action. 3.3.3 (S01): this common path itself refuses AOM and
    /// an app AOM is paused for, whoever asks.
    static func politeQuit(_ app: PoliteQuitTarget,
                           gracePeriod: TimeInterval = 3,
                           report: @escaping (_ title: String, _ detail: String) -> Void = { title, detail in
                               TrackpadUtilityGestures.showHUD(title, detail)
                           },
                           after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
                               DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                           }) {
        let name = app.localizedName ?? "The app"
        guard !app.isTerminated else { return }
        if let running = app as? NSRunningApplication {
            guard running.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !TriggerSuppression.shared.isPaused(forApp: running.bundleIdentifier) else {
                GestureLog.shared.logFromAnyThread("Quit not requested: \(name) is AOM itself or paused", level: .error)
                return
            }
        }
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
