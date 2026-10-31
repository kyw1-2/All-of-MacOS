import XCTest
@testable import AllOfMacOS

/// N338, the user's rule: in one touch, a sideways swipe that turns up (an L,
/// fingers down throughout) takes that side's top quarter: left then up the
/// top-left, right then up the top-right, whether the turn is continuous or
/// rests at the corner (the multi-motion pause). 3.3.7 ended such a stroke in
/// Maximize in two ways, both reproduced here from frames:
/// - an up leg drifting back over the start re-picked the axis as a plain
///   up (`refine`'s "back near the start" rule), shown and committed as
///   "↑ Maximize";
/// - a turn that slowed or rested `motionPause` at the corner locked the
///   half, and the up became a new motion, which 3.3.7 maximizes.
/// A long sideways leg with a short up was the half (the 45 % cross share).
/// Everything else of 3.3.7 stays: a plain up maximizes, an up after a
/// vertical motion or after a quarter maximizes, a second touch is never an
/// L, nothing reaches the top or bottom half.
/// Pure: the recognizer fed 60 Hz frames at the user's settings (sensitivity
/// 1, multi-motion pause 0.5 s, Down action Center, modifier gestures on)
/// and a model of the service (`Desk`) that plans with `SwishSnap.move(at:…)`
/// and labels as the tooltip does.
final class N338LShapeTopCornerTests: XCTestCase {
    // MARK: Helpers

    private func at(_ layout: CustomSnapZone.Layout) -> SwishSnap.Place { SwishSnap.Place(layout)! }

    private var user: SwishSnap.GestureOptions { SwishSnap.GestureOptions(downAction: .center, modifierGestures: true) }

    /// Two fingers 0.02 apart whose centroid sits at (x, y) in the snap's pad
    /// coordinates (y toward the bottom of the pad: a swipe up lowers y).
    private func pair(_ x: Float, _ y: Float) -> [TouchPoint] {
        [TouchPoint(id: 1, x: x - 0.01, y: 1 - y, size: 1, pressure: 0),
         TouchPoint(id: 2, x: x + 0.01, y: 1 - y, size: 1, pressure: 0)]
    }

    /// `TitleBarWindowSnap`'s order of calls without windows: `begin` reads
    /// the window's place and sets `cornerTurns` from the modifiers (as
    /// `adopt` does), every stroke on show is planned and labelled with the
    /// tooltip's arrow (`SwishSnap.tooltipDirection`), and `commit` lands at
    /// once.
    private final class Desk {
        let recognizer = TitleBarSnapRecognizer()
        var options: SwishSnap.GestureOptions
        var modifiers: SwishSnap.Modifiers
        var place: SwishSnap.Place?
        private(set) var gestures: [[String]] = []
        private(set) var committed: [String] = []
        private(set) var readies = 0
        private var start: SwishSnap.Place?
        private var stroke: SwishSnap.Stroke?

        init(options: SwishSnap.GestureOptions, place: SwishSnap.Place? = nil, modifiers: SwishSnap.Modifiers = []) {
            self.options = options
            self.place = place
            self.modifiers = modifiers
            let distances = TitleBarWindowSnap.distances(sensitivity: 1)
            recognizer.engage = distances.engage
            recognizer.crossEngage = distances.crossEngage
            recognizer.motionPause = 0.5
            recognizer.onBegin = { [unowned self] stroke in
                self.start = self.place
                self.recognizer.cornerTurns = SwishSnap.cornerTurns(modifiers: self.modifiers, options: self.options)
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
                           stroke: stroke, modifiers: modifiers, options: options)
        }

        private func label(_ move: SwishSnap.Move?, _ stroke: SwishSnap.Stroke) -> String {
            let arrow = SwishSnap.tooltipDirection(for: stroke)
            switch move {
            case .action(let action)?: return SwishSnap.title(for: action, appName: nil)
            case .restore?: return SwishSnap.tooltipText(direction: arrow, place: nil)
            case let move?: return SwishSnap.tooltipText(direction: arrow, place: move.destination)
            case nil: return "nothing"
            }
        }

