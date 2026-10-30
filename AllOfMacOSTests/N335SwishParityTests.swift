import XCTest
@testable import AllOfMacOS

/// N335: the title-bar snap brought closer to Swish 1.13 where the evidence is
/// clear (its gesture help strings: "Swipe down once to minimize a window",
/// "Double-swipe vertically to snap to the top or bottom half of the screen",
/// "Try swiping up twice on the titlebar of this window" with the multi-motion
/// engine, "Unsnap: Avoid cropping"), and a swipe that can be taken back.
/// Pure: the mapping, the recognizer fed with frames and a model of the
/// service's sequencing (`Desk`) on an injected clock; no trackpad,
/// Accessibility or windows.
final class N335SwishParityTests: XCTestCase {
    // MARK: Helpers

    private func at(_ layout: CustomSnapZone.Layout) -> SwishSnap.Place { SwishSnap.Place(layout)! }

    private func move(_ place: SwishSnap.Place?, _ stroke: SwishSnap.Stroke,
                      _ options: SwishSnap.GestureOptions = SwishSnap.GestureOptions(),
                      modifiers: SwishSnap.Modifiers = [], double: SwishSnap.Direction? = nil,
                      fullscreen: Bool = false) -> SwishSnap.Move? {
        SwishSnap.move(at: place, stroke: stroke, modifiers: modifiers, options: options, fullscreen: fullscreen,
                       doubleSwipe: double)
    }

    private var centerOption: SwishSnap.GestureOptions {
        var options = SwishSnap.GestureOptions()
        options.downAction = .center
        return options
    }

    /// Two fingers 0.02 apart whose centroid sits at (x, y) in the snap's pad
    /// coordinates (y toward the bottom of the pad: a swipe down raises y).
    private func pair(_ x: Float, _ y: Float) -> [TouchPoint] {
        [TouchPoint(id: 1, x: x - 0.01, y: 1 - y, size: 1, pressure: 0),
         TouchPoint(id: 2, x: x + 0.01, y: 1 - y, size: 1, pressure: 0)]
    }

    /// The title-bar snap's decisions as `TitleBarWindowSnap` takes them:
    /// `begin` (the window's place, the separate double swipe from the
    /// tracker, the double swipe carried by the commit just before),
    /// `showPreview`/`plan(for:)` (labels as the tooltip says them),
    /// `withdraw`, `commit(continuingWith:)` (the double swipe in one touch)
    /// and `finishCommit` (what a landing arms). Commits land at once.
    private final class Desk {
        let recognizer = TitleBarSnapRecognizer()
        var options = SwishSnap.GestureOptions()
        var place: SwishSnap.Place?
        var key = "w"
        var tracker = SwishDoubleSwipeUp()
        private(set) var gestures: [[String]] = []
        private(set) var committed: [String] = []
        private(set) var withdrawals = 0
        private(set) var readies = 0
        private(set) var minimized = false
        private var start: SwishSnap.Place?
        private var secondUp = false
        private var double: SwishSnap.Direction?
        private var carried: SwishSnap.Direction?
        private var stroke: SwishSnap.Stroke?
        private var now: Double = 0

        init(motionPause: Double = 0.25) {
            let distances = TitleBarWindowSnap.distances(sensitivity: TitleBarWindowSnap.sensitivityDefault)
            recognizer.engage = distances.engage
            recognizer.crossEngage = distances.crossEngage
            recognizer.motionPause = motionPause
            recognizer.onBegin = { [unowned self] stroke in
                let carried = self.carried
                self.carried = nil
                self.start = self.place
                let separate = self.tracker.secondSwipe(key: self.key, newTouch: self.recognizer.motionIndex == 0,
                                                        at: self.now)
                self.secondUp = separate == .up
                self.double = carried ?? (separate == .down ? .down : nil)
                self.gestures.append([])
                self.show(stroke)
            }
            recognizer.onUpdate = { [unowned self] stroke in self.show(stroke) }
            recognizer.onWithdraw = { [unowned self] in
                self.withdrawals += 1
                self.stroke = nil
                self.gestures[self.gestures.count - 1].append("nothing")
            }
            recognizer.onCommit = { [unowned self] in self.commit(continuingWith: nil) }
            recognizer.onMotionCommit = { [unowned self] next in self.commit(continuingWith: next) }
            recognizer.onCancel = { [unowned self] in self.stroke = nil; self.double = nil; self.secondUp = false }
            recognizer.onMotionReady = { [unowned self] in
                // `TitleBarWindowSnap.motionReady`: only with something planned.
                if SwishSnap.motionReadyHaptic(planOnShow: self.stroke != nil, motionQueued: false) { self.readies += 1 }
            }
        }

