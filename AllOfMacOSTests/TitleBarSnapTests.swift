import XCTest
@testable import AllOfMacOS

/// Swish-style title-bar two-finger snap. Pure recognition and geometry only —
/// no trackpad, Accessibility or overlay windows are touched.
final class TitleBarSnapTests: XCTestCase {
    /// The tests below give positions in the pad coordinates the snap reasons
    /// in (y grows toward the bottom of the pad); TouchPoint's y grows toward
    /// the top, as the trackpad reports it, so the helpers flip it.
    private func touch(_ id: Int, _ x: Float, _ y: Float) -> TouchPoint {
        TouchPoint(id: id, x: x, y: 1 - y, size: 1, pressure: 0)
    }

    /// Two fingers whose centroid sits at (x, y).
    private func pair(_ x: Float, _ y: Float) -> [TouchPoint] {
        [touch(1, x - 0.01, y), touch(2, x + 0.01, y)]
    }

    /// The state-machine tests below predate the 3.3.2 touch-down settle
    /// time; they check transitions, so the settle gate is switched off
    /// (`testASwipeWaitsForTheTouchDownToSettle` covers it).
    private static func stateMachineRecognizer() -> TitleBarSnapRecognizer {
        let recognizer = TitleBarSnapRecognizer()
        recognizer.settleTime = 0
        return recognizer
    }

    private func sized(_ id: Int, _ x: Float, _ y: Float, size: Float) -> TouchPoint {
        TouchPoint(id: id, x: x, y: 1 - y, size: size, pressure: 0)
    }

    /// 3.3.2: TouchPoint's y grows toward the top of the pad (MultitouchSupport
    /// and NSTouch put the origin at the bottom left; `LiveTouchView` draws
    /// `1 - y`, and `GestureReplaySuite` builds a two-finger swipe up as +y).
    /// The snap read it the other way round, so on a real trackpad a swipe
    /// down maximized or went to the top quarter, and a window at the top
    /// never reached a bottom quarter. Raw TouchPoints, no helper flip.
    func testAPhysicalSwipeDownTheTrackpadSnapsDown() {
        func strokes(fromY: Float, toY: Float, x: Float = 0.5) -> [SwishSnap.Stroke] {
            let recognizer = Self.stateMachineRecognizer()
            var begins: [SwishSnap.Stroke] = []
            recognizer.onBegin = { begins.append($0) }
            func raw(_ y: Float) -> [TouchPoint] {
                [TouchPoint(id: 1, x: x - 0.01, y: y, size: 1, pressure: 0),
                 TouchPoint(id: 2, x: x + 0.01, y: y, size: 1, pressure: 0)]
            }
            recognizer.feed(contacts: raw(fromY), timestamp: 0)
            recognizer.feed(contacts: raw((fromY + toY) / 2), timestamp: 0.03)
            recognizer.feed(contacts: raw(toY), timestamp: 0.06)
            recognizer.feed(contacts: [], timestamp: 0.2)
            return begins
        }
        // Toward y = 0 is toward the user: a swipe down.
        XCTAssertEqual(strokes(fromY: 0.6, toY: 0.45).first?.direction, .down)
        XCTAssertEqual(strokes(fromY: 0.4, toY: 0.55).first?.direction, .up)
        // So a top-left quarter swiped down moves to the bottom-left one, and
        // a window at the top is no longer stuck there.
        let down = SwishSnap.Stroke(.down)
        XCTAssertEqual(SwishSnap.move(from: .topLeft, stroke: down, thirds: false), .cell(.bottomLeft))
        XCTAssertEqual(SwishSnap.move(from: .topHalf, stroke: down, thirds: false), .cell(.bottomHalf))
    }

    // MARK: 3.3.2 — taps, settling and lift-off never snap

