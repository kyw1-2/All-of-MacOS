import XCTest
@testable import AllOfMacOS

/// N334: a swipe up on a title bar maximizes, however long, fast or lifted it
/// is. Until now a swipe past the longer-swipe distance (0.16 of the pad,
/// measured from touch-down) took the top half, so a quick flick, a long swipe
/// or the slide of the lifting fingers often showed and committed the top half
/// before the maximize the user meant. 3.3.4–3.3.6 then took the top half with
/// Swish's double swipe up; N337 removed it (the user's rule: a swipe up always
/// maximizes, and no gesture takes the top or bottom half). Pure: the mapping
/// and the recognizer fed with frames on an injected clock; no trackpad,
/// Accessibility or windows.
final class N334SwipeUpMaximizeTests: XCTestCase {
    // MARK: Helpers

    private let swish = SwishSnap.GestureOptions()

    private func up(_ tier: Int = 1) -> SwishSnap.Stroke { .init(.up, tier: tier) }

    private func at(_ layout: CustomSnapZone.Layout) -> SwishSnap.Place { SwishSnap.Place(layout)! }

    private func move(_ place: SwishSnap.Place?, _ stroke: SwishSnap.Stroke,
                      _ options: SwishSnap.GestureOptions = SwishSnap.GestureOptions(),
                      modifiers: SwishSnap.Modifiers = []) -> SwishSnap.Move? {
        SwishSnap.move(at: place, stroke: stroke, modifiers: modifiers, options: options)
    }

    /// Two fingers 0.02 apart whose centroid sits at (x, y) in the snap's pad
    /// coordinates (y toward the bottom of the pad, so a swipe up lowers y),
    /// at `size` of their peak contact size.
    private func pair(_ x: Float, _ y: Float, size: Float = 1) -> [TouchPoint] {
        [TouchPoint(id: 1, x: x - 0.01, y: 1 - y, size: size, pressure: 0),
         TouchPoint(id: 2, x: x + 0.01, y: 1 - y, size: size, pressure: 0)]
    }

    /// The title-bar snap's decisions without windows or Accessibility: each
    /// gesture starts from where the last commit put the window, every stroke
    /// it shows is planned with `SwishSnap.move(at:…)`, a commit lands at once
    /// (most apps take `WindowManager.applySnap`'s immediate write). Labels
    /// are what the tooltip (or the HUD) says.
    private final class Desk {
        let recognizer = TitleBarSnapRecognizer()
        var options = SwishSnap.GestureOptions()
        /// Where the window is now; the next gesture starts there.
        var place: SwishSnap.Place?
        /// Per gesture, what each stroke on show said.
        private(set) var gestures: [[String]] = []
        private(set) var committed: [String] = []
        private(set) var strokes: [SwishSnap.Stroke] = []
        private(set) var readies = 0
        private var start: SwishSnap.Place?
        private var stroke: SwishSnap.Stroke?

        init(sensitivity: Double = TitleBarWindowSnap.sensitivityDefault) {
            let distances = TitleBarWindowSnap.distances(sensitivity: sensitivity)
            recognizer.engage = distances.engage
            recognizer.crossEngage = distances.crossEngage
            recognizer.onBegin = { [unowned self] stroke in
                self.start = self.place
                self.gestures.append([])
                self.show(stroke)
            }
            recognizer.onUpdate = { [unowned self] stroke in self.show(stroke) }
            recognizer.onCommit = { [unowned self] in self.commit() }
            recognizer.onCancel = { [unowned self] in self.stroke = nil }
            recognizer.onMotionReady = { [unowned self] in self.readies += 1 }
        }

        func feed(_ contacts: [TouchPoint], at time: Double) {
            recognizer.feed(contacts: contacts, timestamp: time)
        }

        private func plan(_ stroke: SwishSnap.Stroke) -> SwishSnap.Move? {
            SwishSnap.move(at: start, stroke: stroke, modifiers: [], options: options)
        }

