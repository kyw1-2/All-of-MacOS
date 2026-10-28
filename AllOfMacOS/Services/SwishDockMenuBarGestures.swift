import AppKit
import ApplicationServices

// Swish's two-finger Dock and menu-bar gestures (Swish 1.13 help strings).
// AOM's own implementation; `TrackpadUtilityGestures` feeds the recognizer and
// runs the actions through `GestureDesktop`.
//
// Dock, pointer over an app's icon:
// - tap and hold, then lift: activate the app and raise its front window;
// - swipe left / right: activate it and step through its windows (chains);
// - swipe down: minimize the front window (⇧ Shift: all of them);
// - swipe up: unminimize the window AOM minimized last, else one the app has
//   (⇧: all of them);
// - double tap: hide the app (⇧: hide the other apps);
// - pinch out: activate it and send ⌘N; pinch in: ask it to quit.
// Menu bar, pointer in the top band:
// - swipe left / right: Spaces (unchanged); after tap and hold: the
//   previous / next app;
// - tap and hold, then lift (or scroll): the window switcher;
// - double tap: unsnap the windows the title-bar snap placed on this screen
//   (⇧: every screen);
// - swipe down: minimize this screen's windows (twice or ⇧: every screen);
// - swipe up: unminimize what that minimized, newest batch first (twice or ⇧:
//   every screen);
// - ⌘ Command + swipe: move this screen's snapped windows to the display that
//   way, keeping their cells.

// MARK: - Recognition (pure, unit-tested)

/// One two-finger touch at a time, classified into Swish's utility gestures:
/// taps and double taps, tap and hold (and lifting after it), swipes that
/// chain within the touch, pinches, and the hold-still cancel.
///
/// Pure value type: fed contact frames it returns at most one event per
/// frame. Positions are TouchPoint's pad units (0…1, y growing toward the top
/// of the pad, as `LiveTouchView` and the gesture engine read them), so a
/// swipe with dy > 0 is a swipe up. No clocks, no AppKit, no allocation per
/// frame.
struct UtilityGestureRecognizer {
    enum Direction: Equatable {
        case left, right, up, down
        var isHorizontal: Bool { self == .left || self == .right }
    }

    enum Event: Equatable {
        /// Two fingers lifted within `tapTime` without travelling `tapTravel`.
        case tap
        /// A tap whose lift came within `doubleTapWindow` of the previous tap's.
        case doubleTap
        /// The fingers rested `holdTime` before swiping or pinching.
        case holdBegan
        /// They lifted after a tap and hold without swiping, pinching or moving.
        case holdReleased
        /// The fingers travelled `swipeDistance` along one axis since the touch
        /// landed or since the last swipe. `chain` counts the swipes of this
        /// touch (1 for the first); `held`: the touch rested first.
        case swipe(Direction, held: Bool, chain: Int)
        /// The finger spread fell below `pinchInRatio` or grew past
        /// `pinchOutRatio` of its touch-down value, before any swipe. A touch
        /// pinches once.
        case pinchIn(held: Bool)
        case pinchOut(held: Bool)
        /// The fingers rested `holdCancel` seconds without moving: nothing this
        /// touch does acts any more until they lift (Swish's hold-still cancel).
        case holdCancelled
    }

    struct Tuning: Equatable {
        var tapTime: Double = 0.18
        var tapTravel: Float = 0.065
        var doubleTapWindow: Double = 0.35
        var holdTime: Double = 0.45
        /// Swish's hold-still cancel in seconds; 0 turns it off.
        var holdCancel: Double = 2
        /// With the cancel off, a rest this long is no tap and hold any more:
        /// a later swipe is a plain one again.
        var holdLapse: Double = 2
        var swipeDistance: Float = 0.10
        var swipeRatio: Float = 1.6
        /// The shortest time between two swipes of one touch.
        var chainInterval: Double = 0.15
        var pinchInRatio: Float = 0.62
        var pinchInMinSpread: Float = 0.08
        var pinchOutRatio: Float = 1.38
        var pinchOutMinSpread: Float = 0.05
        /// How far (pad units) resting fingers may wander and still be still:
        /// 0.018, as on a title bar (3.3.2 review: 0.012, about 1.2–1.9 mm,
        /// let a resting hand's drift restart the 2 s clock).
        var stillRadius: Float = 0.018
    }

    var tuning = Tuning()

