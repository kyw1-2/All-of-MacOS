import AppKit

// Swish-style window snapping: rest the pointer over a window's title bar and
// swipe with two fingers on the trackpad; a translucent preview shows where the
// window will land, and lifting the fingers commits it (with a haptic tap).
//
// 3.2.0 recovered the interaction from Swish 1.13.3's strings and metadata
// (REA/Ghidra on Oracle: `SnappingTabController`, `AccessibilityWindowController`,
// the per-layout `GestureView`/`snappingView` overlays, a `gestureTimeout`
// `gestureDispatchItem`, `NSHapticFeedbackManager`, the rounded-rect overlay
// animated with `setFrame:display:animate:`).
//
// 3.3.0 applies the DeepSeek Harness Ghidra pass of the same build
// (`/data/rea-targets-swish-20261027/report`, kept in `work/rea-swish/dsh-20261027`):
// - The commit follows Swish's frame setter (`FUN_1000329c8`): AXEnhancedUserInterface
//   is suspended, size → position → size is written and read back, and a window
//   that keeps its own size is anchored to the snapped edge (`WindowManager.applySnap`).
// - The preview settles on the frame the window really took before fading.
// - Swish keeps each window's pre-snap frame (`ActionSnapUnsnap`, "Unsnap"): a swipe
//   down on a window AOM snapped restores it.
// - "Swipe horizontally and vertically to snap to a quarter. Both orders work."
// - Haptics on zone changes and commit, `activateAfterSnapping`, and the optional
//   `snappingMoveCursor` warp (`CGWarpMouseCursorPosition`) back to the title bar.
// - Readiness checks phrased the way Swish's settings explain them (Accessibility,
//   haptic feedback, Mission Control shortcuts).
// This is AOM's own implementation of that behaviour, not Swish code.
//
// Stability first: the recognizer is pure and runs on the multitouch callback
// thread doing only float maths; it never blocks the existing gesture pipeline,
// only engages over a title bar (so it does not fight AOM's own trackpad
// gestures), resets on a timeout, and is off until the user turns it on.

// MARK: - Service

/// Set once on the main actor; read from the multitouch frame handler, so the
/// handler never has to reach the main-actor singleton. A nil handler
/// (feature never initialised) simply does nothing. Arguments: the contacts,
/// the frame timestamp and the trackpad's device ID.
nonisolated(unsafe) var aomTitleBarSnapFeed: (([TouchPoint], Double, UInt64) -> Void)?

/// Owns the recognizer, the preview overlay, the pre-snap history and the
/// commit. The `handle` entry point is called from `TrackpadMonitor`'s
/// multitouch callback; all UI and Accessibility work hops to the main actor.
final class TitleBarWindowSnap {
    @MainActor static let shared = TitleBarWindowSnap()

    static let enabledKey = "AOMTitleBarSnapEnabled"
    static let hapticKey = "AOMTitleBarSnapHaptic"
    static let marginKey = "AOMTitleBarSnapMargin"
    /// Swish `activateAfterSnapping`: raise and focus the snapped window. Default on.
    static let activateKey = "AOMTitleBarSnapActivate"
    /// Swish `snappingMoveCursor`: put the pointer back on the snapped window's
    /// title bar so the next swipe chains. Default off.
    static let keepPointerKey = "AOMTitleBarSnapKeepPointer"
    /// Thirds and two-thirds (Swish's 3×2 grid). Off by default (3.3.2): the
    /// 2×2 grid of halves and quarters, with no longer-swipe third.
    static let thirdsKey = "AOMTitleBarSnapThirds"
    /// The translucent preview while swiping. On by default.
    static let previewKey = "AOMTitleBarSnapPreview"
    /// Swish's hold-still cancel, in seconds (0 = off, default 2): fingers
    /// resting without moving on a title bar, the menu bar or the Dock cancel
    /// the gesture. Shared with `TrackpadUtilityGestures`.
    static let holdCancelKey = "AOMTitleBarSnapHoldCancel"
    static let holdCancelDefault: Double = 2

    /// Swish's title-bar pinches (3.3.2): pinch in closes the window (twice:
    /// quits the app), pinch out enters or leaves full screen. Default on.
    static let pinchKey = "AOMTitleBarSnapPinch"
    /// Two-finger double tap on a title bar, a `SwishSnap.DoubleTap` raw
    /// value: "restoreOrCenter" (default: unsnap, else centre), "center" or "off".
    static let doubleTapKey = "AOMTitleBarSnapDoubleTap"
    /// Tap and hold, then swipe: up full screen, down minimize, sideways a
    /// Space. Default on.
    static let holdKey = "AOMTitleBarSnapHold"
    /// A short swipe down on a free-floating window, a `SwishSnap.DownAction`
    /// raw value: "minimize" (Swish, default) or "center" (as in 3.3.1).
    static let downActionKey = "AOMTitleBarSnapDownAction"
    /// The ⌥ / ⇧ / ⌘ variants (Spaces, close, quit, hide, displays). Default on.
    static let modifiersKey = "AOMTitleBarSnapModifiers"
    /// How little travel engages a swipe, as a multiple of the 3.3.1 distance
    /// (5 % of the pad). 3.3.2 defaults to 1.25 — engaging after 4 % — since
    /// "the snap reacts too slowly" was the first complaint; the tap guard
    /// still turns a sloppy two-finger tap into nothing.
    static let sensitivityKey = "AOMTitleBarSnapSensitivity"
    static let sensitivityDefault: Double = 1.25

    /// The swipe sensitivity, clamped to 0.5…2.
    static func sensitivity(_ defaults: UserDefaults = .standard) -> Double {
        guard let value = defaults.object(forKey: sensitivityKey) as? Double, value.isFinite else { return sensitivityDefault }
        return min(max(value, 0.5), 2)
    }

    /// The recognizer distances (pad units) for a sensitivity: engage and the
    /// cross leg of a quarter scale together, so L-shapes and diagonals feel
    /// the same at every setting. Thirds' longer swipe (`tier2`) stays put.
    static func distances(sensitivity: Double) -> (engage: Float, crossEngage: Float) {
        let s = Float(min(max(sensitivity.isFinite ? sensitivity : 1, 0.5), 2))
        return (0.05 / s, 0.06 / s)
    }

    /// The tap-and-hold rest, and how soon the second half of a "twice"
    /// gesture or a double tap must follow the first.
    static let holdTime: Double = 0.45
    static let repeatWindow: Double = 0.35
    /// How long the first half of a "twice" gesture waits for the second — a
    /// second pinch in, a second ⌥ swipe down (3.4.12). 0.35 s was shorter
    /// than two deliberate pinches take: the first one closed the window
    /// before the second arrived, so "pinch in twice" read as two closes.
    /// 0.6 s fits the pair, and a double tap keeps the shorter `repeatWindow`.
    static let twiceWindow: Double = 0.6
    /// How far (points) the pointer may move between the taps of a double tap.
    static let doubleTapDistance: CGFloat = 8

    /// The hold-still cancel time in seconds, clamped to 0…10 (0 = off).
    static func holdCancelSeconds(_ defaults: UserDefaults = .standard) -> Double {
        guard let value = defaults.object(forKey: holdCancelKey) as? Double, value.isFinite else { return holdCancelDefault }
        return min(max(value, 0), 10)
    }

    // MARK: 3.3.3 settings

    /// Swish's multi-motion pause, in seconds: fingers resting this long on a
    /// swipe or pinch lock it in, and the next movement starts another
    /// gesture in the same touch. 0 = off (one gesture per touch, as in
    /// 3.3.2); default 0.25, clamped to 0.15…1.
    static let motionPauseKey = "AOMTitleBarSnapMotionPause"
    static let motionPauseDefault: Double = 0.25

    static func motionPause(_ defaults: UserDefaults = .standard) -> Double {
        guard let value = defaults.object(forKey: motionPauseKey) as? Double, value.isFinite else { return motionPauseDefault }
        guard value > 0 else { return 0 }
        return min(max(value, 0.15), 1)
    }

    /// Swish's Super modifier "to perform window gestures on their entire
    /// area instead of their titlebar only": while the Super role's keys are
    /// held, a gesture may start anywhere on another app's window. Off by default.
    static let superAnywhereKey = "AOMTitleBarSnapSuperAnywhere"

