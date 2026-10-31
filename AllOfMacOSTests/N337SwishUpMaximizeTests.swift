import XCTest
@testable import AllOfMacOS

/// N337, the user's rules over Swish parity:
/// - R1: a plain two-finger swipe up on a title bar always maximizes, from
///   every place (free, centred, a half, a quarter — bottom-right ↑ used to be
///   top-right —, a third, a sixth, a ninth, maximized), at any length, as the
///   first or a later motion of a touch, and right after another swipe.
///   N338: except right after a plain sideways motion of the same touch,
///   which it turns into an L (`N338LShapeTopCornerTests`).
/// - R2: no title-bar gesture takes the top or bottom half (Swish's
///   "Double-swipe vertically to snap to the top or bottom half of the
///   screen" is left out on purpose); a swipe down that would have reached
///   one puts the window back.
/// Pure: the mapping, the recognizer fed with 60 Hz frames and a model of the
/// service's order of calls (`Desk`), with the user's settings (Down action
/// Center, multi-motion pause 0.5 s, modifier gestures on, sensitivity 1).
final class N337SwishUpMaximizeTests: XCTestCase {
    // MARK: Helpers

    private func at(_ layout: CustomSnapZone.Layout) -> SwishSnap.Place { SwishSnap.Place(layout)! }

    /// The user's options: Down action Center, modifier gestures on.
    private var user: SwishSnap.GestureOptions { SwishSnap.GestureOptions(downAction: .center, modifierGestures: true) }

    /// Every place a window can be in for `grid`: free, centred,
    /// almost-maximized, and every cell of every grid (cells of another grid
    /// are free-floating there, which must maximize too).
    private func places(_ grid: SwishSnap.Grid) -> [SwishSnap.Place?] {
        var cells = grid.cells
        for other in SwishSnap.Grid.allCases {
            for cell in other.cells where !cells.contains(cell) { cells.append(cell) }
        }
        return [nil, .center, .almostMaximize] + cells.map { .grid($0) }
    }

    private static let topHalf = SwishSnap.Place(.topHalf)!
    private static let bottomHalf = SwishSnap.Place(.bottomHalf)!

    private func isVerticalHalf(_ move: SwishSnap.Move?) -> Bool {
        guard let place = move?.destination else { return false }
        return place == Self.topHalf || place == Self.bottomHalf
    }

    /// Two fingers 0.02 apart whose centroid sits at (x, y) in the snap's pad
    /// coordinates (y toward the bottom of the pad: a swipe up lowers y).
    private func pair(_ x: Float, _ y: Float) -> [TouchPoint] {
        [TouchPoint(id: 1, x: x - 0.01, y: 1 - y, size: 1, pressure: 0),
         TouchPoint(id: 2, x: x + 0.01, y: 1 - y, size: 1, pressure: 0)]
    }

    /// `TitleBarWindowSnap`'s order of calls without windows: `begin` reads
    /// the window's place, every stroke on show is planned with
    /// `SwishSnap.move(at:…)` (labels as the tooltip or HUD says them), and
    /// `commit` lands at once, so the next motion starts from there.
    private final class Desk {
        let recognizer = TitleBarSnapRecognizer()
        var options: SwishSnap.GestureOptions
        var place: SwishSnap.Place?
        private(set) var gestures: [[String]] = []
        private(set) var committed: [String] = []
        private(set) var readies = 0
        private var start: SwishSnap.Place?
        private var stroke: SwishSnap.Stroke?

        init(options: SwishSnap.GestureOptions, place: SwishSnap.Place? = nil,
             sensitivity: Double = 1, motionPause: Double = 0.5) {
            self.options = options
            self.place = place
            let distances = TitleBarWindowSnap.distances(sensitivity: sensitivity)
            recognizer.engage = distances.engage
            recognizer.crossEngage = distances.crossEngage
            recognizer.motionPause = motionPause
            recognizer.onBegin = { [unowned self] stroke in
                self.start = self.place
                self.gestures.append([])
                self.show(stroke)
            }
            recognizer.onUpdate = { [unowned self] stroke in self.show(stroke) }
            recognizer.onWithdraw = { [unowned self] in self.stroke = nil }
            recognizer.onCommit = { [unowned self] in self.commit() }
            recognizer.onCancel = { [unowned self] in self.stroke = nil }
            recognizer.onMotionReady = { [unowned self] in self.readies += 1 }
        }