    /// Two fingers are down (a touch is being followed).
    private(set) var isTouching = false
    /// The touch rested `holdTime` before swiping or pinching.
    private(set) var isHeld = false
    /// The hold-still cancel spent the touch.
    private(set) var isSpent = false
    /// Swipes recognised in this touch.
    private(set) var swipes = 0
    private(set) var hasPinched = false

    /// A third finger joined: no tap, double tap or hold release.
    private var tainted = false
    private var startedAt: Double = 0
    private var startX: Float = 0, startY: Float = 0, startSpread: Float = 0
    private var anchorX: Float = 0, anchorY: Float = 0
    private var maxTravel: Float = 0
    private var holdX: Float = 0, holdY: Float = 0
    private var travelSinceHold: Float = 0
    private var stillX: Float = 0, stillY: Float = 0, stillSpread: Float = 0
    private var stillSince: Double = 0
    /// The still period a lapsed hold belonged to; a new hold needs movement first.
    private var lapsedStillSince: Double?
    private var lastSwipeAt: Double = 0
    private var lastTapAt: Double?

    /// Feeds one contact frame of the touch's trackpad. Two contacts track
    /// the touch, a third taints it (it keeps going, as the Space swipe did),
    /// four or more end it silently, and none or one lift it.
    mutating func feed(_ contacts: [TouchPoint], at timestamp: Double) -> Event? {
        switch contacts.count {
        case 2: return track(contacts, at: timestamp)
        case 3:
            if isTouching { tainted = true }
            return nil
        case 0, 1: return lift(at: timestamp)
        default:
            endTouch()
            lastTapAt = nil
            return nil
        }
    }

    /// Forgets the touch and any tap waiting for its second half.
    mutating func reset() {
        endTouch()
        lastTapAt = nil
    }

    private mutating func track(_ contacts: [TouchPoint], at t: Double) -> Event? {
        let x = (contacts[0].x + contacts[1].x) / 2
        let y = (contacts[0].y + contacts[1].y) / 2
        let sx = contacts[0].x - contacts[1].x, sy = contacts[0].y - contacts[1].y
        let spread = (sx * sx + sy * sy).squareRoot()
        guard isTouching else {
            begin(x, y, spread, at: t)
            return nil
        }
        let travel = Self.distance(x - startX, y - startY)
        maxTravel = max(maxTravel, travel)
        if isHeld { travelSinceHold = max(travelSinceHold, Self.distance(x - holdX, y - holdY)) }
        if Self.distance(x - stillX, y - stillY) > tuning.stillRadius || abs(spread - stillSpread) > tuning.stillRadius {
            (stillX, stillY, stillSpread) = (x, y, spread)
            stillSince = t
        }
        guard !isSpent else { return nil }
        let rested = t - stillSince
        if tuning.holdCancel > 0, rested >= tuning.holdCancel {
            isSpent = true
            isHeld = false
            return .holdCancelled
        }
        if isHeld, swipes == 0, !hasPinched, tuning.holdCancel <= 0, rested >= tuning.holdLapse {
            isHeld = false
            lapsedStillSince = stillSince
        }
        if !hasPinched, swipes == 0, let pinch = pinchEvent(spread: spread, travel: travel) {
            hasPinched = true
            return pinch
        }
        if !hasPinched, let swipe = swipeEvent(x, y, at: t) { return swipe }
        if !isHeld, !tainted, swipes == 0, !hasPinched, tuning.holdTime > 0, rested >= tuning.holdTime,
           lapsedStillSince != stillSince {
            isHeld = true
            (holdX, holdY) = (x, y)
            travelSinceHold = 0
            return .holdBegan
        }
        return nil
    }

    private mutating func begin(_ x: Float, _ y: Float, _ spread: Float, at t: Double) {
        isTouching = true
        isHeld = false
        isSpent = false
        swipes = 0
        hasPinched = false
        tainted = false
        startedAt = t
        (startX, startY, startSpread) = (x, y, spread)
        (anchorX, anchorY) = (x, y)
        (stillX, stillY, stillSpread) = (x, y, spread)
        stillSince = t
        lapsedStillSince = nil
        maxTravel = 0
        travelSinceHold = 0
        lastSwipeAt = t
    }

