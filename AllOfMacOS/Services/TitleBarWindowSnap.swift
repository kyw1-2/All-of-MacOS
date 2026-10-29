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

// MARK: - Pure recognition (unit-tested)

enum SwishSnap {
    enum Axis: Equatable { case horizontal, vertical }

    enum Direction: Equatable {
        case left, right, up, down
        var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    }

    /// One recognised swipe: its primary direction and tier, plus an optional
    /// leg along the other axis that turns a half into a quarter.
    struct Stroke: Equatable {
        var direction: Direction
        var tier: Int
        var cross: Direction?
        /// The fingers rested `TitleBarSnapRecognizer.holdTime` before the
        /// swipe (Swish's "tap and hold"): up toggles full screen, down
        /// minimizes, sideways moves the window a Space.
        var held: Bool

        init(_ direction: Direction, tier: Int = 1, cross: Direction? = nil, held: Bool = false) {
            self.direction = direction
            self.tier = tier
            self.cross = cross
            self.held = held
        }
    }

    /// The layout a swipe maps to. Tier 1 is a short swipe; tier 2 is a longer
    /// swipe in the same direction, so one gesture refines from half → third
    /// (horizontal) or maximize/centre → top/bottom half (vertical).
    static func layout(for direction: Direction, tier: Int) -> CustomSnapZone.Layout {
        switch (direction, tier >= 2) {
        case (.left, false): return .leftHalf
        case (.left, true): return .leftThird
        case (.right, false): return .rightHalf
        case (.right, true): return .rightThird
        case (.up, false): return .maximize
        case (.up, true): return .topHalf
        case (.down, false): return .center
        case (.down, true): return .bottomHalf
        }
    }

    /// A stroke with a perpendicular leg is a quarter, whichever axis came
    /// first (Swish: "Swipe horizontally and vertically to snap to a quarter.
    /// Both orders work.").
    static func layout(for stroke: Stroke) -> CustomSnapZone.Layout {
        guard let cross = stroke.cross, cross.axis != stroke.direction.axis else {
            return layout(for: stroke.direction, tier: stroke.tier)
        }
        let horizontal = stroke.direction.axis == .horizontal ? stroke.direction : cross
        let vertical = stroke.direction.axis == .vertical ? stroke.direction : cross
        switch (horizontal, vertical) {
        case (.left, .up): return .topLeft
        case (.right, .up): return .topRight
        case (.left, _): return .bottomLeft
        default: return .bottomRight
        }
    }

    /// The dominant swipe direction, or nil while the movement is too small or
    /// too diagonal to be sure. Distances are in normalised trackpad units
    /// (0…1 across the pad), so they are independent of trackpad size.
    static func direction(dx: Float, dy: Float, engage: Float, ratio: Float) -> Direction? {
        let ax = abs(dx), ay = abs(dy)
        if ax >= ay {
            guard ax >= engage, ax >= ay * ratio else { return nil }
            return dx < 0 ? .left : .right
        } else {
            guard ay >= engage, ay >= ax * ratio else { return nil }
            // The recognizer hands over pad coordinates with y growing toward
            // the bottom of the pad (it flips TouchPoint's y, which grows
            // toward the top), so dy > 0 is a swipe down the pad, which the
            // user feels as pulling the window down.
            return dy > 0 ? .down : .up
        }
    }

    /// Tier from the dominant-axis displacement.
    static func tier(dx: Float, dy: Float, tier2: Float) -> Int {
        max(abs(dx), abs(dy)) >= tier2 ? 2 : 1
    }

    /// The trackpad's width over its height: MacBook trackpads are about 1.5,
    /// the Magic Trackpad 1.4. Pad units stretch by it, so a swipe at 45° on
    /// the glass reads steeper than 45° in pad units.
    static let padAspect: Float = 1.5

    /// A diagonal swipe (3.3.2): both legs past most of `engage` and, measured
    /// on the glass, between about 31° and 59° — Swish snaps it straight to
    /// that quarter, from any cell (top half or maximized ↙ → bottom-left).
    /// Until now such a swipe was "too diagonal" for `direction` and did
    /// nothing at all. The longer leg is the primary direction, the shorter
    /// one the cross, so `refine` keeps following it like an L-shape.
    static func diagonal(dx: Float, dy: Float, engage: Float, aspect: Float = padAspect,
                         share: Float = 0.6) -> Stroke? {
        let ax = abs(dx), ay = abs(dy)
        // 0.8 × engage keeps the shorter leg above `refine`'s held-cross
        // threshold (0.6 × crossEngage), so the quarter does not flicker
        // back to a half on the next frame.
        guard min(ax, ay) >= engage * 0.8 else { return nil }
        let glassX = ax * aspect, glassY = ay
        guard min(glassX, glassY) >= max(glassX, glassY) * share else { return nil }
        let horizontal: Direction = dx < 0 ? .left : .right
        // Pad Y grows downward, as in `direction`.
        let vertical: Direction = dy > 0 ? .down : .up
        return glassX >= glassY ? Stroke(horizontal, cross: vertical) : Stroke(vertical, cross: horizontal)
    }

    /// Follows an engaged swipe. The primary axis was fixed when the gesture
    /// engaged and the tier comes from the distance along it. A deliberate leg
    /// along the other axis — past `crossEngage` and at least `crossShare` of
    /// the primary distance, so the natural arc of a long swipe never counts —
    /// adds the cross direction; once held it is released only below 60% of
    /// that. Back near the start, a clear swipe along the other axis re-picks
    /// the axis; anything less returns nil so the preview holds still.
    static func refine(dx: Float, dy: Float, axis: Axis, previous: Stroke?,
                       engage: Float, tier2: Float, ratio: Float,
                       crossEngage: Float = 0.06, crossShare: Float = 0.45) -> Stroke? {
        let primary = axis == .horizontal ? dx : dy
        let other = axis == .horizontal ? dy : dx
        if abs(primary) < engage * 0.5 {
            guard let fresh = direction(dx: dx, dy: dy, engage: engage, ratio: ratio),
                  fresh.axis != axis else { return nil }
            return Stroke(fresh, tier: tier(dx: dx, dy: dy, tier2: tier2))
        }
        let direction: Direction = axis == .horizontal
            ? (primary < 0 ? .left : .right)
            : (primary > 0 ? .down : .up)
        let held = previous?.cross != nil && previous?.direction.axis == axis
        let needed = max(crossEngage, abs(primary) * crossShare) * (held ? 0.6 : 1)
        var cross: Direction?
        if abs(other) >= needed {
            cross = axis == .horizontal ? (other > 0 ? .down : .up) : (other < 0 ? .left : .right)
        }
        return Stroke(direction, tier: abs(primary) >= tier2 ? 2 : 1, cross: cross)
    }

    /// The tallest title bar plus unified toolbar AOM looks in (Safari,
    /// Finder and Mail are about 52 pt). Within it, the Accessibility hit-test
    /// decides whether the pointer is really on the title bar or toolbar.
    static let toolbarBand: CGFloat = 60

    /// How far below a window's top edge a gesture may start (3.3.3, F04):
    /// the title bar, a unified toolbar and a native tab bar under it (a
    /// toolbar with labels and window tabs reach about 100 pt).
    static let tabBarBand: CGFloat = 110

    /// Pure: whether the window-server pre-filter lets a pointer `pointerY`
    /// (top-left) through to the Accessibility hit-test of a window whose top
    /// edge is at `windowTop`: in its top `tabBarBand`, or anywhere on it
    /// while the Super modifier's whole-window gestures are wanted.
    static func inPreFilterBand(pointerY: CGFloat, windowTop: CGFloat, anywhere: Bool) -> Bool {
        guard pointerY >= windowTop else { return false }
        return anywhere || pointerY - windowTop <= tabBarBand
    }

    /// Pure (F04): the places a title-bar gesture may start: the title bar or
    /// a toolbar (the hit-test found an AXToolbar, the window itself or a
    /// window button), a tab bar (an AXTabGroup), the top `band` of the
    /// window, or anywhere while the Super modifier allows it.
    static func isStartArea(onTitleBar: Bool, onTabBar: Bool, inTitleBand: Bool, anywhere: Bool) -> Bool {
        onTitleBar || onTabBar || inTitleBand || anywhere
    }

