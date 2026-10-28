import XCTest
@testable import AllOfMacOS

/// Swish-style title-bar two-finger snap. Pure recognition and geometry only —
/// no trackpad, Accessibility or overlay windows are touched.
final class TitleBarSnapTests: XCTestCase {
    private func touch(_ id: Int, _ x: Float, _ y: Float) -> TouchPoint {
        TouchPoint(id: id, x: x, y: y, size: 1, pressure: 0)
    }

    /// Two fingers whose centroid sits at (x, y).
    private func pair(_ x: Float, _ y: Float) -> [TouchPoint] {
        [touch(1, x - 0.01, y), touch(2, x + 0.01, y)]
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
        let recognizer = TitleBarSnapRecognizer()
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
        let recognizer = TitleBarSnapRecognizer()
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
        let recognizer = TitleBarSnapRecognizer()
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
        let recognizer = TitleBarSnapRecognizer()
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
        recognizer.onActive = { events.actives += 1 }
        recognizer.onCommit = { events.commits += 1 }
        recognizer.onCancel = { events.cancels += 1 }
        return events
    }

    /// The audit's SnapProbe ADD_THIRD_FINGER: 3.3.0 committed the snap.
    func testAThirdFingerCancelsInsteadOfCommitting() {
        let recognizer = TitleBarSnapRecognizer()
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
    func testHoldingOneZoneForThreeSecondsThenLiftingCommits() {
        let recognizer = TitleBarSnapRecognizer()
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

    /// The service's watchdog or a sleep notification ended the gesture on
    /// main: the recognizer must drop it too, without callbacks, and wait
    /// for the lift before a new snap can start.
    func testAServiceCancelResetsTheRecognizerUntilTheLift() {
        let recognizer = TitleBarSnapRecognizer()
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
        let recognizer = TitleBarSnapRecognizer()
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
        let recognizer = TitleBarSnapRecognizer()
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
        let recognizer = TitleBarSnapRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        recognizer.feed(contacts: [touch(1, 0.49, 0.50)], timestamp: 0.04)
        XCTAssertEqual(events.commits, 1)
        recognizer.feed(contacts: [], timestamp: 0.06)
        XCTAssertEqual(events.commits, 1, "one commit per gesture")
    }

    func testAGapInTheFramesDropsAStaleStart() {
        let recognizer = TitleBarSnapRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        // The trackpad slept without a lift frame; much later fingers land elsewhere.
        recognizer.feed(contacts: pair(0.60, 0.50), timestamp: 5.0)
        XCTAssertEqual(events.begins, [], "a jump across a gap is not a swipe (3.3.0 engaged instantly)")
        recognizer.feed(contacts: pair(0.70, 0.50), timestamp: 5.02)
        XCTAssertEqual(events.begins, [.init(.right)], "measured from the new start")
    }

    func testASecondTrackpadIsIgnoredWhileTheFirstIsLive() {
        let recognizer = TitleBarSnapRecognizer()
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
        let recognizer = TitleBarSnapRecognizer()
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
        let recognizer = TitleBarSnapRecognizer()
        let events = observe(recognizer)
        recognizer.feed(contacts: pair(0.40, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0.02)
        recognizer.reset()      // the snap or AOM was switched off mid-gesture
        recognizer.feed(contacts: [], timestamp: 0.04)
        XCTAssertEqual(events.commits, 0)
        XCTAssertEqual(events.cancels, 0)
    }
}
