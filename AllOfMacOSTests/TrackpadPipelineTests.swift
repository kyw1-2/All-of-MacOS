import XCTest
@testable import AllOfMacOS

final class TrackpadPipelineTests: XCTestCase {
    private var savedEnabled: Any?
    private var savedRest: Any?

    override func setUp() {
        super.setUp()
        savedEnabled = UserDefaults.standard.object(forKey: "AOMGlobalEnabled")
        savedRest = UserDefaults.standard.object(forKey: "AOMTipTapMinRestTime")
        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
        UserDefaults.standard.set(0.12, forKey: "AOMTipTapMinRestTime")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedEnabled, forKey: "AOMGlobalEnabled")
        UserDefaults.standard.set(savedRest, forKey: "AOMTipTapMinRestTime")
        ActionExecutor.onActionExecuted = nil
        super.tearDown()
    }

    // MARK: - Tap gesture tests

    /// Simulates a 4-finger tap through TrackpadMonitor and verifies the action fires.
    func testFourFingerTapTriggersAction() {
        let expectation = expectation(description: "Action should be executed")

        var trigger = Trigger(name: "Test 4-Finger Tap", input: .trackpadGesture(.fourFingerTap))
        let action = TriggerAction(
            actionType: .sendKeyStroke,
            parameters: {
                var p = ActionParameters()
                p.shortcutKeyCode = 15  // R key
                p.shortcutModifiers = NSEvent.ModifierFlags.command.rawValue
                return p
            }()
        )
        trigger.actions = [action]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        var firedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { executedAction in
            firedAction = executedAction
            expectation.fulfill()
        }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 4, timestamp: now)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 2.0)

        XCTAssertNotNil(firedAction, "Action should have been triggered by 4-finger tap")
        XCTAssertEqual(firedAction?.actionType, .sendKeyStroke)
        XCTAssertEqual(firedAction?.parameters.shortcutKeyCode, 15)
        XCTAssertEqual(firedAction?.parameters.shortcutModifiers, NSEvent.ModifierFlags.command.rawValue)

        monitor.unregisterAll()
    }

    /// Verifies that a 3-finger tap does NOT trigger a 4-finger tap action.
    func testThreeFingerTapDoesNotTriggerFourFingerAction() {
        let expectation = expectation(description: "Action should NOT fire")
        expectation.isInverted = true

        var trigger = Trigger(name: "4-Finger Only", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [TriggerAction(actionType: .sendKeyStroke)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        ActionExecutor.onActionExecuted = { _ in
            expectation.fulfill()
        }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 3, timestamp: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 1.0)
        monitor.unregisterAll()
    }

    /// Verifies that holding fingers too long counts as a hold, not a tap.
    func testLongHoldDoesNotTriggerTap() {
        let expectation = expectation(description: "Action should NOT fire for long hold")
        expectation.isInverted = true

        var trigger = Trigger(name: "Tap", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [TriggerAction(actionType: .sendKeyStroke)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        ActionExecutor.onActionExecuted = { _ in
            expectation.fulfill()
        }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 4, timestamp: now)

        // Lift after 0.5s — exceeds the 0.35s tap timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.5)
        }

        waitForExpectations(timeout: 2.0)
        monitor.unregisterAll()
    }

    func testThreeFingerTapTriggersAction() {
        let expectation = expectation(description: "3-finger tap fires")

        var trigger = Trigger(name: "3-Finger Tap", input: .trackpadGesture(.threeFingerTap))
        trigger.actions = [TriggerAction(actionType: .volumeUp)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        var firedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { a in
            firedAction = a
            expectation.fulfill()
        }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 3, timestamp: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(firedAction?.actionType, .volumeUp)
        monitor.unregisterAll()
    }

    func testFiveFingerTapTriggersAction() {
        let expectation = expectation(description: "5-finger tap fires")

        var trigger = Trigger(name: "5-Finger Tap", input: .trackpadGesture(.fiveFingerTap))
        trigger.actions = [TriggerAction(actionType: .lockScreen)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        var firedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { a in
            firedAction = a
            expectation.fulfill()
        }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 5, timestamp: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(firedAction?.actionType, .lockScreen)
        monitor.unregisterAll()
    }

    /// 2-finger tap does NOT fire 3-finger tap
    func testTwoFingerTapDoesNotTriggerThreeFingerAction() {
        let expectation = expectation(description: "Should NOT fire")
        expectation.isInverted = true

        var trigger = Trigger(name: "3-Finger Only", input: .trackpadGesture(.threeFingerTap))
        trigger.actions = [TriggerAction(actionType: .sendKeyStroke)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        ActionExecutor.onActionExecuted = { _ in expectation.fulfill() }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 2, timestamp: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 1.0)
        monitor.unregisterAll()
    }

    // MARK: - Peak finger tracking

    /// Fingers ramp up 1→2→3→4 then lift — should fire 4-finger tap (peak)
    func testPeakFingerCountTracked() {
        let expectation = expectation(description: "4-finger tap via ramp-up")

        var trigger = Trigger(name: "4F", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [TriggerAction(actionType: .playPause)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        var firedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { a in
            firedAction = a
            expectation.fulfill()
        }

        let now = Date().timeIntervalSince1970
        // Fingers land progressively
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 1, timestamp: now)
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 2, timestamp: now + 0.02)
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 3, timestamp: now + 0.04)
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 4, timestamp: now + 0.06)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.15)
        }

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(firedAction?.actionType, .playPause)
        monitor.unregisterAll()
    }

    // MARK: - Multiple triggers / routing

    /// Two different gestures registered, only the matching one fires
    func testMultipleTriggerRoutesCorrectly() {
        let exp3 = expectation(description: "3-finger should fire")
        let exp4 = expectation(description: "4-finger should NOT fire")
        exp4.isInverted = true

        var trigger3 = Trigger(name: "3F", input: .trackpadGesture(.threeFingerTap))
        trigger3.actions = [TriggerAction(actionType: .volumeUp)]

        var trigger4 = Trigger(name: "4F", input: .trackpadGesture(.fourFingerTap))
        trigger4.actions = [TriggerAction(actionType: .volumeDown)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger3, trigger4])

        ActionExecutor.onActionExecuted = { a in
            if a.actionType == .volumeUp { exp3.fulfill() }
            if a.actionType == .volumeDown { exp4.fulfill() }
        }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 3, timestamp: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 2.0)
        monitor.unregisterAll()
    }

    // MARK: - Disabled trigger

    func testDisabledTriggerDoesNotFire() {
        let expectation = expectation(description: "Should NOT fire")
        expectation.isInverted = true

        var trigger = Trigger(name: "Disabled", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [TriggerAction(actionType: .sendKeyStroke)]
        trigger.isEnabled = false

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        ActionExecutor.onActionExecuted = { _ in expectation.fulfill() }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 4, timestamp: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 1.0)
        monitor.unregisterAll()
    }

    // MARK: - Unregister clears state

    func testUnregisterClearsAllTriggers() {
        let expectation = expectation(description: "Should NOT fire after unregister")
        expectation.isInverted = true

        var trigger = Trigger(name: "T", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [TriggerAction(actionType: .sendKeyStroke)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])
        monitor.unregisterAll()

        ActionExecutor.onActionExecuted = { _ in expectation.fulfill() }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 4, timestamp: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 1.0)
    }

    // MARK: - App-specific vs global trigger priority

    /// When an app-specific trigger exists for a different app, the global trigger fires instead
    func testGlobalTriggerFiresWhenNoAppMatch() {
        let globalExp = self.expectation(description: "Global fires")
        let appExp = self.expectation(description: "App-specific should NOT fire")
        appExp.isInverted = true

        var globalTrigger = Trigger(name: "Global", input: .trackpadGesture(.threeFingerTap))
        globalTrigger.actions = [TriggerAction(actionType: .volumeUp)]

        // Use a fake bundle ID that won't match the frontmost app
        var appTrigger = Trigger(name: "App", input: .trackpadGesture(.threeFingerTap), appBundleID: "com.fake.nonexistent.app")
        appTrigger.actions = [TriggerAction(actionType: .volumeDown)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([globalTrigger, appTrigger])

        ActionExecutor.onActionExecuted = { a in
            if a.actionType == .volumeUp { globalExp.fulfill() }
            if a.actionType == .volumeDown { appExp.fulfill() }
        }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 3, timestamp: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 2.0)
        monitor.unregisterAll()
    }

    // MARK: - Multiple actions on single trigger

    func testMultipleActionsAllFire() {
        let exp1 = expectation(description: "Action 1 fires")
        let exp2 = expectation(description: "Action 2 fires")

        var trigger = Trigger(name: "Multi", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [
            TriggerAction(actionType: .volumeUp),
            TriggerAction(actionType: .playPause)
        ]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        ActionExecutor.onActionExecuted = { a in
            if a.actionType == .volumeUp { exp1.fulfill() }
            if a.actionType == .playPause { exp2.fulfill() }
        }

        let now = Date().timeIntervalSince1970
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 4, timestamp: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: now + 0.1)
        }

        waitForExpectations(timeout: 2.0)
        monitor.unregisterAll()
    }

    // MARK: - Two-finger press-drag tests

    func testTwoFingerPressDragLeftTriggersAction() {
        let expectation = expectation(description: "Press drag left fires")

        var trigger = Trigger(name: "Drag Left", input: .trackpadGesture(.twoFingerPressDragLeft))
        trigger.actions = [TriggerAction(actionType: .snapWindowLeft)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        var firedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { a in
            firedAction = a
            expectation.fulfill()
        }

        monitor.fireGestureForTest(.twoFingerPressDragLeft)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(firedAction?.actionType, .snapWindowLeft)
        monitor.unregisterAll()
    }

    func testTwoFingerPressDragRightTriggersAction() {
        let expectation = expectation(description: "Press drag right fires")

        var trigger = Trigger(name: "Drag Right", input: .trackpadGesture(.twoFingerPressDragRight))
        trigger.actions = [TriggerAction(actionType: .snapWindowRight)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        var firedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { a in
            firedAction = a
            expectation.fulfill()
        }

        monitor.fireGestureForTest(.twoFingerPressDragRight)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(firedAction?.actionType, .snapWindowRight)
        monitor.unregisterAll()
    }

    func testPressDragLeftDoesNotFireDragRight() {
        let expectation = expectation(description: "Should NOT fire")
        expectation.isInverted = true

        var trigger = Trigger(name: "Right Only", input: .trackpadGesture(.twoFingerPressDragRight))
        trigger.actions = [TriggerAction(actionType: .sendKeyStroke)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        ActionExecutor.onActionExecuted = { _ in expectation.fulfill() }

        monitor.fireGestureForTest(.twoFingerPressDragLeft)

        waitForExpectations(timeout: 1.0)
        monitor.unregisterAll()
    }

    func testPressDragGesturesCodable() throws {
        for gesture in [TrackpadGesture.twoFingerPressDragLeft, .twoFingerPressDragRight] {
            let trigger = Trigger(name: gesture.rawValue, input: .trackpadGesture(gesture))
            let data = try JSONEncoder().encode(trigger)
            let decoded = try JSONDecoder().decode(Trigger.self, from: data)
            if case .trackpadGesture(let g) = decoded.input {
                XCTAssertEqual(g, gesture)
            } else {
                XCTFail("Expected trackpadGesture for \(gesture)")
            }
        }
    }

    // MARK: - Edge slider tests

    func testLeftEdgeSlideUpTriggersAction() {
        let expectation = expectation(description: "Left edge slide up fires")

        var trigger = Trigger(name: "L Slide Up", input: .trackpadGesture(.leftEdgeSlideUp))
        trigger.actions = [TriggerAction(actionType: .brightnessUp)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        var firedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { a in
            firedAction = a
            expectation.fulfill()
        }

        monitor.fireGestureForTest(.leftEdgeSlideUp)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(firedAction?.actionType, .brightnessUp)
        monitor.unregisterAll()
    }

    func testRightEdgeSlideDownTriggersAction() {
        let expectation = expectation(description: "Right edge slide down fires")

        var trigger = Trigger(name: "R Slide Down", input: .trackpadGesture(.rightEdgeSlideDown))
        trigger.actions = [TriggerAction(actionType: .brightnessDown)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        var firedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { a in
            firedAction = a
            expectation.fulfill()
        }

        monitor.fireGestureForTest(.rightEdgeSlideDown)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(firedAction?.actionType, .brightnessDown)
        monitor.unregisterAll()
    }

    func testEdgeSlideUpDoesNotFireSlideDown() {
        let expectation = expectation(description: "Should NOT fire")
        expectation.isInverted = true

        var trigger = Trigger(name: "Down Only", input: .trackpadGesture(.rightEdgeSlideDown))
        trigger.actions = [TriggerAction(actionType: .sendKeyStroke)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        ActionExecutor.onActionExecuted = { _ in expectation.fulfill() }

        monitor.fireGestureForTest(.rightEdgeSlideUp)

        waitForExpectations(timeout: 1.0)
        monitor.unregisterAll()
    }

    func testEdgeSliderGesturesCodable() throws {
        let gestures: [TrackpadGesture] = [.leftEdgeSlideUp, .leftEdgeSlideDown, .rightEdgeSlideUp, .rightEdgeSlideDown]
        for gesture in gestures {
            let trigger = Trigger(name: gesture.rawValue, input: .trackpadGesture(gesture))
            let data = try JSONEncoder().encode(trigger)
            let decoded = try JSONDecoder().decode(Trigger.self, from: data)
            if case .trackpadGesture(let g) = decoded.input {
                XCTAssertEqual(g, gesture)
            } else {
                XCTFail("Expected trackpadGesture for \(gesture)")
            }
        }
    }

    // MARK: - Triangle drawing tests

    func testDrawTriangleTriggersAction() {
        let expectation = expectation(description: "Triangle fires")

        var trigger = Trigger(name: "Triangle", input: .trackpadGesture(.drawTriangle))
        trigger.actions = [TriggerAction(actionType: .lockScreen)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        var firedAction: TriggerAction?
        ActionExecutor.onActionExecuted = { a in
            firedAction = a
            expectation.fulfill()
        }

        monitor.fireGestureForTest(.drawTriangle)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(firedAction?.actionType, .lockScreen)
        monitor.unregisterAll()
    }

    func testDrawTriangleCodable() throws {
        let trigger = Trigger(name: "Tri", input: .trackpadGesture(.drawTriangle))
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(Trigger.self, from: data)
        if case .trackpadGesture(let g) = decoded.input {
            XCTAssertEqual(g, .drawTriangle)
        } else {
            XCTFail("Expected trackpadGesture drawTriangle")
        }
    }

    // MARK: - Global toggle tests

    func testGlobalToggleOffSuppressesActions() {
        let expectation = expectation(description: "Should NOT fire when disabled")
        expectation.isInverted = true

        var trigger = Trigger(name: "Tap", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [TriggerAction(actionType: .volumeUp)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        // Disable global toggle
        UserDefaults.standard.set(false, forKey: "AOMGlobalEnabled")

        ActionExecutor.onActionExecuted = { _ in expectation.fulfill() }

        monitor.fireGestureForTest(.fourFingerTap)

        waitForExpectations(timeout: 1.0)

        // Restore
        UserDefaults.standard.removeObject(forKey: "AOMGlobalEnabled")
        monitor.unregisterAll()
    }

    func testGlobalToggleOnAllowsActions() {
        let expectation = expectation(description: "Should fire when enabled")

        var trigger = Trigger(name: "Tap", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [TriggerAction(actionType: .volumeUp)]

        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])

        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")

        ActionExecutor.onActionExecuted = { _ in expectation.fulfill() }

        monitor.fireGestureForTest(.fourFingerTap)

        waitForExpectations(timeout: 2.0)

        UserDefaults.standard.removeObject(forKey: "AOMGlobalEnabled")
        monitor.unregisterAll()
    }

    // MARK: - SwipeResolver
    //
    // The swipe rule used to live inside the private handleScroll, driven by
    // NSEvent phases, so none of it was reachable from a test. These pin down
    // the distance gate, the axis tie-break and the direction sign convention.

    private func decide(
        deltaX: CGFloat,
        deltaY: CGFloat,
        fingers: Int = 2,
        duration: TimeInterval = 0.1,
        distance: CGFloat = 50,
        minVelocity: CGFloat = 500
    ) -> SwipeResolver.Decision? {
        SwipeResolver.decide(
            deltaX: deltaX,
            deltaY: deltaY,
            fingerCount: fingers,
            duration: duration,
            distanceThreshold: distance,
            minVelocityFor: { _ in minVelocity }
        )
    }

    func testSwipeResolvesDominantAxisAndSign() {
        // Positive delta means the content moved up/left → up/left swipe.
        XCTAssertEqual(decide(deltaX: 0, deltaY: 200)?.gesture, .twoFingerSwipeUp)
        XCTAssertEqual(decide(deltaX: 0, deltaY: -200)?.gesture, .twoFingerSwipeDown)
        XCTAssertEqual(decide(deltaX: 200, deltaY: 0)?.gesture, .twoFingerSwipeLeft)
        XCTAssertEqual(decide(deltaX: -200, deltaY: 0)?.gesture, .twoFingerSwipeRight)
    }

    func testSwipeUsesTheLargerAxisWhenBothMove() {
        XCTAssertEqual(decide(deltaX: 300, deltaY: 100)?.gesture, .twoFingerSwipeLeft)
        XCTAssertEqual(decide(deltaX: 100, deltaY: 300)?.gesture, .twoFingerSwipeUp)
    }

    func testSwipeRespectsFingerCount() {
        XCTAssertEqual(decide(deltaX: 0, deltaY: 200, fingers: 3)?.gesture, .threeFingerSwipeUp)
        XCTAssertEqual(decide(deltaX: 0, deltaY: 200, fingers: 4)?.gesture, .fourFingerSwipeUp)
    }

    func testSwipeRejectsTravelBelowTheDistanceThreshold() {
        // Exactly at the threshold is not enough — the rule requires strictly more.
        XCTAssertNil(decide(deltaX: 0, deltaY: 50, distance: 50))
        XCTAssertNotNil(decide(deltaX: 0, deltaY: 51, distance: 50))
    }

    func testSwipeRejectsAFlickBelowTheVelocityFloor() {
        // 200pt in 1s is 200pt/s, under a 500pt/s floor.
        XCTAssertNil(decide(deltaX: 0, deltaY: 200, duration: 1.0, minVelocity: 500))
        // The same distance in 0.2s clears it.
        XCTAssertNotNil(decide(deltaX: 0, deltaY: 200, duration: 0.2, minVelocity: 500))
    }

    func testSwipeReportsTheVelocityItMeasured() {
        let decision = decide(deltaX: 0, deltaY: 200, duration: 0.5, minVelocity: 100)
        XCTAssertEqual(decision?.velocity ?? 0, 400, accuracy: 0.001)
    }

    /// Five-finger swipes now exist, matching BTT, so the resolver must answer
    /// for all four directions rather than refusing the count outright.
    func testSwipeResolvesEveryDirectionForFiveFingers() {
        // A positive delta is an up/left swipe, the same convention the
        // two-finger cases above use.
        XCTAssertEqual(decide(deltaX: 0, deltaY: 200, fingers: 5)?.gesture, .fiveFingerSwipeUp)
        XCTAssertEqual(decide(deltaX: 0, deltaY: -200, fingers: 5)?.gesture, .fiveFingerSwipeDown)
        XCTAssertEqual(decide(deltaX: 200, deltaY: 0, fingers: 5)?.gesture, .fiveFingerSwipeLeft)
        XCTAssertEqual(decide(deltaX: -200, deltaY: 0, fingers: 5)?.gesture, .fiveFingerSwipeRight)
    }

    /// The recognizer must admit five fingers at all; it previously capped at
    /// four, which is why the resolver's answer was never reached.
    func testFiveFingerContactsReachTheSwipeRecognizer() {
        var recognizer = ContactSwipeRecognizer()
        let start = (0..<5).map { TouchPoint(id: $0, x: 0.2 + Float($0) * 0.12, y: 0.5, size: 0.4) }
        XCTAssertNil(recognizer.update(start, peak: 5, timestamp: 1,
                                       enabled: [.fiveFingerSwipeUp], minVelocity: { _ in 200 }))
        let moved = (0..<5).map { TouchPoint(id: $0, x: 0.2 + Float($0) * 0.12, y: 0.9, size: 0.4) }
        XCTAssertEqual(recognizer.update(moved, peak: 5, timestamp: 1.15,
                                         enabled: [.fiveFingerSwipeUp], minVelocity: { _ in 200 }),
                       .fiveFingerSwipeUp)
    }

    func testSwipeRejectsZeroDurationOnlyWhenVelocityCannotBeMet() {
        // A zero duration must not divide by zero; with no movement there is
        // nothing to fire regardless.
        XCTAssertNil(decide(deltaX: 0, deltaY: 0, duration: 0))
    }

    // MARK: - TipTap (contact-based)
    //
    // TipTap is "one finger rests, another taps" and must not require the
    // trackpad to be physically clicked. These drive handleMultitouchFrame with
    // a real touch buffer, because the rest position comes from touch
    // coordinates and is not reachable with a nil buffer.

    /// Builds a raw touch buffer in the layout the monitor reads:
    /// fingerID at +24, normalized x at +32, y at +36, majorAxis at +52,
    /// with `stride` bytes between entries. The monitor auto-detects stride
    /// from the frame field, so all entries carry the same frame.
    private func makeTouchBuffer(_ points: [(x: Float, y: Float)], frame: Int32 = 1) -> UnsafeMutableRawPointer {
        let stride = 96
        let raw = UnsafeMutableRawPointer.allocate(byteCount: stride * max(points.count, 1), alignment: 8)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: stride * max(points.count, 1))
        for (i, p) in points.enumerated() {
            let base = i * stride
            raw.storeBytes(of: frame, toByteOffset: base, as: Int32.self)
            raw.storeBytes(of: Int32(i + 1), toByteOffset: base + 16, as: Int32.self)
            raw.storeBytes(of: Int32(4), toByteOffset: base + 20, as: Int32.self)
            raw.storeBytes(of: Int32(i), toByteOffset: base + 24, as: Int32.self)
            raw.storeBytes(of: p.x, toByteOffset: base + 32, as: Float.self)
            raw.storeBytes(of: p.y, toByteOffset: base + 36, as: Float.self)
            raw.storeBytes(of: Float(0.1), toByteOffset: base + 60, as: Float.self)
        }
        return raw
    }

    private func tiptapMonitor() -> (TrackpadMonitor, () -> TriggerAction?) {
        var fired: TriggerAction?
        ActionExecutor.onActionExecuted = { fired = $0 }
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        var left = Trigger(name: "TipTap L", input: .trackpadGesture(.tipTapLeft))
        left.actions = [TriggerAction(actionType: .volumeDown)]
        var right = Trigger(name: "TipTap R", input: .trackpadGesture(.tipTapRight))
        right.actions = [TriggerAction(actionType: .volumeUp)]
        monitor.registerTriggers([left, right])
        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
        // Keep the rest requirement small so the test is not timing-sensitive.
        UserDefaults.standard.set(0.05, forKey: "AOMTipTapMinRestTime")
        return (monitor, { fired })
    }

    /// Rest on the right, tap with the left → TipTap Left.
    func testTipTapLeftFiresFromRestAndTapWithoutAClick() {
        let (monitor, fired) = tiptapMonitor()
        defer {
            monitor.unregisterAll()
            ActionExecutor.onActionExecuted = nil
            UserDefaults.standard.removeObject(forKey: "AOMTipTapMinRestTime")
        }

        let expectation = expectation(description: "TipTap Left fires")

        // 1 finger resting on the right half, held long enough to count as a rest.
        let one = makeTouchBuffer([(x: 0.7, y: 0.5)])
        monitor.handleMultitouchFrame(rawTouches: one, numTouches: 1, timestamp: 0)
        Thread.sleep(forTimeInterval: 0.12)

        // Second finger lands on the left half.
        let two = makeTouchBuffer([(x: 0.7, y: 0.5), (x: 0.3, y: 0.5)])
        monitor.handleMultitouchFrame(rawTouches: two, numTouches: 2, timestamp: 0.12)
        Thread.sleep(forTimeInterval: 0.05)

        // Tapper lifts, rester stays → 2→1.
        monitor.handleMultitouchFrame(rawTouches: one, numTouches: 1, timestamp: 0.17)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if fired() != nil { expectation.fulfill() }
        }
        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(fired()?.actionType, .volumeDown, "left tap should map to the TipTap Left trigger")

        one.deallocate()
        two.deallocate()
    }

    /// A long rest followed by a slow tap must NOT arm — the tap itself is brief.
    func testTipTapDoesNotFireWhenTheSecondFingerStaysDown() {
        let (monitor, fired) = tiptapMonitor()
        defer {
            monitor.unregisterAll()
            ActionExecutor.onActionExecuted = nil
            UserDefaults.standard.removeObject(forKey: "AOMTipTapMinRestTime")
        }

        let one = makeTouchBuffer([(x: 0.7, y: 0.5)])
        let two = makeTouchBuffer([(x: 0.7, y: 0.5), (x: 0.3, y: 0.5)])
        monitor.handleMultitouchFrame(rawTouches: one, numTouches: 1, timestamp: 0)
        Thread.sleep(forTimeInterval: 0.12)
        monitor.handleMultitouchFrame(rawTouches: two, numTouches: 2, timestamp: 0.12)
        // Hold both fingers well past the tap window, then lift the tapper.
        Thread.sleep(forTimeInterval: 0.6)
        monitor.handleMultitouchFrame(rawTouches: one, numTouches: 1, timestamp: 0.72)

        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        waitForExpectations(timeout: 2.0)
        XCTAssertNil(fired(), "a held second finger is not a tap")

        one.deallocate()
        two.deallocate()
    }

    /// Resting for less than the minimum rest time is not a TipTap.
    func testTipTapDoesNotFireWithoutARest() {
        let (monitor, fired) = tiptapMonitor()
        defer {
            monitor.unregisterAll()
            ActionExecutor.onActionExecuted = nil
            UserDefaults.standard.removeObject(forKey: "AOMTipTapMinRestTime")
        }

        let one = makeTouchBuffer([(x: 0.7, y: 0.5)])
        let two = makeTouchBuffer([(x: 0.7, y: 0.5), (x: 0.3, y: 0.5)])
        // Both fingers arrive almost together — no rest phase.
        monitor.handleMultitouchFrame(rawTouches: one, numTouches: 1, timestamp: 0)
        monitor.handleMultitouchFrame(rawTouches: two, numTouches: 2, timestamp: 0.001)
        Thread.sleep(forTimeInterval: 0.05)
        monitor.handleMultitouchFrame(rawTouches: one, numTouches: 1, timestamp: 0.051)

        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        waitForExpectations(timeout: 2.0)
        XCTAssertNil(fired(), "no rest phase means no TipTap")

        one.deallocate()
        two.deallocate()
    }

    // MARK: - Multi-finger tap timing
    //
    // Laying four fingers down is not instantaneous. Timing the tap from the
    // first finger's landing made a staggered but ordinary four-finger tap
    // exceed the window, so the hold is now measured from when the full count
    // was reached.

    func testFourFingerTapToleratesStaggeredLanding() {
        let expectation = expectation(description: "4-finger tap fires despite stagger")

        var trigger = Trigger(name: "4 Tap", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [TriggerAction(actionType: .volumeUp)]
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        monitor.registerTriggers([trigger])
        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
        ActionExecutor.onActionExecuted = { _ in expectation.fulfill() }

        // Fingers land one at a time over ~0.3s, then lift together.
        let buffers = (1...4).map { n in makeTouchBuffer(Array(repeating: (x: 0.5, y: 0.5), count: n)) }
        for (i, buf) in buffers.enumerated() {
            monitor.handleMultitouchFrame(rawTouches: buf, numTouches: i + 1, timestamp: Double(i) * 0.1)
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.1)
        monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: 0.5)

        waitForExpectations(timeout: 2.0)
        monitor.unregisterAll()
        ActionExecutor.onActionExecuted = nil
        buffers.forEach { $0.deallocate() }
    }

    // MARK: - Corner click zoning

    func testCornerZonesCoverTheTrackpadTips() {
        // The zones the fire path and the suppression path share must agree.
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        // Top-left tip, well inside the widened zone.
        XCTAssertEqual(monitor.positionClickGestureForTest(x: 0.05, y: 0.95), .cornerClickTopLeft)
        // Top-right tip.
        XCTAssertEqual(monitor.positionClickGestureForTest(x: 0.95, y: 0.95), .cornerClickTopRight)
        // Dead centre is not a corner and not a middle strip.
        XCTAssertNil(monitor.positionClickGestureForTest(x: 0.5, y: 0.5))
        // A point just outside the widened corner zone is not a corner.
        XCTAssertNil(monitor.positionClickGestureForTest(x: 0.25, y: 0.75))
    }

    // MARK: - Unbound gesture detection is skipped
    //
    // The drawing detectors used to run (and false-fire) even when nothing was
    // bound to them. With no circle/triangle/edge trigger registered they must
    // not detect at all — that load was destabilising the other gestures.

    func testCircleIsNotDetectedWhenNoCircleTriggerIsRegistered() {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        // Only an unrelated trigger — no circle.
        var tap = Trigger(name: "4 Tap", input: .trackpadGesture(.fourFingerTap))
        tap.actions = [TriggerAction(actionType: .volumeUp)]
        monitor.registerTriggers([tap])

        XCTAssertFalse(monitor.hasCircleTriggerForTest, "no circle trigger should be reported")
        XCTAssertFalse(monitor.hasTriangleTriggerForTest)
        XCTAssertFalse(monitor.hasEdgeSlideTriggerForTest)

        // Feed a path that would otherwise read as a circle; nothing must fire.
        let buf = makeTouchBuffer(Array(repeating: (x: 0.5, y: 0.5), count: 1))
        var fired = false
        ActionExecutor.onActionExecuted = { _ in fired = true }
        for i in 0..<60 {
            let angle = Float(i) * 0.4
            let p = (x: 0.5 + 0.05 * cos(angle), y: 0.5 + 0.05 * sin(angle))
            let b = makeTouchBuffer([p])
            monitor.handleMultitouchFrame(rawTouches: b, numTouches: 1, timestamp: Double(i) * 0.016)
            b.deallocate()
        }
        XCTAssertFalse(fired, "a circle path must not fire when no circle trigger exists")

        monitor.unregisterAll()
        ActionExecutor.onActionExecuted = nil
        buf.deallocate()
    }

    func testCircleTriggerIsReportedWhenRegistered() {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        var c = Trigger(name: "Circle", input: .trackpadGesture(.circleClockwise))
        c.actions = [TriggerAction(actionType: .volumeUp)]
        monitor.registerTriggers([c])

        XCTAssertTrue(monitor.hasCircleTriggerForTest)
        XCTAssertFalse(monitor.hasTriangleTriggerForTest)
        monitor.unregisterAll()
    }
}

/// No hardware registration, real input injection, or timing sleeps are needed
/// to reproduce recognizer transitions. Timestamps come from the input frames.
final class TrackpadRegressionTests: XCTestCase {
    private var monitor: TrackpadMonitor!
    private var fired: [ActionType] = []
    private var savedEnabled: Any?
    private var savedRest: Any?
    private var savedSuppression: Any?

    override func setUp() {
        super.setUp()
        savedSuppression = UserDefaults.standard.object(forKey: "AOMSuppressMouseDuringDrawing")
        UserDefaults.standard.set(true, forKey: "AOMSuppressMouseDuringDrawing")
        savedEnabled = UserDefaults.standard.object(forKey: "AOMGlobalEnabled")
        savedRest = UserDefaults.standard.object(forKey: "AOMTipTapMinRestTime")
        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
        UserDefaults.standard.set(0.12, forKey: "AOMTipTapMinRestTime")
        monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "test.front" })
        ActionExecutor.onActionExecuted = { [weak self] in self?.fired.append($0.actionType) }
    }

    override func tearDown() {
        monitor.unregisterAll()
        monitor = nil
        ActionExecutor.onActionExecuted = nil
        UserDefaults.standard.set(savedSuppression, forKey: "AOMSuppressMouseDuringDrawing")
        UserDefaults.standard.set(savedEnabled, forKey: "AOMGlobalEnabled")
        UserDefaults.standard.set(savedRest, forKey: "AOMTipTapMinRestTime")
        super.tearDown()
    }

    private func trigger(_ gesture: TrackpadGesture, action: ActionType = .volumeUp,
                         app: String? = nil, suppress: Bool = false) -> Trigger {
        var trigger = Trigger(name: "Regression", input: .trackpadGesture(gesture), appBundleID: app)
        trigger.actions = [TriggerAction(actionType: action)]
        trigger.suppressClick = suppress
        return trigger
    }

    private func frame(_ points: [(Int, Float, Float)], at timestamp: Double, pressed: Int = 0) {
        monitor.processTouchFrame(points.map { TouchPoint(id: $0.0, x: $0.1, y: $0.2, size: 0.1) },
                                  count: points.count, timestamp: timestamp, pressedButtons: pressed)
    }

    private func drain(after delay: TimeInterval = 0) {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testMovementRejectsTapEvenWithoutScrollEventsAndResetsForNextTap() {
        monitor.registerTriggers([trigger(.threeFingerTap)])
        frame([(1, 0.2, 0.5), (2, 0.4, 0.5), (3, 0.6, 0.5)], at: 1)
        frame([(1, 0.4, 0.5), (2, 0.6, 0.5), (3, 0.8, 0.5)], at: 1.1)
        frame([], at: 1.2)
        drain()
        XCTAssertTrue(fired.isEmpty)
        frame([(1, 0.2, 0.5), (2, 0.4, 0.5), (3, 0.6, 0.5)], at: 2)
        frame([], at: 2.1)
        drain()
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testTwoQuickSingleTapsAreNotLostWhenDoubleTapIsUnbound() {
        monitor.registerTriggers([trigger(.twoFingerTap)])
        for start in [1.0, 1.2] {
            frame([(1, 0.3, 0.5), (2, 0.6, 0.5)], at: start)
            frame([], at: start + 0.05)
            drain()
        }
        XCTAssertEqual(fired, [.volumeUp, .volumeUp])
    }

    func testBoundDoubleTapCancelsSingleTap() {
        monitor.registerTriggers([trigger(.twoFingerTap), trigger(.twoFingerDoubleTap, action: .volumeDown)])
        for start in [1.0, 1.2] {
            frame([(1, 0.3, 0.5), (2, 0.6, 0.5)], at: start)
            frame([], at: start + 0.05)
        }
        drain(after: 0.5)
        XCTAssertEqual(fired, [.volumeDown])
    }

    private func threeTap(at start: Double, device: UInt64 = 0) {
        let points = (0..<3).map { TouchPoint(id: $0, x: 0.2 + Float($0) * 0.2, y: 0.5, size: 0.4) }
        monitor.processTouchFrame(points, count: 3, timestamp: start, pressedButtons: 0, deviceID: device)
        monitor.processTouchFrame([], count: 0, timestamp: start + 0.05, pressedButtons: 0, deviceID: device)
    }

    func testThreeFingerDoubleTapFiresOnceWithoutSingle() {
        monitor.registerTriggers([trigger(.threeFingerTap), trigger(.threeFingerDoubleTap, action: .volumeDown)])
        threeTap(at: 1); threeTap(at: 1.2)
        drain(after: 0.45)
        XCTAssertEqual(fired, [.volumeDown])
    }

    func testThreeFingerSingleFallsBackWhenSecondTapNeverArrives() {
        monitor.registerTriggers([trigger(.threeFingerTap), trigger(.threeFingerDoubleTap, action: .volumeDown)])
        threeTap(at: 1); drain()
        XCTAssertTrue(fired.isEmpty)
        drain(after: 0.45)
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testThreeFingerSinglesRemainImmediateWhenDoubleUnbound() {
        monitor.registerTriggers([trigger(.threeFingerTap)])
        threeTap(at: 1); drain()
        XCTAssertEqual(fired, [.volumeUp])
        threeTap(at: 1.2); drain()
        XCTAssertEqual(fired, [.volumeUp, .volumeUp])
    }

    func testTwoAndThreeFingerTapsCannotCombineIntoDoubleTap() {
        monitor.registerTriggers([trigger(.twoFingerTap), trigger(.threeFingerTap),
            trigger(.twoFingerDoubleTap, action: .volumeDown), trigger(.threeFingerDoubleTap, action: .volumeDown)])
        frame([(1, 0.3, 0.5), (2, 0.6, 0.5)], at: 1); frame([], at: 1.05)
        threeTap(at: 1.2); drain(after: 0.45)
        XCTAssertEqual(fired, [.volumeUp, .volumeUp])
    }

    func testThreeFingerDoubleTapDoesNotCombineDevices() {
        monitor.registerTriggers([trigger(.threeFingerTap), trigger(.threeFingerDoubleTap, action: .volumeDown)])
        threeTap(at: 1, device: 1); threeTap(at: 1.2, device: 2)
        drain(after: 0.45)
        XCTAssertEqual(fired, [.volumeUp, .volumeUp])
    }

    func testThreeFingerPendingTapCancelledByReregistration() {
        let bindings = [trigger(.threeFingerTap), trigger(.threeFingerDoubleTap, action: .volumeDown)]
        monitor.registerTriggers(bindings); threeTap(at: 1)
        monitor.registerTriggers(bindings); drain(after: 0.45)
        XCTAssertTrue(fired.isEmpty)
    }

    func testThreeFingerDoubleTapDoesNotCrossApplicationContext() {
        monitor.unregisterAll()
        var front = "app.a"
        monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { front })
        monitor.registerTriggers([trigger(.threeFingerTap), trigger(.threeFingerDoubleTap, action: .volumeDown)])
        threeTap(at: 1); front = "app.b"; threeTap(at: 1.2)
        drain(after: 0.45)
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testThreeFingerDoubleTapSurvivesPresetSerialization() throws {
        let original = trigger(.threeFingerDoubleTap)
        let restored = try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(original))
        guard case .trackpadGesture(let gesture) = restored.input else { return XCTFail("Wrong trigger category") }
        XCTAssertEqual(gesture, .threeFingerDoubleTap)
    }

    func testReregisterCancelsPendingSingleTapAndQueuedGesture() {
        let bindings = [trigger(.twoFingerTap), trigger(.twoFingerDoubleTap), trigger(.threeFingerTap)]
        monitor.registerTriggers(bindings)
        frame([(1, 0.3, 0.5), (2, 0.6, 0.5)], at: 1)
        frame([], at: 1.05)
        frame([(1, 0.2, 0.5), (2, 0.4, 0.5), (3, 0.6, 0.5)], at: 2)
        frame([], at: 2.05)
        monitor.registerTriggers(bindings)
        drain(after: 0.5)
        XCTAssertTrue(fired.isEmpty)
    }

    func testTipTapSuppressedReleaseCannotFireLaterFromRestOnlyFrames() {
        monitor.registerTriggers([trigger(.tipTapLeft)])
        frame([(10, 0.7, 0.5)], at: 1)
        frame([(10, 0.7, 0.5), (20, 0.3, 0.5)], at: 1.2)
        frame([(10, 0.7, 0.5)], at: 1.25)
        drain()
        frame([(10, 0.7, 0.5), (21, 0.3, 0.5)], at: 1.4)
        frame([(10, 0.7, 0.5)], at: 1.45)
        frame([(10, 0.7, 0.5)], at: 1.52)
        drain()
        XCTAssertEqual(fired, [.volumeUp], "A released contact rejected by the cooldown must not become a delayed second action")
    }

    func testTipTapRepeatedFramesAndContactBounceFireOnce() {
        monitor.registerTriggers([trigger(.tipTapLeft)])
        frame([(10, 0.7, 0.5)], at: 1)
        frame([(10, 0.7, 0.5), (20, 0.3, 0.5)], at: 1.2)
        frame([(10, 0.7, 0.5)], at: 1.25)
        for time in [1.25, 1.26, 1.27] { frame([(10, 0.7, 0.5)], at: time) }
        frame([(10, 0.7, 0.5), (20, 0.3, 0.5)], at: 1.28)
        frame([(10, 0.7, 0.5)], at: 1.30)
        drain()
        XCTAssertEqual(fired, [.volumeUp])
        // A subsequent deliberate tap still works while the anchor stays down.
        frame([(10, 0.7, 0.5), (21, 0.3, 0.5)], at: 1.7)
        frame([(10, 0.7, 0.5)], at: 1.75)
        drain()
        XCTAssertEqual(fired, [.volumeUp, .volumeUp])
    }

    func testTipTapRejectsReplacementOfRestingFinger() {
        monitor.registerTriggers([trigger(.tipTapLeft), trigger(.tipTapRight)])
        frame([(10, 0.7, 0.5)], at: 1)
        frame([(10, 0.7, 0.5), (20, 0.3, 0.5)], at: 1.2)
        frame([(20, 0.3, 0.5)], at: 1.25)
        drain()
        XCTAssertTrue(fired.isEmpty)
    }

    func testTipTapUsesRelativeFingerPositionOnSameHalf() {
        monitor.registerTriggers([trigger(.tipTapLeft, action: .volumeDown), trigger(.tipTapRight)])
        frame([(10, 0.2, 0.5)], at: 1)
        frame([(20, 0.1, 0.5), (10, 0.2, 0.5)], at: 1.2)
        frame([(10, 0.2, 0.5)], at: 1.25)
        drain()
        XCTAssertEqual(fired, [.volumeDown])
    }

    func testSuppressionRespectsNonSuppressingAppOverride() {
        monitor.registerTriggers([trigger(.cornerClickTopLeft, suppress: true),
            trigger(.cornerClickTopLeft, app: "test.front", suppress: false)])
        frame([(1, 0.05, 0.95)], at: 1)
        XCTAssertNil(monitor.clickGestureToSuppress())
    }

    func testSuppressionUsesAppOverrideAndFallsBackToGlobal() {
        monitor.registerTriggers([trigger(.cornerClickTopLeft),
            trigger(.cornerClickTopLeft, app: "test.front", suppress: true)])
        frame([(1, 0.05, 0.95)], at: 1)
        XCTAssertEqual(monitor.clickGestureToSuppress(), .cornerClickTopLeft)
        monitor.registerTriggers([trigger(.cornerClickTopLeft, suppress: true),
            trigger(.cornerClickTopLeft, app: "test.other", suppress: false)])
        frame([(1, 0.05, 0.95)], at: 2)
        XCTAssertEqual(monitor.clickGestureToSuppress(), .cornerClickTopLeft)
    }

    func testUnsuppressedMultiFingerClickFiresOnceAndDoesNotAlsoTap() {
        monitor.registerTriggers([trigger(.twoFingerClick), trigger(.twoFingerTap, action: .volumeDown)])
        frame([(1, 0.3, 0.5), (2, 0.6, 0.5)], at: 1)
        monitor.handleMousePress()
        monitor.handleMouseRelease()
        frame([], at: 1.1)
        drain()
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testMouseReleaseCancelsDelayedCornerClick() {
        monitor.registerTriggers([trigger(.cornerClickTopLeft)])
        monitor.handleMousePress()
        monitor.handleMouseRelease()
        frame([(1, 0.05, 0.95)], at: 1)
        drain(after: 0.1)
        XCTAssertTrue(fired.isEmpty)
    }

    func testCancelledSwipeDoesNotFireAndNextSwipeStartsClean() {
        monitor.registerTriggers([trigger(.twoFingerSwipeLeft)])
        monitor.processScroll(deltaX: 1000, deltaY: 0, phase: .began, timestamp: 1)
        monitor.processScroll(deltaX: 0, deltaY: 0, phase: .cancelled, timestamp: 1.1)
        XCTAssertTrue(fired.isEmpty)
        monitor.processScroll(deltaX: 1, deltaY: 0, phase: .began, timestamp: 2)
        monitor.processScroll(deltaX: 0, deltaY: 0, phase: .ended, timestamp: 2.1)
        XCTAssertTrue(fired.isEmpty)
        monitor.processScroll(deltaX: 1000, deltaY: 0, phase: .began, timestamp: 3)
        monitor.processScroll(deltaX: 0, deltaY: 0, phase: .ended, timestamp: 3.1)
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testMomentumDoesNotContaminateNextSwipe() {
        monitor.registerTriggers([trigger(.twoFingerSwipeLeft)])
        monitor.processScroll(deltaX: 1000, deltaY: 0, phase: [], momentumPhase: .changed, timestamp: 1)
        monitor.processScroll(deltaX: 1, deltaY: 0, phase: .changed, timestamp: 1.1)
        monitor.processScroll(deltaX: 0, deltaY: 0, phase: .ended, timestamp: 1.2)
        XCTAssertTrue(fired.isEmpty)
    }

    func testCancelledPinchAndRotationDoNotFire() {
        monitor.registerTriggers([trigger(.twoFingerPinchOut), trigger(.twoFingerRotateRight)])
        monitor.processMagnify(delta: 0.5, phase: .began)
        monitor.processMagnify(delta: 0, phase: .cancelled)
        monitor.processRotate(delta: 20, phase: .began)
        monitor.processRotate(delta: 0, phase: .cancelled)
        XCTAssertTrue(fired.isEmpty)
        monitor.processMagnify(delta: 0, phase: .ended)
        monitor.processRotate(delta: 0, phase: .ended)
        XCTAssertTrue(fired.isEmpty)
        monitor.processMagnify(delta: 0.5, phase: .began)
        monitor.processMagnify(delta: 0, phase: .ended)
        monitor.processRotate(delta: 20, phase: .began)
        monitor.processRotate(delta: 0, phase: .ended)
        XCTAssertEqual(fired, [.volumeUp, .volumeUp])
    }

    func testDrawingDoesNotSuppressInWrongAppOrDirectionOrWhilePaused() {
        monitor.registerTriggers([trigger(.leftEdgeSlideUp, app: "test.other")])
        frame([(1, 0.05, 0.3)], at: 1, pressed: 1)
        frame([(1, 0.05, 0.4)], at: 1.1, pressed: 1)
        XCTAssertFalse(monitor.isSuppressingMouseForTest)
        monitor.registerTriggers([trigger(.leftEdgeSlideDown)])
        frame([(1, 0.05, 0.3)], at: 2, pressed: 1)
        frame([(1, 0.05, 0.4)], at: 2.1, pressed: 1)
        XCTAssertFalse(monitor.isSuppressingMouseForTest)
        UserDefaults.standard.set(false, forKey: "AOMGlobalEnabled")
        frame([(1, 0.05, 0.2)], at: 2.2, pressed: 1)
        XCTAssertFalse(monitor.isSuppressingMouseForTest)
    }

    func testLeavingEdgeOrUnregisteringReleasesPointerSuppression() {
        monitor.registerTriggers([trigger(.leftEdgeSlideUp)])
        frame([(1, 0.05, 0.3)], at: 1, pressed: 1)
        frame([(1, 0.05, 0.4)], at: 1.1, pressed: 1)
        XCTAssertTrue(monitor.isSuppressingMouseForTest)
        frame([(1, 0.5, 0.4)], at: 1.2, pressed: 1)
        XCTAssertFalse(monitor.isSuppressingMouseForTest)
        frame([(1, 0.05, 0.3)], at: 1.3, pressed: 1)
        frame([(1, 0.05, 0.4)], at: 1.4, pressed: 1)
        XCTAssertTrue(monitor.isSuppressingMouseForTest)
        monitor.unregisterAll()
        XCTAssertFalse(monitor.isSuppressingMouseForTest)
    }
    func testUnboundDirectionReleasesExistingEdgeSuppression() {
        monitor.registerTriggers([trigger(.leftEdgeSlideUp)])
        frame([(1, 0.05, 0.3)], at: 1, pressed: 1)
        frame([(1, 0.05, 0.4)], at: 1.1, pressed: 1)
        XCTAssertTrue(monitor.isSuppressingMouseForTest)
        frame([(1, 0.05, 0.3)], at: 1.2, pressed: 1)
        XCTAssertFalse(monitor.isSuppressingMouseForTest)
    }

    func testBackgroundFramesCopyBufferAndDiscardOldRegistration() {
        let bindings = [trigger(.threeFingerTap)]
        monitor.registerTriggers(bindings)
        let monitor = self.monitor!
        let sendFrames = {
            // Copying must finish before this callback-owned buffer is freed.
            let raw = UnsafeMutableRawPointer.allocate(byteCount: 3 * 96, alignment: 8)
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: 3 * 96)
            for i in 0..<3 {
                raw.storeBytes(of: Int32(1), toByteOffset: i * 96, as: Int32.self)
                raw.storeBytes(of: Int32(i + 1), toByteOffset: i * 96 + 16, as: Int32.self)
                raw.storeBytes(of: Int32(i), toByteOffset: i * 96 + 16, as: Int32.self)
                raw.storeBytes(of: Int32(4), toByteOffset: i * 96 + 20, as: Int32.self)
                raw.storeBytes(of: Float(0.2 + Double(i) * 0.2), toByteOffset: i * 96 + 32, as: Float.self)
                raw.storeBytes(of: Float(0.5), toByteOffset: i * 96 + 36, as: Float.self)
            }
            monitor.handleMultitouchFrame(rawTouches: raw, numTouches: 3, timestamp: 1)
            raw.deallocate()
            monitor.handleMultitouchFrame(rawTouches: nil, numTouches: 0, timestamp: 1.1)
        }
        let queue = DispatchQueue(label: "regression.multitouch")
        let delivered = DispatchGroup()
        func deliverOnBackgroundThread() {
            delivered.enter()
            queue.async { sendFrames(); delivered.leave() }
            XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        }
        deliverOnBackgroundThread()
        drain()
        drain()
        XCTAssertEqual(fired, [.volumeUp])
        fired.removeAll()
        deliverOnBackgroundThread()
        monitor.registerTriggers(bindings)
        drain()
        drain()
        XCTAssertTrue(fired.isEmpty)
    }

    func testSyntheticActionClickCannotReenterGesturePipeline() throws {
        monitor.registerTriggers([trigger(.twoFingerClick)])
        frame([(1, 0.3, 0.5), (2, 0.6, 0.5)], at: 1)
        let cgEvent = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                           mouseCursorPosition: .zero, mouseButton: .left))
        cgEvent.setIntegerValueField(.eventSourceUserData, value: 0x475454)
        monitor.handleMousePress(try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
        drain()
        XCTAssertTrue(fired.isEmpty)
        let physicalEvent = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                                 mouseCursorPosition: .zero, mouseButton: .left))
        physicalEvent.setIntegerValueField(.eventSourceUserData, value: 0)
        monitor.handleMousePress(try XCTUnwrap(NSEvent(cgEvent: physicalEvent)))
        drain()
        XCTAssertEqual(fired, [.volumeUp])
    }

    private func fourPoints(y: Float, dx: Float = 0) -> [(Int, Float, Float)] {
        [(1, 0.2 + dx, y), (2, 0.4 + dx, y), (3, 0.6 + dx, y), (4, 0.8 + dx, y)]
    }

    func testFourFingerDownSwipeNeedsNoScrollEventAndNeverAlsoTaps() {
        monitor.registerTriggers([trigger(.fourFingerSwipeDown), trigger(.fourFingerTap, action: .volumeDown)])
        frame(fourPoints(y: 0.7), at: 1)
        frame(fourPoints(y: 0.66), at: 1.04)
        frame(fourPoints(y: 0.58), at: 1.12)
        frame(fourPoints(y: 0.4), at: 1.2)
        frame([], at: 1.25)
        drain()
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testFourFingerTapToleratesStaggeredLandingLiftAndJitter() {
        monitor.registerTriggers([trigger(.fourFingerSwipeDown), trigger(.fourFingerTap, action: .volumeDown)])
        frame(Array(fourPoints(y: 0.7).prefix(1)), at: 1)
        frame(Array(fourPoints(y: 0.7).prefix(2)), at: 1.1)
        frame(Array(fourPoints(y: 0.7).prefix(3)), at: 1.2)
        frame(fourPoints(y: 0.7), at: 1.3)
        frame(fourPoints(y: 0.69), at: 1.35)
        frame(Array(fourPoints(y: 0.69).prefix(3)), at: 1.4)
        frame(Array(fourPoints(y: 0.69).prefix(1)), at: 1.45)
        frame([], at: 1.5)
        drain()
        XCTAssertEqual(fired, [.volumeDown])
    }

    func testPointerMovementBeforeFourthFingerDoesNotInvalidateFourFingerTap() {
        monitor.registerTriggers([trigger(.fourFingerTap)])
        frame([(1, 0.2, 0.2)], at: 1)
        frame([(1, 0.2, 0.7)], at: 2)
        frame(fourPoints(y: 0.7), at: 2.1)
        frame([], at: 2.2)
        drain()
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testFourFingerHoldDoesNotTapButCanStartASwipeLater() {
        monitor.registerTriggers([trigger(.fourFingerSwipeDown), trigger(.fourFingerTap, action: .volumeDown)])
        frame(fourPoints(y: 0.7), at: 1)
        frame(fourPoints(y: 0.7), at: 3)
        frame(fourPoints(y: 0.58), at: 3.1)
        frame([], at: 3.2)
        drain()
        XCTAssertEqual(fired, [.volumeUp])
        frame(fourPoints(y: 0.7), at: 4)
        frame([], at: 5)
        drain()
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testFourFingerSwipeKeepsIdentityWhenOneFingerLifts() {
        monitor.registerTriggers([trigger(.fourFingerSwipeDown), trigger(.fourFingerTap, action: .volumeDown)])
        frame(fourPoints(y: 0.7), at: 1)
        frame(fourPoints(y: 0.67), at: 1.04)
        frame(Array(fourPoints(y: 0.58).suffix(3)), at: 1.12)
        frame([], at: 1.2)
        drain()
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testLiftingFingerDoesNotInventFourFingerSwipe() {
        monitor.registerTriggers([trigger(.fourFingerSwipeLeft), trigger(.fourFingerSwipeDown)])
        frame([(1, 0.1, 0.4), (2, 0.3, 0.5), (3, 0.5, 0.6), (4, 0.9, 0.9)], at: 1)
        frame([(1, 0.1, 0.4), (2, 0.3, 0.5), (3, 0.5, 0.6)], at: 1.05)
        frame([], at: 1.1)
        drain()
        XCTAssertTrue(fired.isEmpty)
    }

    func testFourFingerRawAndScrollCannotDoubleFireOrBecomeTwoFingerSwipe() {
        monitor.registerTriggers([trigger(.fourFingerSwipeDown), trigger(.twoFingerSwipeDown, action: .volumeDown)])
        frame(Array(fourPoints(y: 0.7).prefix(2)), at: 1)
        monitor.processScroll(deltaX: 0, deltaY: -100, phase: .began, timestamp: 1)
        frame(fourPoints(y: 0.7), at: 1.02)
        frame(fourPoints(y: 0.58), at: 1.12)
        frame([], at: 1.15)
        monitor.processScroll(deltaX: 0, deltaY: -100, phase: .ended, timestamp: 1.2)
        drain()
        XCTAssertEqual(fired, [.volumeUp])
    }

    func testFourFingerSwipeRejectsSlowTravelAndIncoherentMotion() {
        monitor.registerTriggers([trigger(.fourFingerSwipeDown), trigger(.fourFingerTap, action: .volumeDown)])
        frame(fourPoints(y: 0.7), at: 1)
        frame(fourPoints(y: 0.68), at: 1.2)
        frame(fourPoints(y: 0.58), at: 2)
        frame([], at: 2.1)
        frame(fourPoints(y: 0.7), at: 3)
        frame([(1, 0.2, 0.3), (2, 0.4, 0.7), (3, 0.6, 0.7), (4, 0.8, 0.7)], at: 3.1)
        frame([], at: 3.2)
        drain()
        XCTAssertTrue(fired.isEmpty)
    }

    func testFourFingerDirectionsUsePhysicalCoordinates() {
        monitor.registerTriggers([trigger(.fourFingerSwipeUp, action: .volumeDown),
                                  trigger(.fourFingerSwipeRight), trigger(.fourFingerSwipeLeft, action: .muteVolume)])
        frame(fourPoints(y: 0.5), at: 1)
        frame(fourPoints(y: 0.62), at: 1.1)
        frame([], at: 1.2)
        frame(fourPoints(y: 0.5), at: 2)
        frame(fourPoints(y: 0.5, dx: 0.12), at: 2.1)
        frame([], at: 2.2)
        frame(fourPoints(y: 0.5), at: 3)
        frame(fourPoints(y: 0.5, dx: -0.12), at: 3.1)
        frame([], at: 3.2)
        drain()
        XCTAssertEqual(fired, [.volumeDown, .volumeUp, .muteVolume])
    }

}