        func feed(_ contacts: [TouchPoint], at time: Double) {
            now = time
            recognizer.feed(contacts: contacts, timestamp: time)
        }

        func plan(_ stroke: SwishSnap.Stroke) -> SwishSnap.Move? {
            SwishSnap.move(at: start, stroke: stroke, modifiers: [], options: options, secondSwipeUp: secondUp,
                           doubleSwipe: double)
        }

        private func label(_ move: SwishSnap.Move?, _ stroke: SwishSnap.Stroke) -> String {
            switch move {
            case .action(let action)?: return SwishSnap.title(for: action, appName: nil)
            case .restore?: return SwishSnap.tooltipText(direction: stroke.direction, place: nil)
            case let move?:
                let twice = SwishSnap.isDoubleSwipeResult(move, stroke: stroke, double: secondUp ? .up : double)
                return SwishSnap.tooltipText(direction: stroke.direction, place: move.destination, double: twice)
            case nil: return "nothing"
            }
        }

        private func show(_ stroke: SwishSnap.Stroke) {
            self.stroke = stroke
            gestures[gestures.count - 1].append(label(plan(stroke), stroke))
        }

        private func commit(continuingWith next: SwishSnap.Stroke?) {
            guard let stroke else { return }
            let move = plan(stroke)
            if let next, let direction = SwishSnap.doubleSwipe(first: stroke, firstMove: move, next: next) {
                carried = direction
                self.stroke = nil
                return
            }
            committed.append(label(move, stroke))
            switch move {
            case .cell?, .place?:
                place = move?.destination
                tracker.commitEnded(key: key, vertical: SwishDoubleSwipeUp.arming(direction: stroke.direction,
                                                                                  place: place, action: nil), at: now)
            case .restore?:
                place = nil
                tracker.commitEnded(key: key, vertical: SwishDoubleSwipeUp.arming(direction: stroke.direction,
                                                                                  place: nil, action: nil), at: now)
            case .action(.minimize)?:
                minimized = true
                tracker.commitEnded(key: key, vertical: nil, at: now)
            case .action?, nil:
                break
            }
            self.stroke = nil
            double = nil
            secondUp = false
        }
    }

    /// From `from` to `to` over `duration` at 60 Hz, starting at `time`
    /// (no touch-down, no lift).
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

    /// A vertical swipe, a rest that locks it, the same swipe again, lift.
    private func doubleSwipe(_ desk: Desk, down: Bool, pause: Double = 0.35) {
        let sign: Float = down ? 1 : -1
        let y0: Float = 0.5
        desk.feed(pair(0.5, y0), at: 0)
        slide(desk, from: (0.5, y0), to: (0.5, y0 + sign * 0.12), at: 0, duration: 0.08)
        rest(desk, at: (0.5, y0 + sign * 0.12), from: 0.09, duration: pause)
        let t = 0.10 + pause
        slide(desk, from: (0.5, y0 + sign * 0.12), to: (0.5, y0 + sign * 0.30), at: t, duration: 0.10)
        desk.feed([], at: t + 0.12)
    }

    /// One vertical swipe of 0.12 from (0.5, 0.5) at `time`, then the lift.
    private func swipe(_ desk: Desk, down: Bool, at time: Double, length: Float = 0.12) {
        let sign: Float = down ? 1 : -1
        desk.feed(pair(0.5, 0.5), at: time)
        slide(desk, from: (0.5, 0.5), to: (0.5, 0.5 + sign * length), at: time, duration: 0.08)
        desk.feed([], at: time + 0.10)
    }

    // MARK: 1. Down at any length is the single swipe down