    /// Whether a top-left pointer sits in a window's title-bar band.
    static func titleBarHit(pointerTopLeft: CGPoint, windowFrame: CGRect, band: CGFloat = 30) -> Bool {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return false }
        let strip = CGRect(x: windowFrame.minX, y: windowFrame.minY,
                           width: windowFrame.width, height: min(band, windowFrame.height))
        return strip.contains(pointerTopLeft)
    }

    /// The window's target frame for a layout, in Accessibility (top-left)
    /// coordinates within the given visible display area.
    static func targetFrame(layout: CustomSnapZone.Layout, visible: CGRect, margin: CGFloat) -> CGRect {
        let unit = AOMTilingGeometry.rect(for: layout, in: CGSize(width: 1, height: 1))
        var rect = CGRect(x: visible.minX + unit.minX * visible.width,
                          y: visible.minY + unit.minY * visible.height,
                          width: unit.width * visible.width,
                          height: unit.height * visible.height)
        guard margin > 0 else { return rect }
        rect = rect.insetBy(dx: margin, dy: margin)
        return rect
    }

    /// Accessibility (top-left) rect → AppKit (bottom-left) screen rect for the
    /// overlay window.
    static func appKitRect(_ axRect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: axRect.minX, y: primaryTop - axRect.minY - axRect.height,
               width: axRect.width, height: axRect.height)
    }

    /// Where the pointer goes after a snap when "Keep pointer on title bar" is
    /// on: the middle of the title-bar band, so the next swipe chains. Swish
    /// warps to its title bar the same way. Global top-left coordinates.
    static func titleBarRestPoint(for frame: CGRect, band: CGFloat = 30) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.minY + min(band, frame.height) / 2)
    }

    // MARK: Moving between cells (3.3.2)

    /// What a swipe does to a window, given the cell it sits in now.
    enum Move: Equatable {
        case cell(CustomSnapZone.Layout)
        /// A place no tiling layout names (3.3.2): a sixth, a ninth, a span
        /// of them, or almost-maximize. A place that has a layout is always
        /// reported as `.cell` (`Move.to`), so equal moves compare equal.
        case place(Place)
        /// Put the window back where it was before AOM snapped it (centre it
        /// when AOM has no earlier frame).
        case restore
        /// Act on the window instead of moving it to a cell (Swish's other
        /// title-bar gestures: minimize, close, quit, full screen, hide,
        /// Spaces and displays).
        case action(WindowAction)

        /// The move to `place`, named by its tiling layout when it has one.
        static func to(_ place: Place) -> Move {
            place.layout.map { .cell($0) } ?? .place(place)
        }

        /// Where the window goes, for a move to a cell or place.
        var destination: Place? {
            switch self {
            case .cell(let layout): return Place(layout)
            case .place(let place): return place
            case .restore, .action: return nil
            }
        }
    }

    /// The cells a window can be recognised in, most specific first.
    static let recognisedCells: [CustomSnapZone.Layout] = [
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
        .leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize
    ]

    /// The grid cell a frame fills, so the next swipe can move it from there
    /// (Swish chains swipes the same way). Nil for a free-floating window.
    /// With thirds off a window that happens to fill a third is free-floating,
    /// so no swipe steps it through thirds (3.3.2).
    ///
    /// A window with a minimum size larger than its cell (snapped by AOM's
    /// keyboard or drag snapping, or by another tool) does not fill it: it
    /// sits flush with the cell's snapped edges and overflows it, the way
    /// `WindowGeometry.anchoredFrame` places it. Such a window counts as in
    /// the cell it overflows least, so a top quarter swiped down still moves
    /// to the bottom instead of being treated as free-floating (3.3.2).
    static func cell(of frame: CGRect, visible: CGRect, margin: CGFloat, tolerance: CGFloat = 16,
                     thirds: Bool = true) -> CustomSnapZone.Layout? {
        let candidates = recognisedCells.filter { thirds || !isThird($0) }
        if let exact = candidates.first(where: { layout in
            let rect = targetFrame(layout: layout, visible: visible, margin: margin)
            return abs(rect.minX - frame.minX) <= tolerance && abs(rect.minY - frame.minY) <= tolerance
                && abs(rect.maxX - frame.maxX) <= tolerance && abs(rect.maxY - frame.maxY) <= tolerance
        }) { return exact }
        let area = margin > 0 ? visible.insetBy(dx: margin, dy: margin) : visible
        var best: (layout: CustomSnapZone.Layout, overflow: CGFloat)?
        for layout in candidates {
            let rect = targetFrame(layout: layout, visible: visible, margin: margin)
            let overflowX = frame.width - rect.width, overflowY = frame.height - rect.height
            // Each side fits the cell or is larger than it, and at least one is larger.
            guard overflowX >= -tolerance, overflowY >= -tolerance,
                  overflowX > tolerance || overflowY > tolerance else { continue }
            let anchored = WindowGeometry.anchoredFrame(desired: rect, actualSize: frame.size, visible: area)
            guard abs(anchored.minX - frame.minX) <= tolerance, abs(anchored.minY - frame.minY) <= tolerance else { continue }
            let overflow = max(0, overflowX) + max(0, overflowY)
            if best.map({ overflow < $0.overflow }) ?? true { best = (layout, overflow) }
        }
        return best?.layout
    }

    /// The cells of the opt-in 3 × 2 grid.
    static func isThird(_ layout: CustomSnapZone.Layout) -> Bool {
        [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds].contains(layout)
    }

    /// Swish-style chaining on the 2 × 2 grid, or with `thirds` on the 3 × 2
    /// grid (`step(from:stroke:grid:almost:)` has the full rules and the 3 × 3
    /// grid):
    /// - From a half, the other axis halves it again: left half + down →
    ///   bottom-left quarter, top half + right → top-right quarter.
    /// - From a quarter, a swipe toward the other row or column moves it
    ///   there (top-left + down → bottom-left); a swipe toward the edge it
    ///   already touches grows it along that edge (top-left + up → top half,
    ///   top-left + left → left half).
    /// - Maximized, or on the bottom edge, a swipe down puts the window back.
    /// - Thirds only when `thirds` is on: a longer swipe on a free window, and
    ///   swipes toward an edge that step half → third → two thirds → half;
    ///   a third swiped up or down becomes its upper or lower sixth.
    /// - An L-shaped swipe picks a quarter outright, from anywhere.
    static func move(from current: CustomSnapZone.Layout?, stroke: Stroke, thirds: Bool) -> Move {
        step(from: current.flatMap(Place.init), stroke: stroke, grid: thirds ? .threeByTwo : .twoByTwo)
    }

    // MARK: Swish's other title-bar gestures (3.3.2)

    /// A two-finger pinch on a title bar.
    enum Pinch: Equatable { case `in`, out }

    /// The modifier keys Swish names for its title-bar gestures: the general
    /// modifier (⌥ Option), the secondary modifier (⇧ Shift, double tap only)
    /// and the screen modifier (⌘ Command).
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        static let general = Modifiers(rawValue: 1)
        static let secondary = Modifiers(rawValue: 1 << 1)
        static let screen = Modifiers(rawValue: 1 << 2)

        init(flags: NSEvent.ModifierFlags) {
            self.init(rawValue: (flags.contains(.option) ? Modifiers.general.rawValue : 0)
                | (flags.contains(.shift) ? Modifiers.secondary.rawValue : 0)
                | (flags.contains(.command) ? Modifiers.screen.rawValue : 0))
        }

        /// The gesture modifiers of the roles held (3.3.3, F05: the keys come
        /// from `ModifierRoles`; Super and Tertiary do not change a gesture's
        /// meaning, they change where it may start and the grid).
        init(held roles: Set<ModifierRole>) {
            self.init(rawValue: (roles.contains(.general) ? Modifiers.general.rawValue : 0)
                | (roles.contains(.secondary) ? Modifiers.secondary.rawValue : 0)
                | (roles.contains(.screen) ? Modifiers.screen.rawValue : 0))
        }
    }

    /// What a title-bar gesture does to the window instead of moving it to a cell.
    enum WindowAction: Equatable {
        case minimize, close, quitApp, toggleFullscreen, hideApp, hideOthers
        case spaceLeft, spaceRight
        /// To the display in that direction, keeping the window's cell.
        case screen(Direction)
        /// To the next display, then into full screen there (Swish: "On a two
        /// screen setup, use the screen modifier or pinch out twice to
        /// directly enter fullscreen mode on the other screen").
        case fullscreenOnOtherScreen
        /// The tab under the pointer (3.3.3, F02): its close button, or ⌘W to
        /// its app while it is the selected tab ("Pinch in to close a tab").
        case closeTab
        /// The tab under the pointer into a new window ("Tap and hold to
        /// detach a native tab into a new window").
        case detachTab
    }

    /// Pure (3.3.3 multi-motion): whether the touch may go on to another
    /// gesture after `action`. Yes after Space moves (several in a row), a
    /// closed tab (the next tab may follow), and the first half of a "twice"
    /// gesture (its second half may follow); no once the window went away or
    /// changed mode (minimized, its app quit or hidden, full screen).
    static func touchContinues(after action: WindowAction, waits: Bool) -> Bool {
        switch action {
        case .spaceLeft, .spaceRight, .closeTab: return true
        case .close, .toggleFullscreen: return waits
        case .minimize, .quitApp, .hideApp, .hideOthers, .screen, .fullscreenOnOtherScreen, .detachTab: return false
        }
    }

    /// What a short swipe down does to a free-floating window.
    enum DownAction: String, CaseIterable { case minimize, center }

    /// What a two-finger double tap on a title bar does.
    enum DoubleTap: String, CaseIterable { case restoreOrCenter, center, off }

    /// The settings the gesture mapping depends on.
    struct GestureOptions: Equatable {
        /// The snapping grid (3.3.2: Swish's thirds, sixths and ninths).
        var grid: Grid
        var downAction: DownAction
        var holdGestures: Bool
        var modifierGestures: Bool
        /// Swish's "Almost Maximize".
        var almostMaximize: Bool

        /// Thirds are reachable (a 3 × 2 or 3 × 3 grid): the 3.3.2 switch.
        /// Turning it on picks 3 × 2 unless a grid with thirds is set.
        var thirds: Bool {
            get { grid.thirds }
            set { grid = newValue ? (grid.thirds ? grid : .threeByTwo) : .twoByTwo }
        }

        /// `grid` nil follows `thirds`: 3 × 2 with thirds, else 2 × 2.
        init(thirds: Bool = false, downAction: DownAction = .minimize, holdGestures: Bool = true,
             modifierGestures: Bool = true, grid: Grid? = nil, almostMaximize: Bool = false) {
            self.grid = grid ?? (thirds ? .threeByTwo : .twoByTwo)
            self.downAction = downAction
            self.holdGestures = holdGestures
            self.modifierGestures = modifierGestures
            self.almostMaximize = almostMaximize
        }
    }

    /// Every title-bar swipe, after Swish 1.13:
    /// - ⌘ (screen modifier), any direction: "move a window to the next
    ///   screen in that direction".
    /// - ⌥ (general modifier): sideways moves the window a Space ("use the
    ///   general modifier to move a window between Mission Control spaces"),
    ///   down closes it ("swipe down once while holding the general
    ///   modifier"), and after tap-and-hold down quits the app. Up is a
    ///   plain swipe up.
    /// - Tap and hold first (`stroke.held`): up enters or leaves full screen,
    ///   down minimizes ("in fullscreen mode, tap and hold before swiping
    ///   down"), sideways moves a Space.
    /// - Otherwise the cell chaining of `step(from:stroke:grid:almost:)`,
    ///   except that a short swipe down on a free-floating or centred window
    ///   minimizes it ("Swipe down once to minimize a window") while
    ///   `downAction` is `.minimize`; a longer one still snaps the bottom half.
    /// A window in native full screen only answers to tap-and-hold and the
    /// modifiers. Nil: the stroke does nothing.
    static func move(from current: CustomSnapZone.Layout?, stroke: Stroke, modifiers: Modifiers,
                     options: GestureOptions, fullscreen: Bool = false) -> Move? {
        move(at: current.flatMap(Place.init), stroke: stroke, modifiers: modifiers, options: options,
             fullscreen: fullscreen)
    }

    /// The same mapping for any place (sixths, ninths, almost-maximize).
    static func move(at current: Place?, stroke: Stroke, modifiers: Modifiers,
                     options: GestureOptions, fullscreen: Bool = false) -> Move? {
        let modifiers = options.modifierGestures ? modifiers : []
        let held = stroke.held && options.holdGestures
        let direction = stroke.direction
        if modifiers.contains(.screen) { return .action(.screen(direction)) }
        if modifiers.contains(.general), direction != .up {
            switch direction {
            case .down: return .action(held ? .quitApp : .close)
            case .left: return fullscreen ? nil : .action(.spaceLeft)
            default: return fullscreen ? nil : .action(.spaceRight)
            }
        }
        if held {
            switch direction {
            case .up: return .action(.toggleFullscreen)
            case .down: return .action(.minimize)
            case .left: return fullscreen ? nil : .action(.spaceLeft)
            case .right: return fullscreen ? nil : .action(.spaceRight)
            }
        }
        guard !fullscreen else { return nil }
        let grid = options.grid, almost = options.almostMaximize
        guard options.downAction == .minimize else { return step(from: current, stroke: stroke, grid: grid, almost: almost) }
        // Swish: a centred window, or a place the grid cannot produce (a
        // third while thirds are off), is free-floating too.
        let free = current.map { $0 == .center || !usable($0, grid: grid, almost: almost) } ?? true
        if free, direction == .down, stroke.tier < 2, stroke.cross == nil { return .action(.minimize) }
        return step(from: free ? nil : current, stroke: stroke, grid: grid, almost: almost)
    }

    /// What a finished pinch does, and whether it first waits for a second
    /// pinch of the same kind. `second`: it follows such a pinch on the same
    /// app within the repeat window.
    /// - In closes the window, after waiting: a second pinch in quits the app
    ///   instead ("Pinch in twice to quit an application"), as does a
    ///   tap-and-hold pinch in ("tap, hold and pinch in once").
    /// - Out toggles full screen. With two or more displays it waits: a second
    ///   pinch out, ⌘, or a tap-and-hold pinch out moves the window to the
    ///   other display and enters full screen there.
    static func pinchAction(_ pinch: Pinch, second: Bool, held: Bool, modifiers: Modifiers,
                            displays: Int) -> (action: WindowAction, waits: Bool) {
        switch pinch {
        case .in:
            return held || second ? (.quitApp, false) : (.close, true)
        case .out:
            guard displays >= 2 else { return (.toggleFullscreen, false) }
            if held || second || modifiers.contains(.screen) { return (.fullscreenOnOtherScreen, false) }
            return (.toggleFullscreen, true)
        }
    }

    /// Swish's double tap: "unsnap and/or center a window" (or only centre
    /// it), ⌥ hides the app's windows and ⇧ every other app. Nil: off.
    static func doubleTapMove(_ option: DoubleTap, modifiers: Modifiers) -> Move? {
        guard option != .off else { return nil }
        if modifiers.contains(.secondary) { return .action(.hideOthers) }
        if modifiers.contains(.general) { return .action(.hideApp) }
        return option == .center ? .cell(.center) : .restore
    }

    /// The display a swipe in `direction` moves a window to: the nearest one
    /// that lies that way from the window's display — its centre is further
    /// that way, and it either overlaps the display across the swipe (side
    /// by side for a sideways swipe, stacked for a vertical one) or lies more
    /// that way than sideways, so a taller display to the right is not
    /// "below". Overlapping displays win. Accessibility (top-left)
    /// coordinates, so up is towards smaller y. Nil when none lies that way.
    static func screenIndex(toward direction: Direction, from window: CGRect, screens: [CGRect]) -> Int? {
        let own = WindowGeometry.screenIndex(for: window, screens: screens)
        let origin = own.map { screens[$0] } ?? window
        func along(_ screen: CGRect) -> CGFloat {
            switch direction {
            case .left: return origin.midX - screen.midX
            case .right: return screen.midX - origin.midX
            case .up: return origin.midY - screen.midY
            case .down: return screen.midY - origin.midY
            }
        }
        func across(_ screen: CGRect) -> CGFloat {
            direction.axis == .horizontal ? abs(screen.midY - origin.midY) : abs(screen.midX - origin.midX)
        }
        func overlaps(_ screen: CGRect) -> Bool {
            direction.axis == .horizontal
                ? screen.minY < origin.maxY && screen.maxY > origin.minY
                : screen.minX < origin.maxX && screen.maxX > origin.minX
        }
        let candidates = screens.indices.filter { index in
            let screen = screens[index]
            return index != own && along(screen) > 0 && (overlaps(screen) || along(screen) >= across(screen))
        }
        let aligned = candidates.filter { overlaps(screens[$0]) }
        if let nearest = aligned.min(by: { along(screens[$0]) < along(screens[$1]) }) { return nearest }
        return candidates.min {
            hypot(screens[$0].midX - origin.midX, screens[$0].midY - origin.midY)
                < hypot(screens[$1].midX - origin.midX, screens[$1].midY - origin.midY)
        }
    }

    static func arrow(_ direction: Direction) -> String {
        switch direction {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        }
    }

    /// The HUD title naming what lifting the fingers will do.
    static func title(for action: WindowAction, appName: String?, fullscreen: Bool = false) -> String {
        let app = appName.flatMap { $0.isEmpty ? nil : $0 } ?? "App"
        switch action {
        case .minimize: return "Minimize"
        case .close: return "Close Window"
        case .quitApp: return "Quit \(app)"
        case .toggleFullscreen: return fullscreen ? "Exit Full Screen" : "Full Screen"
        case .hideApp: return "Hide \(app)"
        case .hideOthers: return "Hide Others"
        case .spaceLeft: return "Move to Space ←"
        case .spaceRight: return "Move to Space →"
        case .screen(let direction): return "Move to Display \(arrow(direction))"
        case .fullscreenOnOtherScreen: return "Full Screen on Other Display"
        case .closeTab: return "Close Tab"
        case .detachTab: return "Detach Tab"
        }
    }
}