        private func show(_ stroke: SwishSnap.Stroke) {
            self.stroke = stroke
            gestures[gestures.count - 1].append(label(plan(stroke), stroke))
        }

        private func commit() {
            guard let stroke else { return }
            let move = plan(stroke)
            committed.append(label(move, stroke))
            switch move {
            case .cell?, .place?: place = move?.destination
            case .restore?: place = nil
            case .action?, nil: break
            }
            self.stroke = nil
        }

        var shown: [String] { gestures.flatMap { $0 } }
    }

    /// One piece of a touch: a slide by (dx, dy) over some seconds, or a rest.
    private enum Leg {
        case move(Float, Float, Double)
        case rest(Double)

        var mirrored: Leg {
            switch self {
            case let .move(dx, dy, duration): return .move(-dx, dy, duration)
            case .rest: return self
            }
        }
    }

    /// A named path drawn on the left side (`mirrored` gives the right).
    private struct Shape {
        let name: String
        let legs: [Leg]
        var ease = false
    }

    /// One touch: lands at `from`, follows the legs at 60 Hz (`ease`
    /// smoothsteps each slide, so the fingers slow into and out of every
    /// corner), lifts. Returns when it lifted.
    @discardableResult
    private func touch(_ desk: Desk, _ legs: [Leg], at time: Double = 0, ease: Bool = false,
                       from: (Float, Float) = (0.5, 0.6)) -> Double {
        var point = from
        var t = time
        desk.feed(pair(point.0, point.1), at: t)
        for leg in legs {
            switch leg {
            case let .move(dx, dy, duration):
                let frames = max(1, Int((duration * 60).rounded()))
                for frame in 1...frames {
                    var share = Float(frame) / Float(frames)
                    if ease { share = share * share * (3 - 2 * share) }
                    desk.feed(pair(point.0 + dx * share, point.1 + dy * share), at: t + duration * Double(frame) / Double(frames))
                }
                t += duration
                point = (point.0 + dx, point.1 + dy)
            case .rest(let duration):
                var r = 1.0 / 60
                while r <= duration + 1e-9 {
                    desk.feed(pair(point.0, point.1), at: t + r)
                    r += 1.0 / 60
                }
                t += duration
            }
        }
        desk.feed([], at: t + 0.02)
        return t + 0.02
    }

    private static let aspect = SwishSnap.padAspect

    /// An up leg `length` long leaning `degrees` off vertical on the glass,
    /// back over the start (toward +x for a left L) or out.
    private func up(_ length: Float, _ degrees: Double = 0, back: Bool = true, _ duration: Double = 0.2) -> Leg {
        let dx = Float(tan(degrees * .pi / 180)) * length / Self.aspect
        return .move(back ? dx : -dx, -length, duration)
    }

    /// A left leg `length` long drifting `degrees` up (negative: down) on the glass.
    private func left(_ length: Float, _ degrees: Double = 0, _ duration: Double = 0.15) -> Leg {
        .move(-length, -length * Self.aspect * Float(tan(degrees * .pi / 180)), duration)
    }