    /// Until 3.3.5 a swipe down past 0.16 of the pad (a flick, a long swipe,
    /// the lift slide) took the bottom half instead of the centre or the
    /// minimize. Swish: "Swipe down once to minimize a window."
    func testASwipeDownAtAnyLengthIsTheDownAction() {
        for tier in [1, 2] {
            let down = SwishSnap.Stroke(.down, tier: tier)
            XCTAssertEqual(move(nil, down), .action(.minimize), "tier \(tier)")
            XCTAssertEqual(move(.center, down), .action(.minimize), "tier \(tier)")
            XCTAssertEqual(move(nil, down, centerOption), .cell(.center), "tier \(tier)")
            XCTAssertEqual(move(.center, down, centerOption), .restore, "tier \(tier)")
            for grid in SwishSnap.Grid.allCases {
                XCTAssertEqual(SwishSnap.step(from: nil, stroke: down, grid: grid), .cell(.center), "\(grid) tier \(tier)")
            }
        }
        XCTAssertEqual(SwishSnap.layout(for: .down, tier: 2), .center)
        // Chains and L-shapes are untouched.
        XCTAssertEqual(move(at(.topHalf), .init(.down, tier: 2)), .cell(.bottomHalf))
        XCTAssertEqual(move(at(.topLeft), .init(.down, tier: 2)), .cell(.bottomLeft))
        XCTAssertEqual(move(nil, .init(.down, tier: 2, cross: .left)), .cell(.bottomLeft))
    }

    /// A long swipe down from frames: one plan on every frame, one commit.
    func testALongSwipeDownFromFramesShowsAndCommitsOnlyTheCentre() {
        let desk = Desk()
        desk.options = centerOption
        swipe(desk, down: true, at: 0, length: 0.35)
        XCTAssertEqual(desk.gestures.count, 1)
        XCTAssertEqual(Set(desk.gestures[0]), ["↓ Center"])
        XCTAssertEqual(desk.committed, ["↓ Center"])
    }

    // MARK: 2. From maximized, down at any length restores

    func testFromMaximizedOrAlmostMaximizedASwipeDownRestoresAtAnyLength() {
        let almost = SwishSnap.GestureOptions(almostMaximize: true)
        for tier in [1, 2] {
            let down = SwishSnap.Stroke(.down, tier: tier)
            XCTAssertEqual(move(at(.maximize), down), .restore, "tier \(tier)")
            XCTAssertEqual(move(at(.maximize), down, centerOption), .restore, "tier \(tier)")
            XCTAssertEqual(move(.almostMaximize, down, almost), .restore, "tier \(tier)")
            XCTAssertEqual(SwishSnap.step(from: at(.maximize), stroke: down, grid: .threeByThree), .restore)
        }
    }

    // MARK: 3–5. The double swipe in one touch

    /// Swish's "Try swiping up twice on the titlebar" (multi-motion): up, a
    /// rest (haptic), up again. The maximize never lands; the second swipe
    /// shows "↑↑ Top Half" from its first frame and commits it.
    func testUpPauseUpInOneTouchIsTheTopHalf() {
        for pause in [0.35, 0.6] {
            let desk = Desk(motionPause: pause == 0.6 ? 0.5 : 0.25)   // the user's 0.5 s too
            doubleSwipe(desk, down: false, pause: pause)
            XCTAssertEqual(desk.readies, 1, "the rest locked the swipe (\(pause))")
            XCTAssertEqual(desk.gestures.count, 2)
            XCTAssertEqual(Set(desk.gestures[0]), ["↑ Maximize"])
            XCTAssertEqual(Set(desk.gestures[1]), ["↑↑ Top Half"])
            XCTAssertEqual(desk.committed, ["↑↑ Top Half"], "no maximize first")
            XCTAssertEqual(desk.place, at(.topHalf))
        }
    }

    /// With the Center option a second swipe down put the centred window back
    /// (3.3.4); Swish's double swipe down takes the bottom half, and the
    /// centre never lands.
    func testDownPauseDownInOneTouchIsTheBottomHalf() {
        let desk = Desk()
        desk.options = centerOption
        doubleSwipe(desk, down: true)
        XCTAssertEqual(Set(desk.gestures[0]), ["↓ Center"])
        XCTAssertEqual(Set(desk.gestures[1]), ["↓↓ Bottom Half"])
        XCTAssertEqual(desk.committed, ["↓↓ Bottom Half"])
        XCTAssertEqual(desk.place, at(.bottomHalf))
        // From maximized: the restore never lands either.
        let full = Desk()
        full.options = centerOption
        full.place = at(.maximize)
        doubleSwipe(full, down: true)
        XCTAssertEqual(Set(full.gestures[0]), ["↓ Restore"])
        XCTAssertEqual(full.committed, ["↓↓ Bottom Half"])
    }