/// Swish keeps each window's frame from before its first snap so the window
/// can be unsnapped. Pure; the service keys windows by `pid:CFHash(window)`.
struct SwishSnapHistory {
    struct Entry: Equatable {
        /// Where the window was before the first snap of the current chain.
        var original: CGRect
        /// The frame the window really took at its last snap.
        var snapped: CGRect
        /// The place AOM snapped it to (a grid cell, the centre or
        /// almost-maximize), so the next swipe moves on from there even when
        /// a size-limited app is not exactly the cell's size.
        var place: SwishSnap.Place? = nil

        /// The tiling layout of `place`, when it has one.
        var layout: CustomSnapZone.Layout? { place?.layout }
    }

    private(set) var entries: [String: Entry] = [:]
    private var order: [String] = []
    var limit = 64

    /// Records a snap. A chain of snaps keeps the first starting frame, so a
    /// restore goes back to where the window began; a window moved by hand
    /// since its last snap starts a new chain.
    mutating func recordSnap(key: String, from start: CGRect, to actual: CGRect,
                             layout: CustomSnapZone.Layout? = nil) {
        recordSnap(key: key, from: start, to: actual, place: layout.flatMap(SwishSnap.Place.init))
    }

    mutating func recordSnap(key: String, from start: CGRect, to actual: CGRect, place: SwishSnap.Place?) {
        if var entry = entries[key] {
            if !WindowGeometry.close(entry.snapped, start) { entry.original = start }
            entry.snapped = actual
            entry.place = place
            entries[key] = entry
            return
        }
        entries[key] = Entry(original: start, snapped: actual, place: place)
        order.append(key)
        if order.count > limit { entries.removeValue(forKey: order.removeFirst()) }
    }