        func feed(_ contacts: [TouchPoint], at time: Double) {
            recognizer.feed(contacts: contacts, timestamp: time)
        }

        private func plan(_ stroke: SwishSnap.Stroke) -> SwishSnap.Move? {
            SwishSnap.move(at: TitleBarWindowSnap.place(forStroke: stroke, start: start, startForUp: start),
                           stroke: stroke, modifiers: [], options: options)
        }

        static func label(_ move: SwishSnap.Move?, _ direction: SwishSnap.Direction) -> String {
            switch move {
            case .action(let action)?: return SwishSnap.title(for: action, appName: nil)
            case .restore?: return SwishSnap.tooltipText(direction: direction, place: nil)
            case let move?: return SwishSnap.tooltipText(direction: direction, place: move.destination)
            case nil: return "nothing"
            }
        }

        private func show(_ stroke: SwishSnap.Stroke) {
            self.stroke = stroke
            gestures[gestures.count - 1].append(Self.label(plan(stroke), SwishSnap.tooltipDirection(for: stroke)))
        }

        private func commit() {
            guard let stroke else { return }
            let move = plan(stroke)
            committed.append(Self.label(move, SwishSnap.tooltipDirection(for: stroke)))
            switch move {
            case .cell?, .place?: place = move?.destination
            case .restore?: place = nil
            case .action?, nil: break
            }
            self.stroke = nil
        }

        var shown: [String] { gestures.flatMap { $0 } }
    }

    /// From `from` to `to` over `duration` at 60 Hz, starting at `time`.
    private func slide(_ desk: Desk, from: (Float, Float), to: (Float, Float), at time: Double, duration: Double) {
        let frames = max(1, Int((duration * 60).rounded()))
        for frame in 1...frames {
            let share = Float(frame) / Float(frames)
            desk.feed(pair(from.0 + (to.0 - from.0) * share, from.1 + (to.1 - from.1) * share),
                      at: time + duration * Double(frame) / Double(frames))
        }
    }

    /// Fingers resting at `point` from `time` for `duration`.
    private func rest(_ desk: Desk, at point: (Float, Float), from time: Double, duration: Double) {
        var t = time
        while t <= time + duration + 1e-9 {
            desk.feed(pair(point.0, point.1), at: t)
            t += 1.0 / 60
        }
    }

    /// One touch: the moves in order, each `(dx, dy)` from where the last one
    /// ended over 0.08 s, with a rest of `pause` between them (so each later
    /// one is a further motion), then the lift. Returns when the touch ended.
    @discardableResult
    private func touch(_ desk: Desk, _ moves: [(Float, Float)], at time: Double = 0, pause: Double = 0.65,
                       duration: Double = 0.08) -> Double {
        var point: (Float, Float) = (0.5, 0.6)
        var t = time
        desk.feed(pair(point.0, point.1), at: t)
        for (index, move) in moves.enumerated() {
            if index > 0 {
                rest(desk, at: point, from: t + 1.0 / 60, duration: pause)
                t += pause + 2.0 / 60
            }
            let next = (point.0 + move.0, point.1 + move.1)
            slide(desk, from: point, to: next, at: t, duration: duration)
            t += duration
            point = next
        }
        desk.feed([], at: t + 0.02)
        return t + 0.02
    }

    private let up: (Float, Float) = (0, -0.15)
    private let down: (Float, Float) = (0, 0.15)
    private let left: (Float, Float) = (-0.15, 0)
    private let right: (Float, Float) = (0.15, 0)