        private func show(_ stroke: SwishSnap.Stroke) {
            self.stroke = stroke
            strokes.append(stroke)
            if gestures.isEmpty { gestures.append([]) }
            gestures[gestures.count - 1].append(Self.label(plan(stroke), stroke.direction))
        }

        private func commit() {
            guard let stroke else { return }
            let move = plan(stroke)
            committed.append(Self.label(move, stroke.direction))
            switch move {
            case .cell?, .place?, .restore?: place = move?.destination
            case .action?, nil: break
            }
            self.stroke = nil
        }

        static func label(_ move: SwishSnap.Move?, _ direction: SwishSnap.Direction) -> String {
            switch move {
            case .action(let action)?: return SwishSnap.title(for: action, appName: nil)
            case .restore?: return SwishSnap.tooltipText(direction: direction, place: nil)
            case let move?: return SwishSnap.tooltipText(direction: direction, place: move.destination)
            case nil: return "nothing"
            }
        }
    }

    /// One swipe up from `fromY` to `toY` starting at `time`: touch-down, then
    /// 60 Hz frames over `duration`, then the lift.
    private func swipeUp(_ desk: Desk, fromY: Float = 0.80, toY: Float, at time: Double, duration: Double = 0.25) {
        desk.feed(pair(0.5, fromY), at: time)
        let frames = max(1, Int((duration * 60).rounded()))
        for frame in 1...frames {
            let share = Float(frame) / Float(frames)
            desk.feed(pair(0.5, fromY + (toY - fromY) * share), at: time + duration * Double(frame) / Double(frames))
        }
        desk.feed([], at: time + duration + 0.02)
    }

    // MARK: A single swipe up maximizes

    func testASwipeUpMaximizesAFreeCentredOrMaximizedWindowAtAnyLength() {
        for tier in [1, 2] {
            for start: SwishSnap.Place? in [nil, .center, at(.maximize)] {
                XCTAssertEqual(move(start, up(tier)), .cell(.maximize), "\(String(describing: start)) tier \(tier)")
            }
            let almost = SwishSnap.GestureOptions(almostMaximize: true)
            XCTAssertEqual(move(nil, up(tier), almost), .place(.almostMaximize), "Almost Maximize on")
            XCTAssertEqual(move(.almostMaximize, up(tier), almost), .cell(.maximize), "up again maximizes")
            XCTAssertEqual(move(.almostMaximize, up(tier)), .cell(.maximize), "off: a remembered almost-maximize is free")
        }
        XCTAssertEqual(SwishSnap.layout(for: .up, tier: 2), .maximize)
        XCTAssertEqual(SwishSnap.layout(for: up(2)), .maximize)
        XCTAssertEqual(SwishSnap.step(from: nil, stroke: up(2), grid: .twoByTwo), .cell(.maximize))
        XCTAssertEqual(SwishSnap.move(from: nil, stroke: up(2), thirds: true), .cell(.maximize))
    }

    func testWithSecondaryASwipeUpAlmostMaximizesAtAnyLength() {
        let secondary = SwishSnap.effectiveOptions(swish, held: [.secondary])
        for tier in [1, 2] {
            XCTAssertEqual(move(nil, up(tier), secondary, modifiers: .secondary), .place(.almostMaximize))
            XCTAssertEqual(move(.center, up(tier), secondary, modifiers: .secondary), .place(.almostMaximize))
            XCTAssertEqual(move(.almostMaximize, up(tier), secondary, modifiers: .secondary), .cell(.maximize),
                           "from almost-maximized, up maximizes as before")
            XCTAssertEqual(move(at(.maximize), up(tier), secondary, modifiers: .secondary), .cell(.maximize))
        }
    }