    private mutating func lift(at t: Double) -> Event? {
        guard isTouching else { return nil }
        defer { endTouch() }
        guard !isSpent, !tainted, !hasPinched, swipes == 0 else { lastTapAt = nil; return nil }
        if isHeld {
            lastTapAt = nil
            return travelSinceHold < tuning.tapTravel ? .holdReleased : nil
        }
        guard t - startedAt < tuning.tapTime, maxTravel < tuning.tapTravel else { lastTapAt = nil; return nil }
        if let last = lastTapAt, t >= last, t - last <= tuning.doubleTapWindow {
            lastTapAt = nil
            return .doubleTap
        }
        lastTapAt = t
        return .tap
    }

    private mutating func endTouch() {
        isTouching = false
        isHeld = false
        isSpent = false
        swipes = 0
        hasPinched = false
        tainted = false
    }

    private func pinchEvent(spread: Float, travel: Float) -> Event? {
        guard startSpread > 0 else { return nil }
        let ratio = spread / startSpread
        if startSpread > tuning.pinchInMinSpread, ratio < tuning.pinchInRatio { return .pinchIn(held: isHeld) }
        // Spreading apart while the centroid stays put: a swipe moves the
        // centroid, a pinch mostly changes the spread.
        if startSpread > tuning.pinchOutMinSpread, ratio >= tuning.pinchOutRatio, spread - startSpread > travel {
            return .pinchOut(held: isHeld)
        }
        return nil
    }

    private mutating func swipeEvent(_ x: Float, _ y: Float, at t: Double) -> Event? {
        let dx = x - anchorX, dy = y - anchorY
        let ax = abs(dx), ay = abs(dy)
        let direction: Direction
        if ax >= tuning.swipeDistance, ax >= ay * tuning.swipeRatio {
            direction = dx < 0 ? .left : .right
        } else if ay >= tuning.swipeDistance, ay >= ax * tuning.swipeRatio {
            direction = dy > 0 ? .up : .down
        } else {
            return nil
        }
        // A clock that went backwards is not a recent swipe.
        let since = t - lastSwipeAt
        guard swipes == 0 || since >= tuning.chainInterval || since < 0 else { return nil }
        (anchorX, anchorY) = (x, y)
        swipes += 1
        lastSwipeAt = t
        return .swipe(direction, held: isHeld, chain: swipes)
    }

    private static func distance(_ dx: Float, _ dy: Float) -> Float { (dx * dx + dy * dy).squareRoot() }
}

// MARK: - Dock items (pure matching)

/// Which running app a Dock icon stands for. The Dock's Accessibility element
/// carries the app's bundle URL (`AXURL`) and its title; the URL, then the
/// bundle identifier read from it, decide, and only then the name (3.3.2:
/// matching by name alone picked the wrong app when two had the same name, and
/// missed apps whose Dock title differs from their process name).
enum DockItemMatcher {
    struct Item: Equatable {
        var title: String?
        var url: URL?
        /// `AXApplicationDockItem`, `AXFolderDockItem`, `AXTrashDockItem`, …;
        /// nil when the Dock did not say.
        var subrole: String?

        var representsApplication: Bool { subrole == nil || subrole == "AXApplicationDockItem" }
    }

    struct Candidate: Equatable {
        let pid: pid_t
        let name: String?
        let bundleID: String?
        let bundleURL: URL?
        /// A regular, still running app (the Dock shows nothing else as a tile).
        let isRegular: Bool
    }

    /// The matching app's process, or nil. `bundleID` reads the identifier
    /// from the item's bundle and is only asked when the URL did not match.
    static func match(_ item: Item, in candidates: [Candidate], bundleID: () -> String?) -> pid_t? {
        guard item.representsApplication else { return nil }
        let apps = candidates.filter(\.isRegular)
        if let url = item.url.map(path) {
            if let hit = apps.first(where: { $0.bundleURL.map(path) == url }) { return hit.pid }
            // A bundle seen through a different path (Safari's cryptex, a
            // translocated download) still has the same identifier.
            if let identifier = bundleID()?.lowercased(), !identifier.isEmpty,
               let hit = apps.first(where: { $0.bundleID?.lowercased() == identifier }) { return hit.pid }
        }
        guard let title = item.title, !title.isEmpty else { return nil }
        return apps.first { $0.name == title }?.pid
    }