    // MARK: R1: the mapping, from every place

    /// Table-driven: every grid, both Down actions, every place, both tiers,
    /// with and without ⌥ (⌥ up is a plain swipe up): maximize.
    func testAPlainSwipeUpMaximizesFromEveryPlace() {
        for grid in SwishSnap.Grid.allCases {
            for downAction in SwishSnap.DownAction.allCases {
                let options = SwishSnap.GestureOptions(downAction: downAction, grid: grid)
                for place in places(grid) {
                    for tier in [1, 2] {
                        for modifiers: SwishSnap.Modifiers in [[], .general] {
                            XCTAssertEqual(SwishSnap.move(at: place, stroke: .init(.up, tier: tier), modifiers: modifiers,
                                                          options: options), .cell(.maximize),
                                           "\(grid) \(downAction) \(String(describing: place)) tier \(tier) \(modifiers)")
                        }
                        XCTAssertEqual(SwishSnap.step(from: place, stroke: .init(.up, tier: tier), grid: grid), .cell(.maximize))
                    }
                }
            }
        }
    }

    /// The user's report: a bottom-right window swiped up went to the top
    /// right. Every quarter and half, read from its frame as the service
    /// reads it, maximizes.
    func testTheBottomRightQuarterSwipedUpMaximizes() {
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 920)
        for layout: CustomSnapZone.Layout in [.bottomRight, .bottomLeft, .topLeft, .topRight, .leftHalf, .rightHalf,
                                              .topHalf, .bottomHalf, .maximize] {
            let frame = SwishSnap.targetFrame(layout: layout, visible: visible, margin: 0)
            let start = SwishSnap.place(of: frame, visible: visible, margin: 0, grid: .twoByTwo)
            let startForUp = SwishSnap.place(of: frame, visible: visible, margin: 0, grid: .twoByTwo, overflowing: false)
            XCTAssertEqual(start, at(layout))
            let read = TitleBarWindowSnap.place(forStroke: .init(.up), start: start, startForUp: startForUp)
            XCTAssertEqual(SwishSnap.move(at: read, stroke: .init(.up), modifiers: [], options: user), .cell(.maximize),
                           "\(layout)")
        }
        XCTAssertNotEqual(SwishSnap.move(at: at(.bottomRight), stroke: .init(.up), modifiers: [], options: user),
                          .cell(.topRight))
    }

    /// Almost Maximize on, or ⇧ held (Swish's "swiping up while holding ⇧"):
    /// up almost-maximizes from every place; from almost-maximized or
    /// maximized it maximizes. Never the top half, so ⇧ up twice is almost
    /// maximize, then maximize.
    func testWithAlmostMaximizeOrShiftUpAlmostMaximizesFromEveryPlace() {
        for grid in SwishSnap.Grid.allCases {
            let almost = SwishSnap.GestureOptions(downAction: .center, grid: grid, almostMaximize: true)
            let shift = SwishSnap.effectiveOptions(SwishSnap.GestureOptions(downAction: .center, grid: grid), held: [.secondary])
            for (options, modifiers) in [(almost, SwishSnap.Modifiers()), (shift, SwishSnap.Modifiers.secondary)] {
                for place in places(options.grid) {
                    let expected: SwishSnap.Move = place == .almostMaximize || place == .grid(.full)
                        ? .cell(.maximize) : .place(.almostMaximize)
                    for tier in [1, 2] {
                        XCTAssertEqual(SwishSnap.move(at: place, stroke: .init(.up, tier: tier), modifiers: modifiers,
                                                      options: options), expected,
                                       "\(options.grid) \(String(describing: place)) tier \(tier)")
                    }
                }
            }
        }
    }

    /// The other up gestures keep Swish's meaning: tap and hold toggles full
    /// screen, ⌘ moves to the display above, a window in full screen ignores
    /// a plain swipe, and a genuine diagonal still picks its top quarter.
    func testTheOtherUpGesturesKeepTheirMeaning() {
        for place in places(.twoByTwo) {
            XCTAssertEqual(SwishSnap.move(at: place, stroke: .init(.up, held: true), modifiers: [], options: user),
                           .action(.toggleFullscreen))
            XCTAssertEqual(SwishSnap.move(at: place, stroke: .init(.up), modifiers: .screen, options: user),
                           .action(.screen(.up)))
            XCTAssertNil(SwishSnap.move(at: place, stroke: .init(.up), modifiers: [], options: user, fullscreen: true))
            XCTAssertEqual(SwishSnap.move(at: place, stroke: .init(.up, cross: .right), modifiers: [], options: user),
                           .cell(.topRight))
            XCTAssertEqual(SwishSnap.move(at: place, stroke: .init(.left, cross: .up), modifiers: [], options: user),
                           .cell(.topLeft))
        }
    }

    // MARK: R2: no path to the top or bottom half

    /// Exhaustive: every grid, Almost Maximize, Down action, place, direction,
    /// tier, cross leg, hold, modifier combination and full-screen state.
    func testNoTitleBarSwipeEverTakesTheTopOrBottomHalf() {
        let directions: [SwishSnap.Direction] = [.left, .right, .up, .down]
        let modifierSets: [SwishSnap.Modifiers] = (0..<8).map { SwishSnap.Modifiers(rawValue: $0) }
        var checked = 0
        for grid in SwishSnap.Grid.allCases {
            for almost in [false, true] {
                for downAction in SwishSnap.DownAction.allCases {
                    let options = SwishSnap.GestureOptions(downAction: downAction, grid: grid, almostMaximize: almost)
                    for place in places(grid) {
                        for direction in directions {
                            let crosses: [SwishSnap.Direction?] = [nil] + directions.filter { $0.axis != direction.axis }
                            for cross in crosses {
                                for tier in [1, 2] {
                                    for held in [false, true] {
                                        let stroke = SwishSnap.Stroke(direction, tier: tier, cross: cross, held: held)
                                        XCTAssertFalse(isVerticalHalf(SwishSnap.step(from: place, stroke: stroke, grid: grid,
                                                                                     almost: almost)))
                                        for modifiers in modifierSets {
                                            for fullscreen in [false, true] {
                                                let move = SwishSnap.move(at: place, stroke: stroke, modifiers: modifiers,
                                                                          options: options, fullscreen: fullscreen)
                                                checked += 1
                                                XCTAssertFalse(isVerticalHalf(move),
                                                               "\(grid) almost \(almost) \(downAction) \(String(describing: place)) \(stroke) \(modifiers) fs \(fullscreen) → \(String(describing: move))")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 100_000)
        // The double tap and the hotkeys' plain swipes go through the same
        // mapping; the double tap never names a half either.
        for option in SwishSnap.DoubleTap.allCases {
            for modifiers in modifierSets {
                XCTAssertFalse(isVerticalHalf(SwishSnap.doubleTapMove(option, modifiers: modifiers)))
            }
        }
        XCTAssertTrue(SwishSnap.isVerticalHalf(Self.topHalf))
        XCTAssertTrue(SwishSnap.isVerticalHalf(Self.bottomHalf))
        XCTAssertFalse(SwishSnap.isVerticalHalf(at(.leftHalf)))
        XCTAssertFalse(SwishSnap.isVerticalHalf(nil))
    }

    /// The layouts themselves stay for presets, menus, hotkey actions and
    /// snap zones.
    func testTheTopAndBottomHalfLayoutsStayInTheModel() {
        XCTAssertTrue(CustomSnapZone.Layout.allCases.contains(.topHalf))
        XCTAssertTrue(CustomSnapZone.Layout.allCases.contains(.bottomHalf))
        XCTAssertEqual(SwishGridCell(.topHalf)?.layout, .topHalf)
        XCTAssertEqual(SwishSnap.placeName(Self.bottomHalf), "Bottom Half")
    }

    // MARK: Down, place by place

    /// What a plain swipe down does from each place, both Down actions.
    func testTheSwipeDownTable() {
        let minimize = SwishSnap.GestureOptions(downAction: .minimize)
        let rows: [(SwishSnap.Place?, center: SwishSnap.Move, minimize: SwishSnap.Move, why: String)] = [
            (nil, .cell(.center), .action(.minimize), "free: the Down action"),
            (.center, .restore, .action(.minimize), "centred: back, or minimized like a free window"),
            (at(.maximize), .restore, .restore, "Swish's unsnap"),
            (at(.leftHalf), .cell(.bottomLeft), .cell(.bottomLeft), "Swish: both orders give a quarter"),
            (at(.rightHalf), .cell(.bottomRight), .cell(.bottomRight), "Swish: both orders give a quarter"),
            (at(.topLeft), .cell(.bottomLeft), .cell(.bottomLeft), "the bottom quarter of its column"),
            (at(.topRight), .cell(.bottomRight), .cell(.bottomRight), "the bottom quarter of its column"),
            (at(.bottomLeft), .restore, .restore, "N337: was the bottom half"),
            (at(.bottomRight), .restore, .restore, "N337: was the bottom half"),
            (at(.topHalf), .restore, .restore, "N337: was the bottom half"),
            (at(.bottomHalf), .restore, .restore, "a bottom-edge window"),
        ]
        for row in rows {
            for tier in [1, 2] {
                let stroke = SwishSnap.Stroke(.down, tier: tier)
                XCTAssertEqual(SwishSnap.move(at: row.0, stroke: stroke, modifiers: [], options: user), row.center,
                               "\(String(describing: row.0)) Center: \(row.why)")
                XCTAssertEqual(SwishSnap.move(at: row.0, stroke: stroke, modifiers: [], options: minimize), row.minimize,
                               "\(String(describing: row.0)) Minimize: \(row.why)")
            }
        }
        // Almost-maximized (option on): back.
        XCTAssertEqual(SwishSnap.move(at: .almostMaximize, stroke: .init(.down), modifiers: [],
                                      options: SwishSnap.GestureOptions(downAction: .center, almostMaximize: true)), .restore)
        // 3 × 2: a third takes its lower sixth; a lower sixth grows along the
        // bottom unless that would be the bottom half.
        let sixths = SwishSnap.GestureOptions(downAction: .center, grid: .threeByTwo)
        func down(_ place: SwishSnap.Place) -> SwishSnap.Move? {
            SwishSnap.move(at: place, stroke: .init(.down), modifiers: [], options: sixths)
        }
        XCTAssertEqual(down(at(.leftThird)), .place(.grid(.sixth(0, 1))))
        XCTAssertEqual(down(.grid(.sixth(0, 1))), .place(.grid(.sixth(0, 1, columnSpan: 2))))
        XCTAssertEqual(down(.grid(.sixth(1, 1))), .restore)
        XCTAssertEqual(down(.grid(.sixth(0, 1, columnSpan: 2))), .restore)
        // The modifier gestures down are Swish's: ⌥ closes (held: quits), ⌘
        // moves to the display below, tap and hold minimizes.
        XCTAssertEqual(SwishSnap.move(at: at(.bottomRight), stroke: .init(.down), modifiers: .general, options: user),
                       .action(.close))
        XCTAssertEqual(SwishSnap.move(at: nil, stroke: .init(.down, held: true), modifiers: .general, options: user),
                       .action(.quitApp))
        XCTAssertEqual(SwishSnap.move(at: at(.topHalf), stroke: .init(.down), modifiers: .screen, options: user),
                       .action(.screen(.down)))
        XCTAssertEqual(SwishSnap.move(at: at(.leftHalf), stroke: .init(.down, held: true), modifiers: [], options: user),
                       .action(.minimize))
    }

    // MARK: R1 from frames: first motion, later motions, separate swipes

    /// Every place of the 2 × 2 grid, a short, a long and a quick swipe up:
    /// every frame on show says Maximize and the lift maximizes.
    func testFromFramesASwipeUpMaximizesFromEveryPlaceAtAnyLength() {
        let starts: [SwishSnap.Place?] = [nil, .center] + SwishSnap.Grid.twoByTwo.cells.map { .grid($0) }
        for start in starts {
            for (length, duration) in [(Float(0.08), 0.06), (0.4, 0.25), (0.3, 0.05)] {
                let desk = Desk(options: user, place: start)
                touch(desk, [(0, -length)], duration: duration)
                XCTAssertEqual(Set(desk.shown), ["↑ Maximize"], "\(String(describing: start)) \(length)")
                XCTAssertEqual(desk.committed, ["↑ Maximize"], "\(String(describing: start)) \(length)")
                XCTAssertEqual(desk.place, at(.maximize))
            }
        }
    }

    /// Multi-motion chains at the user's 0.5 s pause: an up after a vertical
    /// motion or a quarter maximizes. N338 (the user's rule): an up right
    /// after a plain sideways motion turns that corner instead, one L, the
    /// top quarter of that side (3.3.7: the half, then Maximize).
    func testInOneTouchAnUpAfterOtherMotionsMaximizes() {
        let chains: [([(Float, Float)], [String], SwishSnap.Place)] = [
            ([left, up], ["↑ Top Left"], at(.topLeft)),
            ([right, up], ["↑ Top Right"], at(.topRight)),
            ([right, down, up], ["→ Right Half", "↓ Bottom Right", "↑ Maximize"], at(.maximize)),
            ([left, down, up], ["← Left Half", "↓ Bottom Left", "↑ Maximize"], at(.maximize)),
            ([left, up, up], ["↑ Top Left", "↑ Maximize"], at(.maximize)),
            ([up, up], ["↑ Maximize", "↑ Maximize"], at(.maximize)),
            ([up, down, up], ["↑ Maximize", "↓ Restore", "↑ Maximize"], at(.maximize)),
            ([down, up], ["↓ Center", "↑ Maximize"], at(.maximize)),
        ]
        for (moves, expected, place) in chains {
            let desk = Desk(options: user)
            touch(desk, moves)
            XCTAssertEqual(desk.committed, expected, "\(moves)")
            XCTAssertEqual(desk.readies, moves.count - 1, "each rest locked the motion (\(moves))")
            XCTAssertEqual(desk.place, place, "\(moves)")
        }
        // From every 2 × 2 place: down, a rest, then up maximizes; left or
        // right, a rest, then up is that top quarter (N338).
        for start in [nil] + SwishSnap.Grid.twoByTwo.cells.map({ SwishSnap.Place.grid($0) }) {
            for (first, expected) in [(left, ["↑ Top Left"]), (right, ["↑ Top Right"])] {
                let desk = Desk(options: user, place: start)
                touch(desk, [first, up])
                XCTAssertEqual(desk.committed, expected, "\(String(describing: start)) \(first)")
            }
            let desk = Desk(options: user, place: start)
            touch(desk, [down, up])
            XCTAssertEqual(desk.committed.last, "↑ Maximize", "\(String(describing: start)) down")
            XCTAssertEqual(desk.committed.count, 2)
        }
    }

    /// A new touch within the 0.5 s that 3.3.4–3.3.6 kept for the separate
    /// double swipe: up again stays maximized, and down twice is two plain
    /// swipes down (centre, then back).
    func testASecondSeparateSwipeSoonAfterIsAPlainSwipe() {
        let desk = Desk(options: user, place: at(.bottomRight))
        var end = touch(desk, [up])
        end = touch(desk, [up], at: end + 0.2)
        XCTAssertEqual(desk.committed, ["↑ Maximize", "↑ Maximize"])
        touch(desk, [down], at: end + 0.2)
        touch(desk, [down], at: end + 0.6)
        XCTAssertEqual(desk.committed, ["↑ Maximize", "↑ Maximize", "↓ Restore", "↓ Center"])
    }

    /// "Mostly vertical" is up: a stroke 20° off vertical on the glass
    /// maximizes from a bottom quarter; a genuine diagonal (45°, inside
    /// Swish's 31–59°) still takes the top quarter that way.
    func testAMostlyVerticalStrokeIsUpAndOnlyAGenuineDiagonalIsAQuarter() {
        let rise: Float = 0.3
        for degrees in [8.0, 15.0, 20.0, 25.0] {
            let dx = Float(tan(degrees * .pi / 180)) * rise / SwishSnap.padAspect
            for sign: Float in [-1, 1] {
                let desk = Desk(options: user, place: at(.bottomRight))
                touch(desk, [(sign * dx, -rise)], duration: 0.2)
                XCTAssertEqual(Set(desk.shown), ["↑ Maximize"], "\(degrees)° \(sign)")
                XCTAssertEqual(desk.committed, ["↑ Maximize"], "\(degrees)° \(sign)")
            }
        }
        for (sign, name) in [(Float(1), "Top Right"), (-1, "Top Left")] {
            let dx = rise / SwishSnap.padAspect
            let desk = Desk(options: user, place: at(.bottomRight))
            touch(desk, [(sign * dx, -rise)], duration: 0.2)
            XCTAssertEqual(desk.committed.count, 1)
            XCTAssertTrue(desk.committed.first?.hasSuffix(name) == true, "45° \(sign): \(desk.committed)")
        }
    }

    // MARK: Tooltips

    /// No tooltip names the top or bottom half or shows two arrows, for any
    /// place and any plain or diagonal stroke.
    func testNoTooltipNamesTheTopOrBottomHalf() {
        for grid in SwishSnap.Grid.allCases {
            let options = SwishSnap.GestureOptions(downAction: .center, grid: grid)
            for place in places(grid) {
                for direction: SwishSnap.Direction in [.left, .right, .up, .down] {
                    for cross: SwishSnap.Direction? in [nil, .left, .right, .up, .down] where cross?.axis != direction.axis {
                        let stroke = SwishSnap.Stroke(direction, cross: cross)
                        let move = SwishSnap.move(at: place, stroke: stroke, modifiers: [], options: options)
                        let text = Desk.label(move, direction)
                        XCTAssertFalse(text.contains("Top Half") || text.contains("Bottom Half"), text)
                        XCTAssertFalse(text.contains("↑↑") || text.contains("↓↓"), text)
                    }
                }
            }
        }
        XCTAssertEqual(SwishSnap.tooltipText(direction: .up, place: at(.maximize)), "↑ Maximize")
        XCTAssertEqual(SwishSnap.tooltipText(direction: .down, place: nil), "↓ Restore")
    }

    // MARK: R3: the user's settings still read

    func testTheUsersSettingsStillRead() {
        let suite = "aom.test.n337.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("center", forKey: TitleBarWindowSnap.downActionKey)
        defaults.set(0.5, forKey: TitleBarWindowSnap.motionPauseKey)
        defaults.set(1, forKey: TitleBarWindowSnap.modifiersKey)          // `defaults write … -int 1`
        defaults.set(1, forKey: TitleBarWindowSnap.sensitivityKey)
        let options = TitleBarWindowSnap.gestureOptions(defaults)
        XCTAssertEqual(options.downAction, .center)
        XCTAssertTrue(options.modifierGestures)
        XCTAssertEqual(TitleBarWindowSnap.motionPause(defaults), 0.5)
        XCTAssertEqual(TitleBarWindowSnap.sensitivity(defaults), 1)
        XCTAssertEqual(SwishSnap.move(at: at(.bottomRight), stroke: .init(.up), modifiers: [], options: options),
                       .cell(.maximize))
        XCTAssertEqual(SwishSnap.move(at: nil, stroke: .init(.down), modifiers: [], options: options), .cell(.center))
    }
}