    /// With Minimize (Swish's default), the first swipe down used to minimize
    /// the window as the second one began, so the double swipe could never
    /// reach the bottom half.
    func testDownPauseDownWithMinimizeNeverMinimizes() {
        let desk = Desk()
        doubleSwipe(desk, down: true)
        XCTAssertEqual(Set(desk.gestures[0]), ["Minimize"])
        XCTAssertFalse(desk.minimized)
        XCTAssertEqual(desk.committed, ["↓↓ Bottom Half"])
    }

    /// Only a plain swipe that way, after a plain first swipe whose move is
    /// the single swipe's (maximize, almost-maximize; centre, minimize,
    /// restore). Everything else commits the first motion as before.
    func testTheDoubleSwipeRuleIsOnlyForPlainSameWaySwipes() {
        let up = SwishSnap.Stroke(.up), down = SwishSnap.Stroke(.down)
        XCTAssertEqual(SwishSnap.doubleSwipe(first: up, firstMove: .cell(.maximize), next: up), .up)
        XCTAssertEqual(SwishSnap.doubleSwipe(first: up, firstMove: .place(.almostMaximize), next: .init(.up, tier: 2)), .up)
        XCTAssertEqual(SwishSnap.doubleSwipe(first: down, firstMove: .cell(.center), next: down), .down)
        XCTAssertEqual(SwishSnap.doubleSwipe(first: down, firstMove: .action(.minimize), next: down), .down)
        XCTAssertEqual(SwishSnap.doubleSwipe(first: down, firstMove: .restore, next: down), .down)
        // Other ways, legs, holds and moves.
        XCTAssertNil(SwishSnap.doubleSwipe(first: up, firstMove: .cell(.maximize), next: down))
        XCTAssertNil(SwishSnap.doubleSwipe(first: up, firstMove: .cell(.maximize), next: .init(.left)))
        XCTAssertNil(SwishSnap.doubleSwipe(first: up, firstMove: .cell(.maximize), next: .init(.up, cross: .left)))
        XCTAssertNil(SwishSnap.doubleSwipe(first: .init(.up, held: true), firstMove: .action(.toggleFullscreen),
                                           next: .init(.up, held: true)))
        XCTAssertNil(SwishSnap.doubleSwipe(first: up, firstMove: .cell(.topHalf), next: up), "top half + up maximizes")
        XCTAssertNil(SwishSnap.doubleSwipe(first: down, firstMove: .cell(.bottomHalf), next: down))
        XCTAssertNil(SwishSnap.doubleSwipe(first: down, firstMove: .action(.close), next: down), "⌥ down twice quits")
        XCTAssertNil(SwishSnap.doubleSwipe(first: up, firstMove: .action(.screen(.up)), next: up), "⌘ display moves")
        XCTAssertNil(SwishSnap.doubleSwipe(first: .init(.left), firstMove: .cell(.leftHalf), next: .init(.left)))
        XCTAssertNil(SwishSnap.doubleSwipe(first: up, firstMove: nil, next: up))
        // The mapping of the second half: only a plain swipe that way.
        XCTAssertEqual(move(nil, up, double: .up), .cell(.topHalf))
        XCTAssertEqual(move(nil, .init(.up, tier: 2), double: .up), .cell(.topHalf))
        XCTAssertEqual(move(.center, down, double: .down), .cell(.bottomHalf))
        XCTAssertEqual(move(nil, .init(.left), double: .up), .cell(.leftHalf))
        XCTAssertEqual(move(nil, .init(.up, cross: .right), double: .up), .cell(.topRight))
        XCTAssertEqual(move(nil, down, double: .up), .action(.minimize))
        XCTAssertEqual(move(nil, down, modifiers: .general, double: .down), .action(.close))
        XCTAssertNil(move(at(.maximize), up, double: .up, fullscreen: true))
    }

    /// Other multi-motion chains still commit each motion: left, rest, down
    /// is the left half, then the bottom-left quarter.
    func testOtherChainsInOneTouchStillCommitEachMotion() {
        let desk = Desk()
        desk.feed(pair(0.5, 0.5), at: 0)
        slide(desk, from: (0.5, 0.5), to: (0.38, 0.5), at: 0, duration: 0.08)
        rest(desk, at: (0.38, 0.5), from: 0.09, duration: 0.35)
        slide(desk, from: (0.38, 0.5), to: (0.38, 0.62), at: 0.45, duration: 0.08)
        desk.feed([], at: 0.56)
        XCTAssertEqual(desk.committed, ["← Left Half", "↓ Bottom Left"])
        // And up, rest, up from the top half: top half → maximize.
        let top = Desk()
        top.place = at(.bottomHalf)
        doubleSwipe(top, down: false)
        XCTAssertEqual(top.committed, ["↑ Top Half", "↑ Maximize"])
    }