    /// The user's L shapes at realistic sizes and speeds (pad units: 0.05 is
    /// the engage distance at sensitivity 1, about 7 mm across a 14 cm pad).
    private var shapes: [Shape] {
        [
            Shape(name: "a short left just past engage, then a long up", legs: [.move(-0.06, 0, 0.08), up(0.3)]),
            Shape(name: "a short left, the up drifting 15° back over the start", legs: [.move(-0.06, 0, 0.08), up(0.3, 15)]),
            Shape(name: "a short left, the up drifting 20° back", legs: [.move(-0.08, 0, 0.1), up(0.3, 20)]),
            Shape(name: "a short left, the up drifting 25° back past the start",
                  legs: [.move(-0.06, 0, 0.08), up(0.4, 25, back: true, 0.3)]),
            Shape(name: "a short left, the up drifting 15° out", legs: [.move(-0.06, 0, 0.08), up(0.25, 15, back: false)]),
            Shape(name: "a long left, then a short up", legs: [.move(-0.3, 0, 0.2), up(0.12, 0, back: true, 0.12)]),
            Shape(name: "a long left, then up", legs: [.move(-0.3, 0, 0.2), up(0.2, 0, back: true, 0.15)]),
            Shape(name: "a fast flick", legs: [.move(-0.1, 0, 0.05), up(0.2, 0, back: true, 0.06)]),
            Shape(name: "a slow turn", legs: [.move(-0.15, 0, 0.4), up(0.25, 0, back: true, 0.4)], ease: true),
            Shape(name: "a slow turn slowing 0.2 s at the corner",
                  legs: [.move(-0.15, 0, 0.4), .rest(0.2), up(0.25, 0, back: true, 0.4)], ease: true),
            Shape(name: "a slow turn slowing 0.45 s at the corner (locks)",
                  legs: [.move(-0.15, 0, 0.4), .rest(0.45), up(0.25, 0, back: true, 0.4)], ease: true),
            Shape(name: "a rest of 0.6 s at the corner", legs: [.move(-0.15, 0, 0.12), .rest(0.6), up(0.25)]),
            Shape(name: "a rest at the corner, the up drifting 20° back",
                  legs: [.move(-0.08, 0, 0.1), .rest(0.6), up(0.3, 20)]),
            Shape(name: "left drifting 15° up, the up drifting 15° back", legs: [left(0.15, 15), up(0.25, 15)]),
            Shape(name: "left drifting 20° down, the up drifting 20° out", legs: [left(0.12, -20), up(0.25, 20, back: false)]),
            Shape(name: "a long left drifting 10° up, a short up drifting 10° back", legs: [left(0.25, 10, 0.2), up(0.1, 10)]),
            Shape(name: "a long left drifting 15° down, a short up", legs: [left(0.35, -15, 0.25), up(0.1, 0, back: true, 0.1)]),
            Shape(name: "a rounded corner",
                  legs: [.move(-0.07, 0, 0.07), .move(-0.02, -0.01, 0.03), .move(-0.01, -0.02, 0.03), up(0.22, 0, back: true, 0.17)]),
        ]
    }

    private func assertNoVerticalHalf(_ desk: Desk, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in desk.shown + desk.committed {
            XCTAssertFalse(text.contains("Top Half") || text.contains("Bottom Half") || text.contains("↑↑") || text.contains("↓↓"),
                           "\(context): \(text)", file: file, line: line)
        }
    }

    // MARK: The L, from frames

    /// Every shape, both sides, from a free window: one commit, the top
    /// quarter of that side; the up leg shows "↑ Top Left"/"↑ Top Right" and
    /// nothing ever shows Maximize.
    func testEveryLShapeTakesThatSidesTopQuarter() {
        for shape in shapes {
            for (mirror, name, layout) in [(false, "Top Left", CustomSnapZone.Layout.topLeft), (true, "Top Right", .topRight)] {
                let desk = Desk(options: user)
                let legs = mirror ? shape.legs.map(\.mirrored) : shape.legs
                touch(desk, legs, ease: shape.ease)
                let context = "\(shape.name) \(mirror ? "right" : "left"): shown \(desk.shown), committed \(desk.committed)"
                XCTAssertEqual(desk.committed, ["↑ \(name)"], context)
                XCTAssertEqual(desk.shown.last, "↑ \(name)", context)
                XCTAssertFalse(desk.shown.contains { $0.contains("Maximize") }, context)
                XCTAssertEqual(desk.gestures.count, 1, "one gesture, never a second motion: \(context)")
                XCTAssertEqual(desk.place, at(layout), context)
                assertNoVerticalHalf(desk, context)
            }
        }
    }