    /// Every grid, Almost Maximize on or off, either down option, both tiers:
    /// a free, centred, almost-maximized or maximized window swiped up is
    /// maximized or almost-maximized, never put in the top half.
    func testNoSingleSwipeUpFromAFreeOrMaximizedPlaceIsTheTopHalf() {
        for grid in SwishSnap.Grid.allCases {
            for almost in [false, true] {
                for downAction in SwishSnap.DownAction.allCases {
                    let options = SwishSnap.GestureOptions(downAction: downAction, grid: grid, almostMaximize: almost)
                    for start: SwishSnap.Place? in [nil, .center, .almostMaximize, .grid(.full)] {
                        for tier in [1, 2] {
                            let result = move(start, up(tier), options)
                            XCTAssertTrue(result == .cell(.maximize) || result == .place(.almostMaximize),
                                          "\(grid) almost \(almost) \(downAction) \(String(describing: start)) tier \(tier) → \(String(describing: result))")
                        }
                    }
                }
            }
        }
    }

    /// The tier never matters for a swipe up, from any place of any grid, so a
    /// swipe growing past the longer-swipe distance never re-presents another
    /// plan: no new preview, tooltip or zone haptic half-way.
    func testTheTierNeverChangesWhereASwipeUpGoes() {
        for grid in SwishSnap.Grid.allCases {
            for almost in [false, true] {
                let options = SwishSnap.GestureOptions(grid: grid, almostMaximize: almost)
                let starts: [SwishSnap.Place?] = [nil, .center, .almostMaximize] + grid.cells.map { .grid($0) }
                for start in starts {
                    XCTAssertEqual(move(start, up(1), options), move(start, up(2), options),
                                   "\(grid) almost \(almost) \(String(describing: start))")
                }
            }
        }
    }

    // MARK: N337: no swipe up chains any more

    /// 3.3.4–3.3.6 chained a swipe up from a half or quarter (left half →
    /// top-left, bottom-right → top-right, top-left → top half). N337: every
    /// one maximizes.
    func testTheOtherSwipesUpMaximizeToo() {
        for tier in [1, 2] {
            for layout: CustomSnapZone.Layout in [.bottomHalf, .topLeft, .topRight, .topHalf, .leftHalf, .rightHalf,
                                                  .bottomLeft, .bottomRight] {
                XCTAssertEqual(move(at(layout), up(tier)), .cell(.maximize), "\(layout) tier \(tier)")
            }
        }
    }