    // MARK: 6. A second, separate swipe down

    /// N334's separate double swipe up, for down too: a swipe down that
    /// centred or restored the window arms a second swipe down within
    /// `doubleSwipeWindow` on the same window, which takes the bottom half.
    func testASecondSeparateSwipeDownAfterACentreOrRestoreTakesTheBottomHalf() {
        XCTAssertEqual(SwishDoubleSwipeUp.arming(direction: .down, place: .center, action: nil), .down)
        XCTAssertEqual(SwishDoubleSwipeUp.arming(direction: .down, place: nil, action: nil), .down, "a restore")
        XCTAssertEqual(SwishDoubleSwipeUp.arming(direction: .up, place: at(.maximize), action: nil), .up)
        XCTAssertNil(SwishDoubleSwipeUp.arming(direction: .down, place: nil, action: .minimize))
        XCTAssertNil(SwishDoubleSwipeUp.arming(direction: .down, place: at(.bottomHalf), action: nil))
        XCTAssertNil(SwishDoubleSwipeUp.arming(direction: .down, place: at(.bottomLeft), action: nil))
        XCTAssertNil(SwishDoubleSwipeUp.arming(direction: nil, place: .center, action: nil), "a hotkey or double tap")
        var tracker = SwishDoubleSwipeUp()
        tracker.commitEnded(key: "w", vertical: .down, at: 10)
        XCTAssertFalse(tracker.swipeBegan(key: "w", newTouch: true, at: 10.2), "not an up double swipe")
        tracker.commitEnded(key: "w", vertical: .down, at: 20)
        XCTAssertEqual(tracker.secondSwipe(key: "w", newTouch: true, at: 20.4), .down)
        tracker.commitEnded(key: "w", vertical: .down, at: 30)
        XCTAssertNil(tracker.secondSwipe(key: "w", newTouch: true, at: 30.6), "too late")
        // From frames, Center option: down (centre), lift, down within 0.5 s.
        let desk = Desk()
        desk.options = centerOption
        swipe(desk, down: true, at: 0)
        swipe(desk, down: true, at: 0.3)
        XCTAssertEqual(desk.committed, ["↓ Center", "↓↓ Bottom Half"])
        // Later than that: the centred window is put back, as before.
        let late = Desk()
        late.options = centerOption
        swipe(late, down: true, at: 0)
        swipe(late, down: true, at: 0.9)
        XCTAssertEqual(late.committed, ["↓ Center", "↓ Restore"])
        // Maximized: down restores, a quick second down takes the bottom half.
        let full = Desk()
        full.place = at(.maximize)
        swipe(full, down: true, at: 0)
        swipe(full, down: true, at: 0.3)
        XCTAssertEqual(full.committed, ["↓ Restore", "↓↓ Bottom Half"])
        XCTAssertFalse(full.minimized)
    }

    // MARK: 7–8. Taking a swipe back

    /// Back to where it started: nothing on show, and the lift does nothing.
    /// Until now the preview held its last place and the lift committed it.
    func testTakingASwipeBackToItsStartWithdrawsItAndTheLiftDoesNothing() {
        let desk = Desk()
        desk.feed(pair(0.5, 0.5), at: 0)
        slide(desk, from: (0.5, 0.5), to: (0.38, 0.5), at: 0, duration: 0.08)
        slide(desk, from: (0.38, 0.5), to: (0.495, 0.5), at: 0.09, duration: 0.08)
        desk.feed([], at: 0.2)
        XCTAssertEqual(desk.withdrawals, 1)
        XCTAssertEqual(desk.gestures.first?.first, "← Left Half")
        XCTAssertEqual(desk.gestures.first?.last, "nothing")
        XCTAssertEqual(desk.committed, [])
        // Most of the way back is not back: a wobble keeps the snap.
        let wobble = Desk()
        wobble.feed(pair(0.5, 0.5), at: 0)
        slide(wobble, from: (0.5, 0.5), to: (0.38, 0.5), at: 0, duration: 0.08)
        slide(wobble, from: (0.38, 0.5), to: (0.47, 0.5), at: 0.09, duration: 0.08)
        wobble.feed([], at: 0.2)
        XCTAssertEqual(wobble.withdrawals, 0)
        XCTAssertEqual(wobble.committed, ["← Left Half"])
    }