    /// The window was moved for it, not by hand (re-snapped after a display
    /// change, or following a neighbour's resize): it stays snapped in its
    /// place, and an unsnap still restores the frame from before the chain.
    mutating func moveSnapped(key: String, to actual: CGRect) {
        entries[key]?.snapped = actual
    }

    /// The cell AOM last snapped the window to, while it still sits there.
    func cell(key: String, current: CGRect) -> CustomSnapZone.Layout? {
        place(key: key, current: current)?.layout
    }

    /// The place AOM last snapped the window to, while it still sits there.
    func place(key: String, current: CGRect) -> SwishSnap.Place? {
        guard let entry = entries[key], WindowGeometry.close(entry.snapped, current) else { return nil }
        return entry.place
    }

    /// The frame to restore, while the window still sits where it was snapped.
    /// Nothing to restore when the snap never moved the window (it was already
    /// in that cell), so a swipe down then centres it as usual.
    func restoreFrame(key: String, current: CGRect) -> CGRect? {
        guard let entry = entries[key], WindowGeometry.close(entry.snapped, current),
              !WindowGeometry.close(entry.original, current) else { return nil }
        return entry.original
    }

    mutating func forget(key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }
}

/// The prerequisites Swish's settings spell out ("Haptic Feedback needs to be
/// enabled for your Magic Trackpad", "Mission Control shortcuts are set
/// correctly / to a custom combination / disabled"), checked read-only for
/// AOM's trackpad gestures. Nothing here writes system preferences.
enum TrackpadReadiness {
    struct Item: Identifiable, Equatable {
        enum Fix: Equatable { case accessibility, trackpad, keyboardShortcuts }
        let id: String
        let title: String
        let detail: String
        let ready: Bool
        let fix: Fix?
    }

    /// Force Click and haptic feedback: `ForceSuppressed` = 1 turns it off and
    /// `ActuateDetents` = 0 silences the detents. Missing keys are the default (on).
    static func hapticsEnabled(actuateDetents: Any?, forceSuppressed: Any?) -> Bool {
        func flag(_ value: Any?) -> Bool? {
            if let number = value as? NSNumber { return number.boolValue }
            return value as? Bool
        }
        return flag(forceSuppressed) != true && flag(actuateDetents) != false
    }

    /// The Mission Control "Move left/right a space" shortcuts the top-bar
    /// Space swipe posts. A custom combination works too: AOM posts whatever
    /// the shortcut is set to.
    static func spaceShortcuts(left: SymbolicHotKey?, right: SymbolicHotKey?) -> (ready: Bool, detail: String) {
        guard let left, let right, left.isEnabled, right.isEnabled else {
            return (false, "Turn on Move left/right a space in Keyboard Shortcuts › Mission Control.")
        }
        let standard = left.keyCode == 123 && right.keyCode == 124
            && left.flags.contains(.maskControl) && right.flags.contains(.maskControl)
        return (true, standard ? "⌃← and ⌃→ are on." : "On, set to a custom combination.")
    }

    @MainActor
    static func current(hapticsWanted: Bool, spaceSwipeOn: Bool) -> [Item] {
        let trusted = AXIsProcessTrusted()
        var items = [Item(id: "accessibility", title: "Accessibility",
                          detail: trusted ? "Allowed — windows can be moved." : "Needed to move windows.",
                          ready: trusted, fix: trusted ? nil : .accessibility)]
        if hapticsWanted {
            let domain = "com.apple.AppleMultitouchTrackpad" as CFString
            let on = hapticsEnabled(actuateDetents: CFPreferencesCopyAppValue("ActuateDetents" as CFString, domain),
                                    forceSuppressed: CFPreferencesCopyAppValue("ForceSuppressed" as CFString, domain))
            items.append(Item(id: "haptics", title: "Haptic feedback",
                              detail: on ? "On (Force Touch trackpads)." : "Turn on Force Click and haptic feedback in Trackpad settings.",
                              ready: on, fix: on ? nil : .trackpad))
        }
        if spaceSwipeOn {
            let table = SymbolicHotKeys.load()
            let state = spaceShortcuts(left: SymbolicHotKeys.hotKey(id: SymbolicHotKeys.spaceLeft, in: table),
                                       right: SymbolicHotKeys.hotKey(id: SymbolicHotKeys.spaceRight, in: table))
            items.append(Item(id: "spaces", title: "Space shortcuts", detail: state.detail,
                              ready: state.ready, fix: state.ready ? nil : .keyboardShortcuts))
        }
        return items
    }