    /// From free, centred, maximized and snapped windows, in every grid, the
    /// continuous L and the L that rests at the corner both give the 2 × 2
    /// top quarter of that side (as the continuous L and the diagonal always
    /// did): a corner, never a half and never the top sixth or ninth.
    func testFromEveryPlaceAndGridTheLIsTheTopQuarter() {
        let common: [SwishSnap.Place?] = [nil, .center, at(.maximize), at(.leftHalf), at(.rightHalf), at(.bottomLeft),
                                          at(.bottomRight), at(.topLeft), at(.topRight)]
        let extra: [SwishSnap.Grid: [SwishSnap.Place?]] = [
            .twoByTwo: [],
            .threeByTwo: [at(.leftThird), at(.rightTwoThirds), .grid(.sixth(2, 1)), .grid(.sixth(0, 0))],
            .threeByThree: [at(.centerThird), .grid(.ninth(1, 1)), .grid(.ninth(2, 2)), .grid(.ninth(0, 0, columnSpan: 2))],
        ]
        let forms: [(String, [Leg])] = [
            ("continuous", [.move(-0.1, 0, 0.08), up(0.25)]),
            ("rest at the corner", [.move(-0.15, 0, 0.1), .rest(0.6), up(0.25)]),
            ("long left then a short up", [.move(-0.3, 0, 0.2), up(0.12, 0, back: true, 0.12)]),
        ]
        for grid in SwishSnap.Grid.allCases {
            let options = SwishSnap.GestureOptions(downAction: .center, modifierGestures: true, grid: grid)
            for start in common + (extra[grid] ?? []) {
                for (form, legs) in forms {
                    for (mirror, name, layout) in [(false, "Top Left", CustomSnapZone.Layout.topLeft), (true, "Top Right", .topRight)] {
                        let desk = Desk(options: options, place: start)
                        touch(desk, mirror ? legs.map(\.mirrored) : legs)
                        let context = "\(grid) \(String(describing: start)) \(form) \(name): \(desk.shown) → \(desk.committed)"
                        XCTAssertEqual(desk.committed, ["↑ \(name)"], context)
                        XCTAssertEqual(desk.place, at(layout), context)
                        XCTAssertFalse(desk.shown.contains { $0.contains("Maximize") }, context)
                        assertNoVerticalHalf(desk, context)
                    }
                }
            }
        }
    }

    /// The rest form in detail: the rest locks the half (the haptic), the up
    /// turns it into the quarter instead of committing it, and lifting
    /// commits the quarter once.
    func testRestingAtTheCornerTurnsTheHalfIntoTheQuarter() {
        for (mirror, side, name) in [(false, "← Left Half", "↑ Top Left"), (true, "→ Right Half", "↑ Top Right")] {
            let legs: [Leg] = [.move(-0.15, 0, 0.1), .rest(0.6), up(0.25)]
            let desk = Desk(options: user)
            touch(desk, mirror ? legs.map(\.mirrored) : legs)
            XCTAssertEqual(desk.readies, 1, "the rest locked the half")
            XCTAssertEqual(desk.gestures, [[side, name]], "no second motion, no Maximize")
            XCTAssertEqual(desk.committed, [name])
        }
    }

    // MARK: 3.3.7 kept

    /// A plain up that starts a touch maximizes from every place, a window
    /// already in a half or a quarter included.
    func testAPlainUpStartingATouchStillMaximizesEverywhere() {
        let starts: [SwishSnap.Place?] = [nil, .center, at(.leftHalf), at(.rightHalf), at(.topLeft), at(.topRight),
                                          at(.bottomLeft), at(.bottomRight), at(.maximize)]
        for start in starts {
            let desk = Desk(options: user, place: start)
            touch(desk, [up(0.3, 0, back: true, 0.2)])
            XCTAssertEqual(desk.committed, ["↑ Maximize"], "\(String(describing: start))")
            XCTAssertEqual(Set(desk.shown), ["↑ Maximize"])
        }
    }

