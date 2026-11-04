import AppKit

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
    /// (horizontal). Up is maximize and down the centre at any length (N334,
    /// N335): a longer swipe up or down used to read as the top or bottom
    /// half, which a quick or long swipe reached before the move it was meant
    /// for. N337: no title-bar swipe reaches those halves any more.
    static func layout(for direction: Direction, tier: Int) -> CustomSnapZone.Layout {
        switch (direction, tier >= 2) {
        case (.left, false): return .leftHalf
        case (.left, true): return .leftThird
        case (.right, false): return .rightHalf
        case (.right, true): return .rightThird
        case (.up, _): return .maximize
        case (.down, _): return .center
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
    ///
    /// N338, the vertical leg of an L that began sideways: `turn` is the
    /// vertical travel since the sideways leg stopped (the recognizer's
    /// `turn(dy:)`, 0 for none and for a vertical stroke). Past `crossEngage`
    /// it is the cross leg on its own, that way, however long the sideways
    /// leg was and wherever it drifted (a long left then a short up was the
    /// left half: the 45 % share is there for the arc of a straight swipe,
    /// which never moves mostly vertically). While it lasts, the corner keeps
    /// the side it turned from: an up leg drifting back over the start used
    /// to re-pick the axis as a plain up and maximize.
    static func refine(dx: Float, dy: Float, axis: Axis, previous: Stroke?,
                       engage: Float, tier2: Float, ratio: Float,
                       crossEngage: Float = 0.06, crossShare: Float = 0.45, turn: Float = 0) -> Stroke? {
        let primary = axis == .horizontal ? dx : dy
        let other = axis == .horizontal ? dy : dx
        let held = previous?.cross != nil && previous?.direction.axis == axis
        let turn = axis == .horizontal ? turn : 0
        let direction: Direction
        if held, turn != 0, let previous {
            direction = previous.direction
        } else {
            if abs(primary) < engage * 0.5 {
                guard let fresh = Self.direction(dx: dx, dy: dy, engage: engage, ratio: ratio),
                      fresh.axis != axis else { return nil }
                return Stroke(fresh, tier: tier(dx: dx, dy: dy, tier2: tier2))
            }
            direction = axis == .horizontal
                ? (primary < 0 ? .left : .right)
                : (primary > 0 ? .down : .up)
        }
        let share = held ? Float(0.6) : 1
        let needed = max(crossEngage, abs(primary) * crossShare) * share
        var cross: Direction?
        if abs(turn) >= crossEngage * share {
            cross = turn > 0 ? .down : .up
        } else if abs(other) >= needed {
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

    /// Pure (3.4.12): whether an Accessibility frame is the window the window
    /// server reported under the pointer. Both are top-left coordinates; the
    /// window server rounds its bounds to whole points, so `tolerance` covers
    /// that rounding and nothing else. A background app can answer its own
    /// hit-test with the window it last had in front, and a close or a quit
    /// must never land on a window the pointer is not on, so nothing is done
    /// to a window whose frame is not this one.
    static func sameWindow(accessibilityFrame: CGRect, windowServerBounds: CGRect,
                           tolerance: CGFloat = 1) -> Bool {
        guard accessibilityFrame.width > 0, accessibilityFrame.height > 0,
              windowServerBounds.width > 0, windowServerBounds.height > 0 else { return false }
        return abs(accessibilityFrame.minX - windowServerBounds.minX) <= tolerance
            && abs(accessibilityFrame.minY - windowServerBounds.minY) <= tolerance
            && abs(accessibilityFrame.width - windowServerBounds.width) <= tolerance
            && abs(accessibilityFrame.height - windowServerBounds.height) <= tolerance
    }

    /// The apps a title-bar gesture never acts on (3.4.12), whatever the
    /// window under the pointer looks like: the Dock and Stage Manager (their
    /// "windows" are icons and thumbnails, which have gestures of their own
    /// and are handed to the snap by `beginChain`, never captured here), the
    /// menu bar's hosts, and the login window. AOM's own bundle IDs count as
    /// protected too, so no gesture can move, close or quit AOM itself.
    static let protectedGestureBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.systemuiserver", "com.apple.notificationcenterui", "com.apple.loginwindow",
    ]

    /// Pure: whether the app with `bundleID` is one no title-bar gesture may
    /// act on. A nil bundle ID (a process with no bundle) is not protected
    /// here; `forceQuit` asks for the bundle separately, since force
    /// termination is only ever allowed for an app AOM can name.
    static func isProtectedGestureApp(bundleID: String?, own: Set<String> = FocusIdlePolicy.aomBundleIDs) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return own.contains(bundleID) || protectedGestureBundleIDs.contains(bundleID)
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
                     thirds: Bool = true, overflowing: Bool = true) -> CustomSnapZone.Layout? {
        let candidates = recognisedCells.filter { thirds || !isThird($0) }
        if let exact = candidates.first(where: { layout in
            let rect = targetFrame(layout: layout, visible: visible, margin: margin)
            return abs(rect.minX - frame.minX) <= tolerance && abs(rect.minY - frame.minY) <= tolerance
                && abs(rect.maxX - frame.maxX) <= tolerance && abs(rect.maxY - frame.maxY) <= tolerance
        }) { return exact }
        // `overflowing` false (N334, a swipe up): only a cell the frame fills.
        guard overflowing else { return nil }
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
    /// - Up maximizes from everywhere (N337).
    /// - From a half, the other axis halves it again: left half + down →
    ///   bottom-left quarter, top half + right → top-right quarter.
    /// - From a quarter, a swipe toward the other row or column moves it
    ///   there (top-left + down → bottom-left, bottom-left + right →
    ///   bottom-right); sideways toward the edge it already touches it grows
    ///   to that half (top-left + left → left half).
    /// - Maximized, or on the bottom edge (a bottom quarter, the bottom half),
    ///   a swipe down puts the window back; so does the top half swiped down
    ///   (N337: never the bottom half).
    /// - Thirds only when `thirds` is on: a longer swipe on a free window, and
    ///   swipes toward an edge that step half → third → two thirds → half;
    ///   a third swiped down becomes its lower sixth.
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
        /// 3.4.12: two quick pinches in terminate the app outright (the user's
        /// explicit rule), where `quitApp` stays the polite Quit of a
        /// tap-and-hold pinch. Only a window the Accessibility hit-test
        /// confirmed, of an app AOM may quit, ever reaches this.
        case forceQuitApp
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
        case .minimize, .quitApp, .forceQuitApp, .hideApp, .hideOthers, .screen, .fullscreenOnOtherScreen,
             .detachTab: return false
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
    ///   except that a swipe down on a free-floating or centred window
    ///   minimizes it ("Swipe down once to minimize a window") while
    ///   `downAction` is `.minimize`, at any length (N335).
    /// - N337 (the user's rule over Swish's "Double-swipe vertically to snap
    ///   to the top or bottom half of the screen"): no double swipe. A plain
    ///   swipe up maximizes from every place, as the first motion of a touch,
    ///   a later one, or a new touch right after another swipe; nothing here
    ///   produces the top or bottom half (`step`). 3.3.4–3.3.6 took them with
    ///   a second swipe up or down, in the same touch or within 0.5 s.
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
        // third while thirds are off), is free-floating too. A swipe down
        // minimizes it at any length (N335).
        let free = current.map { $0 == .center || !usable($0, grid: grid, almost: almost) } ?? true
        if free, direction == .down, stroke.cross == nil { return .action(.minimize) }
        return step(from: free ? nil : current, stroke: stroke, grid: grid, almost: almost)
    }

    /// Pure (N338): whether a sideways swipe that rested may turn its corner
    /// into an L in the same touch (`TitleBarSnapRecognizer.cornerTurns`):
    /// not while ⌥ or ⌘ make it a Space or display move, which commits
    /// before the next motion as before (⌥ left, rest, up: a Space, then a
    /// plain up). ⇧ turns it like no modifier: the corner wins over almost
    /// maximize, as in a continuous ⇧ L or diagonal.
    static func cornerTurns(modifiers: Modifiers, options: GestureOptions) -> Bool {
        guard options.modifierGestures else { return true }
        return !modifiers.contains(.general) && !modifiers.contains(.screen)
    }

    /// What a finished pinch does, and whether it first waits for a second
    /// pinch of the same kind. `second`: it follows such a pinch on the same
    /// app within the twice window.
    /// - In closes the window, after waiting: a second pinch in quits the app
    ///   instead ("Pinch in twice to quit an application"), as does a
    ///   tap-and-hold pinch in ("tap, hold and pinch in once").
    ///   3.4.12 (the user's rule): the second quick pinch in *force* quits,
    ///   and only when `mayForceQuit` — the capture was confirmed by the
    ///   Accessibility hit-test and the app may be quit at all. Otherwise the
    ///   same double pinch is the polite `quitApp`, so a window found by its
    ///   frame alone, or a protected app, is never terminated by surprise.
    /// - Out toggles full screen. With two or more displays it waits: a second
    ///   pinch out, ⌘, or a tap-and-hold pinch out moves the window to the
    ///   other display and enters full screen there.
    static func pinchAction(_ pinch: Pinch, second: Bool, held: Bool, modifiers: Modifiers,
                            displays: Int, mayForceQuit: Bool = true) -> (action: WindowAction, waits: Bool) {
        switch pinch {
        case .in:
            guard held || second else { return (.close, true) }
            return second && mayForceQuit ? (.forceQuitApp, false) : (.quitApp, false)
        case .out:
            guard displays >= 2 else { return (.toggleFullscreen, false) }
            if held || second || modifiers.contains(.screen) { return (.fullscreenOnOtherScreen, false) }
            return (.toggleFullscreen, true)
        }
    }

    /// Pure (3.4.12): the action a gesture starting on `capturePid` completes as
    /// the second half of a "twice" gesture — the close or full-screen toggle
    /// still waiting on that app. Nil when nothing waits, when the gesture
    /// starts on another app, or when the waiting action is not one that waits
    /// (only those have a second half).
    static func repeatingAction(pending: WindowAction, pendingPid: pid_t, capturePid: pid_t) -> WindowAction? {
        guard pendingPid > 0, pendingPid == capturePid else { return nil }
        switch pending {
        case .close, .toggleFullscreen: return pending
        default: return nil
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
        case .forceQuitApp: return "Force Quit \(app)"
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
