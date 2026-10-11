import XCTest
@testable import AllOfMacOS

final class TouchEngineTests: XCTestCase {
    private func point(_ id: Int, _ x: Float = 0.5, _ y: Float = 0.5) -> TouchPoint {
        TouchPoint(id: id, x: x, y: y, size: 0.4)
    }
    private func decode(_ data: Data, count: Int) -> TouchFrameDecoder.Frame? {
        data.withUnsafeBytes { TouchFrameDecoder.decode($0, count: count) }
    }
    func testExactHardwareLayoutAndLiftedContacts() throws {
        let points = (0..<4).map { point($0, 0.2 + Float($0) * 0.15) }
        let active = try XCTUnwrap(decode(GestureReplaySuite.rawFrame(points), count: 4))
        XCTAssertEqual(active.contacts.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(active.contacts[0].size, 0.4, accuracy: 0.001)
        for state: Int32 in [0, 1, 2, 5, 6, 7] {
            let frame = try XCTUnwrap(decode(GestureReplaySuite.rawFrame(points, state: state), count: 4))
            XCTAssertEqual(frame.rawCount, 4)
            XCTAssertTrue(frame.contacts.isEmpty, "state \(state) is not contact")
        }
        XCTAssertEqual(decode(GestureReplaySuite.rawFrame(points, state: 3), count: 4)?.contacts.count, 4)
    }
    func testDecoderRejectsTruncationNonfiniteCoordinatesAndDuplicateIDs() {
        let data = GestureReplaySuite.rawFrame([point(1), point(2)])
        XCTAssertNil(decode(Data(data.dropLast()), count: 2))
        XCTAssertNil(decode(data, count: -1))
        XCTAssertNil(decode(data, count: 33))
        XCTAssertNil(decode(GestureReplaySuite.rawFrame([point(1, .nan)]), count: 1))
        XCTAssertNil(decode(GestureReplaySuite.rawFrame([point(1), point(1)]), count: 2))
        XCTAssertNil(decode(GestureReplaySuite.rawFrame([point(1)], state: 99), count: 1))
    }
    func testFourFingerTapFinishesOnLiftStateWithoutEmptyHardwareFrame() throws {
        var engine = ContactGestureSession()
        let points = (0..<4).map { point($0, 0.2 + Float($0) * 0.15) }
        let active = try XCTUnwrap(decode(GestureReplaySuite.rawFrame(points), count: 4))
        let lifted = try XCTUnwrap(decode(GestureReplaySuite.rawFrame(points, state: 7), count: 4))
        XCTAssertTrue(engine.update(active.contacts, timestamp: 1, pressed: false, enabled: [.fourFingerTap], restTime: 0.12, minVelocity: { _ in 200 }).isEmpty)
        XCTAssertEqual(engine.update(lifted.contacts, timestamp: 1.1, pressed: false, enabled: [.fourFingerTap], restTime: 0.12, minVelocity: { _ in 200 }), [.fourFingerTap])
    }
    func testAllSupportedGesturesReplayExactlyOnce() {
        let result = GestureReplaySuite.run()
        XCTAssertEqual(result["count"] as? Int, TrackpadGesture.allCases.count)
        let failed = (result["cases"] as? [[String: Any]] ?? []).filter { $0["pass"] as? Bool != true }
        XCTAssertTrue(failed.isEmpty, "\(failed)")
    }
    func testTipTapMiddleRequiresTapBetweenRestingIdentities() {
        for x: Float in [0.1, 0.5, 0.9] {
            var engine = ContactGestureSession()
            let rest = [point(1, 0.3), point(2, 0.7)]
            _ = engine.update(rest, timestamp: 1, pressed: false, enabled: [.tipTapMiddle], restTime: 0.12, minVelocity: { _ in 200 })
            _ = engine.update(rest + [point(3, x)], timestamp: 1.2, pressed: false, enabled: [.tipTapMiddle], restTime: 0.12, minVelocity: { _ in 200 })
            let result = engine.update(rest, timestamp: 1.25, pressed: false, enabled: [.tipTapMiddle], restTime: 0.12, minVelocity: { _ in 200 })
            XCTAssertEqual(result, x == 0.5 ? [.tipTapMiddle] : [])
        }
    }
    func testOneWanderingFingerCannotTurnFourFingerTapIntoSwipe() {
        var engine = ContactGestureSession()
        let p = (0..<4).map { point($0, 0.2 + Float($0) * 0.15) }
        _ = engine.update(p, timestamp: 1, pressed: false, enabled: [.fourFingerTap, .fourFingerSwipeDown], restTime: 0.12, minVelocity: { _ in 200 })
        var moved = p; moved[0].y -= 0.4
        XCTAssertTrue(engine.update(moved, timestamp: 1.05, pressed: false, enabled: [.fourFingerTap, .fourFingerSwipeDown], restTime: 0.12, minVelocity: { _ in 200 }).isEmpty)
        XCTAssertTrue(engine.update([], timestamp: 1.1, pressed: false, enabled: [.fourFingerTap, .fourFingerSwipeDown], restTime: 0.12, minVelocity: { _ in 200 }).isEmpty)
    }
    func testOutOfOrderFrameCannotReopenEndedGesture() {
        var engine = ContactGestureSession()
        let p = [point(1, 0.3), point(2, 0.7)]
        _ = engine.update(p, timestamp: 2, pressed: false, enabled: [.twoFingerTap], restTime: 0.12, minVelocity: { _ in 200 })
        XCTAssertTrue(engine.update([], timestamp: 1, pressed: false, enabled: [.twoFingerTap], restTime: 0.12, minVelocity: { _ in 200 }).isEmpty)
        XCTAssertEqual(engine.update([], timestamp: 2.1, pressed: false, enabled: [.twoFingerTap], restTime: 0.12, minVelocity: { _ in 200 }), [.twoFingerTap])
    }
    func testVelocitySettingStillControlsRawSwipe() {
        for minimum: CGFloat in [100, 2000] {
            var engine = ContactGestureSession()
            let p = (0..<4).map { point($0, 0.2 + Float($0) * 0.15) }
            _ = engine.update(p, timestamp: 1, pressed: false, enabled: [.fourFingerSwipeDown], restTime: 0.12, minVelocity: { _ in minimum })
            let moved = p.map { point($0.id, $0.x, $0.y - 0.1) }
            let result = engine.update(moved, timestamp: 1.1, pressed: false, enabled: [.fourFingerSwipeDown], restTime: 0.12, minVelocity: { _ in minimum })
            XCTAssertEqual(result, minimum == 100 ? [.fourFingerSwipeDown] : [])
        }
    }
    func testPointerPauseBeforeSwipeDoesNotDiluteVelocity() {
        var engine = ContactGestureSession()
        let p = (0..<4).map { point($0, 0.2 + Float($0) * 0.15) }
        _ = engine.update(p, timestamp: 1, pressed: false, enabled: [.fourFingerSwipeDown], restTime: 0.12, minVelocity: { _ in 500 })
        _ = engine.update(p, timestamp: 5, pressed: false, enabled: [.fourFingerSwipeDown], restTime: 0.12, minVelocity: { _ in 500 })
        let moved = p.map { point($0.id, $0.x, $0.y - 0.12) }
        XCTAssertEqual(engine.update(moved, timestamp: 5.1, pressed: false, enabled: [.fourFingerSwipeDown], restTime: 0.12, minVelocity: { _ in 500 }), [.fourFingerSwipeDown])
    }

    func testIdleSecondDeviceDoesNotCompleteFirstDevicesTap() {
        let old = UserDefaults.standard.object(forKey: "AOMGlobalEnabled")
        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        var t = Trigger(name: "Four", input: .trackpadGesture(.fourFingerTap))
        t.actions = [TriggerAction(actionType: .volumeUp)]
        monitor.registerTriggers([t])
        var count = 0; ActionExecutor.onActionExecuted = { _ in count += 1 }
        defer { monitor.unregisterAll(); ActionExecutor.onActionExecuted = nil; UserDefaults.standard.set(old, forKey: "AOMGlobalEnabled") }
        let p = (0..<4).map { point($0, 0.2 + Float($0) * 0.15) }
        monitor.processTouchFrame(p, count: 4, timestamp: 1, pressedButtons: 0, deviceID: 1)
        monitor.processTouchFrame([], count: 0, timestamp: 1.05, pressedButtons: 0, deviceID: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02)); XCTAssertEqual(count, 0)
        monitor.processTouchFrame([], count: 0, timestamp: 1.1, pressedButtons: 0, deviceID: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02)); XCTAssertEqual(count, 1)
    }

    func testSuppressionPairsLongRightClickAndDoesNotSwallowNextUp() {
        let old = UserDefaults.standard.object(forKey: "AOMGlobalEnabled")
        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        let oldHook = ActionExecutor.onActionExecuted
        ActionExecutor.onActionExecuted = { _ in }
        var t = Trigger(name: "Click", input: .trackpadGesture(.twoFingerClick)); t.suppressClick = true; t.actions = [TriggerAction(actionType: .playPause)]
        monitor.registerTriggers([t])
        defer {
            monitor.unregisterAll()
            ActionExecutor.onActionExecuted = oldHook
            UserDefaults.standard.set(old, forKey: "AOMGlobalEnabled")
        }
        monitor.processTouchFrame([point(1, 0.3), point(2, 0.7)], count: 2, timestamp: 1, pressedButtons: 0)
        XCTAssertTrue(monitor.shouldSuppressMouseEvent(.rightMouseDown))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(monitor.shouldSuppressMouseEvent(.leftMouseUp))
        XCTAssertTrue(monitor.shouldSuppressMouseEvent(.rightMouseUp))
        XCTAssertFalse(monitor.shouldSuppressMouseEvent(.rightMouseUp))
    }
    private func withCompletedTipTap(suppress: Bool = true, override: Bool = false,
                                    _ check: (TrackpadMonitor) -> Void) {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "AOMGlobalEnabled")
        let rest = defaults.object(forKey: "AOMTipTapMinRestTime")
        defaults.set(true, forKey: "AOMGlobalEnabled"); defaults.set(0.12, forKey: "AOMTipTapMinRestTime")
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "test.app" })
        let oldHook = ActionExecutor.onActionExecuted
        ActionExecutor.onActionExecuted = { _ in }
        defer {
            monitor.unregisterAll(); ActionExecutor.onActionExecuted = oldHook
            defaults.set(enabled, forKey: "AOMGlobalEnabled"); defaults.set(rest, forKey: "AOMTipTapMinRestTime")
        }
        var t = Trigger(name: "Back", input: .trackpadGesture(.tipTapLeft))
        t.suppressClick = suppress; t.actions = [TriggerAction(actionType: .volumeDown)]
        var bindings = [t]
        if override {
            var scoped = Trigger(name: "Override", input: .trackpadGesture(.tipTapLeft))
            scoped.appBundleID = "test.app"; scoped.suppressClick = false
            scoped.actions = t.actions; bindings.append(scoped)
        }
        monitor.registerTriggers(bindings)
        monitor.processTouchFrame([point(1, 0.7)], count: 1, timestamp: 1, pressedButtons: 0)
        XCTAssertFalse(monitor.shouldSuppressMouseEvent(.leftMouseDown), "Resting alone is an ordinary click")
        monitor.processTouchFrame([point(1, 0.7), point(2, 0.3)], count: 2, timestamp: 1.2, pressedButtons: 0)
        monitor.processTouchFrame([point(1, 0.7)], count: 1, timestamp: 1.25, pressedButtons: 0)
        check(monitor)
    }

    func testTipTapConsumesMultipleResidualClicksAndPairsLateRelease() {
        withCompletedTipTap { monitor in
            let now = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(monitor.shouldSuppressMouseEvent(.leftMouseDown, at: now))
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.rightMouseUp, at: now))
            XCTAssertTrue(monitor.shouldSuppressMouseEvent(.leftMouseUp, at: now + 1))
            XCTAssertTrue(monitor.shouldSuppressMouseEvent(.leftMouseDown, at: now + 1.1))
            XCTAssertTrue(monitor.shouldSuppressMouseEvent(.leftMouseUp, at: now + 2.2))
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.leftMouseDown, at: now + 2.3))
        }
    }

    func testTipTapShieldExpiresWithoutSwallowingLaterIntentionalClick() {
        withCompletedTipTap { monitor in
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.leftMouseDown,
                at: ProcessInfo.processInfo.systemUptime + 2.1))
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.leftMouseUp))
        }
    }

    func testTipTapShieldHonorsSuppressionSwitchAndAppOverride() {
        withCompletedTipTap(suppress: false) { monitor in
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.leftMouseDown))
        }
        withCompletedTipTap(override: true) { monitor in
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.leftMouseDown))
        }
    }

    func testTipTapShieldHonorsPauseAndResetsOnRegistrationChange() {
        withCompletedTipTap { monitor in
            UserDefaults.standard.set(false, forKey: "AOMGlobalEnabled")
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.leftMouseDown))
            UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
            monitor.registerTriggers([])
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.leftMouseDown))
        }
    }

    func testNativeSecondaryClickPassesDuringTipTapShield() {
        withCompletedTipTap { monitor in
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.rightMouseDown))
            XCTAssertFalse(monitor.shouldSuppressMouseEvent(.rightMouseUp))
            XCTAssertTrue(monitor.shouldSuppressMouseEvent(.leftMouseDown))
        }
    }
    func testNativeSecondaryClickIsNotSuppressedByStaleCornerContact() {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        var corner = Trigger(name: "Volume", input: .trackpadGesture(.cornerClickTopLeft))
        corner.suppressClick = true; corner.actions = [TriggerAction(actionType: .volumeDown)]
        monitor.registerTriggers([corner]); defer { monitor.unregisterAll() }
        monitor.processTouchFrame([TouchPoint(id: 1, x: 0.02, y: 0.98, size: 0.1)], count: 1, timestamp: 1, pressedButtons: 0)
        XCTAssertFalse(monitor.shouldSuppressMouseEvent(.rightMouseDown))
        XCTAssertFalse(monitor.shouldSuppressMouseEvent(.rightMouseUp))
        XCTAssertTrue(monitor.shouldSuppressMouseEvent(.leftMouseDown))
    }
    func testEmptyClickMappingCannotSuppressNativeClick() {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        var trigger = Trigger(name: "Empty", input: .trackpadGesture(.twoFingerClick)); trigger.suppressClick = true
        monitor.registerTriggers([trigger]); defer { monitor.unregisterAll() }
        monitor.processTouchFrame([point(1, 0.3), point(2, 0.7)], count: 2, timestamp: 1, pressedButtons: 0)
        XCTAssertFalse(monitor.shouldSuppressMouseEvent(.rightMouseDown))
    }

}