    /// Out again past the whole engage distance, any way (a change of mind:
    /// left, back, right), never at the edge of the withdraw radius.
    func testAWithdrawnSwipeReengagesOnlyPastTheEngageDistanceAnyWay() {
        let desk = Desk()
        let engage = desk.recognizer.engage
        desk.feed(pair(0.5, 0.5), at: 0)
        slide(desk, from: (0.5, 0.5), to: (0.38, 0.5), at: 0, duration: 0.08)
        slide(desk, from: (0.38, 0.5), to: (0.5, 0.5), at: 0.09, duration: 0.08)
        XCTAssertEqual(desk.withdrawals, 1)
        // Short of the engage distance the other way: still nothing.
        desk.feed(pair(0.5 + engage * 0.8, 0.5), at: 0.20)
        XCTAssertEqual(desk.gestures[0].last, "nothing")
        desk.feed(pair(0.5 + engage * 1.5, 0.5), at: 0.22)
        XCTAssertEqual(desk.gestures[0].last, "→ Right Half")
        desk.feed([], at: 0.25)
        XCTAssertEqual(desk.committed, ["→ Right Half"])
        XCTAssertEqual(desk.gestures.count, 1, "the same gesture: no new begin")
        // Or up after taking a swipe left back.
        let up = Desk()
        up.feed(pair(0.5, 0.5), at: 0)
        slide(up, from: (0.5, 0.5), to: (0.38, 0.5), at: 0, duration: 0.08)
        slide(up, from: (0.38, 0.5), to: (0.5, 0.5), at: 0.09, duration: 0.08)
        slide(up, from: (0.5, 0.5), to: (0.5, 0.38), at: 0.18, duration: 0.08)
        up.feed([], at: 0.3)
        XCTAssertEqual(up.committed, ["↑ Maximize"])
    }

    // MARK: 9–10. Unsnap avoids cropping

    func testUnsnapKeepsTheWindowWholeOnADisplay() {
        let main = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let current = CGRect(x: 0, y: 25, width: 720, height: 875)
        // Whole on a display, or straddling two side by side: as it was.
        let inside = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(SwishSnap.unsnapFrame(original: inside, areas: [main], current: current), inside)
        let straddling = CGRect(x: 1200, y: 100, width: 600, height: 500)
        XCTAssertEqual(SwishSnap.unsnapFrame(original: straddling, areas: [main, right], current: current), straddling)
        // Half off the right edge of the only display: moved in, same size.
        let off = CGRect(x: 1100, y: 200, width: 800, height: 600)
        XCTAssertEqual(SwishSnap.unsnapFrame(original: off, areas: [main], current: current),
                       CGRect(x: 640, y: 200, width: 800, height: 600))
        // Under the menu bar or the Dock: moved in.
        let high = CGRect(x: 100, y: 0, width: 800, height: 600)
        XCTAssertEqual(SwishSnap.unsnapFrame(original: high, areas: [main], current: current).minY, 25)
        // Larger than the display: shrunk to it.
        let huge = CGRect(x: -50, y: 0, width: 2000, height: 1200)
        XCTAssertEqual(SwishSnap.unsnapFrame(original: huge, areas: [main], current: current), main)
        // On a display that has gone: onto the display the window is on now.
        let gone = CGRect(x: 4000, y: 100, width: 800, height: 600)
        XCTAssertEqual(SwishSnap.unsnapFrame(original: gone, areas: [main], current: current),
                       CGRect(x: 640, y: 100, width: 800, height: 600))
        let onRight = CGRect(x: 1500, y: 100, width: 700, height: 500)
        XCTAssertEqual(SwishSnap.unsnapFrame(original: gone, areas: [main, right], current: onRight),
                       CGRect(x: 2560, y: 100, width: 800, height: 600))
        // Nothing to go by: as it was.
        XCTAssertEqual(SwishSnap.unsnapFrame(original: off, areas: [], current: current), off)
    }