    /// The other motions in one touch keep 3.3.7's results.
    func testOtherChainsInOneTouchKeepTheirResults() {
        let rest = Leg.rest(0.6)
        let leftLeg = Leg.move(-0.15, 0, 0.08), downLeg = Leg.move(0, 0.15, 0.08), upLeg = Leg.move(0, -0.15, 0.08)
        let chains: [(String, [Leg], [String], SwishSnap.Place?)] = [
            ("down, rest, up", [downLeg, rest, upLeg], ["↓ Center", "↑ Maximize"], at(.maximize)),
            ("up, rest, up", [upLeg, rest, upLeg], ["↑ Maximize", "↑ Maximize"], at(.maximize)),
            ("left, rest, down, rest, up", [leftLeg, rest, downLeg, rest, upLeg],
             ["← Left Half", "↓ Bottom Left", "↑ Maximize"], at(.maximize)),
            ("an L, rest, up: the top quarter, then up maximizes", [.move(-0.1, 0, 0.08), upLeg, rest, upLeg],
             ["↑ Top Left", "↑ Maximize"], at(.maximize)),
            ("left, rest, up, rest, up", [leftLeg, rest, upLeg, rest, upLeg], ["↑ Top Left", "↑ Maximize"], at(.maximize)),
            ("left, rest, left, rest, up", [leftLeg, rest, leftLeg, rest, upLeg], ["← Left Half", "↑ Top Left"], at(.topLeft)),
            ("mirror: left then down", [.move(-0.1, 0, 0.08), downLeg], ["↓ Bottom Left"], at(.bottomLeft)),
            ("mirror: left, rest, down (the half, then its bottom quarter)", [leftLeg, rest, downLeg],
             ["← Left Half", "↓ Bottom Left"], at(.bottomLeft)),
            ("mirror: right, rest, down", [leftLeg.mirrored, rest, downLeg], ["→ Right Half", "↓ Bottom Right"], at(.bottomRight)),
            ("a sideways nudge short of the engage distance, then up: a tilted up",
             [.move(-0.03, 0, 0.06), up(0.25)], ["↑ Maximize"], at(.maximize)),
            ("a long straight left with a gentle arc stays the half", [.move(-0.35, -0.06, 0.25)], ["← Left Half"], at(.leftHalf)),
            ("a long left curving gently up stays the half", [.move(-0.2, -0.02, 0.15), .move(-0.15, -0.045, 0.1)],
             ["← Left Half"], at(.leftHalf)),
        ]
        for (name, legs, expected, place) in chains {
            let desk = Desk(options: user)
            touch(desk, legs)
            XCTAssertEqual(desk.committed, expected, "\(name): shown \(desk.shown)")
            XCTAssertEqual(desk.place, place, name)
            assertNoVerticalHalf(desk, name)
        }
    }

    /// A second touch is never an L, however soon: left, lift, up within
    /// 0.5 s is the half, then Maximize.
    func testASecondTouchSoonAfterIsNotAnL() {
        for gap in [0.1, 0.3, 0.45] {
            let desk = Desk(options: user)
            let end = touch(desk, [.move(-0.15, 0, 0.1)])
            touch(desk, [up(0.25)], at: end + gap)
            XCTAssertEqual(desk.committed, ["← Left Half", "↑ Maximize"], "gap \(gap)")
            XCTAssertEqual(desk.place, at(.maximize))
        }
    }

    // MARK: Modifiers and hold