    /// A comparable form of a bundle path: standardised, without a trailing
    /// slash and case-folded (the default APFS volume ignores case).
    static func path(_ url: URL) -> String {
        var text = url.standardizedFileURL.path.lowercased()
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

// MARK: - Windows AOM minimized (pure)

/// A window as these gestures see it. `id` is stable for the window's life:
/// `pid:CFHash(element)`, the key the title-bar snap uses for its history.
struct GestureWindow: Equatable {
    let id: String
    let pid: pid_t
    /// The Accessibility window; nil for test doubles.
    let element: AXUIElement?

    init(id: String, pid: pid_t, element: AXUIElement? = nil) {
        self.id = id
        self.pid = pid
        self.element = element
    }

    init(element: AXUIElement, pid: pid_t) {
        self.init(id: "\(pid):\(CFHash(element))", pid: pid, element: element)
    }

    static func == (lhs: GestureWindow, rhs: GestureWindow) -> Bool { lhs.id == rhs.id }
}

/// The windows AOM minimized from the Dock or the menu bar, newest first, so
/// a swipe up brings back the last one (Swish: "unminimize and chain the last
/// window"). A menu-bar swipe down records one batch; the menu-bar swipe up
/// restores the newest batch first.
struct MinimizedWindowStack {
    enum Source: Equatable { case dock, menuBar }

    struct Entry: Equatable {
        let window: GestureWindow
        /// The display it was on (its Accessibility frame), for the menu
        /// bar's "once for the current screen".
        let screen: CGRect?
        let batch: Int
        let source: Source
    }

    private(set) var entries: [Entry] = []
    private var batches = 0
    var capacity = 256

    /// Records windows just minimized together. A window minimized again
    /// moves to the front; the last of a batch is the newest.
    mutating func push(_ windows: [(window: GestureWindow, screen: CGRect?)], source: Source) {
        guard !windows.isEmpty else { return }
        batches += 1
        let ids = Set(windows.map(\.window.id))
        entries.removeAll { ids.contains($0.window.id) }
        let batch = batches
        entries.insert(contentsOf: windows.reversed().map {
            Entry(window: $0.window, screen: $0.screen, batch: batch, source: source)
        }, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    /// The newest window of `pid` that is still minimized, taken off the
    /// stack. Entries of that app restored some other way are dropped.
    mutating func takeNewest(of pid: pid_t, isMinimized: (GestureWindow) -> Bool) -> GestureWindow? {
        while let index = entries.firstIndex(where: { $0.window.pid == pid }) {
            let entry = entries.remove(at: index)
            if isMinimized(entry.window) { return entry.window }
        }
        return nil
    }

    /// Every window of `pid` still minimized, newest first, taken off the stack.
    mutating func takeAll(of pid: pid_t, isMinimized: (GestureWindow) -> Bool) -> [GestureWindow] {
        let mine = entries.filter { $0.window.pid == pid }
        entries.removeAll { $0.window.pid == pid }
        return mine.map(\.window).filter(isMinimized)
    }

    /// The menu bar's swipe up: the newest menu-bar batch that still has a
    /// minimized window on `screen` (nil: on any screen), those windows only,
    /// taken off the stack. Batches the user restored another way are skipped.
    mutating func takeMenuBarBatch(on screen: CGRect?, isMinimized: (GestureWindow) -> Bool) -> [GestureWindow] {
        func here(_ entry: Entry) -> Bool { entry.source == .menuBar && (screen == nil || entry.screen == screen) }
        while let batch = entries.first(where: here)?.batch {
            let chosen = entries.filter { here($0) && $0.batch == batch }
            entries.removeAll { here($0) && $0.batch == batch }
            let windows = chosen.map(\.window).filter(isMinimized)
            if !windows.isEmpty { return windows }
        }
        return []
    }

    mutating func forget(_ window: GestureWindow) {
        entries.removeAll { $0.window == window }
    }
}

/// The app order the menu bar's tap-and-hold swipe walks: the frontmost app,
/// then the ones used before it (AppActivationHistory), then every other
/// regular app in NSWorkspace (launch) order. Left is the previous app (used
/// before this one), right the next (from the far end), wrapping.
struct AppCycle: Equatable {
    let order: [pid_t]
    /// Where the walk stands; nil while the frontmost app is not in `order`.
    private(set) var index: Int?

    init(frontmost: pid_t?, recent: [pid_t], running: [pid_t]) {
        let live = Set(running)
        var seen = Set<pid_t>()
        var order: [pid_t] = []
        for pid in [frontmost].compactMap({ $0 }) + recent + running where live.contains(pid) && seen.insert(pid).inserted {
            order.append(pid)
        }
        self.order = order
        index = frontmost.flatMap { order.firstIndex(of: $0) }
    }

    mutating func step(previous: Bool) -> pid_t? {
        guard !order.isEmpty else { return nil }
        let next: Int
        if let index {
            next = ((index + (previous ? 1 : -1)) % order.count + order.count) % order.count
        } else {
            next = previous ? 0 : order.count - 1
        }
        index = next
        return order[next]
    }
}

/// Steps through one app's windows within a touch (the Dock's swipes left and
/// right). The order is the app's own window order when the walk began.
struct WindowCycle: Equatable {
    let pid: pid_t
    let windows: [GestureWindow]
    private(set) var index = 0

    init(pid: pid_t, windows: [GestureWindow]) {
        self.pid = pid
        self.windows = windows
    }

    var current: GestureWindow? { windows.isEmpty ? nil : windows[index] }

    mutating func step(forward: Bool) -> GestureWindow? {
        guard !windows.isEmpty else { return nil }
        index = ((index + (forward ? 1 : -1)) % windows.count + windows.count) % windows.count
        return windows[index]
    }
}

// MARK: - What the gestures act on

/// Every app, window and display the Dock and menu-bar gestures read or
/// change. The real one speaks Accessibility and AppKit on the main thread,
/// once per gesture; tests substitute a fake so no real window ever moves.
/// It never hands out AOM's own windows or acts on AOM itself.
@MainActor
protocol GestureDesktop: AnyObject {
    // Apps
    func isFrontmost(_ pid: pid_t) -> Bool
    func appName(_ pid: pid_t) -> String?
    /// Unhides and activates the app.
    @discardableResult func activate(_ pid: pid_t) -> Bool
    @discardableResult func hide(_ pid: pid_t) -> Bool
    /// Activates `pid` and hides every other regular app.
    @discardableResult func hideOthers(keeping pid: pid_t) -> Bool
    /// Sends ⌘N to the app (after it was activated).
    @discardableResult func postNewWindow(to pid: pid_t) -> Bool
    /// The menu bar's app walk: frontmost, recently used, the rest.
    func appCycle() -> AppCycle
    // The window switcher
    var switcherIsShowing: Bool { get }
    func showSwitcher()
    @discardableResult func scrollSwitcher(by offset: Int) -> Bool
    func confirmSwitcher()
    // Windows
    /// The app's standard windows, front to back, minimized ones included.
    func windows(of pid: pid_t) -> [GestureWindow]
    func focusedWindow(of pid: pid_t) -> GestureWindow?
    /// Standard, unminimized, non-full-screen windows of every visible
    /// regular app except AOM, with their frames (Accessibility coordinates).
    func visibleWindows() -> [(window: GestureWindow, frame: CGRect)]
    func isMinimized(_ window: GestureWindow) -> Bool
    @discardableResult func setMinimized(_ window: GestureWindow, _ minimized: Bool) -> Bool
    /// Raises the window and makes it its app's main window.
    @discardableResult func raise(_ window: GestureWindow) -> Bool
    /// Displays as (frame, visible area), Accessibility coordinates.
    func screens() -> [(frame: CGRect, visible: CGRect)]
    /// The display under an AppKit (bottom-left) point, an index into `screens()`.
    func screenIndex(containing point: CGPoint) -> Int?
    /// Moves a window the way the title-bar snap commits (anchored inside
    /// `anchorIn` when an app refuses the size); the completion gets the
    /// frame it really took, or nil.
    func move(_ window: GestureWindow, to frame: CGRect, anchorIn visible: CGRect?,
              completion: @escaping (CGRect?) -> Void)
    // The title-bar snap's history (read-only lookups, plus keeping it in
    // step when a snapped window moves to another display)
    func unsnapFrame(for window: GestureWindow, current: CGRect) -> CGRect?
    func snappedCell(for window: GestureWindow, current: CGRect) -> CustomSnapZone.Layout?
    func recordDisplayMove(of window: GestureWindow, from start: CGRect, to actual: CGRect,
                           layout: CustomSnapZone.Layout)
    var snapMargin: CGFloat { get }
    var snapThirds: Bool { get }
    // 3.3.2: every grid cell (sixths, ninths, almost-maximize) and the Stage
    // Manager offset. Defaults below map them onto the layout-based calls.
    func snappedPlace(for window: GestureWindow, current: CGRect) -> SwishSnap.Place?
    func recordDisplayMove(of window: GestureWindow, from start: CGRect, to actual: CGRect,
                           place: SwishSnap.Place)
    var snapGrid: SwishSnap.Grid { get }
    var snapAlmost: Bool { get }
    /// The area windows snap in on a display with this visible area.
    func snapArea(_ visible: CGRect) -> CGRect
}

extension GestureDesktop {
    func snappedPlace(for window: GestureWindow, current: CGRect) -> SwishSnap.Place? {
        snappedCell(for: window, current: current).flatMap(SwishSnap.Place.init)
    }

    func recordDisplayMove(of window: GestureWindow, from start: CGRect, to actual: CGRect,
                           place: SwishSnap.Place) {
        if let layout = place.layout { recordDisplayMove(of: window, from: start, to: actual, layout: layout) }
    }

    var snapGrid: SwishSnap.Grid { snapThirds ? .threeByTwo : .twoByTwo }
    var snapAlmost: Bool { false }
    func snapArea(_ visible: CGRect) -> CGRect { visible }
}

/// The real desktop: Accessibility and AppKit, main thread, bounded waits.
@MainActor
final class SystemGestureDesktop: GestureDesktop {
    static let shared = SystemGestureDesktop()
    private let own = ProcessInfo.processInfo.processIdentifier
    /// How long one Accessibility request may take before AOM gives up on a
    /// busy app (the default is 6 s, which would stall the gesture layer).
    private let timeout: Float = 0.5

    private func app(_ pid: pid_t) -> NSRunningApplication? {
        guard pid != own, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return app
    }

    func isFrontmost(_ pid: pid_t) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

    func appName(_ pid: pid_t) -> String? { NSRunningApplication(processIdentifier: pid)?.localizedName }

    func activate(_ pid: pid_t) -> Bool {
        guard let app = app(pid) else { return false }
        if app.isHidden { app.unhide() }
        return app.activate(options: [])
    }

    func hide(_ pid: pid_t) -> Bool { app(pid)?.hide() ?? false }

    func hideOthers(keeping pid: pid_t) -> Bool {
        guard activate(pid) else { return false }
        var refused: [String] = []
        for other in NSWorkspace.shared.runningApplications
        where other.activationPolicy == .regular && other.processIdentifier != pid && other.processIdentifier != own && !other.isHidden {
            if !other.hide() { refused.append(other.localizedName ?? "?") }
        }
        if !refused.isEmpty {
            GestureLog.shared.logFromAnyThread("Could not hide: \(refused.joined(separator: ", "))", level: .error)
        }
        return refused.isEmpty
    }

    /// ⌘N straight to the app's process, a moment after the activation so
    /// the new window opens in front. Tagged so AOM's own monitors ignore it.
    func postNewWindow(to pid: pid_t) -> Bool {
        guard app(pid) != nil else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: down) else { continue }
                event.flags = .maskCommand
                event.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.selfTag)
                event.postToPid(pid)
            }
        }
        return ActionPermissions.canPostEvents
    }