    static func open(_ fix: Item.Fix) {
        let address: String
        switch fix {
        case .accessibility: address = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .trackpad: address = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
        case .keyboardShortcuts: address = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

/// Classifies a two-finger swipe from raw contact frames — and, since 3.3.2,
/// Swish's other title-bar gestures: a pinch in or out (only from a touch
/// that has not engaged a swipe, and never turning into one), a tap (the
/// service pairs taps into a double tap), and tap-and-hold (fingers resting
/// `holdTime` before the swipe mark its strokes `held`). It is fed from one
/// thread only, allocates nothing per frame and reports state transitions
/// through closures (which the service hops to the main thread).
///
/// Only lifting the fingers commits: going from two contacts to none or one.
/// Activity is measured in contact frames: while two fingers stay on the
/// pad the gesture stays alive, and the recognizer tells the service so
/// (`onActive`). Until 3.3.0 only a zone change refreshed the service's 1.2 s
/// timer, so holding one preview hid it and the later lift had nothing to
/// apply (audit 2026-10-28 F05). Since 3.3.2 fingers held perfectly still for
/// `holdCancelTime` (Swish's 2 s) cancel on purpose, with the preview fading
/// over the last second; any movement keeps the gesture.
///
/// Everything else that ends a gesture cancels it, and a cancelled gesture
/// stays spent until the fingers lift, so its remains can never start a new
/// snap:
/// - a third finger (the start of Mission Control or a three-finger trigger;
///   until 3.3.0 this committed the snap);
/// - a gap of more than `frameGap` between frames (sleep and wake, a device
///   reset, a lost lift frame), so a stale start position cannot turn the
///   next touch into an instant swipe;
/// - the service giving up on its own (`cancelUntilLift`), e.g. when frames
///   stopped altogether or the Mac went to sleep;
/// - frames from a second trackpad are ignored while the gesture's own
///   trackpad is live.
final class TitleBarSnapRecognizer {
    var engage: Float = 0.05
    var tier2: Float = 0.16
    var ratio: Float = 1.3
    var crossEngage: Float = 0.06
    var crossShare: Float = 0.45
    /// Frames arrive at 60 Hz or more while fingers rest on the pad; a longer
    /// silence means the touch sequence was interrupted.
    var frameGap: Double = 0.25
    /// How often an engaged gesture reports that it is still held.
    var activeInterval: Double = 0.25
    /// Two fingers must have rested this long before a swipe can engage, so
    /// the settling of a touch-down is never read as a swipe.
    var settleTime: Double = 0.04
    /// Fingers that lift within `tapTime` of landing without ever travelling
    /// `tapTravel` made a tap: it cancels instead of snapping (3.3.2: a
    /// two-finger tap on a title bar used to maximize the window).
    var tapTime: Double = 0.18
    var tapTravel: Float = 0.065
    /// A contact whose size falls below this share of its peak is lifting.
    /// Its last positions slide towards the top of the pad, which read as a
    /// swipe up, so those frames never engage or change the stroke.
    var liftShare: Float = 0.55
    /// Swish's hold-still cancel (3.3.2): fingers that stay still for this
    /// long, before or after the swipe engaged, cancel the gesture. The
    /// preview fades out and lifting does nothing. 0 turns it off.
    var holdCancelTime: Double = 2.0
    /// How far (pad units) the centroid or the finger spread may wander and
    /// still count as held still. Resting fingers jitter by about 0.003, but
    /// a resting hand drifts further over 2 s: 0.012 (about 1.2–1.9 mm) let
    /// that drift restart the hold clock (3.3.2 review), so 0.018.
    var stillRadius: Float = 0.018
    /// Swish's tap and hold (3.3.2): fingers resting this long, on the same
    /// still clock as the hold-still cancel, before a swipe or pinch make the
    /// touch a held one for the rest of it; its strokes carry `held`. 0
    /// turns it off. 2 s of stillness still spends the touch.
    var holdTime: Double = 0.45
    /// A pinch needs the fingers to land at least this far apart (pad
    /// units); closer together, a spread ratio means nothing.
    var pinchMinSpread: Float = 0.05
    /// Spread ratios (now ÷ at touch-down) that make a pinch in or out, and
    /// the band the ratio must come back into to let the pinch go again.
    var pinchInRatio: Float = 0.72
    var pinchOutRatio: Float = 1.38
    var pinchRelease: ClosedRange<Float> = 0.85...1.18
    /// Swish's multi-motion engine (3.3.3, audit F01): "you can swipe and
    /// pinch in the same direction multiple times in a row without lifting
    /// your fingers. Just pause your movement briefly and haptic feedback will
    /// let you know when it's time to continue." An engaged swipe or a pinch
    /// whose fingers rest this long is locked in (`onMotionReady`). The next
    /// movement from there commits it (`onCommit` or `onPinch`, as a lift
    /// would) and starts another swipe or pinch from where the fingers paused,
    /// in the same touch. Lifting still commits, a third finger still cancels
    /// the gesture on show, and resting on to `holdCancelTime` still cancels
    /// it; motions already committed stay. 0 turns it off (3.3.2: one gesture
    /// per touch).
    var motionPause: Double = 0.25

    /// Two fingers landed: the service can look up the window under the
    /// pointer now, before the swipe engages (the pointer does not move
    /// while two fingers rest or scroll).
    var onTouchDown: (() -> Void)?
    /// Engaged with a stroke; the service captures the window.
    var onBegin: ((SwishSnap.Stroke) -> Void)?
    /// The stroke changed while engaged; the service moves the preview.
    var onUpdate: ((SwishSnap.Stroke) -> Void)?
    /// Still engaged or pinching, fingers on the pad (at most every
    /// `activeInterval`), with how long they have been held still, in seconds.
    var onActive: ((Double) -> Void)?
    /// The fingers lifted after engaging; commit the current preview.
    var onCommit: (() -> Void)?
    /// The gesture fell apart before committing; hide the preview.
    var onCancel: (() -> Void)?
    /// The fingers were held still for `holdCancelTime` after engaging,
    /// pinching or a tap-and-hold. The gesture is spent until they lift.
    /// Without a handler `onCancel` runs.
    var onHoldCancel: (() -> Void)?
    /// The fingers came together (`.in`) or apart (`.out`) far enough to be
    /// a pinch, or (nil) went back to about where they landed. Only a touch
    /// that never engaged a swipe can pinch, and a pinch never swipes.
    var onPinchChange: ((SwishSnap.Pinch?) -> Void)?
    /// The fingers lifted while pinching.
    var onPinch: ((SwishSnap.Pinch) -> Void)?
    /// A tap (lifted within `tapTime` without travelling `tapTravel`), with
    /// the lift's timestamp. Reported right after the tap's `onCancel`.
    var onTap: ((Double) -> Void)?
    /// The fingers rested `holdTime` before swiping: the touch is held.
    var onHoldBegan: (() -> Void)?
    /// The swipe or pinch on show rested `motionPause`: the next movement
    /// commits it and starts another gesture (Swish answers with a haptic).
    var onMotionReady: (() -> Void)?
    /// The touch that `onTouchDown` reported is over: its fingers lifted, the
    /// stream had a gap, or another trackpad took over. Runs after the
    /// commit, pinch, tap or cancel callbacks of that lift.
    var onTouchEnd: (() -> Void)?
    /// The fingers lifted after a tap and hold that never swiped or pinched
    /// (after its `onCancel`): the tab detach (F02) acts on it.
    var onHoldLift: (() -> Void)?

    /// How many motions the current touch has committed before the one in
    /// progress (0: its first gesture). Only a first gesture can be a tap.
    private(set) var motionIndex = 0

    /// Whether the current touch (or, inside the callbacks of its lift, the
    /// touch that just ended) rested `holdTime` before swiping or pinching.
    /// Reset when the next touch lands.
    private(set) var isHeld = false

    private enum Phase { case idle, tracking, engaged, pinching, spent }
    private var phase: Phase = .idle
    private var startX: Float = 0
    private var startY: Float = 0
    private var axis: SwishSnap.Axis = .horizontal
    private var last: SwishSnap.Stroke?
    /// The trackpad that owns the current gesture; nil while idle.
    private var device: UInt64?
    private var lastFrameAt: Double = 0
    private var lastActiveAt: Double = 0
    private var startedAt: Double = 0
    /// The furthest the centroid has been from the start (pad units).
    private var maxTravel: Float = 0
    /// Peak contact sizes by contact id, for the lift-off guard.
    private var peakID: (Int, Int) = (-1, -1)
    private var peakSize: (Float, Float) = (0, 0)
    /// Where the fingers last moved to, and since when they have been still.
    private var stillX: Float = 0
    private var stillY: Float = 0
    private var stillSpread: Float = 0
    private var stillSince: Double = 0
    /// The finger spread at touch-down, and the pinch on show (nil: released).
    private var startSpread: Float = 0
    private var pinch: SwishSnap.Pinch?
    /// Multi-motion: the gesture on show rested `motionPause` and waits for
    /// the next movement, which is measured from where the fingers paused.
    private var locked = false
    private var pauseX: Float = 0
    private var pauseY: Float = 0
    private var pauseSpread: Float = 0
    /// `onTouchDown` ran for the current touch, so `onTouchEnd` is owed.
    private var touchReported = false
    /// The service asked to start the touch over (`rearm`); applied on the
    /// next two-finger frame.
    private var rearmPending = false

    func feed(contacts: [TouchPoint], timestamp: Double, device: UInt64 = 0) {
        if let owner = self.device {
            if owner != device {
                // Another trackpad: ignore it while the gesture's own is live.
                guard timestamp - lastFrameAt > frameGap else { return }
                abandon()
            } else if timestamp - lastFrameAt > frameGap {
                abandon()
            }
        }
        lastFrameAt = timestamp
        let count = contacts.count
        if rearmPending, count == 2, phase == .tracking || phase == .engaged || phase == .pinching {
            rearmPending = false
            restart(contacts, at: timestamp)
            return
        }
        switch phase {
        case .idle:
            rearmPending = false
            if count >= 3 { phase = .spent; self.device = device; return }
            guard count == 2 else { return }
            phase = .tracking
            self.device = device
            startedAt = timestamp
            maxTravel = 0
            isHeld = false
            pinch = nil
            locked = false
            motionIndex = 0
            peakID = (contacts[0].id, contacts[1].id)
            peakSize = (contacts[0].size, contacts[1].size)
            (startX, startY) = Self.centroid(contacts)
            startSpread = Self.spread(contacts)
            (stillX, stillY, stillSpread) = (startX, startY, startSpread)
            stillSince = timestamp
            touchReported = true
            onTouchDown?()
        case .tracking:
            guard count == 2 else {
                // Lifted soon after landing without travelling: a tap. A
                // third finger is never one.
                let tap = count <= 1 && isTap(at: timestamp)
                let heldLift = count <= 1 && isHeld && motionIndex == 0
                onCancel?()
                if count >= 3 { phase = .spent } else { endTouch() }
                if tap { onTap?(timestamp) }
                if heldLift { onHoldLift?() }
                if count <= 1 { touchEnded() }
                return
            }
            guard !isLifting(contacts) else { return }
            let (cx, cy) = Self.centroid(contacts)
            let spread = Self.spread(contacts)
            let still = stillTime(cx, cy, spread, at: timestamp)
            // Resting on the title bar without swiping: after the hold time
            // nothing this touch does can act any more. A tap-and-hold that
            // never swiped is told, so the service can drop what it showed.
            if holdCancelTime > 0, still >= holdCancelTime {
                phase = .spent
                if isHeld { holdCancelled() }
                return
            }
            if !isHeld, holdTime > 0, still >= holdTime {
                isHeld = true
                onHoldBegan?()
            }
            let dx = cx - startX, dy = cy - startY
            let travel = (dx * dx + dy * dy).squareRoot()
            maxTravel = max(maxTravel, travel)
            guard timestamp - startedAt >= settleTime else { return }
            if let kind = pinchKind(from: startSpread, spread: spread, travel: travel) {
                phase = .pinching
                pinch = kind
                lastActiveAt = timestamp
                restartPauseClock(cx, cy, spread, at: timestamp)
                onPinchChange?(kind)
                return
            }
            guard let stroke = engagedStroke(dx: dx, dy: dy) else { return }
            phase = .engaged
            axis = stroke.direction.axis
            last = stroke
            lastActiveAt = timestamp
            restartPauseClock(cx, cy, spread, at: timestamp)
            onBegin?(stroke)
        case .engaged:
            if count <= 1 {
                let tap = isTap(at: timestamp)
                endTouch()
                if tap { onCancel?(); onTap?(timestamp) } else { onCommit?() }
                touchEnded()
                return
            }
            if count >= 3 { phase = .spent; locked = false; onCancel?(); return }
            // Two fingers are still down: this frame is activity, whether or
            // not the stroke changed.
            reportActivity(at: timestamp)
            guard !isLifting(contacts) else { return }
            let (cx, cy) = Self.centroid(contacts)
            let spread = Self.spread(contacts)
            // Swish: holding the fingers still cancels the snap on show.
            let still = stillTime(cx, cy, spread, at: timestamp)
            if holdCancelTime > 0, still >= holdCancelTime {
                phase = .spent
                locked = false
                holdCancelled()
                return
            }
            if locked { continueMotion(cx, cy, spread, at: timestamp); return }
            if motionPause > 0, last != nil, pauseTime(cx, cy, spread, at: timestamp) >= motionPause {
                lock(cx, cy, spread); return
            }
            let dx = cx - startX, dy = cy - startY
            maxTravel = max(maxTravel, (dx * dx + dy * dy).squareRoot())
            guard var stroke = SwishSnap.refine(dx: dx, dy: dy, axis: axis, previous: last,
                                                engage: engage, tier2: tier2, ratio: ratio,
                                                crossEngage: crossEngage, crossShare: crossShare) else { return }
            stroke.held = isHeld
            axis = stroke.direction.axis
            if stroke != last {
                last = stroke
                onUpdate?(stroke)
            }
        case .pinching:
            if count <= 1 {
                let kind = pinch
                endTouch()
                if let kind { onPinch?(kind) } else { onCancel?() }
                touchEnded()
                return
            }
            if count >= 3 { phase = .spent; locked = false; onCancel?(); return }
            reportActivity(at: timestamp)
            guard !isLifting(contacts) else { return }
            let (cx, cy) = Self.centroid(contacts)
            let spread = Self.spread(contacts)
            let still = stillTime(cx, cy, spread, at: timestamp)
            if holdCancelTime > 0, still >= holdCancelTime {
                phase = .spent
                locked = false
                holdCancelled()
                return
            }
            if locked { continueMotion(cx, cy, spread, at: timestamp); return }
            if motionPause > 0, pinch != nil, pauseTime(cx, cy, spread, at: timestamp) >= motionPause {
                lock(cx, cy, spread); return
            }
            // Hysteresis: a pinch in holds until the fingers are back near
            // where they landed, and the same for a pinch out.
            let ratio = spread / startSpread
            var next = pinch
            if ratio <= pinchInRatio { next = .in }
            else if ratio >= pinchOutRatio { next = .out }
            else if pinchRelease.contains(ratio) { next = nil }
            if next != pinch {
                pinch = next
                onPinchChange?(next)
            }
        case .spent:
            if count <= 1 { endTouch(); touchEnded() }
        }
    }

    /// The stroke a movement of (dx, dy) from the start engages, or nil: a
    /// diagonal goes straight into its quarter; otherwise the dominant axis,
    /// once it is clear enough.
    private func engagedStroke(dx: Float, dy: Float) -> SwishSnap.Stroke? {
        var stroke: SwishSnap.Stroke
        if let diagonal = SwishSnap.diagonal(dx: dx, dy: dy, engage: engage) {
            stroke = diagonal
        } else if let direction = SwishSnap.direction(dx: dx, dy: dy, engage: engage, ratio: ratio) {
            stroke = SwishSnap.Stroke(direction)
        } else { return nil }
        stroke.tier = SwishSnap.tier(dx: dx, dy: dy, tier2: tier2)
        stroke.held = isHeld
        return stroke
    }

    /// Multi-motion: the gesture on show rested `motionPause`. It stays what
    /// it is; the next movement is measured from here.
    private func lock(_ cx: Float, _ cy: Float, _ spread: Float) {
        locked = true
        (pauseX, pauseY, pauseSpread) = (cx, cy, spread)
        onMotionReady?()
    }

    /// Multi-motion: a locked gesture and fingers on the move again. Once
    /// they pinch or swipe from where they paused (the same thresholds as a
    /// new touch, no settle or tap: the touch is long past both), the locked
    /// gesture commits and the new one begins from the pause point.
    private func continueMotion(_ cx: Float, _ cy: Float, _ spread: Float, at timestamp: Double) {
        let dx = cx - pauseX, dy = cy - pauseY
        let travel = (dx * dx + dy * dy).squareRoot()
        if let kind = pinchKind(from: pauseSpread, spread: spread, travel: travel) {
            commitLocked()
            phase = .pinching
            startSpread = pauseSpread
            (startX, startY) = (pauseX, pauseY)
            pinch = kind
            last = nil
            lastActiveAt = timestamp
            restartPauseClock(cx, cy, spread, at: timestamp)
            onPinchChange?(kind)
            return
        }
        guard let stroke = engagedStroke(dx: dx, dy: dy) else { return }
        commitLocked()
        phase = .engaged
        (startX, startY) = (pauseX, pauseY)
        startSpread = pauseSpread
        pinch = nil
        axis = stroke.direction.axis
        last = stroke
        lastActiveAt = timestamp
        restartPauseClock(cx, cy, spread, at: timestamp)
        onBegin?(stroke)
    }

    /// Commits the locked gesture as its lift would have.
    private func commitLocked() {
        locked = false
        motionIndex += 1
        switch phase {
        case .engaged:
            onCommit?()
        case .pinching:
            if let kind = pinch { onPinch?(kind) }
        default:
            break
        }
    }

    /// The service handed this touch to another window (`beginChain`) or the
    /// tab it detached: whatever the fingers do next starts a new gesture from
    /// where they are, as a further motion of the touch (never a tap, never
    /// held). Applied on the next two-finger frame; only a live touch (not a
    /// spent one) is restarted. No callbacks.
    func rearm() { rearmPending = true }

    private func restart(_ contacts: [TouchPoint], at timestamp: Double) {
        phase = .tracking
        locked = false
        isHeld = false
        pinch = nil
        last = nil
        axis = .horizontal
        motionIndex += 1
        maxTravel = 0
        startedAt = timestamp - settleTime
        (startX, startY) = Self.centroid(contacts)
        startSpread = Self.spread(contacts)
        (stillX, stillY, stillSpread) = (startX, startY, startSpread)
        stillSince = timestamp
        lastActiveAt = timestamp
        restartPauseClock(startX, startY, startSpread, at: timestamp)
    }


    /// A lift soon after landing that never travelled `tapTravel` is a tap.
    /// Once a swipe has engaged (its preview is up) a lift is a tap only if
    /// the fingers moved less than `min(tapTravel, engagedTapShare × engage)`
    /// (3.3.2 review): under `tapTravel` alone, every quick flick between the
    /// engage distance (4 % of the pad at "Quick", 3.1 % at "Instant") and
    /// 6.5 % flashed a preview and then did nothing, which read as "the snap
    /// reacts slowly". The lift-slide behind 3.3.1's "a tap maximizes" is
    /// stopped by `liftShare`, the touch-down settle by `settleTime`.
    private func isTap(at timestamp: Double) -> Bool {
        // A further motion of a touch (multi-motion, a re-armed touch) is long past a tap.
        guard motionIndex == 0 else { return false }
        let travel = phase == .engaged ? min(tapTravel, Self.engagedTapShare * engage) : tapTravel
        return timestamp - startedAt < tapTime && maxTravel < travel
    }

    /// The share of the engage distance an engaged swipe's lift may have
    /// travelled and still count as a tap.
    static let engagedTapShare: Float = 0.6

    private func reportActivity(at timestamp: Double) {
        guard timestamp - lastActiveAt >= activeInterval else { return }
        lastActiveAt = timestamp
        onActive?(timestamp - stillSince)
    }

    private func holdCancelled() {
        if let onHoldCancel { onHoldCancel() } else { onCancel?() }
    }

    /// A pinch: fingers that were apart enough at `base` (touch-down, or
    /// where a multi-motion paused), whose spread changed past a pinch ratio
    /// and by more than their centroid travelled (a swipe moves the centroid;
    /// a pinch mostly changes the spread).
    private func pinchKind(from base: Float, spread: Float, travel: Float) -> SwishSnap.Pinch? {
        guard base > pinchMinSpread, abs(spread - base) > travel else { return nil }
        let ratio = spread / base
        if ratio <= pinchInRatio { return .in }
        if ratio >= pinchOutRatio { return .out }
        return nil
    }

    /// Tracks each contact's peak size; true while either contact has shrunk
    /// below `liftShare` of it (the finger is coming off the pad). Contacts
    /// that report no size (0) never count as lifting.
    private func isLifting(_ contacts: [TouchPoint]) -> Bool {
        var lifting = false
        for contact in contacts.prefix(2) {
            if contact.id == peakID.0 {
                peakSize.0 = max(peakSize.0, contact.size)
                if peakSize.0 > 0, contact.size < peakSize.0 * liftShare { lifting = true }
            } else if contact.id == peakID.1 {
                peakSize.1 = max(peakSize.1, contact.size)
                if peakSize.1 > 0, contact.size < peakSize.1 * liftShare { lifting = true }
            }
        }
        return lifting
    }

    /// Follows the fingers for the hold gestures: any move of the centroid or
    /// the spread beyond `stillRadius` restarts the clock. Returns how long
    /// they have stayed put (`holdTime` holds the touch, `holdCancelTime`
    /// cancels it).
    private func stillTime(_ cx: Float, _ cy: Float, _ spread: Float, at timestamp: Double) -> Double {
        let wx = cx - stillX, wy = cy - stillY
        if (wx * wx + wy * wy).squareRoot() > stillRadius || abs(spread - stillSpread) > stillRadius {
            (stillX, stillY, stillSpread) = (cx, cy, spread)
            stillSince = timestamp
            return 0
        }
        return timestamp - stillSince
    }

    /// How far (pad units) the fingers may move and still count as the
    /// multi-motion pause. Tighter than `stillRadius`, which allows for a
    /// resting hand drifting over 2 s: a slow swipe moving less than that in
    /// `motionPause` must not lock half-way.
    var pauseRadius: Float = 0.008
    private var pauseAnchorX: Float = 0
    private var pauseAnchorY: Float = 0
    private var pauseAnchorSpread: Float = 0
    private var pauseSince: Double = 0

    /// The multi-motion clock: how long the fingers have stayed within
    /// `pauseRadius` (centroid and spread).
    private func pauseTime(_ cx: Float, _ cy: Float, _ spread: Float, at timestamp: Double) -> Double {
        let wx = cx - pauseAnchorX, wy = cy - pauseAnchorY
        if (wx * wx + wy * wy).squareRoot() > pauseRadius || abs(spread - pauseAnchorSpread) > pauseRadius {
            restartPauseClock(cx, cy, spread, at: timestamp)
            return 0
        }
        return timestamp - pauseSince
    }

    private func restartPauseClock(_ cx: Float, _ cy: Float, _ spread: Float, at timestamp: Double) {
        (pauseAnchorX, pauseAnchorY, pauseAnchorSpread) = (cx, cy, spread)
        pauseSince = timestamp
    }

    /// Silently forgets any gesture in progress (the service is already
    /// hiding its preview, e.g. because the feature or AOM was turned off).
    func reset() { clear(); touchReported = false; rearmPending = false }

    /// The service has already cancelled (its watchdog fired, or the Mac is
    /// going to sleep): end the gesture without callbacks and ignore the
    /// fingers until they lift, so the remains cannot start a new snap.
    func cancelUntilLift() {
        if phase == .tracking || phase == .engaged || phase == .pinching { phase = .spent; locked = false }
    }

    /// Ends an interrupted gesture, telling the service if it had begun.
    private func abandon() {
        if phase == .tracking || phase == .engaged || phase == .pinching { onCancel?() }
        clear()
        touchEnded()
    }

    private func clear() {
        phase = .idle; device = nil; last = nil; axis = .horizontal; pinch = nil; locked = false
    }

    /// The touch's fingers lifted: back to idle (callbacks follow).
    private func endTouch() { clear() }

    /// Reports the end of a touch that `onTouchDown` announced, once.
    private func touchEnded() {
        guard touchReported else { return }
        touchReported = false
        onTouchEnd?()
    }

    /// The centroid in the pad coordinates `SwishSnap` works in: x grows to
    /// the right and y toward the BOTTOM of the pad, like the screen, so dy > 0
    /// is a swipe down. TouchPoint's y grows toward the top of the pad (the
    /// MultitouchSupport and NSTouch convention, which `LiveTouchView`, the
    /// gesture engine and `GestureReplaySuite` all use: a swipe up is +y), so
    /// it is flipped here. Until 3.3.2 it was not, and every vertical title-bar
    /// swipe ran the other way on a real trackpad: a swipe down maximized or
    /// went to the top quarter, so a window at the top never reached a bottom
    /// quarter, and a swipe up centred or minimized it.
    private static func centroid(_ contacts: [TouchPoint]) -> (Float, Float) {
        ((contacts[0].x + contacts[1].x) / 2, 1 - (contacts[0].y + contacts[1].y) / 2)
    }

    private static func spread(_ contacts: [TouchPoint]) -> Float {
        let dx = contacts[0].x - contacts[1].x, dy = contacts[0].y - contacts[1].y
        return (dx * dx + dy * dy).squareRoot()
    }
}

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
    /// unsnap all windows"). Read-only: the history stays private.
    @MainActor
    func unsnapFrame(for target: WindowManager.Target, current: CGRect) -> CGRect? {
        history.restoreFrame(key: Self.key(target), current: current)
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
        return Capture(mouse: NSEvent.mouseLocation, window: target, frame: frame, at: now)
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
        startPlace = history.place(key: Self.key(capture.window), current: capture.frame)
            ?? SwishSnap.place(of: capture.frame, visible: area, margin: margin,
                               grid: options.grid, almost: options.almostMaximize)
        // Bounded (3.3.2 review): this runs on main as the swipe engages.
        fullscreen = Self.boundedIsFullscreen(capture.window)
        repeating = pending.flatMap { $0.target.pid == capture.window.pid ? $0.action : nil }
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
            armPending(after: Self.repeatWindow + 0.15)
        }
    }

    /// The window whose title bar (or toolbar) is under the pointer, or nil.
    /// 3.3.2 review: the Accessibility hit-test goes to the window's owner,
    /// the PID the window server reports for it, never to the system-wide
    /// element; each request is bounded to 0.25 s and the walk to 0.3 s, and
    /// the frame read to 0.25 s, since this runs on main as two fingers land.
    @MainActor
    private func captureTitleBar(at mouse: CGPoint) -> Capture? {
        let pointerTopLeft = CGPoint(x: mouse.x, y: primaryTop - mouse.y)
        // F04 (3.3.3): with "anywhere" on, the Super modifier held as the
        // fingers land lets the gesture start anywhere on the window.
        let anywhere = Self.superAnywhereOn()
            && SwishSnap.ModifierRoles.load(.standard).held(NSEvent.modifierFlags).contains(.superKey)
        // Window-server pre-filter: an ordinary (layer 0) window of another
        // app, with the pointer in its top band (title bar, toolbar, tab bar).
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        guard number > 0, !NSApp.windows.contains(where: { $0.windowNumber == number }),
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first,
              (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
              let owner = info[kCGWindowOwnerPID as String] as? pid_t,
              owner > 0, owner != ProcessInfo.processInfo.processIdentifier,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              SwishSnap.inPreFilterBand(pointerY: pointerTopLeft.y, windowTop: bounds.minY, anywhere: anywhere) else { return nil }
        guard let hit = WindowManager.shared.titleBarHit(atMousePoint: mouse, pid: owner, anywhere: anywhere),
              hit.target.pid != ProcessInfo.processInfo.processIdentifier,
              let frame = Self.boundedFrame(of: hit.target),
              SwishSnap.isStartArea(onTitleBar: hit.onTitleBar, onTabBar: hit.onTabBar,
                                    inTitleBand: SwishSnap.titleBarHit(pointerTopLeft: pointerTopLeft, windowFrame: frame),
                                    anywhere: anywhere) else { return nil }
        let tab = Self.tabGesturesOn() ? hit.tab : nil
        return Capture(mouse: mouse, window: hit.target, frame: frame, at: ProcessInfo.processInfo.systemUptime, tab: tab)
    }

    @MainActor
    private func update(_ stroke: SwishSnap.Stroke) {
        // A swipe that began while the last commit was landing keeps its latest stroke.
        if committing { chain.updated(stroke); return }
        guard target != nil, !pinching else { return }
        scheduleTimeout()
        showPreview(for: stroke, zoneHaptic: true)
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
        tooltipDirection = stroke.direction
        present(next)
    }

    /// The swipe moves the window on from the place it sits in (Swish-style
    /// chaining, `SwishSnap.move(at:…)`) or acts on it (minimize, close, quit,
    /// full screen, Spaces, displays). Nil: the swipe does nothing (a
    /// full-screen window swiped without tap-and-hold).
    @MainActor
    private func plan(for stroke: SwishSnap.Stroke, target: WindowManager.Target,
                      visible: CGRect, start: CGRect) -> Plan? {
        guard let move = SwishSnap.move(at: startPlace, stroke: stroke, modifiers: modifiers,
                                        options: gestureOptionsNow(), fullscreen: fullscreen) else { return nil }
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
    /// or centres a window AOM has no frame for.
    @MainActor
    private func restorePlan(target: WindowManager.Target, visible: CGRect, start: CGRect) -> Plan {
        if let original = history.restoreFrame(key: Self.key(target), current: start) {
            return Plan(place: nil, rect: original)
        }
        return Plan(place: .center, rect: SwishSnap.targetFrame(place: .center, visible: visible, margin: margin))
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
    @MainActor
    private func commitFrame(_ rect: CGRect, target: WindowManager.Target, anchorVisible visible: CGRect,
                             start: CGRect, restoring: Bool, place: SwishSnap.Place?) {
        committing = true
        let key = Self.key(target)
        // Anchor inside the margin-inset area, so a gap the user asked for is
        // kept when an app refuses the cell's size.
        let anchorArea = margin > 0 ? visible.insetBy(dx: margin, dy: margin) : visible
        WindowManager.shared.applySnap(rect, target: target, visible: restoring ? nil : anchorArea) { actual in
            // `applySnap` reports on the main thread (its settle polling runs there).
            MainActor.assumeIsolated {
                TitleBarWindowSnap.shared.finishCommit(actual, target: target, key: key,
                                                       start: start, restoring: restoring, place: place)
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
        NativeTiling.tile(target, key: key, mayContinue: {
            TitleBarWindowSnap.shared.allowedNow && !Self.appPaused(target.pid)
        }) { pressed in
            let service = TitleBarWindowSnap.shared
            guard pressed else {
                guard service.allowedNow, !Self.appPaused(target.pid) else {
                    service.finishCommit(nil, target: target, key: windowKey, start: start, restoring: false, place: place)
                    return
                }
                service.commitFrame(rect, target: target, anchorVisible: visible, start: start, restoring: false, place: place)
                return
            }
            // macOS animates the tile; read where the window landed once it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated {
                    let actual = Self.boundedFrame(of: target) ?? rect
                    TitleBarWindowSnap.shared.finishCommit(actual, target: target, key: windowKey, start: start,
                                                           restoring: false, place: place)
                }
            }
        }
    }

    @MainActor
    private func finishCommit(_ actual: CGRect?, target: WindowManager.Target, key: String,
                              start: CGRect, restoring: Bool, place: SwishSnap.Place?) {
        committing = false
        let fromKeyboard = keyboardCommit
        keyboardCommit = false
        // A swipe that engaged meanwhile carries on with this window (3.3.2 review).
        let chained = chain.landed(succeeded: actual != nil)
        guard let actual else { hideOwnPreview(); reset(); return }
        if restoring {
            forgetSnap(key)
        } else {
            history.recordSnap(key: key, from: start, to: actual, place: place)
            remember(target, key: key)
        }
        if hapticsOn { _ = GestureHaptics.shared.feedback(enabled: true) }
        overlay.settle(on: SwishSnap.appKitRect(actual, primaryTop: primaryTop))
        if Self.flag(Self.activateKey, default: true) { bringForward(target) }
        if Self.flag(Self.keepPointerKey, default: false), !fromKeyboard {
            CGWarpMouseCursorPosition(SwishSnap.titleBarRestPoint(for: actual))
            // A warp briefly suppresses local mouse events; re-associate so
            // the pointer moves again immediately.
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        reset()
        if let chained { resumeChain(chained, target: target, frame: actual) }
    }

    /// The swipe that engaged while the last commit was landing (3.3.2
    /// review): it carries on with the window that just moved, from the place
    /// it moved to, as if it had begun now. Lifted already, it commits at
    /// once; still on the pad, its preview follows the fingers as usual.
    @MainActor
    private func resumeChain(_ queued: SwishChainQueue.Pending, target: WindowManager.Target, frame: CGRect) {
        guard active, allowedNow else { return }
        let capture = Capture(mouse: NSEvent.mouseLocation, window: target, frame: frame,
                              at: ProcessInfo.processInfo.systemUptime)
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

    /// The direction of the swipe on show, for the tooltip's arrow.
    @MainActor private var tooltipDirection: SwishSnap.Direction?

    @MainActor
    private func hideTooltip() {
        if SwishGestureTooltip.shared.isShowing { SwishGestureTooltip.shared.hide(speed: Self.animationSpeed()) }
    }

    @MainActor
    private func reset() {
        target = nil; targetVisible = nil; startFrame = nil; startPlace = nil; plan = nil; targetTab = nil
        modifiers = []; fullscreen = false; pinching = false; repeating = nil; shownAction = nil; heldRoles = []
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
        let decision = SwishSnap.pinchAction(kind, second: second, held: recognizer.isHeld && options.holdGestures,
                                             modifiers: options.modifierGestures ? modifiers : [],
                                             displays: WindowManager.shared.screens().count)
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
        SwishTabs.detach(tab: held.tab, window: held.target.window, pid: pid,
                         mayContinue: { TitleBarWindowSnap.shared.allowedNow && !Self.appPaused(pid) }) { detached in
            guard let detached else { return }
            _ = TitleBarWindowSnap.shared.beginChain(window: detached.window, pid: detached.pid, reason: "detached tab")
        }
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
        guard active, target != nil || committing, hapticsOn else { return }
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
        armPending(after: Self.repeatWindow)
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
    /// would otherwise land in place but stay hidden behind others.
    @MainActor
    private func bringForward(_ target: WindowManager.Target) {
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

// MARK: - Preview overlay

/// The translucent rounded rectangle shown while swiping, in a borderless,
/// non-activating, click-through window at a floating level — the mechanism
/// Swish uses for its snapping preview. Frame changes animate briefly, and not
/// at all under Reduce Motion (the preview then jumps and fades).
@MainActor
final class SnapPreviewOverlay {
    private var panel: NSPanel?
    private let view = SnapPreviewView()
    /// Bumped by every `show()`. Fade completions from an earlier gesture
    /// check it, so a swipe that starts while the last snap is still fading
    /// keeps its own preview.
    private var generation = 0
    /// Whether the current gesture has put a preview on screen.
    private(set) var isShowing = false

    func show(frame: CGRect, restoring: Bool = false) {
        generation += 1
        isShowing = true
        let panel = self.panel ?? makePanel()
        self.panel = panel
        view.setStyle(committed: false, restoring: restoring)
        if panel.frame == .zero || !panel.isVisible {
            panel.setFrame(frame, display: true)
            // Short enough that the preview is there as the swipe engages
            // (3.3.2: 0.12 s and 0.14 s felt sluggish).
            let fade = duration(0.08, movesFrame: false)
            panel.alphaValue = fade > 0 ? 0 : 1
            panel.orderFrontRegardless()
            guard fade > 0 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fade
                panel.animator().alphaValue = 1
            }
            return
        }
        let move = duration(0.1, movesFrame: true)
        guard move > 0 else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = move
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Swish animates its preview to the frame the window really took
    /// (`setFrame:display:animate:` after reading `AXFrame` back), then hides
    /// it; a size-limited window therefore shows where it actually landed.
    func settle(on frame: CGRect) {
        guard let panel, panel.isVisible else { return }
        isShowing = false
        let started = generation
        view.setStyle(committed: true, restoring: false)
        let fadeTime = duration(0.16, movesFrame: false)
        let fade = { [weak self] in
            guard let self, self.generation == started else { return }
            guard fadeTime > 0 else {
                self.view.setStyle(committed: false, restoring: false)
                self.panel?.orderOut(nil)
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = fadeTime
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.generation == started else { return }
                self.view.setStyle(committed: false, restoring: false)
                self.panel?.orderOut(nil)
            })
        }
        let move = duration(0.12, movesFrame: true)
        guard move > 0, !WindowGeometry.close(panel.frame, frame) else {
            panel.setFrame(frame, display: true)
            fade()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = move
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { fade() })
    }

    func hide() {
        isShowing = false
        guard let panel, panel.isVisible else { return }
        let started = generation
        let fade = duration(0.1, movesFrame: false)
        guard fade > 0 else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == started else { return }
            self.panel?.orderOut(nil)
        })
    }

    /// Fades a held preview towards the hold-still cancel: 0 is fully shown,
    /// 1 the faintest it gets before it goes. Moving again restores it.
    func dim(_ amount: CGFloat) {
        guard isShowing, let panel, panel.isVisible else { return }
        let alpha = 1 - 0.7 * min(max(amount, 0), 1)
        guard abs(panel.alphaValue - alpha) > 0.01 else { return }
        let time = AOMDesign.reduceMotion ? 0 : duration(0.2, movesFrame: false)
        guard time > 0 else { panel.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = time
            panel.animator().alphaValue = alpha
        }
    }

    /// Swish's "tooltipAnimationTime" (3.3.2): Fast halves every duration,
    /// Off shows and hides the preview at once; Reduce Motion still keeps the
    /// frame from sliding.
    private func duration(_ base: Double, movesFrame: Bool) -> Double {
        SwishSnap.animationDuration(base, speed: TitleBarWindowSnap.animationSpeed(),
                                    reduceMotion: AOMDesign.reduceMotion, movesFrame: movesFrame)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityElement(false)
        panel.contentView = view
        return panel
    }
}

/// A rounded accent rectangle: the fill deepens on commit, and a restore of
/// the pre-snap frame draws a dashed outline so it reads as "put it back"
/// rather than another snap. Increase Contrast and Reduce Transparency get a
/// stronger fill and a solid edge.
private final class SnapPreviewView: NSView {
    private var committed = false
    private var restoring = false
    private let outline = CAShapeLayer()

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.fillColor = nil
        layer?.addSublayer(outline)
    }

    required init?(coder: NSCoder) { nil }

    func setStyle(committed: Bool, restoring: Bool) {
        guard committed != self.committed || restoring != self.restoring else { return }
        self.committed = committed
        self.restoring = restoring
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateOutlinePath()
    }

    private func updateOutlinePath() {
        let inset = bounds.insetBy(dx: 1, dy: 1)
        outline.frame = bounds
        outline.path = CGPath(roundedRect: inset, cornerWidth: 12, cornerHeight: 12, transform: nil)
    }

    override func updateLayer() {
        guard let layer else { return }
        let workspace = NSWorkspace.shared
        let strong = workspace.accessibilityDisplayShouldIncreaseContrast
            || workspace.accessibilityDisplayShouldReduceTransparency
        let accent = NSColor.controlAccentColor
        let base: CGFloat = restoring ? 0.12 : 0.20
        layer.backgroundColor = accent.withAlphaComponent(committed ? 0.34 : (strong ? base + 0.12 : base)).cgColor
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        updateOutlinePath()
        outline.strokeColor = accent.withAlphaComponent(strong ? 1 : 0.95).cgColor
        outline.lineWidth = strong ? 3 : 2
        outline.lineDashPattern = restoring ? [7, 5] : nil
    }
}