    static func superAnywhereOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: superAnywhereKey) as? Bool ?? false
    }

    /// Tab gestures on native tab bars and in supported browsers: pinch in on
    /// a tab closes it, tap and hold on a native or Safari tab detaches it
    /// into a new window. On by default.
    static let tabGesturesKey = "AOMTitleBarSnapTabs"

    static func tabGesturesOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: tabGesturesKey) as? Bool ?? true
    }

    /// Swish's "Native Window Tiling": halves, quarters and Fill go through
    /// the app's Window › Move & Resize menu when it has one. Off by default.
    static let nativeTilingKey = "AOMTitleBarSnapNativeTiling"

    static func nativeTilingOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: nativeTilingKey) as? Bool ?? false
    }

    /// Swish's tooltip: a small label by the pointer naming what lifting will
    /// do while a gesture is on show. On by default; it follows the preview
    /// switch too.
    static let tooltipKey = "AOMTitleBarSnapTooltip"

    static func tooltipOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: tooltipKey) as? Bool ?? true
    }

    /// The options of the swipe mapping (`SwishSnap.move(from:stroke:modifiers:options:fullscreen:)`).
    static func gestureOptions(_ defaults: UserDefaults = .standard) -> SwishSnap.GestureOptions {
        SwishSnap.GestureOptions(
            downAction: defaults.string(forKey: downActionKey).flatMap(SwishSnap.DownAction.init(rawValue:)) ?? .minimize,
            holdGestures: defaults.object(forKey: holdKey) as? Bool ?? true,
            modifierGestures: defaults.object(forKey: modifiersKey) as? Bool ?? true,
            grid: grid(defaults),
            almostMaximize: almostMaximizeOn(defaults))
    }

    static func doubleTapOption(_ defaults: UserDefaults = .standard) -> SwishSnap.DoubleTap {
        defaults.string(forKey: doubleTapKey).flatMap(SwishSnap.DoubleTap.init(rawValue:)) ?? .restoreOrCenter
    }

    static func pinchesOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: pinchKey) as? Bool ?? true
    }

    /// The gap kept around snapped windows, in points: 0 by default, 0…24
    /// (Settings › Window Tiling › Margin).
    static func margin(_ defaults: UserDefaults = .standard) -> CGFloat {
        guard let value = defaults.object(forKey: marginKey) as? Double, value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), marginRange.upperBound))
    }

    static let marginRange: ClosedRange<Double> = 0...24

    // MARK: Swish 1.13's remaining snapping options (3.3.2)

    /// The snapping grid, a `SwishSnap.Grid` raw value: "2x2", "3x2" or
    /// "3x3". Unset, it follows the 3.3.2 Thirds switch (`thirdsKey`, still
    /// read): 3 × 2 when that was on, else 2 × 2.
    static let gridKey = "AOMTitleBarSnapGrid"
    /// Swish's "Almost Maximize": swipe up leaves a small gap all round; up
    /// again maximizes. Off by default.
    static let almostKey = "AOMTitleBarSnapAlmost"
    /// Swish's keyboard hotkeys, a `SwishSnap.HotkeyScheme` raw value: "off"
    /// (default), "arrows", "wasd", "ijkl" or "hjkl", with ⌃⌥.
    static let hotkeysKey = "AOMTitleBarSnapHotkeys"
    /// Swish's "snappingDragUnsnap": dragging a snapped window by its title
    /// bar gives it back its size from before the snap. On by default.
    static let dragUnsnapKey = "AOMTitleBarSnapDragUnsnap"
    /// Swish's re-snapping after a display change. On by default.
    static let resnapKey = "AOMTitleBarSnapResnap"
    /// Swish's "tooltipAnimationTime", a `SwishSnap.AnimationSpeed` raw value:
    /// "fast", "normal" (default) or "off".
    static let animationKey = "AOMTitleBarSnapAnimation"
    /// Swish's "snappingStageManagerOffset": points kept free on the left
    /// while Stage Manager is on, 0…200. 0 by default.
    static let stageManagerOffsetKey = "AOMTitleBarSnapStageManagerOffset"
    static let stageManagerOffsetRange: ClosedRange<Double> = 0...200
    /// Swish's "snappingResizeAdjacent": resizing a snapped window along an
    /// edge it shares with another snapped window resizes that one too. On by default.
    static let resizeAdjacentKey = "AOMTitleBarSnapResizeAdjacent"
    /// Posted when the keyboard hotkeys start or stop being wanted, so the
    /// keyboard monitor installs or drops its event tap (`AppState`).
    static let hotkeysDidChange = Notification.Name("AOMTitleBarSnapHotkeysDidChange")
    /// Swish waits for the displays to settle before re-snapping.
    static let resnapDelay: Double = 1.5

    /// Swish's "External Display Timeout" (3.3.3, X38): seconds to wait for
    /// the displays to settle before re-snapping, 0.5…10, default 1.5; 0
    /// turns re-snapping off ("turn it off entirely by setting it to zero").
    static let resnapDelayKey = "AOMTitleBarSnapResnapDelay"

    static func resnapDelaySeconds(_ defaults: UserDefaults = .standard) -> Double {
        guard let value = defaults.object(forKey: resnapDelayKey) as? Double, value.isFinite else { return resnapDelay }
        guard value > 0 else { return 0 }
        return min(max(value, 0.5), 10)
    }

    static func grid(_ defaults: UserDefaults = .standard) -> SwishSnap.Grid {
        if let raw = defaults.string(forKey: gridKey), let grid = SwishSnap.Grid(rawValue: raw) { return grid }
        return defaults.object(forKey: thirdsKey) as? Bool == true ? .threeByTwo : .twoByTwo
    }

    static func almostMaximizeOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: almostKey) as? Bool ?? false
    }

    static func hotkeyScheme(_ defaults: UserDefaults = .standard) -> SwishSnap.HotkeyScheme {
        defaults.string(forKey: hotkeysKey).flatMap(SwishSnap.HotkeyScheme.init(rawValue:)) ?? .off
    }

    /// The hotkeys are wanted: the snap is on and a key set is chosen.
    static func hotkeysWanted(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool ?? false) && hotkeyScheme(defaults) != .off
    }

    static func dragUnsnapOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: dragUnsnapKey) as? Bool ?? true
    }

    static func resnapOn(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: resnapKey) as? Bool ?? true) && resnapDelaySeconds(defaults) > 0
    }

    static func resizeAdjacentOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: resizeAdjacentKey) as? Bool ?? true
    }

    static func animationSpeed(_ defaults: UserDefaults = .standard) -> SwishSnap.AnimationSpeed {
        defaults.string(forKey: animationKey).flatMap(SwishSnap.AnimationSpeed.init(rawValue:)) ?? .normal
    }

    static func stageManagerOffset(_ defaults: UserDefaults = .standard) -> CGFloat {
        guard let value = defaults.object(forKey: stageManagerOffsetKey) as? Double, value.isFinite else { return 0 }
        return CGFloat(min(max(value, stageManagerOffsetRange.lowerBound), stageManagerOffsetRange.upperBound))
    }

    /// Whether Stage Manager is on. Read-only: `com.apple.WindowManager`
    /// "GloballyEnabled", missing meaning off.
    static func stageManagerOn() -> Bool {
        let value = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    /// The area windows snap in on a display: its visible area, less the
    /// Stage Manager offset on the left while Stage Manager is on.
    static func snapArea(_ visible: CGRect, defaults: UserDefaults = .standard) -> CGRect {
        let offset = stageManagerOffset(defaults)
        guard offset > 0 else { return visible }
        return SwishSnap.stageManagerArea(visible, offset: offset, stageManager: stageManagerOn())
    }

    /// How far apart two snapped windows' facing edges may be and still
    /// count as sharing it: 8 pt plus the gap the margin leaves between cells.
    static func adjacencyTolerance(margin: CGFloat) -> CGFloat { 8 + 2 * max(0, margin) }

    // MARK: The snap history for the menu-bar gestures (3.3.2)

    /// The frame `target` had before the title-bar snap moved it, while it
    /// still sits where the snap put it (Swish's "double tap the menu bar to
    /// unsnap all windows"). Read-only: the history stays private. Kept whole
    /// on a display, as a title-bar unsnap is (N335).
    @MainActor
    func unsnapFrame(for target: WindowManager.Target, current: CGRect) -> CGRect? {
        history.restoreFrame(key: Self.key(target), current: current).map {
            SwishSnap.unsnapFrame(original: $0, areas: WindowManager.shared.screens().map(\.visible), current: current)
        }
    }

    /// The cell the snap last put `target` in, while it is still there.
    @MainActor
    func snappedCell(for target: WindowManager.Target, current: CGRect) -> CustomSnapZone.Layout? {
        history.cell(key: Self.key(target), current: current)
    }

    /// The place (any grid cell, almost-maximize) the snap last put `target`
    /// in, while it is still there.
    @MainActor
    func snappedPlace(for target: WindowManager.Target, current: CGRect) -> SwishSnap.Place? {
        history.place(key: Self.key(target), current: current)
    }

    /// A snapped window the menu bar's ⌘ swipe moved to another display, in
    /// the same cell: the history follows it, so the next title-bar swipe
    /// chains from that cell and an unsnap still restores the frame from
    /// before the first snap.
    @MainActor
    func recordDisplayMove(of target: WindowManager.Target, from start: CGRect, to actual: CGRect,
                           layout: CustomSnapZone.Layout) {
        guard let place = SwishSnap.Place(layout) else { return }
        recordDisplayMove(of: target, from: start, to: actual, place: place)
    }

    @MainActor
    func recordDisplayMove(of target: WindowManager.Target, from start: CGRect, to actual: CGRect,
                           place: SwishSnap.Place) {
        let key = Self.key(target)
        history.recordSnap(key: key, from: start, to: actual, place: place)
        remember(target, key: key)
    }

    /// What lifting the fingers will do: move to a place, (place nil)
    /// restore the frame the window had before AOM snapped it, or (action
    /// set) act on the window; `rect` is then the destination of a display
    /// move, or null.
    struct Plan: Equatable {
        var place: SwishSnap.Place?
        var rect: CGRect
        var action: SwishSnap.WindowAction? = nil
        /// The action first waits `repeatWindow` for the second half of a
        /// "twice" gesture (pinch in or ⌥ swipe down twice: quit; pinch out
        /// twice: full screen on the other display).
        var waits = false
    }

    /// A close or full-screen toggle waiting for a possible second pinch or swipe.
    private struct Pending {
        let action: SwishSnap.WindowAction
        let target: WindowManager.Target
        let start: CGRect
        var extended = false
    }

    /// The window under the pointer, looked up when two fingers land so the
    /// preview can appear the moment the swipe engages (an Accessibility
    /// hit-test is a synchronous round trip to the app).
    private struct Capture {
        let mouse: CGPoint
        let window: WindowManager.Target
        let frame: CGRect
        let at: TimeInterval
        /// The tab under the pointer, on a tab bar AOM can act on (F02).
        var tab: AXUIElement? = nil
        /// 3.4.12: the Accessibility hit-test named this very window (its
        /// frame is the window server's record), so the pointer's part of the
        /// title bar is known. A window found only by its frame is not, and
        /// nothing that cannot be taken back (a force quit) runs on it.
        var verified = true
    }

    /// Read on the multitouch thread, written on main. A stale bool for one
    /// frame is harmless.
    private nonisolated(unsafe) var active = false
    private let recognizer = TitleBarSnapRecognizer()

    @MainActor private var target: WindowManager.Target?
    @MainActor private var targetVisible: CGRect?
    @MainActor private var startFrame: CGRect?
    /// The place the window sat in when the swipe began (nil: free-floating).
    @MainActor private var startPlace: SwishSnap.Place?
    /// The same, for a swipe up (N334): only a place AOM remembers or a cell
    /// the window fills. A large free window flush with a corner or an edge
    /// only overflows a quarter or a half; read as that cell, a swipe up put
    /// it in the top half (or a top quarter) instead of maximizing it.
    @MainActor private var startPlaceForUp: SwishSnap.Place?
    @MainActor private var prefetched: Capture?
    @MainActor private var plan: Plan?
    @MainActor private var committing = false
    @MainActor private var history = SwishSnapHistory()
    /// The windows in the history, so drag to unsnap, re-snapping and
    /// resizing adjacent windows can reach them again. Same keys.
    @MainActor private var snapTargets: [String: WindowManager.Target] = [:]
    @MainActor private var overlay = SnapPreviewOverlay()
    @MainActor private var timeout: DispatchWorkItem?
    /// The modifiers held when the gesture began, and whether its window was
    /// in native full screen then.
    @MainActor private var modifiers: SwishSnap.Modifiers = []
    @MainActor private var fullscreen = false
    /// This gesture is a pinch (its window was captured by `pinchChanged`).
    @MainActor private var pinching = false
    /// The action waiting on the same app when this gesture began, which this
    /// gesture may complete (the second pinch or ⌥ swipe down).
    @MainActor private var repeating: SwishSnap.WindowAction?
    /// The action the HUD names for this gesture.
    @MainActor private var shownAction: SwishSnap.WindowAction?
    @MainActor private var pending: Pending?
    @MainActor private var pendingWork: DispatchWorkItem?
    @MainActor private var lastTap: (at: Double, mouse: CGPoint, target: WindowManager.Target)?
    /// The keyboard hotkeys in use, and whether they were wanted last time
    /// (to tell the keyboard monitor when that changes).
    @MainActor private var hotkeys: SwishSnap.HotkeyScheme = .off
    @MainActor private var hotkeysWereWanted: Bool?
    /// The left-button monitor for drag to unsnap and resizing adjacent
    /// windows; it exists only while the history has windows in it.
    @MainActor private var mouseMonitor: Any?
    @MainActor private var drag: DragState?
    /// The history windows still where they were snapped as the displays
    /// began to change, and the debounced re-snap.
    @MainActor private var resnapKeys: Set<String>?
    @MainActor private var resnapWork: DispatchWorkItem?
    /// 3.3.3: the window gestures go to wherever the pointer is (multi-motion,
    /// `beginChain`, a detached tab), and its element.
    @MainActor private var windowChain = SwishWindowChain()
    @MainActor private var chainTarget: WindowManager.Target?
    /// A terminal action (minimize, quit, hide, full screen) ran in this
    /// touch: what its fingers do next does nothing until they lift.
    @MainActor private var touchSpent = false
    /// Two fingers are on the pad (between `onTouchDown` and `onTouchEnd`).
    @MainActor private var touchLive = false
    /// Delayed full-screen steps (S05), dropped together when the snap stops.
    @MainActor private let fullscreenTasks = SwishDelayedTasks()
    /// A Space move in flight, and one more waiting for it (several held
    /// swipes in one touch).
    @MainActor private var spaceMoveInFlight = false
    @MainActor private var queuedSpaceMove: (action: SwishSnap.WindowAction, target: WindowManager.Target, start: CGRect)?
    /// The tab under the pointer for the gesture on show (F02).
    @MainActor private var targetTab: AXUIElement?
    /// The gesture's window was named by the Accessibility hit-test, rather
    /// than found by its frame alone (3.4.12): only a confirmed window may
    /// force quit, so a background window whose hit-test was refused gets the
    /// polite quit instead.
    @MainActor private var captureVerified = false
    /// The latest tab detach (N333-05). A detach in flight goes on only while
    /// it is still the latest; the snap stopping, sleep and wake move it on.
    @MainActor private var detachRequest = 0
    /// The generation a commit starts in (N333-06). It moves on when the snap
    /// stops (switched off, Accessibility lost), the Mac sleeps or wakes, or a
    /// chain hands the gestures to another window; a commit landing after
    /// that neither activates its window, moves the pointer nor applies a
    /// motion queued behind it.
    @MainActor private var landingGeneration = 0

    /// One left-button press: where it went down (top-left coordinates), the
    /// snapped window its first drag found on a title bar, and the snapped
    /// windows sharing an edge near it, as they were when it went down.
    private struct DragState {
        struct Unsnap {
            let target: WindowManager.Target
            let key: String
            let snapped: CGRect
            let original: CGRect
        }
        let down: CGPoint
        var probed = false
        var unsnap: Unsnap?
        var lastProbe: TimeInterval = 0
        var neighbours: [String: CGRect] = [:]
    }

    @MainActor
    private init() {
        recognizer.onTouchDown = { Self.onMain { TitleBarWindowSnap.shared.prefetch() } }
        recognizer.onBegin = { stroke in Self.onMain { TitleBarWindowSnap.shared.begin(stroke) } }
        recognizer.onUpdate = { stroke in Self.onMain { TitleBarWindowSnap.shared.update(stroke) } }
        recognizer.onActive = { still in Self.onMain { TitleBarWindowSnap.shared.stillHeld(for: still) } }
        recognizer.onCommit = { Self.onMain { TitleBarWindowSnap.shared.commit() } }
        recognizer.onWithdraw = { Self.onMain { TitleBarWindowSnap.shared.withdraw() } }
        recognizer.onCancel = { Self.onMain { TitleBarWindowSnap.shared.cancel() } }
        recognizer.onHoldCancel = { Self.onMain { TitleBarWindowSnap.shared.heldStillCancel() } }
        recognizer.onPinchChange = { kind in Self.onMain { TitleBarWindowSnap.shared.pinchChanged(kind) } }
        recognizer.onPinch = { kind in Self.onMain { TitleBarWindowSnap.shared.pinched(kind) } }
        recognizer.onTap = { timestamp in Self.onMain { TitleBarWindowSnap.shared.tapped(at: timestamp) } }
        recognizer.onHoldBegan = { Self.onMain { TitleBarWindowSnap.shared.holdBegan() } }
        recognizer.onMotionReady = { Self.onMain { TitleBarWindowSnap.shared.motionReady() } }
        recognizer.onTouchEnd = { Self.onMain { TitleBarWindowSnap.shared.touchEnded() } }
        recognizer.onHoldLift = { Self.onMain { TitleBarWindowSnap.shared.holdLifted() } }
        aomTitleBarSnapFeed = { [weak self] contacts, timestamp, device in
            self?.handle(contacts: contacts, timestamp: timestamp, device: device)
        }
        // Settings › General can flip the feature too; pick that up live. The
        // permission watchdog reports Accessibility being granted after launch
        // (or revoked), which used to leave the snap off until the next
        // settings change or relaunch.
        for name in [Notification.Name.aomSettingChanged, PermissionWatchdog.accessibilityLost,
                     PermissionWatchdog.accessibilityRecovered] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.refreshEnabled() }
            }
        }
        // A gesture never survives sleep: the trackpad stream stops without a
        // lift, and the window may be elsewhere on wake.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.abandonGesture() }
            }
        }
        // Re-snapping (3.3.2): which snapped windows were still in place is
        // read as the reconfiguration begins (macOS moves windows off a
        // display that goes away), the re-snap runs once it has settled.
        if !PresetManager.isRunningTests {
            CGDisplayRegisterReconfigurationCallback(aomSnapDisplaysReconfiguring, nil)
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.displaysChanged() }
            }
        }
        refreshEnabled()
    }

    @MainActor
    func refreshEnabled() {
        let on = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        active = on && AXIsProcessTrusted() && AutomationGate.isOn
        recognizer.holdCancelTime = Self.holdCancelSeconds()
        recognizer.holdTime = Self.gestureOptions().holdGestures ? Self.holdTime : 0
        recognizer.motionPause = Self.motionPause()
        let distances = Self.distances(sensitivity: Self.sensitivity())
        recognizer.engage = distances.engage
        recognizer.crossEngage = distances.crossEngage
        hotkeys = Self.hotkeyScheme()
        let hotkeysWanted = Self.hotkeysWanted()
        if hotkeysWanted != hotkeysWereWanted {
            // The keyboard monitor installs its event tap only when something
            // needs it; tell it (after this turn) when the hotkeys came or went.
            if hotkeysWereWanted != nil || hotkeysWanted {
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.hotkeysDidChange, object: nil) }
            }
            hotkeysWereWanted = hotkeysWanted
        }
        if !active {
            // Switched off or paused: nothing waiting may still act, and the
            // trigger engine gets every touch back.
            Self.ownsTouch = false
            cancelPending()
            lastTap = nil
            cancel()
            drag = nil
            resnapWork?.cancel(); resnapWork = nil; resnapKeys = nil
            endChain("the snap is off or paused")
            touchSpent = false
            touchLive = false
            heldTab = nil
            queuedSpaceMove = nil
            fullscreenTasks.cancelAll()
            // N333-05, N333-06: a tab detach or a landing commit from before never acts after this.
            detachRequest &+= 1
            landingGeneration &+= 1
        }
        updateMouseMonitor()
    }

    /// The recognizer is fed on the main thread (`MultitouchSource` hands
    /// every frame to main before `TrackpadMonitor` fans it out), so its
    /// transitions run at once instead of each queueing one more main-queue
    /// turn (3.3.2: part of the lag before the preview appeared). Frames fed
    /// from any other thread still hop.
    private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    /// From `TrackpadMonitor.source.onFrame`. Cheap and non-blocking: it
    /// forwards to the recognizer only while the snap is on and AOM is not
    /// switched off; otherwise any half-seen gesture is forgotten so it
    /// cannot resume with a stale start when the snap comes back.
    nonisolated func handle(contacts: [TouchPoint], timestamp: Double, device: UInt64 = 0) {
        guard Self.feedsRecognizer(active: active, automationOn: AutomationGate.isOn) else {
            recognizer.reset()
            Self.ownsTouch = false
            return
        }
        // The service cancelled on its own since the last frame: the
        // recognizer drops the gesture too, so both reset together.
        if cancelRequests != handledCancelRequests {
            handledCancelRequests = cancelRequests
            recognizer.cancelUntilLift()
        }
        // `beginChain` handed the touch to another window: start it afresh.
        if rearmRequests != handledRearmRequests {
            handledRearmRequests = rearmRequests
            recognizer.rearm()
        }
        recognizer.feed(contacts: contacts, timestamp: timestamp, device: device)
    }

    /// Whether the two-finger touch on the pad landed on a title bar the snap
    /// captured (written on main at touch-down and whenever the snap stops,
    /// read by `TrackpadMonitor` on main). 3.3.2 review: a pinch, double tap,
    /// long touch or two-finger swipe on a title bar ran a BTT-style trigger
    /// and the snap's own action together; the snap now owns that touch.
    nonisolated(unsafe) static var ownsTouch = false

    /// Pure: whether the trigger engine leaves `gesture` to the snap. Only
    /// two-finger gestures of a touch the snap owns, and only those the snap
    /// itself answers with its current settings.
    nonisolated static func claims(_ gesture: TrackpadGesture, ownsTouch: Bool, pinches: Bool,
                                   doubleTap: Bool, hold: Bool) -> Bool {
        guard ownsTouch else { return false }
        switch gesture {
        case .twoFingerSwipeUp, .twoFingerSwipeDown, .twoFingerSwipeLeft, .twoFingerSwipeRight: return true
        case .twoFingerPinchIn, .twoFingerPinchOut: return pinches
        case .twoFingerTap, .twoFingerDoubleTap: return doubleTap
        case .twoFingerLongTouch: return hold
        default: return false
        }
    }

    /// `claims` with the current settings (main thread, like the trigger engine).
    nonisolated static func claimsNow(_ gesture: TrackpadGesture, defaults: UserDefaults = .standard) -> Bool {
        guard ownsTouch else { return false }
        return claims(gesture, ownsTouch: true, pinches: pinchesOn(defaults),
                      doubleTap: doubleTapOption(defaults) != .off, hold: gestureOptions(defaults).holdGestures)
    }

    /// Bumped on main by `abandonGesture`, read on the multitouch thread
    /// (like `active`, a stale value for one frame is harmless).
    private nonisolated(unsafe) var cancelRequests = 0
    /// Multitouch-thread only.
    private nonisolated(unsafe) var handledCancelRequests = 0
    /// Bumped on main by `beginChain`, read on the multitouch thread, like `cancelRequests`.
    private nonisolated(unsafe) var rearmRequests = 0
    /// Multitouch-thread only.
    private nonisolated(unsafe) var handledRearmRequests = 0

    /// The pause rules of the snap (audit 2026-10-28 F04), shared by the
    /// frame handler and the two places that act on a window, so the gate
    /// cannot drift out of one of them. The test host cannot run the AX part.
    nonisolated static func feedsRecognizer(active: Bool, automationOn: Bool) -> Bool { active && automationOn }
    nonisolated static func mayMoveWindow(active: Bool, gateAllows: Bool) -> Bool { active && gateAllows }

    /// The common pause check, consulted where the snap would act: when it
    /// captures a window and again when it moves it.
    @MainActor private var allowedNow: Bool { Self.mayMoveWindow(active: active, gateAllows: AutomationGate.allows(.trackpad)) }

    // MARK: Transitions (main actor)

    @MainActor
    private func begin(_ stroke: SwishSnap.Stroke) {
        // Only engage over a window's title bar, so the gesture never competes
        // with AOM's other two-finger gestures elsewhere on screen. A swipe that
        // engages while the previous snap is still landing is kept (3.3.2
        // review: it used to be dropped): its latest stroke applies to that
        // window once the commit lands (`finishCommit`).
        guard !committing else {
            if allowedNow, !keyboardCommit { chain.began(stroke) }
            return
        }
        guard allowedNow, !touchSpent else { hideOwnPreview(); reset(); return }
        guard let capture = gestureCapture(), adopt(capture) else { hideOwnPreview(); reset(); return }
        scheduleTimeout()
        showPreview(for: stroke, zoneHaptic: false)
    }

    /// The window a gesture starting now acts on: the chained one (a further
    /// motion of this touch, a handed-over window), else, for a touch's first
    /// gesture only, the one under the pointer. A further motion never picks
    /// up whatever window has come under the pointer since.
    @MainActor
    private func gestureCapture() -> Capture? {
        if let chained = chainedCapture() { return chained }
        return recognizer.motionIndex > 0 ? nil : takeCapture()
    }

    /// The chained window as a capture, while the chain holds and the window
    /// can still be acted on (its app is not paused, it still has a frame);
    /// otherwise the chain ends.
    @MainActor
    private func chainedCapture() -> Capture? {
        let now = ProcessInfo.processInfo.systemUptime
        guard let key = windowChain.current(now: now), let target = chainTarget, Self.key(target) == key else {
            if windowChain.link != nil, windowChain.current(now: now) == nil { endChain("timed out") }
            return nil
        }
        guard target.pid != ProcessInfo.processInfo.processIdentifier, !Self.appPaused(target.pid),
              let frame = Self.boundedFrame(of: target) else {
            endChain("its window is gone or its app is paused")
            return nil
        }
        // 3.4.12: a handed-over window (the Dock, a detached tab) was never
        // hit-tested where the pointer is, so it is no window to force quit
        // from; every other gesture acts on it as before.
        return Capture(mouse: NSEvent.mouseLocation, window: target, frame: frame, at: now, verified: false)
    }

    /// The swipe that engaged while a commit was landing.
    @MainActor private var chain = SwishChainQueue()

    /// The modifier roles held as this gesture began (F05), and the options
    /// they give it: Secondary and Tertiary unlock their grids, Secondary
    /// almost-maximizes on a swipe up.
    @MainActor private var heldRoles: Set<SwishSnap.ModifierRole> = []

    @MainActor
    private func gestureOptionsNow() -> SwishSnap.GestureOptions {
        SwishSnap.effectiveOptions(Self.gestureOptions(), held: heldRoles)
    }

    /// The window under the pointer for a gesture that is starting. The
    /// touch-down lookup is reused while the pointer has not moved (two
    /// resting or scrolling fingers do not move it).
    @MainActor
    private func takeCapture() -> Capture? {
        let mouse = NSEvent.mouseLocation
        defer { prefetched = nil }
        if let early = prefetched, hypot(early.mouse.x - mouse.x, early.mouse.y - mouse.y) < 2,
           ProcessInfo.processInfo.systemUptime - early.at < 2 {
            return early
        }
        return captureTitleBar(at: mouse)
    }

    /// Makes `capture` this gesture's window: its display and cell, the
    /// modifiers held now, whether it is in full screen, and whether it
    /// completes an action waiting on the same app. False when no display
    /// holds it.
    @MainActor
    private func adopt(_ capture: Capture, roles: Set<SwishSnap.ModifierRole>? = nil) -> Bool {
        // AOM paused for the window's app: no gesture acts on it, even while
        // another app is in front (3.3.2 review: the pause is keyed to the
        // frontmost app).
        guard !Self.appPaused(capture.window.pid) else { return false }
        let screens = WindowManager.shared.screens()
        guard let index = WindowGeometry.screenIndex(for: capture.frame, screens: screens.map(\.frame)) else { return false }
        target = capture.window
        let area = Self.snapArea(screens[index].visible)
        targetVisible = area
        startFrame = capture.frame
        // F05 (3.3.3): the configurable modifier roles, read as the gesture
        // starts (a hotkey passes the roles its chord stands for).
        heldRoles = roles ?? SwishSnap.heldRoles()
        modifiers = SwishSnap.Modifiers(held: heldRoles)
        let options = gestureOptionsNow()
        recognizer.cornerTurns = SwishSnap.cornerTurns(modifiers: modifiers, options: options)
        let remembered = history.place(key: Self.key(capture.window), current: capture.frame)
        startPlace = remembered
            ?? SwishSnap.place(of: capture.frame, visible: area, margin: margin,
                               grid: options.grid, almost: options.almostMaximize)
        startPlaceForUp = remembered
            ?? SwishSnap.place(of: capture.frame, visible: area, margin: margin,
                               grid: options.grid, almost: options.almostMaximize, overflowing: false)
        // Bounded (3.3.2 review): this runs on main as the swipe engages.
        fullscreen = Self.boundedIsFullscreen(capture.window)
        // 3.4.12: the waiting close or full-screen toggle of this app, which
        // this gesture completes as the second half of a "twice" gesture.
        repeating = pending.flatMap {
            SwishSnap.repeatingAction(pending: $0.action, pendingPid: $0.target.pid, capturePid: capture.window.pid)
        }
        captureVerified = capture.verified
        shownAction = nil
        targetTab = capture.tab
        return true
    }

    /// Whether the window is in native full screen, asked with a bounded wait;
    /// the element goes back to the default timeout for the commit's writes.
    private static func boundedIsFullscreen(_ target: WindowManager.Target, timeout: Float = 0.25) -> Bool {
        AXUIElementSetMessagingTimeout(target.window, timeout)
        defer { AXUIElementSetMessagingTimeout(target.window, 0) }
        return isFullscreen(target)
    }

    /// Two fingers landed: find the window now, so `begin` has nothing slow
    /// left to do. Cheap for the common case: the window server is asked
    /// which window is under the pointer, and only a pointer in the top band
    /// of an ordinary window reaches the Accessibility hit-test, so scrolling
    /// inside documents costs nothing.
    @MainActor
    private func prefetch() {
        touchLive = true
        touchSpent = false
        guard active, !committing, target == nil, allowedNow else { prefetched = nil; Self.ownsTouch = false; return }
        let pointer = captureTitleBar(at: NSEvent.mouseLocation)
        // 3.3.3: a window chained to this touch (handed over, or waiting its
        // grace after the last touch) unless another window's title bar is
        // under the pointer, which ends the chain.
        if windowChain.link != nil,
           windowChain.touchBegan(pointerKey: pointer.map { Self.key($0.window) },
                                  now: ProcessInfo.processInfo.systemUptime) != nil {
            prefetched = pointer ?? chainedCapture()
        } else {
            if windowChain.link == nil { chainTarget = nil }
            prefetched = pointer
        }
        // This touch is on a title bar: its two-finger triggers are the snap's.
        Self.ownsTouch = prefetched != nil
        // The second half of a "twice" gesture is landing on the same app:
        // give it time to show what it is before the first half runs.
        if let waiting = pending, !waiting.extended, prefetched?.window.pid == waiting.target.pid {
            pending?.extended = true
            armPending(after: Self.twiceWindow + 0.15)
        }
    }

    /// The window whose title bar (or toolbar) is under the pointer, or nil.
    /// 3.3.2 review: the Accessibility hit-test goes to the window's owner,
    /// the PID the window server reports for it, never to the system-wide
    /// element; each request is bounded to 0.25 s and the walk to 0.3 s, and
    /// the frame read to 0.25 s, since this runs on main as two fingers land.
    ///
    /// 3.4.12, a window of an app that is not in front: such an app answers
    /// its own hit-test late, not at all, or with the window it last had in
    /// front, which is why gestures over a background title bar did nothing
    /// (or acted on the wrong window). The window server's record of the
    /// window under the pointer is the truth here, fetched once and cheaply:
    /// a hit-tested window is used only when its frame is that record
    /// (`SwishSnap.sameWindow`), and otherwise the app's own windows are
    /// matched to it by frame (one list request, no walk). The shallow probe
    /// that follows still says whether the pointer is over a tab, so a pinch
    /// on a background tab closes the tab. Nothing here activates the app or
    /// writes to it, so the front window stays in front.
    @MainActor
    private func captureTitleBar(at mouse: CGPoint) -> Capture? {
        let pointerTopLeft = CGPoint(x: mouse.x, y: primaryTop - mouse.y)
        // F04 (3.3.3): with "anywhere" on, the Super modifier held as the
        // fingers land lets the gesture start anywhere on the window.
        let anywhere = Self.superAnywhereOn()
            && SwishSnap.ModifierRoles.load(.standard).held(NSEvent.modifierFlags).contains(.superKey)
        // Window-server pre-filter: an ordinary (layer 0) window of another
        // app AOM must not touch, with the pointer in its top band (title bar,
        // toolbar, tab bar).
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        guard number > 0, !NSApp.windows.contains(where: { $0.windowNumber == number }),
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first,
              (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
              let owner = info[kCGWindowOwnerPID as String] as? pid_t,
              owner > 0, owner != ProcessInfo.processInfo.processIdentifier,
              !Self.protectedApp(owner),
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              SwishSnap.inPreFilterBand(pointerY: pointerTopLeft.y, windowTop: bounds.minY, anywhere: anywhere) else { return nil }
        let at = ProcessInfo.processInfo.systemUptime
        if let hit = WindowManager.shared.titleBarHit(atMousePoint: mouse, pid: owner, anywhere: anywhere),
           let frame = Self.boundedFrame(of: hit.target),
           SwishSnap.sameWindow(accessibilityFrame: frame, windowServerBounds: bounds),
           SwishSnap.isStartArea(onTitleBar: hit.onTitleBar, onTabBar: hit.onTabBar,
                                 inTitleBand: SwishSnap.titleBarHit(pointerTopLeft: pointerTopLeft, windowFrame: frame),
                                 anywhere: anywhere) {
            let tab = Self.tabGesturesOn() ? hit.tab : nil
            return Capture(mouse: mouse, window: hit.target, frame: frame, at: at, tab: tab)
        }
        // The hit-test was refused, ran out of its budget, or named a window
        // that is not the one under the pointer: the window server's record,
        // matched by frame, decides. The title band is checked here instead of
        // the hit-test's toolbar and tab bar, so a pointer below the band (a
        // document, a list) never starts a gesture.
        guard let match = WindowManager.shared.window(matching: bounds, pid: owner),
              SwishSnap.isStartArea(onTitleBar: false, onTabBar: false,
                                    inTitleBand: SwishSnap.titleBarHit(pointerTopLeft: pointerTopLeft, windowFrame: match.frame),
                                    anywhere: anywhere) else { return nil }
        // Shallow (four levels, 0.12 s): a tab button or a toolbar is within
        // them, so a pinch on a background tab closes the tab, not the window,
        // and the walk cannot turn into the cost this path exists to avoid.
        let probe = WindowManager.shared.titleBarHit(atMousePoint: mouse, pid: owner, timeout: 0.12,
                                                     budget: 0.12, depth: 4)
        let tab = probe.flatMap { CFEqual($0.target.window, match.target.window) ? $0.tab : nil }
        return Capture(mouse: mouse, window: match.target, frame: match.frame, at: at,
                       tab: Self.tabGesturesOn() ? tab : nil, verified: false)
    }

    /// 3.4.12: whether a window server owner PID belongs to an app a title-bar
    /// gesture must leave alone (AOM itself, the Dock and Stage Manager, the
    /// menu bar's hosts, the login window). Asked from the running app, never
    /// from Accessibility, so it costs nothing.
    @MainActor
    private static func protectedApp(_ pid: pid_t) -> Bool {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return true }
        return SwishSnap.isProtectedGestureApp(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }

    /// 3.4.12: whether a force quit may name this window's app at all: a named
    /// app (a process without a bundle ID is not), not AOM or a protected
    /// system process, and not an app AOM is paused for. The pause is asked
    /// again here, as `perform` asks it for every action.
    @MainActor
    private static func mayForceQuit(_ target: WindowManager.Target) -> Bool {
        let pid = target.pid
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier, !appPaused(pid),
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              !bundleID.isEmpty else { return false }
        return !SwishSnap.isProtectedGestureApp(bundleID: bundleID)
    }

    @MainActor
    private func update(_ stroke: SwishSnap.Stroke) {
        // A swipe that began while the last commit was landing keeps its latest stroke.
        if committing { chain.updated(stroke); return }
        guard target != nil, !pinching else { return }
        scheduleTimeout()
        showPreview(for: stroke, zoneHaptic: true)
    }

    /// N335: the fingers took the swipe back to where it started. Nothing is
    /// on show and lifting does nothing (`commit` finds no plan) until they
    /// swipe out again (`update`). Until now the preview held its last place
    /// and lifting committed it, so a stroke could not be taken back.
    @MainActor
    private func withdraw() {
        if committing { chain.withdraw(); return }
        guard target != nil, !pinching else { return }
        scheduleTimeout()
        plan = nil
        present(nil)
    }

    /// Fingers still on the pad with the preview up: keep it. Over the last
    /// second before a hold-still cancel the preview fades, so the user sees
    /// the cancel coming and can move to keep the snap.
    @MainActor
    private func stillHeld(for still: Double) {
        guard target != nil, !committing else { return }
        scheduleTimeout()
        let limit = recognizer.holdCancelTime
        guard limit > 0, overlay.isShowing else { return }
        let lead = min(1, limit / 2)
        overlay.dim(CGFloat(max(0, min(1, (still - (limit - lead)) / lead))))
    }

    /// Swish: the fingers rested without moving for the hold-cancel time, so
    /// the gesture on show is dropped and lifting them does nothing. When the
    /// HUD named an action (no preview to fade) it says so.
    @MainActor
    private func heldStillCancel() {
        heldTab = nil
        // A chained swipe waiting for the commit in flight is dropped too.
        guard !committing else { chain.cancelTouch(); return }
        let named = shownAction != nil
        if target != nil {
            GestureLog.shared.logFromAnyThread("Title-bar snap cancelled: fingers held still", level: .detect)
        }
        cancel()
        if named { GestureHUD.shared.show(title: "Cancelled") }
    }

    /// Esc cancels the gesture on show (Swish: "Cancel gestures by pressing
    /// Esc or resting for the specified timeout"): its preview or HUD goes, a
    /// "twice" action still waiting is dropped, and the fingers do nothing
    /// more until they lift. False, and the key goes on to the app, when no
    /// gesture is on show. From `KeyboardMonitor`'s Esc handling; the
    /// service is not built while the snap is off.
    @MainActor
    static func cancelOnEscape() -> Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false else { return false }
        return shared.escapeCancel()
    }

    @MainActor
    private func escapeCancel() -> Bool {
        guard SwishSnap.escapeCancels(gestureOnShow: target != nil, tabHeld: heldTab != nil,
                                      actionWaiting: pending != nil,
                                      motionQueued: committing && chain.queue.last?.lifted == false) else { return false }
        heldTab = nil
        cancelPending()
        GestureLog.shared.logFromAnyThread("Title-bar gesture cancelled: Esc", level: .detect)
        cancel()
        // The recognizer drops the rest of the touch, as after a watchdog cancel.
        cancelRequests &+= 1
        GestureHUD.shared.show(title: "Cancelled")
        return true
    }

    /// The service gives up on its own (no frames, sleep): hide the preview,
    /// drop anything waiting, and make the recognizer drop the gesture too.
    @MainActor
    private func abandonGesture() {
        cancelPending()
        lastTap = nil
        cancel()
        cancelRequests &+= 1
        // N333-05, N333-06: nor does a tab detach in flight, or what follows a commit still landing.
        detachRequest &+= 1
        landingGeneration &+= 1
    }

    @MainActor
    private func showPreview(for stroke: SwishSnap.Stroke, zoneHaptic: Bool) {
        guard let target, let visible = targetVisible, let start = startFrame else { return }
        let next = plan(for: stroke, target: target, visible: visible, start: start)
        // Swish taps the trackpad as the preview moves to a new zone.
        if zoneHaptic, next != plan, hapticsOn { _ = GestureHaptics.shared.feedback(enabled: true) }
        plan = next
        // The second ⌥ swipe down on the app quits it: the first one's close no longer waits.
        if next?.action == .quitApp, repeating == .close { cancelPending() }
        tooltipDirection = SwishSnap.tooltipDirection(for: stroke)
        present(next)
    }

    /// The swipe moves the window on from the place it sits in (Swish-style
    /// chaining, `SwishSnap.move(at:…)`) or acts on it (minimize, close, quit,
    /// full screen, Spaces, displays). Nil: the swipe does nothing (a
    /// full-screen window swiped without tap-and-hold).
    @MainActor
    private func plan(for stroke: SwishSnap.Stroke, target: WindowManager.Target,
                      visible: CGRect, start: CGRect) -> Plan? {
        let move = SwishSnap.move(at: Self.place(forStroke: stroke, start: startPlace, startForUp: startPlaceForUp),
                                  stroke: stroke, modifiers: modifiers,
                                  options: gestureOptionsNow(), fullscreen: fullscreen)
        guard let move else { return nil }
        switch move {
        case .restore:
            return restorePlan(target: target, visible: visible, start: start)
        case .cell, .place:
            let place = move.destination ?? .center
            // F06: macOS tiles halves, quarters and Fill itself; preview its frame.
            if Self.nativeTilingWanted,
               let native = NativeTiling.previewFrame(place: place, visible: visible, options: NativeTiling.systemOptions()) {
                return Plan(place: place, rect: native)
            }
            return Plan(place: place, rect: SwishSnap.targetFrame(place: place, visible: visible, margin: margin))
        case .action(.close):
            // ⌥ swipe down twice quits (Swish): the second swipe on an app
            // whose close is still waiting.
            if repeating == .close { return Plan(place: nil, rect: .null, action: .quitApp) }
            return Plan(place: nil, rect: .null, action: .close, waits: true)
        case .action(.screen(let direction)):
            return Plan(place: startPlace, rect: displayFrame(toward: direction, start: start) ?? .null,
                        action: .screen(direction))
        case .action(let action):
            return Plan(place: nil, rect: .null, action: action)
        }
    }

    /// A restore goes back to the frame from before AOM snapped the window,
    /// kept whole on a display (N335, Swish's "Unsnap: Avoid cropping"), or
    /// centres a window AOM has no frame for.
    @MainActor
    private func restorePlan(target: WindowManager.Target, visible: CGRect, start: CGRect) -> Plan {
        if let original = history.restoreFrame(key: Self.key(target), current: start) {
            let areas = WindowManager.shared.screens().map(\.visible)
            return Plan(place: nil, rect: SwishSnap.unsnapFrame(original: original, areas: areas, current: start))
        }
        return Plan(place: .center, rect: SwishSnap.targetFrame(place: .center, visible: visible, margin: margin))
    }

    /// Pure (N334): the place a stroke chains from. A plain swipe up (no
    /// cross leg) uses `startForUp`, which never counts a cell the window
    /// only overflows, so a large free window maximizes; every other stroke
    /// keeps the overflow reading (a size-limited top quarter swiped down
    /// still moves to the bottom).
    static func place(forStroke stroke: SwishSnap.Stroke, start: SwishSnap.Place?,
                      startForUp: SwishSnap.Place?) -> SwishSnap.Place? {
        stroke.direction == .up && stroke.cross == nil ? startForUp : start
    }

    /// Where a display move puts the window: the same place on the display
    /// that way, or, free-floating, centred there at its own size. Nil when
    /// no display lies that way.
    @MainActor
    private func displayFrame(toward direction: SwishSnap.Direction, start: CGRect) -> CGRect? {
        let screens = WindowManager.shared.screens()
        guard let index = SwishSnap.screenIndex(toward: direction, from: start, screens: screens.map(\.frame)) else { return nil }
        let visible = Self.snapArea(screens[index].visible)
        if let place = startPlace { return SwishSnap.targetFrame(place: place, visible: visible, margin: margin) }
        return WindowGeometry.moved(start, into: visible, maximize: false)
    }

    /// Shows what lifting will do: the translucent frame for a snap (for a
    /// display move, on the destination) and the HUD for any other action.
    /// Both follow the preview switch.
    @MainActor
    private func present(_ plan: Plan?) {
        let visuals = Self.flag(Self.previewKey, default: true)
        guard let plan, let action = plan.action else {
            if shownAction != nil { GestureHUD.shared.dismiss(); shownAction = nil }
            guard let plan else { hideOwnPreview(); return }
            guard visuals else { return }
            overlay.show(frame: SwishSnap.appKitRect(plan.rect, primaryTop: primaryTop), restoring: plan.place == nil)
            // Swish's tooltip beside the pointer: where the window goes (3.3.3).
            if Self.tooltipOn() {
                SwishGestureTooltip.shared.show(SwishSnap.tooltipText(direction: tooltipDirection, place: plan.place),
                                                near: NSEvent.mouseLocation, speed: Self.animationSpeed())
            }
            return
        }
        hideTooltip()
        if case .screen = action, !plan.rect.isNull, visuals {
            overlay.show(frame: SwishSnap.appKitRect(plan.rect, primaryTop: primaryTop))
        } else {
            hideOwnPreview()
        }
        guard visuals, shownAction != action else { return }
        shownAction = action
        GestureHUD.shared.show(title: hudTitle(for: action, plan: plan))
    }

    @MainActor
    private func hudTitle(for action: SwishSnap.WindowAction, plan: Plan) -> String {
        if case .screen(let direction) = action, plan.rect.isNull { return "No Display \(SwishSnap.arrow(direction))" }
        let name = target.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName }
        return SwishSnap.title(for: action, appName: name, fullscreen: fullscreen)
    }

    @MainActor
    private func commit() {
        timeout?.cancel(); timeout = nil
        // The lift of a swipe that engaged while the previous snap is still
        // landing: it is applied once that commit is done (`finishCommit`).
        guard !committing else { chain.liftedFingers(); return }
        // Paused (or switched off) while the fingers were down: never move the window.
        guard allowedNow, let target, let visible = targetVisible,
              let plan, let start = startFrame else {
            hideOwnPreview(); reset(); return
        }
        // Multi-motion (3.3.3): what the fingers do next in this touch acts
        // on this window, wherever it ends up.
        chainTouch(to: target)
        if let action = plan.action {
            run(action, plan: plan, target: target, start: start)
            return
        }
        // F06: Swish's "Native Window Tiling" for what macOS can tile.
        if Self.nativeTilingWanted, let place = plan.place, let key = NativeTiling.menuKey(for: place) {
            commitNative(key: key, place: place, rect: plan.rect, target: target, anchorVisible: visible, start: start)
            return
        }
        commitFrame(plan.rect, target: target, anchorVisible: visible, start: start,
                    restoring: plan.place == nil, place: plan.place)
    }

    /// Moves the window to `rect` the way Swish commits a snap; the preview
    /// then settles on the frame it took, which is kept for unsnapping.
    /// `generation`: the one the commit started in (a native tile falling
    /// back here passes its own); nil starts it now.
    @MainActor
    private func commitFrame(_ rect: CGRect, target: WindowManager.Target, anchorVisible visible: CGRect,
                             start: CGRect, restoring: Bool, place: SwishSnap.Place?, generation: Int? = nil) {
        committing = true
        let key = Self.key(target)
        let generation = generation ?? landingGeneration
        // Anchor inside the margin-inset area, so a gap the user asked for is
        // kept when an app refuses the cell's size.
        let anchorArea = margin > 0 ? visible.insetBy(dx: margin, dy: margin) : visible
        WindowManager.shared.applySnap(rect, target: target, visible: restoring ? nil : anchorArea) { actual in
            // `applySnap` reports on the main thread (its settle polling runs there).
            MainActor.assumeIsolated {
                TitleBarWindowSnap.shared.finishCommit(actual, target: target, key: key, start: start,
                                                       restoring: restoring, place: place, generation: generation)
            }
        }
    }

    /// Whether this snap goes through macOS's own tiling (F06): the option is
    /// on and the system has Window › Move & Resize (macOS 15 and later; on
    /// macOS 14 AOM's own engine snaps without first searching the menu).
    @MainActor private static var nativeTilingWanted: Bool {
        guard nativeTilingOn() else { return false }
        if #available(macOS 15, *) { return true }
        return false
    }

    /// Native tiling (F06): the app's own Window › Move & Resize item tiles
    /// the window; where it has none, AOM's engine snaps it (Swish: "Otherwise,
    /// Swish will fall back to its own snapping engine"), unless the pause
    /// came on meanwhile. The commit stays in flight until the tile has been
    /// read back, so chained swipes wait for it as for any commit.
    @MainActor
    private func commitNative(key: String, place: SwishSnap.Place, rect: CGRect, target: WindowManager.Target,
                              anchorVisible visible: CGRect, start: CGRect) {
        committing = true
        let windowKey = Self.key(target)
        let generation = landingGeneration
        NativeTiling.tile(target, key: key, mayContinue: {
            TitleBarWindowSnap.shared.allowedNow && !Self.appPaused(target.pid)
        }) { pressed in
            let service = TitleBarWindowSnap.shared
            guard pressed else {
                guard service.allowedNow, !Self.appPaused(target.pid) else {
                    service.finishCommit(nil, target: target, key: windowKey, start: start, restoring: false, place: place,
                                         generation: generation)
                    return
                }
                service.commitFrame(rect, target: target, anchorVisible: visible, start: start, restoring: false,
                                    place: place, generation: generation)
                return
            }
            // macOS animates the tile; read where the window landed once it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated {
                    let landed = Self.boundedFrame(of: target)
                    // N333-06: a window that no longer answers gets no follow-ups.
                    TitleBarWindowSnap.shared.finishCommit(landed ?? rect, target: target, key: windowKey, start: start,
                                                           restoring: false, place: place, generation: generation,
                                                           windowAnswers: landed != nil)
                }
            }
        }
    }

    /// The end of a commit (N333-06). The bookkeeping always runs: the
    /// history keeps where the window went (or forgets a restore), the
    /// preview goes and the gesture state is cleared. The haptic, the
    /// preview settling on the frame, the activation, the pointer move and a
    /// motion queued behind the commit run only if `landingAllowed`, asked
    /// now: AOM, the window's app or the snap may have changed while the
    /// window moved.
    @MainActor
    private func finishCommit(_ actual: CGRect?, target: WindowManager.Target, key: String, start: CGRect,
                              restoring: Bool, place: SwishSnap.Place?, generation: Int, windowAnswers: Bool = true) {
        committing = false
        let fromKeyboard = keyboardCommit
        keyboardCommit = false
        let followUps = actual != nil
            && landingAllowed(target, generation: generation, keyboard: fromKeyboard, windowAnswers: windowAnswers)
        // A swipe that engaged meanwhile carries on with this window (3.3.2
        // review), only when the follow-ups may run.
        let chained = chain.landed(succeeded: followUps)
        guard let actual else { hideOwnPreview(); reset(); return }
        if !followUps {
            GestureLog.shared.logFromAnyThread("Title-bar snap landed after a pause or a change: "
                                               + "no activation, pointer move or chained gesture", level: .detect)
        }
        let landing = SwishCommitLanding(
            record: {
                if restoring {
                    self.forgetSnap(key)
                } else {
                    self.history.recordSnap(key: key, from: start, to: actual, place: place)
                    self.remember(target, key: key)
                }
            },
            hidePreview: { self.hideOwnPreview() },
            settlePreview: { self.overlay.settle(on: SwishSnap.appKitRect(actual, primaryTop: self.primaryTop)) },
            haptic: { _ = GestureHaptics.shared.feedback(enabled: true) },
            activate: { self.bringForward(target) },
            warpPointer: {
                CGWarpMouseCursorPosition(SwishSnap.titleBarRestPoint(for: actual))
                // A warp briefly suppresses local mouse events; re-associate so
                // the pointer moves again immediately.
                CGAssociateMouseAndMouseCursorPosition(1)
            },
            reset: { self.reset() },
            resumeQueued: {
                if let chained { self.resumeChain(chained, target: target, frame: actual) }
            })
        landing.land(followUps: followUps,
                     options: .init(haptics: hapticsOn, activate: Self.flag(Self.activateKey, default: true),
                                    movePointer: Self.flag(Self.keepPointerKey, default: false) && !fromKeyboard))
    }

    /// Whether what follows a commit's move may run as it lands (N333-06):
    /// the commit's generation still holds (the snap did not stop, the Mac did
    /// not sleep, no chain took the gestures to another window), its window
    /// still answered, and the rules of a delayed window step allow it, with
    /// the gate of the commit's own input (the keyboard's for a hotkey).
    @MainActor
    private func landingAllowed(_ target: WindowManager.Target, generation: Int, keyboard: Bool,
                                windowAnswers: Bool) -> Bool {
        let app = NSRunningApplication(processIdentifier: target.pid)
        return SwishCommitLanding.followUpsAllowed(
            sameGeneration: generation == landingGeneration, windowAnswers: windowAnswers,
            allowed: keyboard ? hotkeyAllowedNow : allowedNow, appPaused: Self.appPaused(target.pid),
            screenLocked: ScreenLock.isLocked, appRunning: app.map { !$0.isTerminated } ?? false)
    }

    /// The swipe that engaged while the last commit was landing (3.3.2
    /// review): it carries on with the window that just moved, from the place
    /// it moved to, as if it had begun now. Lifted already, it commits at
    /// once; still on the pad, its preview follows the fingers as usual.
    @MainActor
    private func resumeChain(_ queued: SwishChainQueue.Pending, target: WindowManager.Target, frame: CGRect) {
        guard active, allowedNow else { return }
        // 3.4.12: the window is known but the pointer's part of its title bar
        // is not (the commit it waited behind moved it), so this gesture never
        // force quits; everything else acts as before.
        let capture = Capture(mouse: NSEvent.mouseLocation, window: target, frame: frame,
                              at: ProcessInfo.processInfo.systemUptime, verified: false)
        guard adopt(capture) else { reset(); return }
        GestureLog.shared.logFromAnyThread("Title-bar snap: chained swipe applied after the last snap landed", level: .detect)
        scheduleTimeout()
        if queued.isPinch {
            // Multi-motion: a pinch after a swipe in the same touch.
            pinching = true
            applyPinch(queued.pinch)
            if queued.lifted {
                if let kind = queued.pinch { pinched(kind) } else { cancel() }
            }
        } else if queued.withdrawn {
            // N335: taken back to where it started; it shows nothing until
            // the fingers swipe out again (`update`), and lifted it does nothing.
            plan = nil
            if queued.lifted { reset() }
        } else {
            showPreview(for: queued.stroke, zoneHaptic: false)
            if queued.lifted { commit() }
        }
        // An action (no frame to land) leaves the next waiting motion with
        // nothing to wait for: it goes on now, from the same frame.
        if !committing, chain.pending != nil, let next = chain.landed(succeeded: true) {
            resumeChain(next, target: target, frame: Self.boundedFrame(of: target) ?? frame)
        }
    }

    /// Keeps the window findable for as long as the history holds it (the
    /// history drops the oldest past its limit; so does this table).
    @MainActor
    private func remember(_ target: WindowManager.Target, key: String) {
        snapTargets[key] = target
        if snapTargets.count > history.entries.count {
            snapTargets = snapTargets.filter { history.entries[$0.key] != nil }
        }
        updateMouseMonitor()
    }

    @MainActor
    private func forgetSnap(_ key: String) {
        history.forget(key: key)
        snapTargets.removeValue(forKey: key)
        updateMouseMonitor()
    }

    /// Lifting on a gesture that acts on the window. A display move is a snap
    /// onto that display (its preview settles there); the first half of a
    /// "twice" gesture waits `repeatWindow` for the second; the rest run now.
    @MainActor
    private func run(_ action: SwishSnap.WindowAction, plan: Plan, target: WindowManager.Target, start: CGRect) {
        if case .screen = action, !Self.isFullscreen(target) {
            guard !plan.rect.isNull else { hideOwnPreview(); reset(); return }
            let screens = WindowManager.shared.screens()
            let visible = WindowGeometry.screenIndex(for: plan.rect, screens: screens.map(\.frame))
                .map { Self.snapArea(screens[$0].visible) } ?? plan.rect
            commitFrame(plan.rect, target: target, anchorVisible: visible, start: start, restoring: false, place: plan.place)
            return
        }
        if hapticsOn { _ = GestureHaptics.shared.feedback(enabled: true) }
        hideOwnPreview()
        if plan.waits {
            schedulePending(Pending(action: action, target: target, start: start))
        } else {
            perform(action, target: target, start: start, destination: plan.rect)
        }
        // Multi-motion: after the window went away or changed mode the rest
        // of this touch does nothing.
        if touchLive, !SwishSnap.touchContinues(after: action, waits: plan.waits) { touchSpent = true }
        reset()
    }

    @MainActor
    private func cancel() {
        timeout?.cancel(); timeout = nil
        chain.cancelTouch()
        hideOwnPreview()
        if shownAction != nil { GestureHUD.shared.dismiss() }
        reset()
    }

    /// Hides the preview only when this gesture put one up, so a gesture that
    /// never engaged cannot cut the previous snap's settle animation short.
    @MainActor
    private func hideOwnPreview() {
        if overlay.isShowing { overlay.hide() }
        hideTooltip()
    }

    /// The direction of the swipe on show, for the tooltip's arrow and for
    /// `commit` to tell a swipe up that maximizes (N334).
    @MainActor private var tooltipDirection: SwishSnap.Direction?

    @MainActor
    private func hideTooltip() {
        if SwishGestureTooltip.shared.isShowing { SwishGestureTooltip.shared.hide(speed: Self.animationSpeed()) }
    }

    @MainActor
    private func reset() {
        target = nil; targetVisible = nil; startFrame = nil; startPlace = nil; startPlaceForUp = nil; plan = nil; targetTab = nil
        modifiers = []; fullscreen = false; pinching = false; repeating = nil; shownAction = nil; heldRoles = []
        captureVerified = false
        tooltipDirection = nil
        hideTooltip()
    }

    // MARK: Pinches, taps and tap-and-hold (3.3.2)

    /// A pinch was recognised, or let go: its window is captured the way a
    /// swipe's is, and the HUD names what lifting will do.
    @MainActor
    private func pinchChanged(_ kind: SwishSnap.Pinch?) {
        guard Self.pinchesOn() else { return }
        if committing {
            // Multi-motion (3.3.3): a pinch after a swipe whose commit is
            // still landing; it applies to that window once it lands.
            guard allowedNow, !keyboardCommit else { return }
            if let last = chain.queue.last, !last.lifted, last.isPinch {
                chain.pinchUpdated(kind)
            } else if kind != nil {
                chain.beganPinch(kind)
            }
            return
        }
        if target == nil {
            guard kind != nil, allowedNow, !touchSpent, let capture = gestureCapture(), adopt(capture) else { return }
            pinching = true
        }
        guard pinching else { return }
        scheduleTimeout()
        applyPinch(kind)
    }

    /// What lifting on the pinch on show will do: its plan, and the HUD.
    @MainActor
    private func applyPinch(_ kind: SwishSnap.Pinch?) {
        guard let kind else {
            // Back to where the fingers landed: lifting now does nothing.
            plan = nil
            present(nil)
            return
        }
        // F02: a pinch in over a tab closes the tab, never the window.
        if kind == .in, targetTab != nil, let target {
            let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
            switch SwishTabs.gesture(pinch: kind, family: SwishTabs.family(bundleID: bundleID)) {
            case .close?:
                let next = Plan(place: nil, rect: .null, action: .closeTab)
                if plan != nil, next != plan, hapticsOn { _ = GestureHaptics.shared.feedback(enabled: true) }
                plan = next
                present(next)
                return
            case .unsupported?:
                plan = nil
                present(nil)
                if Self.flag(Self.previewKey, default: true) { GestureHUD.shared.show(title: "Tabs Not Supported Here") }
                return
            case .detach?, nil:
                break
            }
        }
        let options = Self.gestureOptions()
        let second = (kind == .in && repeating == .close) || (kind == .out && repeating == .toggleFullscreen)
        // 3.4.12: two quick pinches in are the user's explicit force quit. It
        // only ever names a window the hit-test confirmed — a window found by
        // its frame alone could be the wrong one, and there is no taking a
        // force quit back — and never AOM, a system process or a paused app;
        // those take the polite quit on the same double pinch.
        var mayForceQuit = false
        if second, kind == .in, captureVerified, let target { mayForceQuit = Self.mayForceQuit(target) }
        let decision = SwishSnap.pinchAction(kind, second: second, held: recognizer.isHeld && options.holdGestures,
                                             modifiers: options.modifierGestures ? modifiers : [],
                                             displays: WindowManager.shared.screens().count,
                                             mayForceQuit: mayForceQuit)
        // The second pinch completes the first: its action no longer waits.
        if second { cancelPending() }
        let next = Plan(place: nil, rect: .null, action: decision.action, waits: decision.waits)
        if plan != nil, next != plan, hapticsOn { _ = GestureHaptics.shared.feedback(enabled: true) }
        plan = next
        present(next)
    }

    @MainActor
    private func pinched(_ kind: SwishSnap.Pinch) {
        timeout?.cancel(); timeout = nil
        if committing {
            // Multi-motion: the waiting pinch is done; it runs once the commit lands.
            if let last = chain.queue.last, !last.lifted, last.isPinch {
                chain.pinchUpdated(kind)
                chain.liftedFingers()
            }
            return
        }
        guard pinching, allowedNow, let target, let plan, let action = plan.action,
              let start = startFrame else { cancel(); return }
        chainTouch(to: target)
        run(action, plan: plan, target: target, start: start)
    }

    /// A two-finger tap on a title bar. The second one within `repeatWindow`,
    /// on the same window with the pointer where it was, is a double tap.
    @MainActor
    private func tapped(at timestamp: Double) {
        let option = Self.doubleTapOption()
        guard active, !committing, allowedNow, option != .off, let capture = gestureCapture() else { lastTap = nil; return }
        if let last = lastTap, timestamp >= last.at, timestamp - last.at <= Self.repeatWindow,
           hypot(capture.mouse.x - last.mouse.x, capture.mouse.y - last.mouse.y) <= Self.doubleTapDistance,
           last.target.pid == capture.window.pid, CFEqual(last.target.window, capture.window.window) {
            lastTap = nil
            doubleTapped(capture, option: option)
        } else {
            lastTap = (timestamp, capture.mouse, capture.window)
        }
    }

    /// Swish's double tap: unsnap (restore the pre-snap frame while the
    /// window still sits where AOM put it) or centre; ⌥ hides the app and ⇧
    /// the other apps.
    @MainActor
    private func doubleTapped(_ capture: Capture, option: SwishSnap.DoubleTap) {
        let options = Self.gestureOptions()
        let held = options.modifierGestures ? SwishSnap.Modifiers(held: SwishSnap.heldRoles()) : []
        guard let move = SwishSnap.doubleTapMove(option, modifiers: held) else { return }
        switch move {
        case .action(let action):
            if hapticsOn { _ = GestureHaptics.shared.feedback(enabled: true) }
            if Self.flag(Self.previewKey, default: true) {
                let name = NSRunningApplication(processIdentifier: capture.window.pid)?.localizedName
                GestureHUD.shared.show(title: SwishSnap.title(for: action, appName: name))
            }
            perform(action, target: capture.window, start: capture.frame)
        case .restore, .cell, .place:
            guard adopt(capture), let visible = targetVisible else { reset(); return }
            let plan = move == .restore ? restorePlan(target: capture.window, visible: visible, start: capture.frame)
                : Plan(place: .center, rect: SwishSnap.targetFrame(place: .center, visible: visible, margin: margin))
            if Self.flag(Self.previewKey, default: true) {
                overlay.show(frame: SwishSnap.appKitRect(plan.rect, primaryTop: primaryTop), restoring: plan.place == nil)
            }
            commitFrame(plan.rect, target: capture.window, anchorVisible: visible, start: capture.frame,
                        restoring: plan.place == nil, place: plan.place)
        }
    }

    /// The fingers rested long enough for tap-and-hold: Swish answers with a
    /// haptic. Only over a title bar; resting fingers elsewhere are no gesture.
    @MainActor
    private func holdBegan() {
        guard active, !committing, allowedNow, prefetched != nil || chainTarget != nil else { return }
        if hapticsOn { _ = GestureHaptics.shared.feedback(enabled: true) }
        // F02: resting on a tab that can be detached; lifting now detaches it.
        heldTab = nil
        guard let capture = prefetched, let tab = capture.tab, !Self.appPaused(capture.window.pid) else { return }
        let family = SwishTabs.family(bundleID: NSRunningApplication(processIdentifier: capture.window.pid)?.bundleIdentifier)
        guard SwishTabs.support(family).detach, SwishTabs.canDetach(family: family, tabCount: SwishTabs.tabCount(of: tab)) else { return }
        heldTab = (tab, capture.window)
        if Self.flag(Self.previewKey, default: true) { GestureHUD.shared.show(title: "Detach Tab") }
    }

    /// The tab a tap and hold rests on, which lifting detaches (F02).
    @MainActor private var heldTab: (tab: AXUIElement, target: WindowManager.Target)?

    /// The fingers lifted after a tap and hold that never swiped or pinched
    /// (F02, Swish: "Tap and hold to detach a native tab into a new window.
    /// Follow up with any other gesture."): the held tab goes to a new window
    /// through the app's own Move Tab to New Window, and that window is
    /// chained, so the next gesture within `SwishWindowChain.grace` applies to it.
    @MainActor
    private func holdLifted() {
        guard let held = heldTab else { return }
        heldTab = nil
        GestureHUD.shared.dismiss()
        let pid = held.target.pid
        guard active, allowedNow, !Self.appPaused(pid) else { return }
        // N333-05: each detach is a request of its own, asked about at every step.
        detachRequest &+= 1
        let request = detachRequest
        SwishTabs.detach(tab: held.tab, window: held.target.window, pid: pid,
                         mayContinue: { TitleBarWindowSnap.shared.detachMayContinue(request, target: held.target) }) { detached in
            guard let detached else { return }
            _ = TitleBarWindowSnap.shared.beginChain(window: detached.window, pid: detached.pid, reason: "detached tab")
        }
    }

    /// Whether the tab detach `request` may go on (N333-05): it is still the
    /// latest, and the rules of a delayed window step allow it (the snap on
    /// and not paused, the window's app not paused, the screen not locked,
    /// the app still running).
    @MainActor
    private func detachMayContinue(_ request: Int, target: WindowManager.Target) -> Bool {
        request == detachRequest && delayedStepAllowed(target)
    }

    // MARK: Chaining a window (3.3.3)

    /// Chains `window` of `pid` for title-bar gestures (the Dock stream's
    /// hand-over, a detached tab). Until the fingers now on the pad lift, and
    /// for `SwishWindowChain.grace` (3 s) after, title-bar gestures apply to
    /// it wherever the pointer is; a touch landing on another window's title
    /// bar captures that window instead and ends the chain, as does the
    /// timeout, pausing AOM or the window's app, the window going away, and
    /// a newer chain. Called mid-touch, the rest of the touch starts afresh
    /// from where the fingers are (no tap, not held), so the caller must stop
    /// acting on that touch itself. False, and nothing chained, when the snap
    /// is off or paused, `pid` is AOM's own or a paused app, or the window has
    /// no readable frame (bounded to 0.25 s).
    @MainActor
    @discardableResult
    func beginChain(window: AXUIElement, pid: pid_t, reason: String) -> Bool {
        guard active, allowedNow, pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              !Self.appPaused(pid) else { return false }
        let chained = WindowManager.Target(window: window, pid: pid)
        guard Self.boundedFrame(of: chained) != nil else { return false }
        // Whatever this touch showed on another window is dropped.
        if target != nil, !committing { cancel() }
        // N333-06: a commit landing on another window does not take the user
        // back to it (no activation, pointer move or queued motion).
        if committing, target.map({ Self.key($0) }) != Self.key(chained) { landingGeneration &+= 1 }
        windowChain.begin(key: Self.key(chained), pid: pid, reason: reason, outlivesTouch: true,
                          touchLive: touchLive, now: ProcessInfo.processInfo.systemUptime)
        chainTarget = chained
        touchSpent = false
        if touchLive {
            rearmRequests &+= 1
            Self.ownsTouch = true
        }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        GestureLog.shared.logFromAnyThread("Title-bar gestures chained to a window of \(name) (\(reason))", level: .detect)
        return true
    }

    /// Multi-motion: the touch on the pad goes on acting on `target`.
    @MainActor
    private func chainTouch(to target: WindowManager.Target) {
        guard touchLive else { return }
        windowChain.begin(key: Self.key(target), pid: target.pid, reason: "multi-motion", outlivesTouch: false,
                          touchLive: true, now: ProcessInfo.processInfo.systemUptime)
        chainTarget = target
    }

    @MainActor
    private func endChain(_ why: String) {
        if let link = windowChain.link, link.outlivesTouch {
            GestureLog.shared.logFromAnyThread("Title-bar chain ended: \(why)", level: .detect)
        }
        windowChain.end()
        chainTarget = nil
    }

    /// The two-finger touch lifted (`onTouchEnd`).
    @MainActor
    private func touchEnded() {
        touchLive = false
        touchSpent = false
        heldTab = nil
        windowChain.touchEnded(now: ProcessInfo.processInfo.systemUptime)
        if windowChain.link == nil { chainTarget = nil }
    }

    /// The swipe or pinch on show rested (`onMotionReady`): Swish's haptic
    /// says the next movement starts another gesture.
    @MainActor
    private func motionReady() {
        // N335: only while the rest would commit something.
        guard active, target != nil || committing, hapticsOn,
              SwishSnap.motionReadyHaptic(planOnShow: target != nil && plan != nil,
                                          motionQueued: committing && chain.queue.last?.withdrawn == false) else { return }
        _ = GestureHaptics.shared.feedback(enabled: true)
    }

    // MARK: "Twice" gestures

    @MainActor
    private func schedulePending(_ waiting: Pending) {
        // An earlier action still waiting (on another app: on the same app
        // this gesture would have completed it) runs now instead of being lost.
        if pending != nil {
            pendingWork?.cancel()
            firePending()
        }
        pending = waiting
        armPending(after: Self.twiceWindow)
    }

    @MainActor
    private func armPending(after delay: Double) {
        pendingWork?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { TitleBarWindowSnap.shared.firePending() } }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// No second half came: the first half runs (it checks the pause again).
    @MainActor
    private func firePending() {
        pendingWork = nil
        guard let waiting = pending else { return }
        pending = nil
        if repeating == waiting.action { repeating = nil }
        perform(waiting.action, target: waiting.target, start: waiting.start)
    }

    @MainActor
    private func cancelPending() {
        pendingWork?.cancel(); pendingWork = nil
        pending = nil
    }

    // MARK: Window actions

    /// Runs a window action on the gesture's window (never one of AOM's own:
    /// `captureTitleBar` skips them). Each one asks the way the user would:
    /// the close button, the app's own Quit, the system's full screen.
    @MainActor
    private func perform(_ action: SwishSnap.WindowAction, target: WindowManager.Target, start: CGRect,
                         destination: CGRect = .null) {
        guard allowedNow, !Self.appPaused(target.pid) else { return }
        let app = NSRunningApplication(processIdentifier: target.pid)
        let title = SwishSnap.title(for: action, appName: app?.localizedName)
        GestureLog.shared.logFromAnyThread("Title-bar gesture: \(title)", level: .action)
        let report: (Bool) -> Void = { ok in
            if !ok { GestureLog.shared.logFromAnyThread("Title-bar gesture failed: \(title)", level: .error) }
        }
        switch action {
        case .minimize:
            guard Self.isFullscreen(target) else {
                WindowManager.shared.execute(.minimizeWindow, target: target, completion: report); return
            }
            // A full-screen window cannot be minimized: leave full screen first.
            leavingFullscreen(target, report) {
                WindowManager.shared.execute(.minimizeWindow, target: target, completion: report)
            }
        case .close:
            WindowManager.shared.execute(.closeWindow, target: target, completion: report)
        case .quitApp:
            // Never AOM itself, and never forced (the app may ask to save).
            guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { report(false); return }
            TrackpadUtilityGestures.politeQuit(app)
        case .forceQuitApp:
            // 3.4.12, the user's rule: two quick pinches in terminate the app,
            // even if it is asking to save. Never AOM, a system process or an
            // app AOM is paused for (`mayForceQuit`): those fall back to the
            // polite quit, so nothing is terminated by surprise.
            guard let app, Self.mayForceQuit(target) else {
                if let app, !Self.protectedApp(target.pid) { TrackpadUtilityGestures.politeQuit(app) }
                report(false)
                return
            }
            let worked = app.forceTerminate()
            GestureLog.shared.logFromAnyThread("Title-bar force quit\(worked ? "" : " refused"): \(title)", level: .action)
            report(worked)
        case .toggleFullscreen:
            WindowManager.shared.execute(.toggleFullscreenWindow, target: target, completion: report)
        case .hideApp:
            report(app?.hide() ?? false)
        case .hideOthers:
            hideOthers(keeping: target.pid, report)
        case .spaceLeft, .spaceRight:
            // Several held swipes in one touch: one Space move at a time.
            guard !spaceMoveInFlight else { queuedSpaceMove = (action, target, start); return }
            spaceMoveInFlight = true
            bringForward(target)
            let frame = WindowManager.shared.frame(of: target) ?? start
            ExtendedActions.moveWindowToSpace(next: action == .spaceRight, target: target,
                                              grab: spaceGrabPoint(target, frame: frame)) { ok in
                report(ok)
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.spaceMoveFinished() }
            }
        case .screen:
            moveFullscreenWindow(target, to: destination, report)
        case .fullscreenOnOtherScreen:
            fullscreenOnOtherDisplay(target, report)
        case .closeTab:
            guard let tab = targetTab else { report(false); return }
            let method = SwishTabs.close(tab: tab, window: target.window, pid: target.pid)
            GestureLog.shared.logFromAnyThread("Close tab: \(method)", level: method == .none ? .error : .action)
            report(method != .none)
        case .detachTab:
            // Detaching runs from `holdLifted`; a plan never carries it.
            report(false)
        }
    }

    /// The Space move in flight is done; the one waiting for it goes now
    /// (asking the pause again).
    @MainActor
    private func spaceMoveFinished() {
        spaceMoveInFlight = false
        guard let queued = queuedSpaceMove else { return }
        queuedSpaceMove = nil
        perform(queued.action, target: queued.target, start: queued.start)
    }

    /// Hide Others (⌥⌘H) for the window's app: every other regular app is
    /// hidden and the window's app stays in front. AOM is left alone.
    @MainActor
    private func hideOthers(keeping pid: pid_t, _ report: @escaping (Bool) -> Void) {
        let own = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        var refused: [String] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != pid && app.processIdentifier != own && !app.isHidden {
            if !app.hide() { refused.append(app.localizedName ?? "?") }
        }
        if !refused.isEmpty {
            GestureLog.shared.logFromAnyThread("Could not hide: \(refused.joined(separator: ", "))", level: .error)
        }
        report(refused.isEmpty)
    }

    /// Leaves native full screen, then runs `work` once the window is out of
    /// it (the animation takes about 0.8 s; a slow one gets up to 1.2 s more).
    @MainActor
    private func leavingFullscreen(_ target: WindowManager.Target, _ report: @escaping (Bool) -> Void,
                                   then work: @escaping @MainActor () -> Void) {
        guard Self.setFullscreen(false, target) else { report(false); return }
        func check(_ attempt: Int) {
            fullscreenTasks.run(after: attempt == 0 ? 0.8 : 0.4, gate: {
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.delayedStepAllowed(target) }
            }, work: {
                MainActor.assumeIsolated {
                    if Self.isFullscreen(target), attempt < 3 { check(attempt + 1); return }
                    work()
                }
            }, skipped: { report(false) })
        }
        check(0)
    }

    /// Asked when a delayed full-screen step comes due (S05: it ran even after
    /// AOM or the app was paused, the screen locked or the app quit).
    @MainActor
    private func delayedStepAllowed(_ target: WindowManager.Target) -> Bool {
        let app = NSRunningApplication(processIdentifier: target.pid)
        return SwishDelayedTasks.mayRun(allowed: allowedNow, appPaused: Self.appPaused(target.pid),
                                        screenLocked: ScreenLock.isLocked,
                                        appRunning: app.map { !$0.isTerminated } ?? false)
    }

    /// Enters full screen 0.3 s after a move landed, if the gate still allows it.
    @MainActor
    private func enterFullscreenLater(_ target: WindowManager.Target, _ report: @escaping (Bool) -> Void) {
        fullscreenTasks.run(after: 0.3, gate: {
            MainActor.assumeIsolated { TitleBarWindowSnap.shared.delayedStepAllowed(target) }
        }, work: {
            report(Self.setFullscreen(true, target))
        }, skipped: {
            GestureLog.shared.logFromAnyThread("Full screen skipped: paused, locked or the app quit", level: .detect)
            report(false)
        })
    }

    /// A full-screen window cannot be dragged to another display: it leaves
    /// full screen, moves to `destination`, and enters full screen there.
    @MainActor
    private func moveFullscreenWindow(_ target: WindowManager.Target, to destination: CGRect,
                                      _ report: @escaping (Bool) -> Void) {
        guard !destination.isNull else { report(false); return }
        leavingFullscreen(target, report) {
            WindowManager.shared.applySnap(destination, target: target, visible: nil) { actual in
                guard actual != nil else { report(false); return }
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.enterFullscreenLater(target, report) }
            }
        }
    }

    /// Swish's "pinch out twice" with two displays (or ⌘ pinch out): the
    /// window moves to the next display and enters full screen there,
    /// leaving full screen first if it is in it.
    @MainActor
    private func fullscreenOnOtherDisplay(_ target: WindowManager.Target, _ report: @escaping (Bool) -> Void) {
        let move: @MainActor () -> Void = {
            let screens = WindowManager.shared.screens()
            guard screens.count > 1, let frame = WindowManager.shared.frame(of: target),
                  let index = WindowGeometry.screenIndex(for: frame, screens: screens.map(\.frame)) else {
                report(false); return
            }
            let next = screens[(index + 1) % screens.count].visible
            WindowManager.shared.applySnap(WindowGeometry.moved(frame, into: next, maximize: false),
                                           target: target, visible: next) { actual in
                guard actual != nil else { report(false); return }
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.enterFullscreenLater(target, report) }
            }
        }
        if Self.isFullscreen(target) { leavingFullscreen(target, report, then: move) } else { move() }
    }

    /// Where to grab the window for a Space move: the pointer if it rests on
    /// the bare title bar or toolbar background (a control under it would be
    /// pressed instead of the window dragged), else the first such point
    /// along the title bar, else its middle as the Space action does.
    @MainActor
    private func spaceGrabPoint(_ target: WindowManager.Target, frame: CGRect) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let y = frame.minY + 10
        let candidates = [CGPoint(x: mouse.x, y: primaryTop - mouse.y), CGPoint(x: frame.midX, y: y),
                          CGPoint(x: frame.minX + 96, y: y), CGPoint(x: frame.maxX - 64, y: y)]
        return candidates.first { frame.contains($0) && Self.isDragHandle(at: $0, of: target) }
            ?? CGPoint(x: frame.midX, y: y)
    }

    /// Whether a mouse-down at `point` (top-left coordinates) lands on the
    /// window itself or its toolbar background, which drag the window. The
    /// window server must report the window's app on top there (a press
    /// lands on whatever is in front); the hit-test then goes to that app,
    /// bounded to 0.25 s (3.3.2 review: it asked the system-wide element with
    /// no limit, on main).
    @MainActor
    private static func isDragHandle(at point: CGPoint, of target: WindowManager.Target) -> Bool {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        guard DockLookup.windowUnder(CGPoint(x: point.x, y: top - point.y))?.pid == target.pid else { return false }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == target.pid else { return false }
        AXUIElementSetMessagingTimeout(hit, 0.25)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return false }
        if role == kAXWindowRole as String { return CFEqual(hit, target.window) }
        return role == kAXToolbarRole as String
    }

    private static func isFullscreen(_ target: WindowManager.Target) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(target.window, "AXFullScreen" as CFString, &value) == .success
            && (value as? Bool) == true
    }

    @discardableResult
    private static func setFullscreen(_ on: Bool, _ target: WindowManager.Target) -> Bool {
        AXUIElementSetAttributeValue(target.window, "AXFullScreen" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    @MainActor
    private func scheduleTimeout() {
        timeout?.cancel()
        let item = DispatchWorkItem {
            // A commit in flight owns the overlay until it lands.
            guard !TitleBarWindowSnap.shared.committing else { return }
            TitleBarWindowSnap.shared.abandonGesture()
        }
        timeout = item
        // A held stroke reports itself every 0.25 s (`stillHeld`), so this
        // watchdog only fires when contact frames stop arriving altogether
        // (a trackpad that vanished mid-gesture).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    /// Swish raises and activates the window it snapped; a background window
    /// would otherwise land in place but stay hidden behind others. Never
    /// while AOM is switched off or paused (whatever the input), or the
    /// window's app is (N333-06: it asked neither).
    @MainActor
    private func bringForward(_ target: WindowManager.Target) {
        guard SwishCommitLanding.mayBringForward(active: active, gateAllows: AutomationGate.allows(.system),
                                                 appPaused: Self.appPaused(target.pid)) else {
            GestureLog.shared.logFromAnyThread("Title-bar snap: no activation, AOM or the app is paused", level: .detect)
            return
        }
        _ = AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        guard target.pid != ProcessInfo.processInfo.processIdentifier else { return }
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
    }

    // MARK: Keyboard hotkeys (3.3.2, Swish's Advanced tab)

    /// From `KeyboardMonitor`'s event tap, AOM's global shortcut path (after
    /// explicit bindings and the clipboard and capture shortcuts): ⌃⌥ and one
    /// of the chosen keys swipes the front window that way. True consumes the
    /// key. Off, paused, AOM in front, or any other key: it goes on to the app.
    @MainActor
    func handleHotKey(keyCode: UInt16, modifiers flags: NSEvent.ModifierFlags, secureInput: Bool = false) -> Bool {
        // Secure input (a password field) or a paused keyboard: the key goes on.
        guard hotkeys != .off, !secureInput, hotkeyAllowedNow,
              let command = SwishSnap.hotkeyCommand(keyCode: keyCode, modifiers: flags, scheme: hotkeys,
                                                    center: Self.hotkeyCenter(), roles: .load(.standard)),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Self.appPaused(front.processIdentifier) else { return false }
        let pid = front.processIdentifier
        // The Accessibility work runs once the tap callback has returned.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { TitleBarWindowSnap.shared.hotkey(command, pid: pid) }
        }
        return true
    }

    /// The center key of the ⌃⌥ hotkeys (Swish's "Center: Esc | ⌫ | ↩"), a
    /// `SwishSnap.HotkeyCenterKey` raw value: "escape" (default),
    /// "backspace", "return" or "off". Only while the hotkeys are on.
    static let hotkeyCenterKey = "AOMTitleBarSnapHotkeyCenter"

    static func hotkeyCenter(_ defaults: UserDefaults = .standard) -> SwishSnap.HotkeyCenterKey {
        defaults.string(forKey: hotkeyCenterKey).flatMap(SwishSnap.HotkeyCenterKey.init(rawValue:)) ?? .escape
    }

    /// The commit in flight came from a hotkey: the pointer stays where it is.
    @MainActor private var keyboardCommit = false

    /// A hotkey press is a gesture on the front window: the same chaining
    /// from its place, the same commit (`WindowManager.applySnap`) and the
    /// same history as a title-bar swipe. ⌃⌥ belong to the chord, so the
    /// gesture's roles are the ones the command names: none for a plain
    /// swipe, Screen (move to the display that way), Secondary (3 × 2 grid,
    /// up almost-maximizes); the center key restores or centres.
    @MainActor
    private func hotkey(_ command: SwishSnap.HotkeyCommand, pid: pid_t) {
        guard hotkeyAllowedNow, !committing, target == nil, pid != ProcessInfo.processInfo.processIdentifier,
              !Self.appPaused(pid),
              let window = Self.focusedWindow(of: pid), let frame = Self.boundedFrame(of: window) else { return }
        let roles: Set<SwishSnap.ModifierRole>
        let direction: SwishSnap.Direction?
        switch command {
        case .swipe(let way): roles = []; direction = way
        case .screen(let way): roles = [.screen]; direction = way
        case .secondary(let way): roles = [.secondary]; direction = way
        case .center: roles = []; direction = nil
        }
        let capture = Capture(mouse: NSEvent.mouseLocation, window: window, frame: frame,
                              at: ProcessInfo.processInfo.systemUptime)
        // `adopt` asks whether the window is in full screen: bounded too.
        AXUIElementSetMessagingTimeout(window.window, 0.25)
        let adopted = adopt(capture, roles: roles)
        AXUIElementSetMessagingTimeout(window.window, 0)
        guard adopted, let visible = targetVisible else { reset(); return }
        // A key never completes a half-done "twice" gesture.
        repeating = nil
        let next: Plan?
        if let direction {
            next = plan(for: SwishSnap.Stroke(direction), target: window, visible: visible, start: frame)
            GestureLog.shared.logFromAnyThread("Snap hotkey \(SwishSnap.arrow(direction))", level: .detect)
        } else {
            // Swish: "Press the center key to center & unsnap."
            next = restorePlan(target: window, visible: visible, start: frame)
            GestureLog.shared.logFromAnyThread("Snap hotkey: center", level: .detect)
        }
        guard let next else { reset(); return }
        plan = next
        if let action = next.action {
            run(action, plan: next, target: window, start: frame)
            return
        }
        keyboardCommit = true
        commitFrame(next.rect, target: window, anchorVisible: visible, start: frame,
                    restoring: next.place == nil, place: next.place)
    }

    /// The app's focused window, asked with a bounded wait.
    private static func focusedWindow(of pid: pid_t) -> WindowManager.Target? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return WindowManager.Target(window: value as! AXUIElement, pid: pid)
    }

    /// A window's frame with a bounded wait (a busy app answers late or not at
    /// all); the element goes back to the default timeout for the commit's writes.
    private static func boundedFrame(of target: WindowManager.Target, timeout: Float = 0.25) -> CGRect? {
        AXUIElementSetMessagingTimeout(target.window, timeout)
        defer { AXUIElementSetMessagingTimeout(target.window, 0) }
        return WindowManager.shared.frame(of: target)
    }

    /// Minimized and full-screen windows are left where macOS keeps them.
    private static func isMinimizedOrFullscreen(_ target: WindowManager.Target) -> Bool {
        AXUIElementSetMessagingTimeout(target.window, 0.25)
        defer { AXUIElementSetMessagingTimeout(target.window, 0) }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(target.window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true { return true }
        return isFullscreen(target)
    }

    // MARK: Drag to unsnap and resizing adjacent windows (3.3.2)

    /// A global left-button monitor (like `CustomSnapZoneMonitor`), present
    /// only while the history holds windows and one of the two options is on.
    /// Global monitors never see AOM's own windows.
    @MainActor
    private func updateMouseMonitor() {
        let wanted = active && !PresetManager.isRunningTests && !PresetManager.isUIPreview
            && !history.entries.isEmpty && (Self.dragUnsnapOn() || Self.resizeAdjacentOn())
        if wanted, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
                // Global monitors call back on the main thread.
                let type = event.type
                MainActor.assumeIsolated { TitleBarWindowSnap.shared.mouseEvent(type) }
            }
        } else if !wanted, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
            drag = nil
        }
    }

    /// Down: note the snapped windows sharing an edge near the pointer. First
    /// drag: the one hit-test, for a snapped window's title bar. Later drags:
    /// once that window really moves, give it its old size under the pointer.
    /// Up: let neighbours follow a resized edge.
    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType) {
        guard !history.entries.isEmpty else { drag = nil; return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: primaryTop - mouse.y)
        switch type {
        case .leftMouseDown:
            drag = nil
            guard mouseAllowedNow, !committing else { return }
            var state = DragState(down: point)
            if Self.resizeAdjacentOn() { state.neighbours = neighbourFrames(near: point) }
            drag = state
        case .leftMouseDragged:
            guard var state = drag else { return }
            if !state.probed {
                state.probed = true
                // Swish: "Use the secondary modifier to temporarily disable Drag to Unsnap."
                if SwishSnap.dragUnsnapApplies(enabled: Self.dragUnsnapOn(), held: SwishSnap.heldRoles()), mouseAllowedNow {
                    state.unsnap = unsnapCandidate(at: state.down, pointer: point)
                }
            }
            if let candidate = state.unsnap {
                let now = ProcessInfo.processInfo.systemUptime
                if now - state.lastProbe >= 0.05 {
                    state.lastProbe = now
                    let frame = Self.boundedFrame(of: candidate.target)
                    if let frame, WindowGeometry.windowActuallyMoved(from: candidate.snapped, to: frame) {
                        state.unsnap = nil
                        unsnapDrag(candidate, grab: state.down, pointer: point)
                    } else if frame.map({ abs($0.width - candidate.snapped.width) > 4
                                            || abs($0.height - candidate.snapped.height) > 4 }) ?? true {
                        // Resized (its top edge sits in the title-bar band) or gone: no unsnap.
                        state.unsnap = nil
                    }
                }
            }
            drag = state
        case .leftMouseUp:
            let state = drag
            drag = nil
            guard let state, state.probed, state.neighbours.count >= 2, mouseAllowedNow, !committing else { return }
            followResize(from: state.neighbours)
        default:
            break
        }
    }

    /// The snapped window whose title bar the drag started on, while it still
    /// sits where it was snapped (it may already have followed the pointer a
    /// few points, at its snapped size) and has a frame from before to go back to.
    @MainActor
    private func unsnapCandidate(at down: CGPoint, pointer: CGPoint) -> DragState.Unsnap? {
        let mouse = CGPoint(x: down.x, y: primaryTop - down.y)
        // The window server names the window's owner; the hit-test goes to
        // that app, bounded (3.3.2 review), as for the title-bar swipe.
        guard let under = DockLookup.windowUnder(mouse), under.layer == 0,
              under.pid != ProcessInfo.processInfo.processIdentifier,
              let hit = WindowManager.shared.titleBarTarget(atMousePoint: mouse, pid: under.pid),
              hit.target.pid != ProcessInfo.processInfo.processIdentifier, mayWriteBackground(hit.target) else { return nil }
        let key = Self.key(hit.target)
        guard let entry = history.entries[key], entry.place != nil,
              !WindowGeometry.close(entry.original, entry.snapped),
              let frame = Self.boundedFrame(of: hit.target),
              abs(frame.width - entry.snapped.width) <= 3, abs(frame.height - entry.snapped.height) <= 3,
              hypot(frame.minX - entry.snapped.minX, frame.minY - entry.snapped.minY)
                <= hypot(pointer.x - down.x, pointer.y - down.y) + 4,
              hit.onTitleBar || SwishSnap.titleBarHit(pointerTopLeft: down, windowFrame: entry.snapped),
              down.y >= entry.snapped.minY, down.y - entry.snapped.minY <= SwishSnap.toolbarBand else { return nil }
        return DragState.Unsnap(target: hit.target, key: key, snapped: entry.snapped, original: entry.original)
    }

    /// Swish and Windows: the dragged window gets its pre-snap size under the
    /// pointer, which keeps its place along the title bar; the window is no
    /// longer snapped, so its history entry goes.
    @MainActor
    private func unsnapDrag(_ candidate: DragState.Unsnap, grab: CGPoint, pointer: CGPoint) {
        let frame = SwishSnap.unsnapDragFrame(snapped: candidate.snapped, original: candidate.original.size,
                                              grab: grab, pointer: pointer)
        // Asked again right before the write (S03).
        guard mouseAllowedNow, mayWriteBackground(candidate.target) else { return }
        AXUIElementSetMessagingTimeout(candidate.target.window, 0.25)
        let resized = WindowManager.shared.setFrame(frame, of: candidate.target)
        AXUIElementSetMessagingTimeout(candidate.target.window, 0)
        history.forget(key: candidate.key)
        snapTargets.removeValue(forKey: candidate.key)
        // Not from inside the monitor's own callback.
        DispatchQueue.main.async { MainActor.assumeIsolated { TitleBarWindowSnap.shared.updateMouseMonitor() } }
        GestureLog.shared.logFromAnyThread(resized ? "Drag to unsnap: the window is back to its size from before the snap"
                                                   : "Drag to unsnap: the window refused its earlier size",
                                           level: resized ? .action : .error)
    }

    /// The snapped windows sharing an edge near the button going down, read
    /// now: at least two still where they were snapped, or none.
    @MainActor
    private func neighbourFrames(near point: CGPoint) -> [String: CGRect] {
        guard history.entries.count >= 2 else { return [:] }
        let snapped = history.entries.compactMapValues { $0.place != nil ? $0.snapped : nil }
        let keys = SwishSnap.edgeCandidates(at: point, frames: snapped, tolerance: Self.adjacencyTolerance(margin: margin))
        guard keys.count >= 2 else { return [:] }
        var frames: [String: CGRect] = [:]
        for key in keys {
            guard let target = snapTargets[key], let recorded = snapped[key], mayWriteBackground(target),
                  let frame = Self.boundedFrame(of: target), WindowGeometry.close(frame, recorded) else { continue }
            frames[key] = frame
        }
        return frames.count >= 2 ? frames : [:]
    }

    /// Swish's "Drag the divider to resize multiple windows at once", in one
    /// pass on mouse-up: if one of the windows was resized along an edge it
    /// shared with the others, they follow it. All of them stay snapped.
    @MainActor
    private func followResize(from before: [String: CGRect]) {
        var after: [String: CGRect] = [:]
        for key in before.keys {
            if let target = snapTargets[key], let frame = Self.boundedFrame(of: target) { after[key] = frame }
        }
        let moves = SwishSnap.adjacentMoves(before: before, after: after,
                                            tolerance: Self.adjacencyTolerance(margin: margin))
        guard !moves.isEmpty else { return }
        for (key, frame) in after where moves[key] == nil {
            if let old = before[key], !WindowGeometry.close(old, frame) { history.moveSnapped(key: key, to: frame) }
        }
        GestureLog.shared.logFromAnyThread("Resize adjacent: \(moves.count) window(s) follow the shared edge", level: .action)
        let screens = WindowManager.shared.screens()
        let writes: [(key: String, target: WindowManager.Target, frame: CGRect, anchor: CGRect?)] = moves.compactMap { key, frame in
            guard let target = snapTargets[key] else { return nil }
            let anchor = WindowGeometry.screenIndex(for: frame, screens: screens.map(\.frame)).map { index -> CGRect in
                let area = Self.snapArea(screens[index].visible)
                return margin > 0 ? area.insetBy(dx: margin, dy: margin) : area
            }
            return (key, target, frame, anchor)
        }
        // One at a time, the pause asked again right before each write (S03).
        SwishGatedBatch.run(writes.sorted { $0.key < $1.key }[...], mayWrite: { write in
            MainActor.assumeIsolated {
                let service = TitleBarWindowSnap.shared
                return service.mouseAllowedNow && service.mayWriteBackground(write.target)
            }
        }, apply: { write, done in
            MainActor.assumeIsolated {
                WindowManager.shared.applySnap(write.frame, target: write.target, visible: write.anchor) { actual in
                    MainActor.assumeIsolated {
                        if let actual { TitleBarWindowSnap.shared.history.moveSnapped(key: write.key, to: actual) }
                        done()
                    }
                }
            }
        })
    }

    // MARK: Re-snapping after display changes (3.3.2)

    /// The displays are about to change (the reconfiguration callback's begin
    /// flag, before macOS moves windows off a display that goes away): note
    /// which snapped windows still sit where they were snapped.
    @MainActor
    fileprivate func displaysWillChange() {
        guard resnapKeys == nil, active, Self.resnapOn(), !history.entries.isEmpty else { return }
        resnapKeys = snappedInPlace()
        scheduleResnap()
    }

    /// The displays changed (also the Dock or a resolution change, which may
    /// not pass through the reconfiguration callback): re-snap once settled.
    @MainActor
    private func displaysChanged() {
        guard active, Self.resnapOn(), !history.entries.isEmpty else { resnapKeys = nil; return }
        if resnapKeys == nil { resnapKeys = snappedInPlace() }
        scheduleResnap()
    }

    @MainActor
    private func scheduleResnap() {
        resnapWork?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { TitleBarWindowSnap.shared.resnap() } }
        resnapWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, Self.resnapDelaySeconds()), execute: item)
    }

    /// The history windows still at the frame AOM snapped them to: bounded
    /// reads, and no more than half a second in all (hung apps are skipped).
    @MainActor
    private func snappedInPlace() -> Set<String> {
        var keys = Set<String>()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        for (key, entry) in history.entries where entry.place != nil {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard let target = snapTargets[key], let frame = Self.boundedFrame(of: target, timeout: 0.15),
                  WindowGeometry.close(frame, entry.snapped) else { continue }
            keys.insert(key)
        }
        return keys
    }

    private struct Resnap {
        let key: String
        let target: WindowManager.Target
        let frame: CGRect
        let anchor: CGRect
    }

    /// Swish's "Resnapping after …": each window still snapped when the
    /// displays changed gets its place again on the display it is on now.
    @MainActor
    private func resnap() {
        resnapWork = nil
        let keys = resnapKeys ?? []
        resnapKeys = nil
        guard !keys.isEmpty, Self.resnapOn(), resnapAllowedNow else { return }
        let screens = WindowManager.shared.screens()
        let frames = screens.map(\.frame)
        let areas = screens.map { Self.snapArea($0.visible) }
        var moves: [Resnap] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        for key in keys.sorted() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard let place = history.entries[key]?.place, let target = snapTargets[key],
                  mayWriteBackground(target),
                  !Self.isMinimizedOrFullscreen(target),
                  let current = Self.boundedFrame(of: target),
                  let frame = SwishSnap.resnapFrame(place: place, current: current, screens: frames, areas: areas,
                                                    margin: margin),
                  let index = WindowGeometry.screenIndex(for: frame, screens: frames) else { continue }
            let anchor = margin > 0 ? areas[index].insetBy(dx: margin, dy: margin) : areas[index]
            moves.append(Resnap(key: key, target: target, frame: frame, anchor: anchor))
        }
        guard !moves.isEmpty else { return }
        GestureLog.shared.logFromAnyThread("Resnapping after display change: \(moves.count) window(s)", level: .action)
        applyResnaps(moves[...])
    }

    /// One window at a time, each once the last has landed; right before each
    /// write the pause, AOM's own and the window's app's, is asked again (S03).
    @MainActor
    private func applyResnaps(_ moves: ArraySlice<Resnap>) {
        SwishGatedBatch.run(moves, mayWrite: { move in
            MainActor.assumeIsolated {
                let service = TitleBarWindowSnap.shared
                return service.resnapAllowedNow && service.mayWriteBackground(move.target)
            }
        }, apply: { move, done in
            MainActor.assumeIsolated {
                WindowManager.shared.applySnap(move.frame, target: move.target, visible: move.anchor) { actual in
                    MainActor.assumeIsolated {
                        if let actual { TitleBarWindowSnap.shared.history.moveSnapped(key: move.key, to: actual) }
                        done()
                    }
                }
            }
        }, finished: { written in
            if written < moves.count {
                GestureLog.shared.logFromAnyThread("Resnapping: \(moves.count - written) window(s) skipped (paused)",
                                                   level: .detect)
            }
        })
    }

    /// Whether AOM may write to a window it is not gesturing on (re-snapping,
    /// resizing a neighbour, drag to unsnap): never one of AOM's own, never
    /// one of an app paused in AOM (S03: these used the frontmost app's pause).
    @MainActor
    private func mayWriteBackground(_ target: WindowManager.Target) -> Bool {
        SwishSnap.mayWriteBackground(ownApp: target.pid == ProcessInfo.processInfo.processIdentifier,
                                     appPaused: Self.appPaused(target.pid))
    }

    /// The pause rules for the other inputs: hotkeys answer to keyboard
    /// pauses, the mouse handlers to pointer ones, re-snapping to a paused AOM.
    @MainActor private var hotkeyAllowedNow: Bool {
        Self.mayMoveWindow(active: active, gateAllows: AutomationGate.allows(.keyboard))
    }
    @MainActor private var mouseAllowedNow: Bool {
        Self.mayMoveWindow(active: active, gateAllows: AutomationGate.allows(.mouse))
    }
    @MainActor private var resnapAllowedNow: Bool {
        Self.mayMoveWindow(active: active, gateAllows: AutomationGate.allows(.system))
    }

    @MainActor private static func key(_ target: WindowManager.Target) -> String {
        "\(target.pid):\(CFHash(target.window))"
    }

    /// The per-app pause for the app that owns a window (main thread).
    @MainActor private static func appPaused(_ pid: pid_t) -> Bool {
        TriggerSuppression.shared.isPaused(forApp: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }

    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    @MainActor private var hapticsOn: Bool { Self.flag(Self.hapticKey, default: true) }

    @MainActor private var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    @MainActor
    private var margin: CGFloat { Self.margin() }
}

/// `CGDisplayRegisterReconfigurationCallback` for re-snapping: the begin flag
/// arrives before macOS rearranges windows.
private let aomSnapDisplaysReconfiguring: CGDisplayReconfigurationCallBack = { _, flags, _ in
    guard flags.contains(.beginConfigurationFlag) else { return }
    if Thread.isMainThread {
        MainActor.assumeIsolated { TitleBarWindowSnap.shared.displaysWillChange() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { TitleBarWindowSnap.shared.displaysWillChange() } }
    }
}