    func appCycle() -> AppCycle {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own }
            .map(\.processIdentifier)
        return AppCycle(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                        recent: AppActivationHistory.shared.recentPIDs(), running: running)
    }

    var switcherIsShowing: Bool { WindowSwitcherController.shared.isShowing }
    func showSwitcher() { WindowSwitcherController.shared.show() }
    func scrollSwitcher(by offset: Int) -> Bool {
        guard WindowSwitcherController.shared.isShowing else { return false }
        WindowSwitcherController.shared.moveSelection(offset)
        return true
    }
    func confirmSwitcher() {
        guard WindowSwitcherController.shared.isShowing else { return }
        WindowSwitcherController.shared.confirm()
    }

    func windows(of pid: pid_t) -> [GestureWindow] {
        guard app(pid) != nil else { return [] }
        // Bounded per request and in all (3.3.2 review), like `visibleWindows`.
        let limit = AXDeadline(perRequest: timeout, budget: enumerationBudget)
        let element = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard limit.allow(element),
              AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        var result: [GestureWindow] = []
        for window in list {
            guard limit.allow(window) else { logBudgetSpent("an app's windows"); break }
            guard AX.isStandardWindow(window) else { continue }
            AXUIElementSetMessagingTimeout(window, timeout)
            result.append(GestureWindow(element: window, pid: pid))
        }
        return result
    }

    func focusedWindow(of pid: pid_t) -> GestureWindow? {
        guard app(pid) != nil else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        guard let window = AX.element(element, kAXFocusedWindowAttribute) ?? AX.element(element, kAXMainWindowAttribute) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(window, timeout)
        return GestureWindow(element: window, pid: pid)
    }

    func visibleWindows() -> [(window: GestureWindow, frame: CGRect)] {
        // 3.3.2 review: the menu-bar gestures listed every app's windows on
        // main with unbounded requests (four or more per window; 6 s each
        // against a hung app). Each request is bounded now, and the walk
        // stops after `enumerationBudget`: a hung app is skipped, not waited for.
        let limit = AXDeadline(perRequest: timeout, budget: enumerationBudget)
        var result: [(window: GestureWindow, frame: CGRect)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && !app.isTerminated && app.processIdentifier != own
            // An app AOM is paused for keeps its windows, in front or not.
            && !TriggerSuppression.shared.isPaused(forApp: app.bundleIdentifier) {
            guard !limit.isSpent else { logBudgetSpent("visible windows"); break }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard limit.allow(element),
                  AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let list = value as? [AXUIElement] else { continue }
            for window in list {
                guard limit.allow(window), AX.bool(window, kAXMinimizedAttribute) != true,
                      limit.allow(window), AX.bool(window, "AXFullScreen") != true,
                      limit.allow(window), AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                      limit.allow(window) else { continue }
                let target = WindowManager.Target(window: window, pid: app.processIdentifier)
                guard let frame = WindowManager.shared.frame(of: target), frame.width > 0, frame.height > 0 else { continue }
                // Later requests on this window (minimize, raise, move) keep a bounded wait.
                AXUIElementSetMessagingTimeout(window, timeout)
                result.append((GestureWindow(element: window, pid: app.processIdentifier), frame))
                if result.count >= 100 { return result }
            }
        }
        return result
    }

    /// The most an enumeration of windows may take on main, in all.
    private let enumerationBudget: TimeInterval = 1.0

    /// Says once per launch that a window walk ran out of time.
    private var loggedBudget = false
    private func logBudgetSpent(_ what: String) {
        guard !loggedBudget else { return }
        loggedBudget = true
        GestureLog.shared.logFromAnyThread("Listing \(what) took over \(enumerationBudget) s; a busy app was skipped",
                                           level: .error)
    }

    func isMinimized(_ window: GestureWindow) -> Bool {
        guard let element = window.element else { return false }
        AXUIElementSetMessagingTimeout(element, timeout)
        return AX.bool(element, kAXMinimizedAttribute) == true
    }

    func setMinimized(_ window: GestureWindow, _ minimized: Bool) -> Bool {
        guard window.pid != own, let element = window.element else { return false }
        AXUIElementSetMessagingTimeout(element, timeout)
        return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                            minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    func raise(_ window: GestureWindow) -> Bool {
        guard window.pid != own, let element = window.element else { return false }
        AXUIElementSetMessagingTimeout(element, timeout)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        return raised
    }

    func screens() -> [(frame: CGRect, visible: CGRect)] { WindowManager.shared.screens() }

    func screenIndex(containing point: CGPoint) -> Int? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let topLeft = CGPoint(x: point.x, y: top - point.y)
        return screens().firstIndex { $0.frame.contains(topLeft) }
    }

    func move(_ window: GestureWindow, to frame: CGRect, anchorIn visible: CGRect?,
              completion: @escaping (CGRect?) -> Void) {
        guard window.pid != own, let element = window.element else { completion(nil); return }
        WindowManager.shared.applySnap(frame, target: WindowManager.Target(window: element, pid: window.pid),
                                       visible: visible, completion: completion)
    }

    func unsnapFrame(for window: GestureWindow, current: CGRect) -> CGRect? {
        guard let element = window.element else { return nil }
        return TitleBarWindowSnap.shared.unsnapFrame(for: WindowManager.Target(window: element, pid: window.pid), current: current)
    }

    func snappedCell(for window: GestureWindow, current: CGRect) -> CustomSnapZone.Layout? {
        guard let element = window.element else { return nil }
        return TitleBarWindowSnap.shared.snappedCell(for: WindowManager.Target(window: element, pid: window.pid), current: current)
    }

    func recordDisplayMove(of window: GestureWindow, from start: CGRect, to actual: CGRect,
                           layout: CustomSnapZone.Layout) {
        guard let element = window.element else { return }
        TitleBarWindowSnap.shared.recordDisplayMove(of: WindowManager.Target(window: element, pid: window.pid),
                                                    from: start, to: actual, layout: layout)
    }

    var snapMargin: CGFloat { TitleBarWindowSnap.margin() }
    var snapThirds: Bool { TitleBarWindowSnap.gestureOptions().thirds }

    func snappedPlace(for window: GestureWindow, current: CGRect) -> SwishSnap.Place? {
        guard let element = window.element else { return nil }
        return TitleBarWindowSnap.shared.snappedPlace(for: WindowManager.Target(window: element, pid: window.pid),
                                                      current: current)
    }

    func recordDisplayMove(of window: GestureWindow, from start: CGRect, to actual: CGRect,
                           place: SwishSnap.Place) {
        guard let element = window.element else { return }
        TitleBarWindowSnap.shared.recordDisplayMove(of: WindowManager.Target(window: element, pid: window.pid),
                                                    from: start, to: actual, place: place)
    }

    var snapGrid: SwishSnap.Grid { TitleBarWindowSnap.grid() }
    var snapAlmost: Bool { TitleBarWindowSnap.almostMaximizeOn() }
    func snapArea(_ visible: CGRect) -> CGRect { TitleBarWindowSnap.snapArea(visible) }
}