    /// ⌥ and ⌘ make the sideways swipe a Space or display move, which keeps
    /// committing before the up (3.3.7); ⇧ turns the corner like no
    /// modifier (the corner wins over almost maximize); a held touch's
    /// sideways swipe is a Space move and keeps committing too.
    func testModifiersAndHoldKeepTheirMeaning() {
        let restL: [Leg] = [.move(-0.15, 0, 0.1), .rest(0.6), up(0.25)]
        let continuousL: [Leg] = [.move(-0.1, 0, 0.08), up(0.25)]

        let option = Desk(options: user, modifiers: .general)
        touch(option, restL)
        XCTAssertEqual(option.committed, ["Move to Space ←", "↑ Maximize"], "⌥: a Space, then ⌥ up is a plain up")
        let optionL = Desk(options: user, modifiers: .general)
        touch(optionL, continuousL)
        XCTAssertEqual(optionL.committed, ["Move to Space ←"], "⌥ continuous L: the Space move, as in 3.3.7")

        let command = Desk(options: user, modifiers: .screen)
        touch(command, restL)
        XCTAssertEqual(command.committed.first, "Move to Display ←")
        XCTAssertEqual(command.gestures.count, 2, "⌘: no corner turn")

        let shiftOptions = SwishSnap.effectiveOptions(user, held: [.secondary])
        for legs in [restL, continuousL] {
            let shift = Desk(options: shiftOptions, modifiers: .secondary)
            touch(shift, legs)
            XCTAssertEqual(shift.committed, ["↑ Top Left"], "⇧: the corner")
        }
        let almost = SwishSnap.GestureOptions(downAction: .center, modifierGestures: true, almostMaximize: true)
        let almostDesk = Desk(options: almost)
        touch(almostDesk, restL)
        XCTAssertEqual(almostDesk.committed, ["↑ Top Left"], "Almost Maximize on: the corner")

        // Tap and hold (0.5 s still before swiping): held left is a Space,
        // held up full screen, each its own motion.
        let held = Desk(options: user)
        touch(held, [.rest(0.5)] + restL)
        XCTAssertEqual(held.committed, ["Move to Space ←", "Full Screen"])

        XCTAssertTrue(SwishSnap.cornerTurns(modifiers: [], options: user))
        XCTAssertTrue(SwishSnap.cornerTurns(modifiers: .secondary, options: user))
        XCTAssertFalse(SwishSnap.cornerTurns(modifiers: .general, options: user))
        XCTAssertFalse(SwishSnap.cornerTurns(modifiers: .screen, options: user))
        XCTAssertFalse(SwishSnap.cornerTurns(modifiers: [.general, .secondary], options: user))
        XCTAssertTrue(SwishSnap.cornerTurns(modifiers: .general, options: SwishSnap.GestureOptions(modifierGestures: false)),
                      "modifier gestures off: ⌥ is no modifier")
        XCTAssertTrue(TitleBarSnapRecognizer().cornerTurns, "on by default")
    }

    // MARK: No top or bottom half, and the L, over random touches