    /// The menu-bar unsnap reads the same history through
    /// `TitleBarWindowSnap.unsnapFrame(for:current:)`, which now applies the
    /// same rule; the history itself still gives the raw frame.
    func testTheHistoryStillKeepsTheRawFrameForTheClamp() {
        var history = SwishSnapHistory()
        let off = CGRect(x: 1100, y: 200, width: 800, height: 600)
        let snapped = CGRect(x: 0, y: 25, width: 720, height: 875)
        history.recordSnap(key: "w", from: off, to: snapped, place: SwishSnap.Place(.leftHalf))
        XCTAssertEqual(history.restoreFrame(key: "w", current: snapped), off)
        XCTAssertEqual(SwishSnap.unsnapFrame(original: off, areas: [CGRect(x: 0, y: 25, width: 1440, height: 875)],
                                             current: snapped).maxX, 1440)
    }

    // MARK: 11. The rest haptic only for something planned

    func testTheRestHapticOnlyPlaysWithSomethingPlanned() {
        XCTAssertTrue(SwishSnap.motionReadyHaptic(planOnShow: true, motionQueued: false))
        XCTAssertTrue(SwishSnap.motionReadyHaptic(planOnShow: false, motionQueued: true))
        XCTAssertFalse(SwishSnap.motionReadyHaptic(planOnShow: false, motionQueued: false))
        // A swipe taken back to its start never locks while it rests there.
        let desk = Desk()
        desk.feed(pair(0.5, 0.5), at: 0)
        slide(desk, from: (0.5, 0.5), to: (0.38, 0.5), at: 0, duration: 0.08)
        slide(desk, from: (0.38, 0.5), to: (0.5, 0.5), at: 0.09, duration: 0.08)
        rest(desk, at: (0.5, 0.5), from: 0.18, duration: 0.6)
        desk.feed([], at: 0.8)
        XCTAssertEqual(desk.readies, 0)
        XCTAssertEqual(desk.committed, [])
    }

    // MARK: 12. Two arrows for a double swipe

    func testTheTooltipShowsTwoArrowsForADoubleSwipe() {
        XCTAssertEqual(SwishSnap.tooltipText(direction: .up, place: at(.topHalf), double: true), "↑↑ Top Half")
        XCTAssertEqual(SwishSnap.tooltipText(direction: .down, place: at(.bottomHalf), double: true), "↓↓ Bottom Half")
        XCTAssertEqual(SwishSnap.tooltipText(direction: .up, place: at(.topHalf)), "↑ Top Half", "a chained top half")
        XCTAssertTrue(SwishSnap.isDoubleSwipeResult(.cell(.topHalf), stroke: .init(.up), double: .up))
        XCTAssertTrue(SwishSnap.isDoubleSwipeResult(.cell(.bottomHalf), stroke: .init(.down, tier: 2), double: .down))
        XCTAssertFalse(SwishSnap.isDoubleSwipeResult(.cell(.topHalf), stroke: .init(.up), double: nil))
        XCTAssertFalse(SwishSnap.isDoubleSwipeResult(.cell(.leftHalf), stroke: .init(.left), double: .up))
        XCTAssertFalse(SwishSnap.isDoubleSwipeResult(.cell(.topLeft), stroke: .init(.up, cross: .left), double: .up))
    }

    // MARK: 13. A withdrawn swipe queued behind a landing commit

    func testAWithdrawnQueuedSwipeAppliesNothingUntilItSwipesOut() {
        var queue = SwishChainQueue()
        queue.began(.init(.left))
        queue.withdraw()
        XCTAssertEqual(queue.pending?.withdrawn, true)
        queue.updated(.init(.right))
        XCTAssertEqual(queue.pending?.withdrawn, false, "out again")
        XCTAssertEqual(queue.pending?.stroke, .init(.right))
        queue.withdraw()
        queue.liftedFingers()
        let landed = queue.landed(succeeded: true)
        XCTAssertEqual(landed?.withdrawn, true, "lifted while taken back: the service applies nothing")
        XCTAssertEqual(landed?.lifted, true)
        // A lifted motion is never withdrawn afterwards, nor is a pinch.
        queue.began(.init(.up))
        queue.liftedFingers()
        queue.withdraw()
        XCTAssertEqual(queue.pending?.withdrawn, false)
        var pinch = SwishChainQueue()
        pinch.beganPinch(.in)
        pinch.withdraw()
        XCTAssertEqual(pinch.pending?.withdrawn, false)
    }
}