    func testASwipeWaitsForTheTouchDownToSettle() {
        let recognizer = TitleBarSnapRecognizer()
        var begins: [SwishSnap.Stroke] = []
        var touchDowns = 0
        recognizer.onBegin = { begins.append($0) }
        recognizer.onTouchDown = { touchDowns += 1 }
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.48, 0.50), timestamp: 0.02)     // far enough, but too soon
        XCTAssertTrue(begins.isEmpty, "the touch-down is still settling")
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.05)
        XCTAssertEqual(begins, [.init(.right)])
        XCTAssertEqual(touchDowns, 1, "one touch-down per landing, before the swipe engages")
    }

    /// 3.3.1: a two-finger tap on a title bar maximized the window. A tap
    /// that never reaches the engage distance still cancels; 3.3.2 review: a
    /// quick flick that did engage (5.5 % of the pad in 90 ms) commits, where
    /// the tap guard used to throw it away ("the snap reacts slowly").
    func testAQuickTapCancelsButAQuickFlickThatEngagedCommits() {
        let recognizer = TitleBarSnapRecognizer()
        var commits = 0, cancels = 0
        var begins: [SwishSnap.Stroke] = []
        recognizer.onBegin = { begins.append($0) }
        recognizer.onCommit = { commits += 1 }
        recognizer.onCancel = { cancels += 1 }
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.495), timestamp: 0.03)
        recognizer.feed(contacts: pair(0.50, 0.475), timestamp: 0.06)    // 0.025 up: never engages
        recognizer.feed(contacts: [touch(1, 0.49, 0.475)], timestamp: 0.09)
        XCTAssertEqual(begins, [])
        XCTAssertEqual(commits, 0, "a tap never maximizes")
        XCTAssertEqual(cancels, 1)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 1)
        recognizer.feed(contacts: pair(0.50, 0.495), timestamp: 1.03)
        recognizer.feed(contacts: pair(0.50, 0.445), timestamp: 1.06)    // 0.055 up: engages "up"
        recognizer.feed(contacts: [touch(1, 0.49, 0.445)], timestamp: 1.09)
        XCTAssertEqual(begins, [.init(.up)])
        XCTAssertEqual(commits, 1, "the flick that engaged snaps")
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(TitleBarSnapRecognizer.engagedTapShare, 0.6)
    }

    /// A lifting finger's contact shrinks and its last positions slide up the
    /// pad; those frames must not read as a swipe up.
    func testALiftingFingerNeverEngagesASwipe() {
        let recognizer = TitleBarSnapRecognizer()
        var begins = 0, commits = 0
        recognizer.onBegin = { _ in begins += 1 }
        recognizer.onCommit = { commits += 1 }
        recognizer.feed(contacts: [sized(1, 0.49, 0.50, size: 1), sized(2, 0.51, 0.50, size: 1)], timestamp: 0)
        recognizer.feed(contacts: [sized(1, 0.49, 0.50, size: 1), sized(2, 0.51, 0.50, size: 1)], timestamp: 0.05)
        recognizer.feed(contacts: [sized(1, 0.49, 0.42, size: 0.4), sized(2, 0.51, 0.42, size: 0.45)], timestamp: 0.08)
        recognizer.feed(contacts: [sized(1, 0.49, 0.38, size: 0.2)], timestamp: 0.10)
        XCTAssertEqual(begins, 0)
        XCTAssertEqual(commits, 0)
    }

    func testARealSwipeStillCommitsQuickly() {
        let recognizer = TitleBarSnapRecognizer()
        var strokes: [SwishSnap.Stroke] = []
        var commits = 0
        recognizer.onBegin = { strokes.append($0) }
        recognizer.onCommit = { commits += 1 }
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.45, 0.50), timestamp: 0.045)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0.07)
        recognizer.feed(contacts: pair(0.36, 0.50), timestamp: 0.09)
        recognizer.feed(contacts: [], timestamp: 0.11)
        XCTAssertEqual(strokes, [.init(.left)])
        XCTAssertEqual(commits, 1, "a quick, clear swipe is not mistaken for a tap")
    }

    // MARK: 3.3.2 — swipes chain from the window's cell (Swish)

    func testAHalfSwipedVerticallyBecomesAQuarter() {
        XCTAssertEqual(SwishSnap.move(from: .leftHalf, stroke: .init(.down), thirds: false), .cell(.bottomLeft))
        XCTAssertEqual(SwishSnap.move(from: .leftHalf, stroke: .init(.up), thirds: false), .cell(.topLeft))
        XCTAssertEqual(SwishSnap.move(from: .rightHalf, stroke: .init(.down), thirds: false), .cell(.bottomRight))
        XCTAssertEqual(SwishSnap.move(from: .topHalf, stroke: .init(.left), thirds: false), .cell(.topLeft))
        XCTAssertEqual(SwishSnap.move(from: .bottomHalf, stroke: .init(.right), thirds: false), .cell(.bottomRight))
    }

    /// The reported bug: once at the top, a swipe down never reached the bottom.
    func testATopCellSwipedDownMovesToTheBottom() {
        XCTAssertEqual(SwishSnap.move(from: .topLeft, stroke: .init(.down), thirds: false), .cell(.bottomLeft))
        XCTAssertEqual(SwishSnap.move(from: .topRight, stroke: .init(.down), thirds: false), .cell(.bottomRight))
        XCTAssertEqual(SwishSnap.move(from: .topHalf, stroke: .init(.down), thirds: false), .cell(.bottomHalf))
        XCTAssertEqual(SwishSnap.move(from: .bottomLeft, stroke: .init(.up), thirds: false), .cell(.topLeft))
        XCTAssertEqual(SwishSnap.move(from: .topLeft, stroke: .init(.right), thirds: false), .cell(.topRight))
    }

    func testSwipingTowardAnEdgeGrowsTheWindowAlongIt() {
        XCTAssertEqual(SwishSnap.move(from: .topLeft, stroke: .init(.up), thirds: false), .cell(.topHalf))
        XCTAssertEqual(SwishSnap.move(from: .topLeft, stroke: .init(.left), thirds: false), .cell(.leftHalf))
        XCTAssertEqual(SwishSnap.move(from: .bottomRight, stroke: .init(.down), thirds: false), .cell(.bottomHalf))
        XCTAssertEqual(SwishSnap.move(from: .bottomRight, stroke: .init(.right), thirds: false), .cell(.rightHalf))
        XCTAssertEqual(SwishSnap.move(from: .topHalf, stroke: .init(.up), thirds: false), .cell(.maximize))
    }

    func testSwipingDownAtTheBottomOrFromMaximizeRestores() {
        XCTAssertEqual(SwishSnap.move(from: .maximize, stroke: .init(.down), thirds: false), .restore)
        XCTAssertEqual(SwishSnap.move(from: .bottomHalf, stroke: .init(.down), thirds: false), .restore)
        XCTAssertEqual(SwishSnap.move(from: .maximize, stroke: .init(.left), thirds: false), .cell(.leftHalf))
        XCTAssertEqual(SwishSnap.move(from: nil, stroke: .init(.down), thirds: false), .cell(.center))
        XCTAssertEqual(SwishSnap.move(from: .center, stroke: .init(.down), thirds: false), .restore)
    }

    /// Thirds are opt-in (3.3.2): with the switch off a longer swipe or a
    /// swipe toward the edge never produces a third.
    func testThirdsOnlyWhenTurnedOn() {
        XCTAssertEqual(SwishSnap.move(from: nil, stroke: .init(.left, tier: 2), thirds: false), .cell(.leftHalf))
        XCTAssertEqual(SwishSnap.move(from: .leftHalf, stroke: .init(.left), thirds: false), .cell(.leftHalf))
        XCTAssertEqual(SwishSnap.move(from: nil, stroke: .init(.left, tier: 2), thirds: true), .cell(.leftThird))
        XCTAssertEqual(SwishSnap.move(from: .leftHalf, stroke: .init(.left), thirds: true), .cell(.leftThird))
        XCTAssertEqual(SwishSnap.move(from: .leftThird, stroke: .init(.left), thirds: true), .cell(.leftTwoThirds))
        XCTAssertEqual(SwishSnap.move(from: .leftTwoThirds, stroke: .init(.left), thirds: true), .cell(.leftHalf))
        XCTAssertEqual(SwishSnap.move(from: .leftThird, stroke: .init(.right), thirds: true), .cell(.centerThird))
        XCTAssertEqual(SwishSnap.move(from: .rightHalf, stroke: .init(.right), thirds: true), .cell(.rightThird))
    }

    func testAnLShapedSwipePicksAQuarterFromAnywhere() {
        for cell: CustomSnapZone.Layout? in [nil, .maximize, .leftHalf, .bottomRight, .topHalf] {
            XCTAssertEqual(SwishSnap.move(from: cell, stroke: .init(.left, cross: .down), thirds: false), .cell(.bottomLeft))
            XCTAssertEqual(SwishSnap.move(from: cell, stroke: .init(.up, cross: .right), thirds: false), .cell(.topRight))
        }
    }

    func testTheCellAWindowFillsIsRecognised() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        for layout: CustomSnapZone.Layout in [.leftHalf, .bottomRight, .topHalf, .maximize, .centerThird] {
            let frame = SwishSnap.targetFrame(layout: layout, visible: visible, margin: 0)
            XCTAssertEqual(SwishSnap.cell(of: frame, visible: visible, margin: 0), layout, "\(layout)")
        }
        let nudged = SwishSnap.targetFrame(layout: .topLeft, visible: visible, margin: 8).offsetBy(dx: 6, dy: -5)
        XCTAssertEqual(SwishSnap.cell(of: nudged, visible: visible, margin: 8), .topLeft, "within tolerance, with a margin")
        XCTAssertNil(SwishSnap.cell(of: CGRect(x: 200, y: 150, width: 900, height: 600), visible: visible, margin: 0))
    }

    func testHistoryRemembersTheCellWhileTheWindowStaysThere() {
        var history = SwishSnapHistory()
        let snapped = CGRect(x: 0, y: 25, width: 700, height: 875)   // a size-limited left half
        history.recordSnap(key: "w", from: CGRect(x: 100, y: 100, width: 700, height: 500), to: snapped, layout: .leftHalf)
        XCTAssertEqual(history.cell(key: "w", current: snapped), .leftHalf)
        XCTAssertNil(history.cell(key: "w", current: snapped.offsetBy(dx: 40, dy: 0)), "moved by hand")
    }

    // MARK: Direction and tiers

    func testDirectionNeedsADominantAxisPastTheEngageDistance() {
        XCTAssertNil(SwishSnap.direction(dx: 0.03, dy: 0.0, engage: 0.05, ratio: 1.3), "too small")
        XCTAssertNil(SwishSnap.direction(dx: 0.08, dy: 0.07, engage: 0.05, ratio: 1.3), "too diagonal")
        XCTAssertEqual(SwishSnap.direction(dx: 0.10, dy: 0.0, engage: 0.05, ratio: 1.3), .right)
        XCTAssertEqual(SwishSnap.direction(dx: -0.10, dy: 0.02, engage: 0.05, ratio: 1.3), .left)
        // Trackpad Y grows downward, so dy > 0 feels like pulling the window down.
        XCTAssertEqual(SwishSnap.direction(dx: 0.0, dy: 0.12, engage: 0.05, ratio: 1.3), .down)
        XCTAssertEqual(SwishSnap.direction(dx: 0.01, dy: -0.12, engage: 0.05, ratio: 1.3), .up)
    }

    func testTierGrowsWithTheLongerSwipe() {
        XCTAssertEqual(SwishSnap.tier(dx: 0.10, dy: 0, tier2: 0.16), 1)
        XCTAssertEqual(SwishSnap.tier(dx: 0.18, dy: 0, tier2: 0.16), 2)
        XCTAssertEqual(SwishSnap.tier(dx: 0, dy: -0.20, tier2: 0.16), 2)
    }

    func testLayoutMapping() {
        XCTAssertEqual(SwishSnap.layout(for: .left, tier: 1), .leftHalf)
        XCTAssertEqual(SwishSnap.layout(for: .left, tier: 2), .leftThird)
        XCTAssertEqual(SwishSnap.layout(for: .right, tier: 1), .rightHalf)
        XCTAssertEqual(SwishSnap.layout(for: .right, tier: 2), .rightThird)
        XCTAssertEqual(SwishSnap.layout(for: .up, tier: 1), .maximize)
        XCTAssertEqual(SwishSnap.layout(for: .up, tier: 2), .topHalf)
        XCTAssertEqual(SwishSnap.layout(for: .down, tier: 1), .center)
        XCTAssertEqual(SwishSnap.layout(for: .down, tier: 2), .bottomHalf)
    }

    /// Swish: "Swipe horizontally and vertically to snap to a quarter. Both orders work."
    func testAPerpendicularLegMakesAQuarterInEitherOrder() {
        XCTAssertEqual(SwishSnap.layout(for: .init(.left, cross: .up)), .topLeft)
        XCTAssertEqual(SwishSnap.layout(for: .init(.up, cross: .left)), .topLeft)
        XCTAssertEqual(SwishSnap.layout(for: .init(.right, cross: .up)), .topRight)
        XCTAssertEqual(SwishSnap.layout(for: .init(.up, cross: .right)), .topRight)
        XCTAssertEqual(SwishSnap.layout(for: .init(.left, cross: .down)), .bottomLeft)
        XCTAssertEqual(SwishSnap.layout(for: .init(.down, cross: .left)), .bottomLeft)
        XCTAssertEqual(SwishSnap.layout(for: .init(.right, tier: 2, cross: .down)), .bottomRight)
        XCTAssertEqual(SwishSnap.layout(for: .init(.down, cross: .right)), .bottomRight)
        // Without a leg the tiered mapping is unchanged.
        XCTAssertEqual(SwishSnap.layout(for: .init(.right, tier: 2)), .rightThird)
    }

    func testRefineNeedsADeliberateLegAndReleasesWithHysteresis() {
        let engaged = SwishSnap.Stroke(.left)
        // The natural arc of a long swipe (small share of the distance) is not a leg.
        XCTAssertEqual(SwishSnap.refine(dx: -0.25, dy: 0.07, axis: .horizontal, previous: engaged,
                                        engage: 0.05, tier2: 0.16, ratio: 1.3), .init(.left, tier: 2))
        // An L-shaped move is.
        let quarter = SwishSnap.refine(dx: -0.12, dy: -0.08, axis: .horizontal, previous: engaged,
                                       engage: 0.05, tier2: 0.16, ratio: 1.3)
        XCTAssertEqual(quarter, .init(.left, cross: .up))
        // Once held, the leg survives a small drift back…
        XCTAssertEqual(SwishSnap.refine(dx: -0.12, dy: -0.05, axis: .horizontal, previous: quarter,
                                        engage: 0.05, tier2: 0.16, ratio: 1.3), .init(.left, cross: .up))
        // …and is released once clearly gone.
        XCTAssertEqual(SwishSnap.refine(dx: -0.12, dy: -0.01, axis: .horizontal, previous: quarter,
                                        engage: 0.05, tier2: 0.16, ratio: 1.3), .init(.left))
    }

    func testRefineRepicksTheAxisWhenTheSwipeTurnsBackThroughTheStart() {
        let up = SwishSnap.Stroke(.up)
        XCTAssertEqual(SwishSnap.refine(dx: -0.12, dy: 0.0, axis: .vertical, previous: up,
                                        engage: 0.05, tier2: 0.16, ratio: 1.3), .init(.left))
        // Near the start with nothing clear: hold the current preview.
        XCTAssertNil(SwishSnap.refine(dx: 0.01, dy: 0.01, axis: .vertical, previous: up,
                                      engage: 0.05, tier2: 0.16, ratio: 1.3))
    }

    // MARK: Title-bar hit test and geometry

    func testTitleBarHitOnlyInsideTheTopBand() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)   // AX top-left
        XCTAssertTrue(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 400, y: 210), windowFrame: window))
        XCTAssertFalse(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 400, y: 400), windowFrame: window), "body, not title bar")
        XCTAssertFalse(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 50, y: 210), windowFrame: window), "left of the window")
        XCTAssertFalse(SwishSnap.titleBarHit(pointerTopLeft: .zero, windowFrame: .zero))
    }

    func testTargetFrameAndMargin() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let left = SwishSnap.targetFrame(layout: .leftHalf, visible: visible, margin: 0)
        XCTAssertEqual(left, CGRect(x: 0, y: 25, width: 720, height: 875))
        let maxed = SwishSnap.targetFrame(layout: .maximize, visible: visible, margin: 8)
        XCTAssertEqual(maxed, CGRect(x: 8, y: 33, width: 1424, height: 859))
        let quarter = SwishSnap.targetFrame(layout: .bottomRight, visible: visible, margin: 0)
        XCTAssertEqual(quarter, CGRect(x: 720, y: 462.5, width: 720, height: 437.5))
    }

    func testAccessibilityRectToAppKitFlipsTheOrigin() {
        let axRect = CGRect(x: 100, y: 50, width: 400, height: 300)   // top-left, 50 from the top
        let appKit = SwishSnap.appKitRect(axRect, primaryTop: 1000)
        XCTAssertEqual(appKit, CGRect(x: 100, y: 650, width: 400, height: 300))
    }

    func testPointerRestsInTheMiddleOfTheTitleBarBand() {
        let point = SwishSnap.titleBarRestPoint(for: CGRect(x: 720, y: 25, width: 720, height: 875))
        XCTAssertEqual(point, CGPoint(x: 1080, y: 40))
    }

    // MARK: Swish edge anchoring for size-limited windows

    func testAnchoringKeepsTheSnappedEdgeWhenTheAppRefusesTheSize() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        // A fixed-width window (System Settings style) snapped right stays flush right.
        let right = CGRect(x: 720, y: 25, width: 720, height: 875)
        XCTAssertEqual(WindowGeometry.anchoredFrame(desired: right, actualSize: CGSize(width: 680, height: 875), visible: visible),
                       CGRect(x: 760, y: 25, width: 680, height: 875))
        // Snapped left it stays flush left.
        let left = CGRect(x: 0, y: 25, width: 720, height: 875)
        XCTAssertEqual(WindowGeometry.anchoredFrame(desired: left, actualSize: CGSize(width: 680, height: 600), visible: visible).origin,
                       CGPoint(x: 0, y: 162.5), "full-height cell centres a shorter window vertically")
        // A middle third centres a narrower window on the cell.
        let middle = CGRect(x: 480, y: 25, width: 480, height: 875)
        XCTAssertEqual(WindowGeometry.anchoredFrame(desired: middle, actualSize: CGSize(width: 400, height: 875), visible: visible).minX, 520)
        // A bottom quarter keeps the bottom edge.
        let bottomRight = CGRect(x: 720, y: 462.5, width: 720, height: 437.5)
        let anchored = WindowGeometry.anchoredFrame(desired: bottomRight, actualSize: CGSize(width: 800, height: 500), visible: visible)
        XCTAssertEqual(anchored.maxX, visible.maxX)
        XCTAssertEqual(anchored.maxY, visible.maxY)
    }

    func testAnchoringStaysOnTheDisplayAndToleratesMargins() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        // Wider than a left half: overflow goes right but never off the display.
        let left = CGRect(x: 8, y: 33, width: 704, height: 859)          // 8 pt margin
        let wide = WindowGeometry.anchoredFrame(desired: left, actualSize: CGSize(width: 900, height: 859), visible: visible)
        XCTAssertEqual(wide.minX, 8, "margin still reads as the left edge")
        // Larger than the whole display keeps its leading edge visible.
        let huge = WindowGeometry.anchoredFrame(desired: visible, actualSize: CGSize(width: 2000, height: 1000), visible: visible)
        XCTAssertEqual(huge.origin, CGPoint(x: 0, y: 25))
    }

    // MARK: Pre-snap history (unsnap)

    func testHistoryRestoresTheFrameFromBeforeTheFirstSnapOfAChain() {
        var history = SwishSnapHistory()
        let original = CGRect(x: 200, y: 150, width: 900, height: 600)
        let leftHalf = CGRect(x: 0, y: 25, width: 720, height: 875)
        let maximized = CGRect(x: 0, y: 25, width: 1440, height: 875)
        history.recordSnap(key: "w", from: original, to: leftHalf)
        history.recordSnap(key: "w", from: leftHalf, to: maximized)          // chained
        XCTAssertEqual(history.restoreFrame(key: "w", current: maximized), original)
        XCTAssertNil(history.restoreFrame(key: "w", current: CGRect(x: 40, y: 60, width: 1440, height: 875)),
                     "moved by hand since the snap: no restore")
        history.forget(key: "w")
        XCTAssertNil(history.restoreFrame(key: "w", current: maximized))
    }

    func testASnapThatDidNotMoveTheWindowLeavesNothingToRestore() {
        var history = SwishSnapHistory()
        let maximized = CGRect(x: 0, y: 25, width: 1440, height: 875)
        // Already maximized, swiped up: a later swipe down should centre, not "restore" in place.
        history.recordSnap(key: "w", from: maximized, to: maximized)
        XCTAssertNil(history.restoreFrame(key: "w", current: maximized))
    }

    /// The side-by-side diagnostics drawer must leave the Automation page its
    /// two panes (list minimum + editor minimum).
    func testDrawerThresholdKeepsTheAutomationSplit() {
        let left = AOMSize.drawerSideBySideMinimum - AOMSize.drawerWidth.upperBound - 1
        XCTAssertGreaterThanOrEqual(left, CGFloat(AOMSize.listColumnRange.lowerBound) + AOMSize.editorMinimum)
    }

    func testHistoryStartsANewChainAfterAManualMoveAndIsBounded() {
        var history = SwishSnapHistory()
        history.limit = 2
        let first = CGRect(x: 10, y: 10, width: 500, height: 400)
        let snapped = CGRect(x: 0, y: 25, width: 720, height: 875)
        history.recordSnap(key: "a", from: first, to: snapped)
        let movedByHand = CGRect(x: 300, y: 300, width: 720, height: 875)
        history.recordSnap(key: "a", from: movedByHand, to: snapped)
        XCTAssertEqual(history.restoreFrame(key: "a", current: snapped), movedByHand)
        history.recordSnap(key: "b", from: first, to: snapped)
        history.recordSnap(key: "c", from: first, to: snapped)
        XCTAssertNil(history.entries["a"], "oldest window dropped past the limit")
        XCTAssertEqual(history.entries.count, 2)
    }

    // MARK: Readiness (Swish's settings checks)

    func testHapticsReadinessFollowsTrackpadPreferences() {
        XCTAssertTrue(TrackpadReadiness.hapticsEnabled(actuateDetents: nil, forceSuppressed: nil), "defaults are on")
        XCTAssertTrue(TrackpadReadiness.hapticsEnabled(actuateDetents: NSNumber(value: 1), forceSuppressed: NSNumber(value: 0)))
        XCTAssertFalse(TrackpadReadiness.hapticsEnabled(actuateDetents: NSNumber(value: 1), forceSuppressed: NSNumber(value: 1)))
        XCTAssertFalse(TrackpadReadiness.hapticsEnabled(actuateDetents: NSNumber(value: 0), forceSuppressed: nil))
    }

    func testSpaceShortcutReadiness() {
        let control = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | CGEventFlags.maskSecondaryFn.rawValue)
        let left = SymbolicHotKey(id: 79, keyCode: 123, flags: control, isEnabled: true, isConfigured: false)
        let right = SymbolicHotKey(id: 81, keyCode: 124, flags: control, isEnabled: true, isConfigured: false)
        XCTAssertEqual(TrackpadReadiness.spaceShortcuts(left: left, right: right).ready, true)
        XCTAssertEqual(TrackpadReadiness.spaceShortcuts(left: left, right: right).detail, "⌃← and ⌃→ are on.")
        let custom = SymbolicHotKey(id: 81, keyCode: 2, flags: .maskAlternate, isEnabled: true, isConfigured: true)
        XCTAssertEqual(TrackpadReadiness.spaceShortcuts(left: left, right: custom).detail, "On, set to a custom combination.")
        let off = SymbolicHotKey(id: 79, keyCode: 123, flags: control, isEnabled: false, isConfigured: true)
        XCTAssertFalse(TrackpadReadiness.spaceShortcuts(left: off, right: right).ready)
        XCTAssertFalse(TrackpadReadiness.spaceShortcuts(left: nil, right: right).ready)
    }

    // MARK: Recognizer state machine

    func testRecognizerEngagesRefinesAndCommits() {
        let recognizer = Self.stateMachineRecognizer()
        var begins: [SwishSnap.Stroke] = []
        var updates: [SwishSnap.Stroke] = []
        var commits = 0, cancels = 0
        recognizer.onBegin = { begins.append($0) }
        recognizer.onUpdate = { updates.append($0) }
        recognizer.onCommit = { commits += 1 }
        recognizer.onCancel = { cancels += 1 }

        // Two fingers land, then slide right past the engage distance.
        recognizer.feed(contacts: pair(0.41, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.51, 0.50), timestamp: 0.02)
        XCTAssertEqual(begins, [.init(.right)])

        // Slide further right → tier 2 (right third).
        recognizer.feed(contacts: pair(0.63, 0.50), timestamp: 0.04)
        XCTAssertEqual(updates.last, .init(.right, tier: 2))

        // Lift both fingers → commit once.
        recognizer.feed(contacts: [], timestamp: 0.06)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(cancels, 0)
    }

    func testRecognizerChainsAQuarterThenCommits() {
        let recognizer = Self.stateMachineRecognizer()
        var strokes: [SwishSnap.Stroke] = []
        var commits = 0
        recognizer.onBegin = { strokes.append($0) }
        recognizer.onUpdate = { strokes.append($0) }
        recognizer.onCommit = { commits += 1 }
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0.02)   // left → left half
        recognizer.feed(contacts: pair(0.38, 0.42), timestamp: 0.04)   // then up → top-left quarter
        recognizer.feed(contacts: [], timestamp: 0.06)
        XCTAssertEqual(strokes.first, .init(.left))
        XCTAssertEqual(strokes.last, .init(.left, cross: .up))
        XCTAssertEqual(SwishSnap.layout(for: strokes.last!), .topLeft)
        XCTAssertEqual(commits, 1)
    }

    func testRecognizerCancelsWhenFingersLiftBeforeEngaging() {
        let recognizer = Self.stateMachineRecognizer()
        var begins = 0, commits = 0, cancels = 0
        recognizer.onBegin = { _ in begins += 1 }
        recognizer.onCommit = { commits += 1 }
        recognizer.onCancel = { cancels += 1 }
        recognizer.feed(contacts: [touch(1, 0.50, 0.50), touch(2, 0.52, 0.50)], timestamp: 0)
        recognizer.feed(contacts: [touch(1, 0.505, 0.50), touch(2, 0.525, 0.50)], timestamp: 0.02) // barely moved
        recognizer.feed(contacts: [touch(1, 0.50, 0.50)], timestamp: 0.04)                          // one finger left
        XCTAssertEqual(begins, 0)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(cancels, 1)
    }

    func testThreeFingersNeverEngage() {
        let recognizer = Self.stateMachineRecognizer()
        var begins = 0
        recognizer.onBegin = { _ in begins += 1 }
        recognizer.feed(contacts: [touch(1, 0.4, 0.5), touch(2, 0.5, 0.5), touch(3, 0.6, 0.5)], timestamp: 0)
        recognizer.feed(contacts: [touch(1, 0.6, 0.5), touch(2, 0.7, 0.5), touch(3, 0.8, 0.5)], timestamp: 0.02)
        XCTAssertEqual(begins, 0)
    }

    // MARK: Stability (audit 2026-10-28 F05; multi-trackpad R02)

    private final class Events {
        var begins: [SwishSnap.Stroke] = []
        var updates: [SwishSnap.Stroke] = []
        var actives = 0
        var commits = 0
        var cancels = 0
    }

    private func observe(_ recognizer: TitleBarSnapRecognizer) -> Events {
        let events = Events()
        recognizer.onBegin = { events.begins.append($0) }
        recognizer.onUpdate = { events.updates.append($0) }
        recognizer.onActive = { _ in events.actives += 1 }
        recognizer.onCommit = { events.commits += 1 }
        recognizer.onCancel = { events.cancels += 1 }
        return events
    }

    /// The audit's SnapProbe ADD_THIRD_FINGER: 3.3.0 committed the snap.
    func testAThirdFingerCancelsInsteadOfCommitting() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        XCTAssertEqual(events.begins, [.init(.right)])
        recognizer.feed(contacts: pair(0.50, 0.50) + [touch(3, 0.70, 0.50)], timestamp: 0.04)
        XCTAssertEqual(events.commits, 0, "a third finger (Mission Control, a 3-finger trigger) is not a lift")
        XCTAssertEqual(events.cancels, 1)
        // Lifting one of three leaves two fingers: the spent gesture must not restart.
        recognizer.feed(contacts: pair(0.62, 0.50), timestamp: 0.06)
        recognizer.feed(contacts: pair(0.78, 0.50), timestamp: 0.08)
        recognizer.feed(contacts: [], timestamp: 0.10)
        XCTAssertEqual(events.begins.count, 1)
        XCTAssertEqual(events.commits, 0)
        XCTAssertEqual(events.cancels, 1)
        // The next deliberate swipe works normally.
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0.20)
        recognizer.feed(contacts: pair(0.30, 0.50), timestamp: 0.22)
        recognizer.feed(contacts: [], timestamp: 0.24)
        XCTAssertEqual(events.begins.last, .init(.left))
        XCTAssertEqual(events.commits, 1)
    }

    /// The audit's acceptance case "hold the same zone for 3 s, then lift".
    /// 3.3.0 sent nothing while a preview was held still (SnapProbe
    /// HOLD_2_SECONDS: updates 0), so the service's 1.2 s timer hid the
    /// preview and the lift applied nothing. Contact frames are activity now.
    /// With Swish's hold-still cancel switched off a 3 s hold still commits.
    func testHoldingOneZoneForThreeSecondsThenLiftingCommits() {
        let recognizer = Self.stateMachineRecognizer()
        recognizer.holdCancelTime = 0
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        XCTAssertEqual(events.begins, [.init(.right)])
        // 60 Hz frames, fingers resting in the same zone for 3 seconds.
        for frame in 1...180 { recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02 + Double(frame) / 60) }
        XCTAssertEqual(events.cancels, 0, "holding a preview is not abandoning it")
        XCTAssertEqual(events.updates, [], "the stroke did not change")
        XCTAssertGreaterThanOrEqual(events.actives, 11, "the service hears about the hold about every 0.25 s")
        recognizer.feed(contacts: [], timestamp: 3.05)
        XCTAssertEqual(events.commits, 1, "the lift applies the held preview")
    }

    /// Swish: fingers resting on the title bar without moving for 2 s cancel
    /// the snap; the lift then does nothing and the next swipe works.
    func testFingersHeldStillForTwoSecondsCancelTheSnap() {
        let recognizer = Self.stateMachineRecognizer()
        XCTAssertEqual(recognizer.holdCancelTime, 2, "Swish's default")
        let events = observe(recognizer)
        var holdCancels = 0
        var stillReports: [Double] = []
        recognizer.onHoldCancel = { holdCancels += 1 }
        recognizer.onActive = { stillReports.append($0) }
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        XCTAssertEqual(events.begins, [.init(.right)])
        // Resting fingers jitter a little; that is still "still".
        var t = 0.02
        for frame in 1...150 {
            t = 0.02 + Double(frame) / 60
            recognizer.feed(contacts: pair(0.50 + (frame % 2 == 0 ? 0.003 : -0.003), 0.50), timestamp: t)
        }
        XCTAssertEqual(holdCancels, 1, "2 s of stillness cancels")
        XCTAssertEqual(events.cancels, 0, "the hold handler runs instead of the plain cancel")
        XCTAssertTrue(stillReports.contains { $0 >= 1.5 }, "the service hears how long the fingers rested (it fades the preview)")
        // The rest of this touch is spent: moving on and lifting do nothing.
        recognizer.feed(contacts: pair(0.30, 0.50), timestamp: t + 0.02)
        recognizer.feed(contacts: [], timestamp: t + 0.04)
        XCTAssertEqual(events.commits, 0)
        XCTAssertEqual(events.begins.count, 1)
        // A new touch snaps as usual.
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: t + 0.2)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: t + 0.22)
        recognizer.feed(contacts: [], timestamp: t + 0.24)
        XCTAssertEqual(events.begins.last, .init(.left))
        XCTAssertEqual(events.commits, 1)
    }

    /// Without an `onHoldCancel` handler the plain cancel runs; movement
    /// restarts the clock, so 1.5 s rests between moves never cancel.
    func testMovingRestartsTheHoldClock() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        var t = 0.02
        var x: Float = 0.50
        for _ in 0..<3 {
            for frame in 1...90 { recognizer.feed(contacts: pair(x, 0.50), timestamp: t + Double(frame) / 60) }
            t += 1.5
            x += 0.02 // a deliberate nudge, beyond the still radius
            recognizer.feed(contacts: pair(x, 0.50), timestamp: t)
        }
        XCTAssertEqual(events.cancels, 0, "4.5 s on the pad, but never 2 s without moving")
        recognizer.feed(contacts: [], timestamp: t + 0.02)
        XCTAssertEqual(events.commits, 1)
        // Held still past the limit with no hold handler: the plain cancel.
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: t + 1)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: t + 1.02)
        for frame in 1...130 { recognizer.feed(contacts: pair(0.50, 0.50), timestamp: t + 1.02 + Double(frame) / 60) }
        XCTAssertEqual(events.cancels, 1)
    }

    /// Resting before the swipe counts too: after 2 s of stillness on the
    /// title bar the touch can no longer start a snap.
    func testRestingBeforeSwipingForTwoSecondsSpendsTheTouch() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
        for frame in 1...125 { recognizer.feed(contacts: pair(0.50, 0.50), timestamp: Double(frame) / 60) }
        recognizer.feed(contacts: pair(0.42, 0.50), timestamp: 2.2)
        recognizer.feed(contacts: [], timestamp: 2.24)
        XCTAssertEqual(events.begins, [], "a 2 s rest spent the touch")
        XCTAssertEqual(events.commits, 0)
        // Switched off, the same rest is harmless.
        recognizer.holdCancelTime = 0
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 3)
        for frame in 1...125 { recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 3 + Double(frame) / 60) }
        recognizer.feed(contacts: pair(0.42, 0.50), timestamp: 5.2)
        recognizer.feed(contacts: [], timestamp: 5.24)
        // 3.3.2: resting 0.45 s or more is also Swish's tap and hold, so the
        // swipe after the rest carries `held` (the mapping turns it into a
        // Space move); the recognizer still engages and commits it.
        XCTAssertEqual(events.begins, [.init(.left, held: true)])
        XCTAssertEqual(events.commits, 1)
    }

    func testHoldCancelSettingIsClampedAndDefaultsToTwoSeconds() {
        let suite = "aom.test.holdcancel.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TitleBarWindowSnap.holdCancelSeconds(defaults), 2)
        defaults.set(0.0, forKey: TitleBarWindowSnap.holdCancelKey)
        XCTAssertEqual(TitleBarWindowSnap.holdCancelSeconds(defaults), 0, "0 turns it off")
        defaults.set(99.0, forKey: TitleBarWindowSnap.holdCancelKey)
        XCTAssertEqual(TitleBarWindowSnap.holdCancelSeconds(defaults), 10)
        defaults.set(-3.0, forKey: TitleBarWindowSnap.holdCancelKey)
        XCTAssertEqual(TitleBarWindowSnap.holdCancelSeconds(defaults), 0)
    }

    /// The 3 × 2 grid stays out of the way with thirds off (the default): a
    /// window that fills a third is free-floating, so no swipe steps it
    /// through thirds and two thirds.
    func testThirdsOffNeverStepsThroughThirds() {
        let visible = CGRect(x: 0, y: 25, width: 1500, height: 900)
        let third = SwishSnap.targetFrame(layout: .leftThird, visible: visible, margin: 0)
        XCTAssertEqual(SwishSnap.cell(of: third, visible: visible, margin: 0, thirds: true), .leftThird)
        XCTAssertNil(SwishSnap.cell(of: third, visible: visible, margin: 0, thirds: false))
        // A third remembered from when thirds were on moves like a free window.
        XCTAssertEqual(SwishSnap.move(from: .leftThird, stroke: .init(.left), thirds: false), .cell(.leftHalf))
        XCTAssertEqual(SwishSnap.move(from: .leftTwoThirds, stroke: .init(.right), thirds: false), .cell(.rightHalf))
        XCTAssertEqual(SwishSnap.move(from: .centerThird, stroke: .init(.left, tier: 2), thirds: false), .cell(.leftHalf))
        XCTAssertEqual(SwishSnap.move(from: .leftThird, stroke: .init(.left), thirds: true), .cell(.leftTwoThirds))
    }

    /// The service's watchdog or a sleep notification ended the gesture on
    /// main: the recognizer must drop it too, without callbacks, and wait
    /// for the lift before a new snap can start.
    func testAServiceCancelResetsTheRecognizerUntilTheLift() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        recognizer.cancelUntilLift()
        recognizer.feed(contacts: pair(0.62, 0.50), timestamp: 0.04)
        recognizer.feed(contacts: pair(0.30, 0.50), timestamp: 0.06)
        recognizer.feed(contacts: [], timestamp: 0.08)
        XCTAssertEqual(events.begins.count, 1)
        XCTAssertEqual(events.updates, [], "the dropped gesture moves no preview")
        XCTAssertEqual(events.commits + events.cancels, 0, "and neither commits nor reports twice")
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0.20)
        recognizer.feed(contacts: pair(0.30, 0.50), timestamp: 0.22)
        recognizer.feed(contacts: [], timestamp: 0.24)
        XCTAssertEqual(events.begins.last, .init(.left), "after the lift the next swipe works")
        XCTAssertEqual(events.commits, 1)
    }

    /// Sleep and wake: the stream stops with the fingers down and resumes
    /// much later. The engaged preview is cancelled, never committed.
    func testFramesResumingAfterSleepCancelTheEngagedSnap() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        recognizer.feed(contacts: pair(0.52, 0.50), timestamp: 30.0)    // woke up 30 s later
        XCTAssertEqual(events.cancels, 1)
        recognizer.feed(contacts: [], timestamp: 30.02)
        XCTAssertEqual(events.commits, 0)
    }

    /// F04 for the snap: the frame handler and the two window-moving steps
    /// share these rules; the AX part cannot run in the test host.
    func testTheSnapGateClosesWhenAOMIsOffOrPaused() {
        XCTAssertTrue(TitleBarWindowSnap.feedsRecognizer(active: true, automationOn: true))
        XCTAssertFalse(TitleBarWindowSnap.feedsRecognizer(active: true, automationOn: false), "switched off: frames reset the recognizer")
        XCTAssertFalse(TitleBarWindowSnap.feedsRecognizer(active: false, automationOn: true))
        XCTAssertTrue(TitleBarWindowSnap.mayMoveWindow(active: true, gateAllows: true))
        XCTAssertFalse(TitleBarWindowSnap.mayMoveWindow(active: true, gateAllows: false), "paused: no capture and no commit")
        XCTAssertFalse(TitleBarWindowSnap.mayMoveWindow(active: false, gateAllows: true))
    }

    func testMovingToANewZoneKeepsTheGestureAlive() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.1)
        for step in 1...20 { recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.1 + Double(step) * 0.05) }
        recognizer.feed(contacts: pair(0.62, 0.50), timestamp: 1.15)     // a new zone
        for step in 1...20 { recognizer.feed(contacts: pair(0.62, 0.50), timestamp: 1.15 + Double(step) * 0.05) }
        recognizer.feed(contacts: [], timestamp: 2.2)
        XCTAssertEqual(events.cancels, 0)
        XCTAssertEqual(events.commits, 1)
        XCTAssertEqual(events.updates.last, .init(.right, tier: 2))
    }

    func testLiftingOneFingerFirstStillCommits() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        recognizer.feed(contacts: [touch(1, 0.49, 0.50)], timestamp: 0.04)
        XCTAssertEqual(events.commits, 1)
        recognizer.feed(contacts: [], timestamp: 0.06)
        XCTAssertEqual(events.commits, 1, "one commit per gesture")
    }

    func testAGapInTheFramesDropsAStaleStart() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        // The trackpad slept without a lift frame; much later fingers land elsewhere.
        recognizer.feed(contacts: pair(0.60, 0.50), timestamp: 5.0)
        XCTAssertEqual(events.begins, [], "a jump across a gap is not a swipe (3.3.0 engaged instantly)")
        recognizer.feed(contacts: pair(0.70, 0.50), timestamp: 5.02)
        XCTAssertEqual(events.begins, [.init(.right)], "measured from the new start")
    }

    func testASecondTrackpadIsIgnoredWhileTheFirstIsLive() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0.00, device: 1)
        recognizer.feed(contacts: [touch(9, 0.9, 0.9)], timestamp: 0.01, device: 2)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02, device: 1)
        recognizer.feed(contacts: [touch(9, 0.9, 0.9)], timestamp: 0.03, device: 2)
        XCTAssertEqual(events.begins, [.init(.right)])
        XCTAssertEqual(events.commits + events.cancels, 0, "the resting thumb on the other pad changes nothing")
        recognizer.feed(contacts: [], timestamp: 0.04, device: 1)
        XCTAssertEqual(events.commits, 1)
    }

    func testASilentTrackpadHandsOverWithoutCommitting() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0.00, device: 1)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02, device: 1)
        recognizer.feed(contacts: pair(0.30, 0.50), timestamp: 1.00, device: 2)
        XCTAssertEqual(events.cancels, 1, "the interrupted gesture is cancelled")
        XCTAssertEqual(events.commits, 0, "and never committed")
        recognizer.feed(contacts: pair(0.20, 0.50), timestamp: 1.02, device: 2)
        XCTAssertEqual(events.begins.last, .init(.left))
    }

    func testResetForgetsAGestureWithoutCallbacks() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        recognizer.reset()      // the snap or AOM was switched off mid-gesture
        recognizer.feed(contacts: [], timestamp: 0.04)
        XCTAssertEqual(events.commits, 0)
        XCTAssertEqual(events.cancels, 0)
    }

    // MARK: 3.3.2 — Swish's pinches, taps and tap-and-hold

    private final class PinchEvents {
        var changes: [SwishSnap.Pinch?] = []
        var lifts: [SwishSnap.Pinch] = []
    }

    private func observePinches(_ recognizer: TitleBarSnapRecognizer) -> PinchEvents {
        let events = PinchEvents()
        recognizer.onPinchChange = { events.changes.append($0) }
        recognizer.onPinch = { events.lifts.append($0) }
        return events
    }

    /// Two fingers `spread` apart side by side, centred on (x, y).
    private func spreadPair(_ x: Float, _ y: Float, spread: Float) -> [TouchPoint] {
        [touch(1, x - spread / 2, y), touch(2, x + spread / 2, y)]
    }

    func testAPinchInIsRecognisedLetGoAndLiftedAsAPinch() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        let pinches = observePinches(recognizer)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.20), timestamp: 0)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.17), timestamp: 0.02)    // 0.85: not yet
        XCTAssertEqual(pinches.changes, [])
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.13), timestamp: 0.04)    // 0.65: pinch in
        XCTAssertEqual(pinches.changes, [.in])
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.16), timestamp: 0.06)    // 0.80: still in
        XCTAssertEqual(pinches.changes, [.in], "hysteresis: a pinch is not let go at once")
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.19), timestamp: 0.08)    // 0.95: let go
        XCTAssertEqual(pinches.changes, [.in, nil])
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12), timestamp: 0.10)    // in again
        recognizer.feed(contacts: [], timestamp: 0.12)
        XCTAssertEqual(pinches.changes, [.in, nil, .in])
        XCTAssertEqual(pinches.lifts, [.in])
        XCTAssertEqual(events.begins, [], "a pinch never swipes")
        XCTAssertEqual(events.commits + events.cancels, 0)
    }

    func testAPinchOutLiftsAsAPinchAndALetGoPinchCancels() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        let pinches = observePinches(recognizer)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12), timestamp: 0)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.18), timestamp: 0.03)     // 1.5: out
        recognizer.feed(contacts: [], timestamp: 0.06)
        XCTAssertEqual(pinches.changes, [.out])
        XCTAssertEqual(pinches.lifts, [.out])
        // Out, then back to where the fingers landed before lifting: nothing.
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12), timestamp: 0.3)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.18), timestamp: 0.33)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.125), timestamp: 0.36)   // 1.04: let go
        recognizer.feed(contacts: [], timestamp: 0.39)
        XCTAssertEqual(pinches.changes, [.out, .out, nil])
        XCTAssertEqual(pinches.lifts, [.out], "a pinch let go before the lift does nothing")
        XCTAssertEqual(events.cancels, 1)
        XCTAssertEqual(events.begins, [])
    }

    func testASwipeNeverBecomesAPinchAndAPinchNeverASwipe() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        let pinches = observePinches(recognizer)
        // Wide fingers swipe left, then squeeze together: still the swipe.
        recognizer.feed(contacts: spreadPair(0.50, 0.5, spread: 0.15), timestamp: 0)
        recognizer.feed(contacts: spreadPair(0.40, 0.5, spread: 0.15), timestamp: 0.03)
        XCTAssertEqual(events.begins, [.init(.left)])
        recognizer.feed(contacts: spreadPair(0.38, 0.5, spread: 0.06), timestamp: 0.06)
        recognizer.feed(contacts: [], timestamp: 0.09)
        XCTAssertEqual(pinches.changes, [])
        XCTAssertEqual(events.commits, 1)
        // A pinch in whose fingers then slide sideways: still the pinch.
        recognizer.feed(contacts: spreadPair(0.50, 0.5, spread: 0.15), timestamp: 0.4)
        recognizer.feed(contacts: spreadPair(0.50, 0.5, spread: 0.09), timestamp: 0.43)
        recognizer.feed(contacts: spreadPair(0.30, 0.5, spread: 0.09), timestamp: 0.46)
        recognizer.feed(contacts: [], timestamp: 0.49)
        XCTAssertEqual(events.begins.count, 1, "no swipe began")
        XCTAssertEqual(pinches.lifts, [.in])
    }

    func testFingersLandingCloseTogetherNeverPinch() {
        let recognizer = Self.stateMachineRecognizer()
        let pinches = observePinches(recognizer)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.04), timestamp: 0)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.01), timestamp: 0.03)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.08), timestamp: 0.06)
        recognizer.feed(contacts: [], timestamp: 0.2)
        XCTAssertEqual(pinches.changes, [])
        XCTAssertEqual(pinches.lifts, [])
    }

    func testAThirdFingerAGapOrHoldingStillCancelsAPinch() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        let pinches = observePinches(recognizer)
        var holdCancels = 0
        recognizer.onHoldCancel = { holdCancels += 1 }
        // A third finger.
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.2), timestamp: 0)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12), timestamp: 0.03)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12) + [touch(3, 0.8, 0.5)], timestamp: 0.06)
        recognizer.feed(contacts: [], timestamp: 0.09)
        XCTAssertEqual(events.cancels, 1)
        XCTAssertEqual(pinches.lifts, [])
        // A gap in the frames (sleep and wake).
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.2), timestamp: 1)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12), timestamp: 1.03)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12), timestamp: 9)
        XCTAssertEqual(events.cancels, 2)
        recognizer.feed(contacts: [], timestamp: 9.02)
        XCTAssertEqual(pinches.lifts, [])
        // Pinched, then held still for 2 s.
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.2), timestamp: 20)
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12), timestamp: 20.03)
        for frame in 1...130 { recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12), timestamp: 20.03 + Double(frame) / 60) }
        XCTAssertEqual(holdCancels, 1)
        recognizer.feed(contacts: [], timestamp: 22.3)
        XCTAssertEqual(pinches.lifts, [], "a cancelled pinch does nothing on lift")
    }

    func testATapIsReportedRightAfterItsCancel() {
        let recognizer = Self.stateMachineRecognizer()
        var log: [String] = []
        recognizer.onCancel = { log.append("cancel") }
        recognizer.onCommit = { log.append("commit") }
        recognizer.onTap = { log.append("tap@\($0)") }
        // A plain tap.
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.505, 0.50), timestamp: 0.05)
        recognizer.feed(contacts: [], timestamp: 0.10)
        XCTAssertEqual(log, ["cancel", "tap@0.1"])
        // A quick 5.5 % flick that engaged commits (3.3.2 review: it used to
        // be reported as a tap and thrown away).
        log.removeAll()
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 1)
        recognizer.feed(contacts: pair(0.50, 0.445), timestamp: 1.05)
        recognizer.feed(contacts: [], timestamp: 1.1)
        XCTAssertEqual(log, ["commit"])
        // A slow lift, a real swipe and a third finger are not taps.
        log.removeAll()
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 2)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 2.15)
        recognizer.feed(contacts: [], timestamp: 2.3)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 3)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 3.05)
        recognizer.feed(contacts: [], timestamp: 3.1)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 4)
        recognizer.feed(contacts: pair(0.50, 0.50) + [touch(3, 0.7, 0.5)], timestamp: 4.05)
        recognizer.feed(contacts: [], timestamp: 4.1)
        XCTAssertEqual(log, ["cancel", "commit", "cancel"])
    }

    func testRestingHalfASecondMakesTheSwipeAHeldOne() {
        let recognizer = Self.stateMachineRecognizer()
        XCTAssertEqual(recognizer.holdTime, 0.45, "Swish-like tap and hold")
        let events = observe(recognizer)
        var holds = 0
        recognizer.onHoldBegan = { holds += 1 }
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
        for frame in 1...24 { recognizer.feed(contacts: pair(0.50, 0.50), timestamp: Double(frame) / 60) }   // 0.4 s
        XCTAssertEqual(holds, 0)
        for frame in 25...33 { recognizer.feed(contacts: pair(0.50, 0.50), timestamp: Double(frame) / 60) }  // 0.55 s
        XCTAssertEqual(holds, 1)
        recognizer.feed(contacts: pair(0.50, 0.42), timestamp: 0.6)      // swipe up
        recognizer.feed(contacts: pair(0.50, 0.30), timestamp: 0.63)
        recognizer.feed(contacts: [], timestamp: 0.66)
        XCTAssertEqual(holds, 1, "once per touch")
        XCTAssertEqual(events.begins, [.init(.up, held: true)])
        XCTAssertEqual(events.updates.last?.held, true, "every stroke of the touch is held")
        XCTAssertEqual(events.commits, 1)
        // The next touch starts out unheld.
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 1)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 1.03)
        XCTAssertEqual(events.begins.last, .init(.left))
        XCTAssertFalse(recognizer.isHeld)
    }

    /// Swish's hold-still cancel still spends a tap-and-hold that never
    /// swipes: 2 s of stillness in all, held at 0.45 s on the way.
    func testATapAndHoldThatNeverSwipesIsStillCancelledAtTwoSeconds() {
        let recognizer = Self.stateMachineRecognizer()
        let events = observe(recognizer)
        var holds = 0, holdCancels = 0
        recognizer.onHoldBegan = { holds += 1 }
        recognizer.onHoldCancel = { holdCancels += 1 }
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
        for frame in 1...125 {
            recognizer.feed(contacts: pair(0.50 + (frame % 2 == 0 ? 0.003 : -0.003), 0.50), timestamp: Double(frame) / 60)
        }
        XCTAssertEqual(holds, 1)
        XCTAssertEqual(holdCancels, 1, "2 s of stillness spends the held touch")
        recognizer.feed(contacts: pair(0.30, 0.50), timestamp: 2.2)
        recognizer.feed(contacts: [], timestamp: 2.24)
        XCTAssertEqual(events.begins, [])
        XCTAssertEqual(events.commits, 0)
        // With tap and hold switched off nothing is held.
        recognizer.holdTime = 0
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 3)
        for frame in 1...40 { recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 3 + Double(frame) / 60) }
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 3.7)
        XCTAssertEqual(events.begins, [.init(.left)])
        XCTAssertEqual(holds, 1)
    }

    func testAHeldPinchKnowsItWasHeld() {
        let recognizer = Self.stateMachineRecognizer()
        var heldAtLift: Bool?
        recognizer.onPinch = { [unowned recognizer] _ in heldAtLift = recognizer.isHeld }
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.2), timestamp: 0)
        for frame in 1...33 { recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.2), timestamp: Double(frame) / 60) }
        recognizer.feed(contacts: spreadPair(0.5, 0.5, spread: 0.12), timestamp: 0.6)
        recognizer.feed(contacts: [], timestamp: 0.63)
        XCTAssertEqual(heldAtLift, true, "tap, hold and pinch in: Swish's quit")
    }

    func testTheGestureMappingCoversHoldModifiersAndTheDownOption() {
        let swish = SwishSnap.GestureOptions()
        func map(_ cell: CustomSnapZone.Layout?, _ stroke: SwishSnap.Stroke, _ modifiers: SwishSnap.Modifiers = [],
                 _ options: SwishSnap.GestureOptions = SwishSnap.GestureOptions(),
                 fullscreen: Bool = false) -> SwishSnap.Move? {
            SwishSnap.move(from: cell, stroke: stroke, modifiers: modifiers, options: options, fullscreen: fullscreen)
        }
        // Swish's default: a short swipe down minimizes a free (or centred)
        // window; a longer one or an L-shape still snaps.
        XCTAssertEqual(map(nil, .init(.down)), .action(.minimize))
        XCTAssertEqual(map(.center, .init(.down)), .action(.minimize))
        XCTAssertEqual(map(nil, .init(.down, tier: 2)), .cell(.bottomHalf))
        XCTAssertEqual(map(nil, .init(.down, cross: .left)), .cell(.bottomLeft))
        // A window in a cell keeps chaining.
        XCTAssertEqual(map(.topLeft, .init(.down)), .cell(.bottomLeft))
        XCTAssertEqual(map(.maximize, .init(.down)), .restore)
        XCTAssertEqual(map(nil, .init(.up)), .cell(.maximize))
        // The Center option keeps 3.3.1's swipe down.
        var center = swish
        center.downAction = .center
        XCTAssertEqual(map(nil, .init(.down), [], center), .cell(.center))
        XCTAssertEqual(map(.center, .init(.down), [], center), .restore)
        // Tap and hold.
        XCTAssertEqual(map(nil, .init(.up, held: true)), .action(.toggleFullscreen))
        XCTAssertEqual(map(.leftHalf, .init(.down, held: true)), .action(.minimize))
        XCTAssertEqual(map(nil, .init(.left, held: true)), .action(.spaceLeft))
        XCTAssertEqual(map(.maximize, .init(.right, tier: 2, held: true)), .action(.spaceRight))
        var noHold = swish
        noHold.holdGestures = false
        XCTAssertEqual(map(nil, .init(.left, held: true), [], noHold), .cell(.leftHalf))
        // ⌥ Option, Swish's general modifier.
        XCTAssertEqual(map(nil, .init(.left), .general), .action(.spaceLeft))
        XCTAssertEqual(map(.rightHalf, .init(.right), .general), .action(.spaceRight))
        XCTAssertEqual(map(nil, .init(.down), .general), .action(.close))
        XCTAssertEqual(map(nil, .init(.down, held: true), .general), .action(.quitApp))
        XCTAssertEqual(map(nil, .init(.up), .general), .cell(.maximize), "⌥ up is a plain swipe up")
        // ⌘ Command, the screen modifier: any direction, held or not.
        for direction: SwishSnap.Direction in [.left, .right, .up, .down] {
            XCTAssertEqual(map(.leftHalf, .init(direction), .screen), .action(.screen(direction)))
        }
        XCTAssertEqual(map(nil, .init(.down, held: true), [.screen, .general]), .action(.screen(.down)))
        // ⇧ alone changes no swipe; with modifier gestures off none does.
        XCTAssertEqual(map(nil, .init(.left), .secondary), .cell(.leftHalf))
        var noModifiers = swish
        noModifiers.modifierGestures = false
        XCTAssertEqual(map(nil, .init(.left), [.general, .screen], noModifiers), .cell(.leftHalf))
        // Native full screen: only tap and hold and the modifiers act.
        XCTAssertNil(map(nil, .init(.down), fullscreen: true))
        XCTAssertNil(map(.maximize, .init(.left), fullscreen: true))
        XCTAssertEqual(map(nil, .init(.down, held: true), fullscreen: true), .action(.minimize))
        XCTAssertEqual(map(nil, .init(.up, held: true), fullscreen: true), .action(.toggleFullscreen))
        XCTAssertNil(map(nil, .init(.left, held: true), fullscreen: true), "a full-screen window is its own Space")
        XCTAssertEqual(map(nil, .init(.down), .general, fullscreen: true), .action(.close))
        XCTAssertEqual(map(nil, .init(.right), .screen, fullscreen: true), .action(.screen(.right)))
        // Thirds off: a remembered third is free-floating, so it minimizes.
        XCTAssertEqual(map(.leftThird, .init(.down)), .action(.minimize))
        var thirds = swish
        thirds.thirds = true
        // 3.3.2: the 3 × 2 grid has Swish's sixths, so a third swiped down
        // takes its lower half instead of being put back (3.3.1's .restore).
        XCTAssertEqual(map(.leftThird, .init(.down), [], thirds), .place(.grid(.sixth(0, 1))))
    }

    func testPinchAndDoubleTapDecisions() {
        func pinch(_ kind: SwishSnap.Pinch, second: Bool = false, held: Bool = false,
                   _ modifiers: SwishSnap.Modifiers = [], displays: Int = 1) -> String {
            let decision = SwishSnap.pinchAction(kind, second: second, held: held, modifiers: modifiers, displays: displays)
            return "\(decision.action)\(decision.waits ? " waits" : "")"
        }
        // Pinch in closes after waiting for a second pinch, which quits.
        XCTAssertEqual(pinch(.in), "close waits")
        XCTAssertEqual(pinch(.in, second: true), "quitApp")
        XCTAssertEqual(pinch(.in, held: true), "quitApp", "tap, hold and pinch in once")
        // Pinch out: full screen; with two displays, twice (or ⌘, or held) on the other one.
        XCTAssertEqual(pinch(.out), "toggleFullscreen")
        XCTAssertEqual(pinch(.out, .screen), "toggleFullscreen", "one display: ⌘ changes nothing")
        XCTAssertEqual(pinch(.out, displays: 2), "toggleFullscreen waits")
        XCTAssertEqual(pinch(.out, second: true, displays: 2), "fullscreenOnOtherScreen")
        XCTAssertEqual(pinch(.out, .screen, displays: 2), "fullscreenOnOtherScreen")
        XCTAssertEqual(pinch(.out, held: true, displays: 2), "fullscreenOnOtherScreen")
        // Double tap.
        XCTAssertEqual(SwishSnap.doubleTapMove(.restoreOrCenter, modifiers: []), .restore)
        XCTAssertEqual(SwishSnap.doubleTapMove(.center, modifiers: []), .cell(.center))
        XCTAssertNil(SwishSnap.doubleTapMove(.off, modifiers: []))
        XCTAssertEqual(SwishSnap.doubleTapMove(.center, modifiers: .general), .action(.hideApp))
        XCTAssertEqual(SwishSnap.doubleTapMove(.restoreOrCenter, modifiers: .secondary), .action(.hideOthers))
        XCTAssertEqual(SwishSnap.doubleTapMove(.restoreOrCenter, modifiers: [.general, .secondary]), .action(.hideOthers))
        XCTAssertNil(SwishSnap.doubleTapMove(.off, modifiers: .general), "off is off, modifiers or not")
        // Swish's modifiers from the keyboard flags.
        XCTAssertEqual(SwishSnap.Modifiers(flags: [.option, .shift]), [.general, .secondary])
        XCTAssertEqual(SwishSnap.Modifiers(flags: [.command, .control]), .screen)
    }

    func testTheDisplayInTheSwipesDirection() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: -1080, width: 1440, height: 1080)
        let screens = [main, right, above]
        let onMain = CGRect(x: 200, y: 100, width: 800, height: 600)
        XCTAssertEqual(SwishSnap.screenIndex(toward: .right, from: onMain, screens: screens), 1)
        XCTAssertEqual(SwishSnap.screenIndex(toward: .up, from: onMain, screens: screens), 2)
        XCTAssertNil(SwishSnap.screenIndex(toward: .left, from: onMain, screens: screens))
        XCTAssertNil(SwishSnap.screenIndex(toward: .down, from: onMain, screens: screens))
        let onRight = CGRect(x: 1600, y: 100, width: 800, height: 600)
        XCTAssertEqual(SwishSnap.screenIndex(toward: .left, from: onRight, screens: screens), 0,
                       "side by side beats the display diagonally up")
        let onAbove = CGRect(x: 100, y: -900, width: 800, height: 600)
        XCTAssertEqual(SwishSnap.screenIndex(toward: .down, from: onAbove, screens: screens), 0)
        XCTAssertEqual(SwishSnap.screenIndex(toward: .right, from: onAbove, screens: screens), 1,
                       "only a diagonal display that way: the nearest")
        // A window across two displays moves from the one holding most of it.
        let straddling = CGRect(x: 1200, y: 100, width: 800, height: 600)
        XCTAssertEqual(SwishSnap.screenIndex(toward: .left, from: straddling, screens: screens), 0)
        XCTAssertNil(SwishSnap.screenIndex(toward: .right, from: straddling, screens: screens))
        XCTAssertNil(SwishSnap.screenIndex(toward: .left, from: onMain, screens: [main]), "one display")
    }

    /// The reported chain for apps with a minimum size: snapped to a top
    /// quarter such a window hangs below it, and was taken for a free window.
    func testAWindowLargerThanItsCellIsStillRecognisedInIt() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        XCTAssertEqual(SwishSnap.cell(of: CGRect(x: 0, y: 25, width: 720, height: 600), visible: visible, margin: 0), .topLeft)
        XCTAssertEqual(SwishSnap.cell(of: CGRect(x: 0, y: 300, width: 720, height: 600), visible: visible, margin: 0), .bottomLeft,
                       "a bottom quarter keeps the bottom edge")
        XCTAssertEqual(SwishSnap.cell(of: CGRect(x: 0, y: 25, width: 900, height: 875), visible: visible, margin: 0, thirds: false),
                       .leftHalf, "a minimum width in the left half")
        // An exact fit still wins, and a free window stays free.
        XCTAssertEqual(SwishSnap.cell(of: CGRect(x: 0, y: 25, width: 720, height: 875), visible: visible, margin: 0), .leftHalf)
        XCTAssertNil(SwishSnap.cell(of: CGRect(x: 0, y: 25, width: 600, height: 400), visible: visible, margin: 0))
        XCTAssertNil(SwishSnap.cell(of: CGRect(x: 300, y: 200, width: 800, height: 600), visible: visible, margin: 0))
        let cell = SwishSnap.cell(of: CGRect(x: 0, y: 25, width: 720, height: 600), visible: visible, margin: 0, thirds: false)
        XCTAssertEqual(SwishSnap.move(from: cell, stroke: .init(.down), modifiers: [], options: SwishSnap.GestureOptions()),
                       .cell(.bottomLeft), "top quarter swiped down: bottom quarter, not minimized")
    }

    func testTheNewGestureSettingsDefaultToSwish() {
        let suite = "aom.test.titlebargestures.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TitleBarWindowSnap.gestureOptions(defaults), SwishSnap.GestureOptions())
        XCTAssertEqual(TitleBarWindowSnap.gestureOptions(defaults).downAction, .minimize)
        XCTAssertEqual(TitleBarWindowSnap.doubleTapOption(defaults), .restoreOrCenter)
        XCTAssertTrue(TitleBarWindowSnap.pinchesOn(defaults))
        defaults.set("center", forKey: TitleBarWindowSnap.downActionKey)
        defaults.set("off", forKey: TitleBarWindowSnap.doubleTapKey)
        defaults.set(false, forKey: TitleBarWindowSnap.holdKey)
        defaults.set(false, forKey: TitleBarWindowSnap.modifiersKey)
        defaults.set(false, forKey: TitleBarWindowSnap.pinchKey)
        defaults.set(true, forKey: TitleBarWindowSnap.thirdsKey)
        XCTAssertEqual(TitleBarWindowSnap.gestureOptions(defaults),
                       SwishSnap.GestureOptions(thirds: true, downAction: .center, holdGestures: false, modifierGestures: false))
        XCTAssertEqual(TitleBarWindowSnap.doubleTapOption(defaults), .off)
        XCTAssertFalse(TitleBarWindowSnap.pinchesOn(defaults))
        defaults.set("bogus", forKey: TitleBarWindowSnap.doubleTapKey)
        XCTAssertEqual(TitleBarWindowSnap.doubleTapOption(defaults), .restoreOrCenter, "an unknown value falls back")
    }

    func testTheHUDNamesEachAction() {
        XCTAssertEqual(SwishSnap.title(for: .minimize, appName: "Safari"), "Minimize")
        XCTAssertEqual(SwishSnap.title(for: .close, appName: "Safari"), "Close Window")
        XCTAssertEqual(SwishSnap.title(for: .quitApp, appName: "Safari"), "Quit Safari")
        XCTAssertEqual(SwishSnap.title(for: .quitApp, appName: nil), "Quit App")
        XCTAssertEqual(SwishSnap.title(for: .hideApp, appName: "Mail"), "Hide Mail")
        XCTAssertEqual(SwishSnap.title(for: .toggleFullscreen, appName: nil), "Full Screen")
        XCTAssertEqual(SwishSnap.title(for: .toggleFullscreen, appName: nil, fullscreen: true), "Exit Full Screen")
        XCTAssertEqual(SwishSnap.title(for: .spaceLeft, appName: nil), "Move to Space ←")
        XCTAssertEqual(SwishSnap.title(for: .screen(.right), appName: nil), "Move to Display →")
    }
}