// MARK: - The Dock under the pointer (one lookup per gesture)

enum DockLookup {
    /// The window the window server reports under an AppKit point: its layer
    /// and owner. Cheap (no Accessibility round trip).
    @MainActor
    static func windowUnder(_ point: CGPoint) -> (layer: Int, pid: pid_t)? {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first,
              let layer = info[kCGWindowLayer as String] as? Int,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return (layer, pid)
    }

    /// The Dock item under an AppKit point: its title, bundle URL and
    /// subrole. Nil unless the element belongs to the Dock. One hit-test on
    /// the Dock's own application element, each request bounded to 0.25 s
    /// and the whole lookup to `budget`. 3.3.2 review: the hit-test used to
    /// go through the system-wide element with its timeout set to 0.25 s,
    /// which set the timeout of every Accessibility call in AOM (AXUIElement.h:
    /// the system-wide element's timeout is the process's); after the first
    /// Dock gesture a busy app's size or position write failed after 0.25 s.
    @MainActor
    static func item(at point: CGPoint, dockPID: pid_t, budget: TimeInterval = 0.4) -> DockItemMatcher.Item? {
        guard dockPID > 0 else { return nil }
        let limit = AXDeadline(perRequest: 0.25, budget: budget)
        let dock = AXUIElementCreateApplication(dockPID)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var hit: AXUIElement?
        guard limit.allow(dock),
              AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(top - point.y), &hit) == .success,
              var current = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(current, &pid) == .success, pid == dockPID else { return nil }
        for _ in 0..<16 {
            guard limit.allow(current), let role = AX.string(current, kAXRoleAttribute) else { return nil }
            if role == "AXDockItem" {
                var url: CFTypeRef?
                if limit.allow(current) { AXUIElementCopyAttributeValue(current, kAXURLAttribute as CFString, &url) }
                let title = limit.allow(current) ? AX.string(current, kAXTitleAttribute) : nil
                let subrole = limit.allow(current) ? AX.string(current, kAXSubroleAttribute) : nil
                return DockItemMatcher.Item(title: title, url: url as? URL, subrole: subrole)
            }
            guard limit.allow(current), let parent = AX.element(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// The running app whose Dock icon is under an AppKit point. A window-server
    /// check first: over an ordinary app window the pointer is not on the
    /// Dock, so no Accessibility request is made at all.
    @MainActor
    static func app(at point: CGPoint) -> NSRunningApplication? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        if let under = windowUnder(point), under.layer == 0, under.pid != dock.processIdentifier { return nil }
        guard let item = item(at: point, dockPID: dock.processIdentifier) else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        let candidates = apps.map {
            DockItemMatcher.Candidate(pid: $0.processIdentifier, name: $0.localizedName, bundleID: $0.bundleIdentifier,
                                      bundleURL: $0.bundleURL, isRegular: $0.activationPolicy == .regular && !$0.isTerminated)
        }
        guard let pid = DockItemMatcher.match(item, in: candidates, bundleID: {
            item.url.flatMap { Bundle(url: $0)?.bundleIdentifier }
        }) else { return nil }
        return apps.first { $0.processIdentifier == pid }
    }
}