    /// Seeded random touches (grids, places, two or three legs any way with
    /// drift, rests, easing): nothing shows or commits the top or bottom
    /// half. Random L shapes (a sideways leg drifting up to 10°, an up leg
    /// drifting up to 20° either way, continuous or resting): always one
    /// commit of that side's top quarter and never Maximize on show.
    func testRandomTouchesNeverReachAVerticalHalfAndRandomLsAreCorners() {
        var seed: UInt64 = 0x338
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        func between(_ a: Double, _ b: Double) -> Double { a + (b - a) * random() }
        let directions: [(Float, Float)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for index in 0..<300 {
            let grid = SwishSnap.Grid.allCases[Int(random() * 3) % 3]
            let cells = grid.cells.map { SwishSnap.Place?.some(.grid($0)) }
            let places: [SwishSnap.Place?] = [nil, .center] + cells
            let start = places[Int(random() * Double(places.count)) % places.count]
            var legs: [Leg] = []
            for leg in 0..<(random() < 0.5 ? 2 : 3) {
                if leg > 0, random() < 0.5 { legs.append(.rest(0.6)) }
                let (ux, uy) = directions[Int(random() * 4) % 4]
                let length = Float(between(0.06, 0.35))
                let drift = Float(tan(between(-25, 25) * .pi / 180))
                let dx = ux != 0 ? ux * length : drift * length / Self.aspect
                let dy = uy != 0 ? uy * length : drift * length * Self.aspect
                legs.append(.move(dx, dy, between(0.05, 0.35)))
            }
            let desk = Desk(options: SwishSnap.GestureOptions(downAction: .center, modifierGestures: true, grid: grid),
                            place: start)
            touch(desk, legs, ease: random() < 0.3)
            assertNoVerticalHalf(desk, "random \(index) \(grid) \(String(describing: start)) \(legs)")
        }
        for index in 0..<300 {
            let mirror = random() < 0.5
            let first = left(Float(between(0.06, 0.35)), between(-10, 10), between(0.05, 0.35))
            let second = up(Float(between(0.1, 0.35)), between(0, 20), back: random() < 0.5, between(0.05, 0.35))
            var legs = random() < 0.4 ? [first, .rest(0.6), second] : [first, second]
            if mirror { legs = legs.map(\.mirrored) }
            let desk = Desk(options: user)
            touch(desk, legs, ease: random() < 0.3)
            let name = mirror ? "↑ Top Right" : "↑ Top Left"
            let context = "L \(index) \(legs): \(desk.shown) → \(desk.committed)"
            XCTAssertEqual(desk.committed, [name], context)
            XCTAssertFalse(desk.shown.contains { $0.contains("Maximize") }, context)
            assertNoVerticalHalf(desk, context)
        }
    }

    // MARK: Pure pieces

    /// `refine`'s turn: past the cross distance it is the cross leg however
    /// long the sideways leg was, and while it lasts the corner keeps its
    /// side. Without a turn (0) 3.3.7's rules apply, including the re-pick
    /// near the start that turned the drifting L into a plain up.
    func testRefineTakesTheTurnAndKeepsTheCornersSide() {
        func refine(_ dx: Float, _ dy: Float, _ axis: SwishSnap.Axis, _ previous: SwishSnap.Stroke?,
                    turn: Float = 0) -> SwishSnap.Stroke? {
            SwishSnap.refine(dx: dx, dy: dy, axis: axis, previous: previous, engage: 0.05, tier2: 0.16, ratio: 1.3,
                             crossEngage: 0.06, crossShare: 0.45, turn: turn)
        }
        XCTAssertEqual(refine(-0.3, -0.07, .horizontal, .init(.left, tier: 2)), .init(.left, tier: 2), "3.3.7: the half")
        XCTAssertEqual(refine(-0.3, -0.07, .horizontal, .init(.left, tier: 2), turn: -0.07), .init(.left, tier: 2, cross: .up))
        XCTAssertEqual(refine(-0.3, 0.07, .horizontal, .init(.left, tier: 2), turn: 0.07), .init(.left, tier: 2, cross: .down))
        XCTAssertEqual(refine(-0.3, -0.05, .horizontal, .init(.left, tier: 2), turn: -0.05), .init(.left, tier: 2),
                       "a turn short of the cross distance is not yet a leg")
        XCTAssertEqual(refine(-0.35, 0.04, .horizontal, .init(.left, tier: 2), turn: -0.1), .init(.left, tier: 2, cross: .up),
                       "left drifting down, then up: the turn's way")
        XCTAssertEqual(refine(-0.01, -0.3, .horizontal, .init(.left, cross: .up)), .init(.up, tier: 2),
                       "3.3.7's cause: back near the start the axis is re-picked as up")
        XCTAssertEqual(refine(-0.01, -0.3, .horizontal, .init(.left, cross: .up), turn: -0.25), .init(.left, cross: .up))
        XCTAssertEqual(refine(0.06, -0.4, .horizontal, .init(.left, cross: .up), turn: -0.35), .init(.left, tier: 1, cross: .up),
                       "past the start the other way, the corner keeps its side")
        XCTAssertEqual(refine(-0.03, -0.3, .vertical, .init(.up), turn: -0.2), .init(.up, tier: 2),
                       "a vertical stroke has no turn: up stays up")
    }

    /// The tooltip's arrow: a quarter shows its vertical leg, so an L going
    /// up reads "↑ Top Left"; anything else its direction.
    func testTheTooltipShowsTheLsUpLeg() {
        let rows: [(SwishSnap.Stroke, SwishSnap.Direction)] = [
            (.init(.left, cross: .up), .up), (.init(.right, cross: .up), .up),
            (.init(.left, cross: .down), .down), (.init(.right, tier: 2, cross: .down), .down),
            (.init(.up, cross: .left), .up), (.init(.down, cross: .right), .down),
            (.init(.left), .left), (.init(.right), .right), (.init(.up), .up), (.init(.down), .down),
            (.init(.left, cross: .left), .left),
        ]
        for (stroke, arrow) in rows {
            XCTAssertEqual(SwishSnap.tooltipDirection(for: stroke), arrow, "\(stroke)")
        }
        XCTAssertEqual(SwishSnap.tooltipText(direction: SwishSnap.tooltipDirection(for: .init(.left, cross: .up)),
                                             place: at(.topLeft)), "↑ Top Left")
        XCTAssertEqual(SwishSnap.tooltipText(direction: SwishSnap.tooltipDirection(for: .init(.right, cross: .up)),
                                             place: at(.topRight)), "↑ Top Right")
    }
}