    /// The second cause: a large free window flush with the top-left corner
    /// of the visible area only overflows the top-left quarter. Read as that
    /// quarter (the reading kept for size-limited windows), a swipe up put it
    /// in the top half. A swipe up reads only remembered or filled cells, so
    /// it maximizes; down and diagonals keep the overflow reading.
    func testALargeFreeWindowFlushWithACornerOrAnEdgeMaximizesOnASwipeUp() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let large = CGRect(x: 0, y: 25, width: 1000, height: 700)
        let overflowRead = SwishSnap.place(of: large, visible: visible, margin: 0, grid: .twoByTwo)
        XCTAssertEqual(overflowRead, at(.topLeft), "the overflow reading, kept for down")
        let upRead = SwishSnap.place(of: large, visible: visible, margin: 0, grid: .twoByTwo, overflowing: false)
        XCTAssertNil(upRead, "a swipe up sees a free window")
        let upStart = TitleBarWindowSnap.place(forStroke: up(), start: overflowRead, startForUp: upRead)
        XCTAssertEqual(move(upStart, up()), .cell(.maximize))
        XCTAssertEqual(move(upStart, up(2)), .cell(.maximize))
        let downStart = TitleBarWindowSnap.place(forStroke: .init(.down), start: overflowRead, startForUp: upRead)
        XCTAssertEqual(move(downStart, .init(.down)), .cell(.bottomLeft), "down still chains from the quarter")
        XCTAssertEqual(TitleBarWindowSnap.place(forStroke: .init(.up, cross: .left), start: overflowRead, startForUp: upRead),
                       overflowRead, "a diagonal keeps the overflow reading")
        // Flush with the left edge, wider than half and full height: free for a swipe up too.
        let wideLeft = CGRect(x: 0, y: 25, width: 900, height: 875)
        XCTAssertNil(SwishSnap.place(of: wideLeft, visible: visible, margin: 0, grid: .twoByTwo, overflowing: false))
        // A cell the window fills chains up as before.
        let filled = CGRect(x: 0, y: 25, width: 720, height: 875)
        let filledRead = SwishSnap.place(of: filled, visible: visible, margin: 0, grid: .twoByTwo, overflowing: false)
        XCTAssertEqual(filledRead, at(.leftHalf))
        XCTAssertEqual(move(filledRead, up()), .cell(.maximize), "N337: a filled half maximizes too")
        XCTAssertEqual(SwishSnap.cell(of: large, visible: visible, margin: 0, thirds: false, overflowing: false), nil)
        XCTAssertEqual(SwishSnap.cell(of: large, visible: visible, margin: 0, thirds: false), .topLeft, "the default is unchanged")
    }

    /// N335: down lost its longer swipe as up did in N334 (Swish: "Swipe
    /// down once to minimize a window"). Sideways keeps its longer swipe for
    /// thirds.
    func testDownAndSidewaysKeepTheirLongerSwipes() {
        XCTAssertEqual(move(nil, .init(.down)), .action(.minimize))
        XCTAssertEqual(move(.center, .init(.down)), .action(.minimize))
        XCTAssertEqual(move(nil, .init(.down, tier: 2)), .action(.minimize))
        XCTAssertEqual(move(at(.maximize), .init(.down)), .restore)
        XCTAssertEqual(move(at(.maximize), .init(.down, tier: 2)), .restore)
        XCTAssertEqual(move(.almostMaximize, .init(.down, tier: 2), .init(almostMaximize: true)), .restore)
        var center = swish
        center.downAction = .center
        XCTAssertEqual(move(nil, .init(.down), center), .cell(.center))
        XCTAssertEqual(move(nil, .init(.down, tier: 2), center), .cell(.center))
        let thirds = SwishSnap.GestureOptions(thirds: true)
        XCTAssertEqual(move(nil, .init(.left, tier: 2), thirds), .cell(.leftThird))
        XCTAssertEqual(move(nil, .init(.right, tier: 2), thirds), .cell(.rightThird))
        XCTAssertEqual(move(nil, .init(.left, tier: 2)), .cell(.leftHalf), "2 × 2: no thirds")
        XCTAssertEqual(SwishSnap.layout(for: .down, tier: 2), .center)
        XCTAssertEqual(SwishSnap.layout(for: .right, tier: 2), .rightThird)
    }

    /// The ⌃⌥ hotkeys send a plain swipe, so ⌃⌥↑ still maximizes and ⌃⌥⇧↑
    /// still almost-maximizes.
    func testTheUpHotkeysAreUnchanged() {
        let chord: NSEvent.ModifierFlags = [.control, .option]
        func command(_ flags: NSEvent.ModifierFlags) -> SwishSnap.HotkeyCommand? {
            SwishSnap.hotkeyCommand(keyCode: 126, modifiers: flags, scheme: .arrows, center: .escape, roles: .standard)
        }
        XCTAssertEqual(command(chord), .swipe(.up))
        XCTAssertEqual(command(chord.union(.shift)), .secondary(.up))
        XCTAssertEqual(move(nil, .init(.up)), .cell(.maximize))
        XCTAssertEqual(move(at(.maximize), .init(.up)), .cell(.maximize))
        let secondary = SwishSnap.effectiveOptions(swish, held: [.secondary])
        XCTAssertEqual(move(nil, .init(.up), secondary, modifiers: .init(held: [.secondary])), .place(.almostMaximize))
        XCTAssertEqual(move(at(.bottomRight), .init(.up)), .cell(.maximize), "N337: ⌃⌥↑ maximizes from a quarter too")
    }

    // MARK: N337: a second swipe up stays maximized

    /// 3.3.4–3.3.6: a second swipe up on the maximized window (separate
    /// within 0.5 s, or after a rest in the same touch) took the top half.
    func testASecondSwipeUpOnTheMaximizedWindowStaysMaximized() {
        let full = at(.maximize)
        XCTAssertEqual(move(full, up()), .cell(.maximize))
        XCTAssertEqual(move(full, up(2)), .cell(.maximize))
        XCTAssertEqual(move(full, up(), modifiers: .general), .cell(.maximize), "⌥ up is a plain swipe up")
        XCTAssertEqual(move(full, up(), SwishSnap.effectiveOptions(swish, held: [.secondary]), modifiers: .secondary),
                       .cell(.maximize))
        XCTAssertEqual(move(full, .init(.left)), .cell(.leftHalf))
        XCTAssertEqual(move(full, .init(.up, cross: .left)), .cell(.topLeft), "a diagonal still picks its quarter")
        XCTAssertEqual(move(full, .init(.up, held: true)), .action(.toggleFullscreen))
        XCTAssertEqual(move(full, up(), modifiers: .screen), .action(.screen(.up)))
        XCTAssertNil(SwishSnap.move(at: full, stroke: up(), modifiers: [], options: swish, fullscreen: true))
    }

    // MARK: Frames from the pad: one swipe up is one maximize

    /// A long swipe up (0.35 of the pad, past twice the longer-swipe distance)
    /// shows and commits the maximize on every frame, at every sensitivity.
    func testALongSwipeUpShowsAndCommitsOnlyTheMaximize() {
        for sensitivity in [0.8, 1.0, 1.25, 1.6, 2.0] {
            let desk = Desk(sensitivity: sensitivity)
            swipeUp(desk, fromY: 0.80, toY: 0.45, at: 0)
            XCTAssertTrue(desk.strokes.contains { $0.tier == 2 }, "the swipe went past the longer-swipe distance (\(sensitivity))")
            XCTAssertEqual(desk.gestures.count, 1, "\(sensitivity)")
            XCTAssertEqual(Set(desk.gestures.first ?? []), ["↑ Maximize"], "\(sensitivity)")
            XCTAssertEqual(desk.committed, ["↑ Maximize"], "\(sensitivity)")
        }
    }

    /// A flick so fast that the first frame after the touch-down settle is
    /// already past the longer-swipe distance: the very first preview is the
    /// maximize.
    func testAFlickWhoseFirstFrameIsPastTheLongerSwipeMaximizes() {
        for sensitivity in [0.8, 1.25, 2.0] {
            let desk = Desk(sensitivity: sensitivity)
            desk.feed(pair(0.5, 0.80), at: 0)
            desk.feed(pair(0.5, 0.58), at: 0.045)
            desk.feed([], at: 0.06)
            XCTAssertEqual(desk.strokes.first, up(2), "engaged at tier 2 (\(sensitivity))")
            XCTAssertEqual(desk.gestures, [["↑ Maximize"]], "\(sensitivity)")
            XCTAssertEqual(desk.committed, ["↑ Maximize"], "\(sensitivity)")
        }
    }

    /// The fingers' last positions slide up the pad as they lift; while the
    /// contacts are still large that slide counts and pushes the tier to 2.
    func testTheLiftSlideNeverTurnsTheMaximizeIntoTheTopHalf() {
        let desk = Desk()
        desk.feed(pair(0.5, 0.75), at: 0)
        desk.feed(pair(0.5, 0.69), at: 0.05)              // engages up
        desk.feed(pair(0.5, 0.65), at: 0.07)
        desk.feed(pair(0.5, 0.55, size: 0.7), at: 0.09)   // lifting, still counted: 0.20 travelled
        desk.feed(pair(0.5, 0.45, size: 0.4), at: 0.10)   // lifting: ignored
        desk.feed([TouchPoint(id: 1, x: 0.49, y: 0.6, size: 0.2, pressure: 0)], at: 0.11)
        XCTAssertEqual(desk.strokes.last, up(2), "the slide reached the longer-swipe distance")
        XCTAssertEqual(desk.gestures, [["↑ Maximize", "↑ Maximize"]])
        XCTAssertEqual(desk.committed, ["↑ Maximize"])
    }

    /// Swish's multi-motion: up, a pause that locks it (haptic), then up again
    /// in the same touch. 3.3.5–3.3.6 held the maximize back and took the top
    /// half (Swish's "Try swiping up twice"); N337: the maximize commits as
    /// the fingers move on, and the second swipe keeps it maximized.
    func testAPauseLockThenMoreSwipeUpInTheSameTouchStaysMaximized() {
        let desk = Desk()
        desk.feed(pair(0.5, 0.80), at: 0)
        desk.feed(pair(0.5, 0.70), at: 0.05)               // engages up
        desk.feed(pair(0.5, 0.66), at: 0.07)
        for t in [0.10, 0.15, 0.20, 0.25, 0.30, 0.35] { desk.feed(pair(0.5, 0.66), at: t) }
        XCTAssertEqual(desk.readies, 1, "the pause locked the swipe")
        desk.feed(pair(0.5, 0.60), at: 0.40)               // moves on: the maximize commits
        XCTAssertEqual(desk.committed, ["↑ Maximize"])
        desk.feed(pair(0.5, 0.40), at: 0.42)               // 0.26 from the pause: tier 2
        desk.feed([], at: 0.45)
        XCTAssertEqual(desk.recognizer.motionIndex, 1, "the touch's second gesture")
        XCTAssertTrue(desk.strokes.contains(up(2)))
        XCTAssertEqual(desk.gestures.count, 2)
        XCTAssertEqual(Set(desk.gestures[0]), ["↑ Maximize"])
        XCTAssertEqual(Set(desk.gestures[1]), ["↑ Maximize"], "every frame of the second swipe")
        XCTAssertEqual(desk.committed, ["↑ Maximize", "↑ Maximize"])
        XCTAssertEqual(desk.place, at(.maximize))
    }

    // MARK: Frames from the pad: a second, separate swipe up

    /// Up, lift, and up again within half a second (3.3.4–3.3.6: the top
    /// half): N337, maximized again, on every frame.
    func testASecondSwipeUpWithinHalfASecondStaysMaximized() {
        let desk = Desk()
        swipeUp(desk, toY: 0.60, at: 0, duration: 0.08)    // lands at 0.10
        XCTAssertEqual(desk.committed, ["↑ Maximize"])
        XCTAssertEqual(desk.place, at(.maximize))
        desk.feed(pair(0.5, 0.80), at: 0.30)               // a new touch
        desk.feed(pair(0.5, 0.70), at: 0.35)               // engages 0.25 s after the landing
        desk.feed(pair(0.5, 0.55), at: 0.38)
        desk.feed([], at: 0.40)
        XCTAssertEqual(desk.gestures.count, 2)
        XCTAssertEqual(Set(desk.gestures[1]), ["↑ Maximize"])
        XCTAssertEqual(desk.committed, ["↑ Maximize", "↑ Maximize"])
        XCTAssertEqual(desk.place, at(.maximize))
    }

    func testASecondSwipeUpAfterHalfASecondStaysMaximized() {
        let desk = Desk()
        swipeUp(desk, toY: 0.60, at: 0, duration: 0.08)    // lands at 0.10
        swipeUp(desk, toY: 0.55, at: 0.65, duration: 0.08) // engages about 0.6 s after
        XCTAssertEqual(desk.committed, ["↑ Maximize", "↑ Maximize"])
        XCTAssertEqual(desk.gestures.flatMap { $0 }.filter { $0 != "↑ Maximize" }, [])
    }

    /// With ⇧ (Secondary) the first swipe up almost-maximizes, and a quick
    /// second one maximizes (N337: never the top half).
    func testWithSecondaryTwoQuickSwipesUpAlmostMaximizeThenMaximize() {
        let desk = Desk()
        desk.options = SwishSnap.effectiveOptions(swish, held: [.secondary])
        swipeUp(desk, toY: 0.45, at: 0, duration: 0.15)    // long: still almost maximize
        XCTAssertEqual(desk.committed, ["↑ Almost Maximize"])
        swipeUp(desk, toY: 0.55, at: 0.35, duration: 0.08)
        XCTAssertEqual(desk.committed, ["↑ Almost Maximize", "↑ Maximize"])
    }
}
