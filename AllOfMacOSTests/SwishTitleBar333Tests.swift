import XCTest
@testable import AllOfMacOS

/// 3.3.3 title-bar Swish work: the multi-motion engine (audit F01), the
/// window chain (`beginChain`), tab gestures (F02), start areas (F04), the
/// modifier roles and keyboard (F05), native tiling (F06), and the pause
/// checks of background writes and delayed steps (S03, S05). Pure: recognizer
/// frames, value types and fakes only; no trackpad, Accessibility or windows.
final class SwishTitleBar333Tests: XCTestCase {
    // MARK: Helpers

    /// Two fingers whose centroid sits at (x, y) in the snap's pad
    /// coordinates (y toward the bottom of the pad), `spread` apart.
    private func pair(_ x: Float, _ y: Float, spread: Float = 0.02) -> [TouchPoint] {
        [TouchPoint(id: 1, x: x - spread / 2, y: 1 - y, size: 1, pressure: 0),
         TouchPoint(id: 2, x: x + spread / 2, y: 1 - y, size: 1, pressure: 0)]
    }

    private func third(_ x: Float, _ y: Float) -> [TouchPoint] {
        pair(x, y) + [TouchPoint(id: 3, x: x + 0.1, y: 1 - y, size: 1, pressure: 0)]
    }

    /// A recognizer that writes every callback into `events`.
    private func recorder() -> (TitleBarSnapRecognizer, () -> [String]) {
        let recognizer = TitleBarSnapRecognizer()
        recognizer.settleTime = 0
        var events: [String] = []
        recognizer.onTouchDown = { events.append("down") }
        recognizer.onBegin = { events.append("begin \($0.direction)\($0.held ? " held" : "")") }
        recognizer.onCommit = { events.append("commit") }
        recognizer.onCancel = { events.append("cancel") }
        recognizer.onHoldCancel = { events.append("hold-cancel") }
        recognizer.onPinchChange = { events.append("pinch-change \($0.map { "\($0)" } ?? "nil")") }
        recognizer.onPinch = { events.append("pinch \($0)") }
        recognizer.onTap = { _ in events.append("tap") }
        recognizer.onMotionReady = { events.append("ready") }
        recognizer.onTouchEnd = { events.append("end") }
        recognizer.onHoldLift = { events.append("hold-lift") }
        return (recognizer, { events })
    }

    // MARK: F01 multi-motion (the audit probe's three scenarios, now passing)

    /// Probe 1: up, a 0.3 s pause, up again without lifting. 3.3.2 committed
    /// once after the lift; now the pause locks the first swipe and the next
    /// movement commits it and begins the second.
    func testSwipePauseSwipeCommitsTwiceInOneTouch() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.6), timestamp: 0)
        r.feed(contacts: pair(0.5, 0.54), timestamp: 0.1)
        for t in [0.2, 0.3, 0.4] { r.feed(contacts: pair(0.5, 0.54), timestamp: t) }
        r.feed(contacts: pair(0.5, 0.48), timestamp: 0.5)
        XCTAssertEqual(events(), ["down", "begin up", "ready", "commit", "begin up"], "before lift")
        r.feed(contacts: [], timestamp: 0.6)
        XCTAssertEqual(events(), ["down", "begin up", "ready", "commit", "begin up", "commit", "end"])
        XCTAssertEqual(r.motionIndex, 1, "the touch's second gesture")
    }

    /// Probe 2: pinch in, pause, pinch in again: two pinches (the service
    /// turns the second into "quit", as with two separate pinches).
    func testPinchPausePinchReportsTwoPinches() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5, spread: 0.30), timestamp: 0)
        r.feed(contacts: pair(0.5, 0.5, spread: 0.20), timestamp: 0.1)
        for t in [0.2, 0.3, 0.4] { r.feed(contacts: pair(0.5, 0.5, spread: 0.20), timestamp: t) }
        r.feed(contacts: pair(0.5, 0.5, spread: 0.10), timestamp: 0.5)
        r.feed(contacts: [], timestamp: 0.6)
        XCTAssertEqual(events(), ["down", "pinch-change in", "ready", "pinch in", "pinch-change in", "pinch in", "end"])
    }

    /// Probe 3: a swipe, a pause, then a pinch in the same touch.
    func testSwipePauseThenPinchInOneTouch() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5, spread: 0.3), timestamp: 0)
        r.feed(contacts: pair(0.62, 0.5, spread: 0.3), timestamp: 0.1)
        for t in [0.2, 0.3, 0.4] { r.feed(contacts: pair(0.62, 0.5, spread: 0.3), timestamp: t) }
        r.feed(contacts: pair(0.62, 0.5, spread: 0.15), timestamp: 0.5)
        r.feed(contacts: [], timestamp: 0.6)
        XCTAssertEqual(events(), ["down", "begin right", "ready", "commit", "pinch-change in", "pinch in", "end"])
    }

    /// Several held swipes after one tap and hold (Swish: Space after Space).
    func testSeveralHeldSwipesAfterOneTapAndHold() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        for t in stride(from: 0.1, through: 0.5, by: 0.1) { r.feed(contacts: pair(0.5, 0.5), timestamp: t) }
        r.feed(contacts: pair(0.57, 0.5), timestamp: 0.6)
        for t in [0.7, 0.8, 0.9] { r.feed(contacts: pair(0.57, 0.5), timestamp: t) }
        r.feed(contacts: pair(0.64, 0.5), timestamp: 1.0)
        r.feed(contacts: [], timestamp: 1.1)
        XCTAssertEqual(events(), ["down", "begin right held", "ready", "commit", "begin right held", "commit", "end"])
    }

    /// Resting then lifting is the 3.3.2 lift: one commit, nothing more.
    func testRestingThenLiftingCommitsOnce() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        r.feed(contacts: pair(0.43, 0.5), timestamp: 0.1)
        for t in [0.2, 0.3, 0.4, 0.5] { r.feed(contacts: pair(0.43, 0.5), timestamp: t) }
        r.feed(contacts: [], timestamp: 0.6)
        XCTAssertEqual(events(), ["down", "begin left", "ready", "commit", "end"])
    }

    /// The hold-still cancel still cancels a locked gesture.
    func testHoldingStillCancelsALockedSwipe() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        r.feed(contacts: pair(0.43, 0.5), timestamp: 0.1)
        for t in stride(from: 0.2, through: 2.3, by: 0.1) { r.feed(contacts: pair(0.43, 0.5), timestamp: t) }
        r.feed(contacts: pair(0.30, 0.5), timestamp: 2.4)
        r.feed(contacts: [], timestamp: 2.5)
        XCTAssertEqual(events(), ["down", "begin left", "ready", "hold-cancel", "end"])
    }

    /// A third finger cancels the gesture on show; the one already committed stays.
    func testAThirdFingerCancelsOnlyTheGestureOnShow() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        r.feed(contacts: pair(0.43, 0.5), timestamp: 0.1)
        for t in [0.2, 0.3, 0.4] { r.feed(contacts: pair(0.43, 0.5), timestamp: t) }
        r.feed(contacts: pair(0.43, 0.56), timestamp: 0.5)
        r.feed(contacts: third(0.43, 0.56), timestamp: 0.55)
        r.feed(contacts: pair(0.43, 0.65), timestamp: 0.6)
        r.feed(contacts: [], timestamp: 0.7)
        XCTAssertEqual(events(), ["down", "begin left", "ready", "commit", "begin down", "cancel", "end"])
    }

    /// A gap in the stream cancels a locked gesture and ends the touch.
    func testAFrameGapCancelsALockedGesture() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        r.feed(contacts: pair(0.43, 0.5), timestamp: 0.1)
        for t in [0.2, 0.3, 0.4] { r.feed(contacts: pair(0.43, 0.5), timestamp: t) }
        r.feed(contacts: pair(0.30, 0.5), timestamp: 1.5)
        XCTAssertEqual(events(), ["down", "begin left", "ready", "cancel", "end", "down"], "the late frame starts a new touch")
    }

    /// A slow swipe never stops long enough to lock half-way.
    func testASlowSwipeDoesNotLockHalfWay() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        r.feed(contacts: pair(0.44, 0.5), timestamp: 0.1)
        var x: Float = 0.44
        for step in 1...20 {
            x -= 0.0025   // 0.05 pad units per second
            r.feed(contacts: pair(x, 0.5), timestamp: 0.1 + Double(step) * 0.05)
        }
        r.feed(contacts: [], timestamp: 1.2)
        XCTAssertEqual(events(), ["down", "begin left", "commit", "end"])
    }

    /// The tap guard is kept for a touch's first gesture.
    func testATapIsStillATap() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        r.feed(contacts: pair(0.505, 0.5), timestamp: 0.05)
        r.feed(contacts: [], timestamp: 0.1)
        XCTAssertEqual(events(), ["down", "cancel", "tap", "end"])
    }

    /// 0 turns the engine off: one gesture per touch, as in 3.3.2 (the probe's old result).
    func testMotionPauseZeroKeepsOneGesturePerTouch() {
        let (r, events) = recorder()
        r.motionPause = 0
        r.feed(contacts: pair(0.5, 0.6), timestamp: 0)
        r.feed(contacts: pair(0.5, 0.54), timestamp: 0.1)
        for t in [0.2, 0.3, 0.4] { r.feed(contacts: pair(0.5, 0.54), timestamp: t) }
        r.feed(contacts: pair(0.5, 0.48), timestamp: 0.5)
        r.feed(contacts: [], timestamp: 0.6)
        XCTAssertEqual(events(), ["down", "begin up", "commit", "end"])
    }

    func testMotionPauseSetting() {
        let defaults = UserDefaults(suiteName: "aom.test.swish333.pause.\(UUID().uuidString)")!
        XCTAssertEqual(TitleBarWindowSnap.motionPause(defaults), 0.25)
        defaults.set(0.0, forKey: TitleBarWindowSnap.motionPauseKey)
        XCTAssertEqual(TitleBarWindowSnap.motionPause(defaults), 0, "off")
        defaults.set(0.05, forKey: TitleBarWindowSnap.motionPauseKey)
        XCTAssertEqual(TitleBarWindowSnap.motionPause(defaults), 0.15)
        defaults.set(9.0, forKey: TitleBarWindowSnap.motionPauseKey)
        XCTAssertEqual(TitleBarWindowSnap.motionPause(defaults), 1)
    }

    /// `rearm` (beginChain mid-touch, a detached tab): the rest of the touch
    /// starts afresh from where the fingers are, not held, never a tap.
    func testRearmStartsTheTouchAfresh() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        for t in stride(from: 0.1, through: 0.5, by: 0.1) { r.feed(contacts: pair(0.5, 0.5), timestamp: t) }
        r.feed(contacts: pair(0.42, 0.5), timestamp: 0.6)          // a held swipe left
        r.rearm()
        r.feed(contacts: pair(0.42, 0.5), timestamp: 0.65)          // restarts here, silently
        r.feed(contacts: pair(0.49, 0.5), timestamp: 0.7)           // right, from the new start
        r.feed(contacts: [], timestamp: 0.72)
        XCTAssertEqual(events(), ["down", "begin left held", "begin right", "commit", "end"])
    }

    func testARearmWhileIdleIsDropped() {
        let (r, events) = recorder()
        r.rearm()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        r.feed(contacts: pair(0.43, 0.5), timestamp: 0.1)
        r.feed(contacts: [], timestamp: 0.2)
        XCTAssertEqual(events(), ["down", "begin left", "commit", "end"])
    }

    /// A tap and hold that lifts without moving is reported (tab detach).
    func testAHoldThenLiftIsReported() {
        let (r, events) = recorder()
        r.feed(contacts: pair(0.5, 0.5), timestamp: 0)
        for t in stride(from: 0.1, through: 0.6, by: 0.1) { r.feed(contacts: pair(0.5, 0.5), timestamp: t) }
        r.feed(contacts: [], timestamp: 0.7)
        XCTAssertEqual(events(), ["down", "cancel", "hold-lift", "end"])
    }

    // MARK: Chaining during a commit (the queue now keeps several motions)

    func testTheChainQueueKeepsCommittedMotionsInOrder() {
        var queue = SwishChainQueue()
        queue.began(.init(.left))
        queue.liftedFingers()                      // committed by the next motion
        queue.began(.init(.down))
        queue.liftedFingers()
        queue.beganPinch(.in)                      // still on the pad
        queue.pinchUpdated(.out)
        XCTAssertEqual(queue.queue.count, 3)
        XCTAssertEqual(queue.landed(succeeded: true), .init(stroke: .init(.left), lifted: true))
        XCTAssertEqual(queue.landed(succeeded: true), .init(stroke: .init(.down), lifted: true))
        let pinch = queue.landed(succeeded: true)
        XCTAssertEqual(pinch?.isPinch, true)
        XCTAssertEqual(pinch?.pinch, .out)
        XCTAssertEqual(pinch?.lifted, false)
        XCTAssertNil(queue.pending)
    }

    func testTheChainQueueDropsOnlyTheLiveMotionOnCancelAndAllOnAFailedCommit() {
        var queue = SwishChainQueue()
        queue.began(.init(.left)); queue.liftedFingers()
        queue.began(.init(.up))
        queue.updated(.init(.up, tier: 2))
        queue.cancelTouch()
        XCTAssertEqual(queue.queue, [.init(stroke: .init(.left), lifted: true)])
        queue.began(.init(.right))
        queue.began(.init(.down))                  // a newer live motion replaces the live one
        XCTAssertEqual(queue.queue.map(\.stroke.direction), [.left, .down])
        XCTAssertNil(queue.landed(succeeded: false))
        XCTAssertTrue(queue.queue.isEmpty)
        for _ in 0..<6 { queue.began(.init(.left)); queue.liftedFingers() }
        XCTAssertEqual(queue.queue.count, SwishChainQueue.limit)
    }

    func testWhichActionsLetTheTouchGoOn() {
        XCTAssertTrue(SwishSnap.touchContinues(after: .spaceRight, waits: false))
        XCTAssertTrue(SwishSnap.touchContinues(after: .closeTab, waits: false))
        XCTAssertTrue(SwishSnap.touchContinues(after: .close, waits: true), "a second pinch may quit")
        XCTAssertTrue(SwishSnap.touchContinues(after: .toggleFullscreen, waits: true))
        XCTAssertFalse(SwishSnap.touchContinues(after: .toggleFullscreen, waits: false))
        for action: SwishSnap.WindowAction in [.minimize, .quitApp, .hideApp, .hideOthers, .fullscreenOnOtherScreen, .detachTab] {
            XCTAssertFalse(SwishSnap.touchContinues(after: action, waits: false), "\(action)")
        }
    }

    // MARK: The window chain (beginChain's contract)

    func testAHandedOverWindowStaysChainedUntilLiftPlusGrace() {
        var chain = SwishWindowChain()
        chain.begin(key: "A", pid: 10, reason: "dock", outlivesTouch: true, touchLive: true, now: 100)
        XCTAssertEqual(chain.current(now: 150), "A", "no timeout while the touch is on the pad")
        chain.touchEnded(now: 150)
        XCTAssertEqual(chain.current(now: 152.9), "A")
        XCTAssertEqual(chain.touchBegan(pointerKey: nil, now: 152.9), "A", "the next touch, pointer anywhere")
        XCTAssertEqual(chain.current(now: 170), "A", "held for that touch too")
        chain.touchEnded(now: 170)
        XCTAssertNil(chain.touchBegan(pointerKey: nil, now: 173.5), "timed out")
        XCTAssertNil(chain.link)
    }

    func testCapturingAnotherWindowEndsTheChain() {
        var chain = SwishWindowChain()
        chain.begin(key: "A", pid: 10, reason: "dock", outlivesTouch: true, touchLive: false, now: 0)
        XCTAssertEqual(chain.touchBegan(pointerKey: "A", now: 1), "A", "its own title bar keeps it")
        chain.touchEnded(now: 1)
        XCTAssertNil(chain.touchBegan(pointerKey: "B", now: 2))
        XCTAssertNil(chain.link)
    }

    func testATouchsOwnChainEndsWithItAndKeepsAHandOver() {
        var chain = SwishWindowChain()
        chain.begin(key: "A", pid: 10, reason: "multi-motion", outlivesTouch: false, touchLive: true, now: 0)
        chain.touchEnded(now: 1)
        XCTAssertNil(chain.link, "multi-motion ends at the lift")
        chain.begin(key: "A", pid: 10, reason: "dock", outlivesTouch: true, touchLive: true, now: 2)
        chain.begin(key: "A", pid: 10, reason: "multi-motion", outlivesTouch: false, touchLive: true, now: 3)
        XCTAssertEqual(chain.link?.outlivesTouch, true)
        XCTAssertEqual(chain.link?.reason, "dock")
        chain.begin(key: "B", pid: 11, reason: "multi-motion", outlivesTouch: false, touchLive: true, now: 4)
        XCTAssertEqual(chain.link?.key, "B", "a gesture on another window replaces it")
        XCTAssertEqual(chain.link?.outlivesTouch, false)
        chain.begin(key: "C", pid: 12, reason: "multi-motion", outlivesTouch: false, touchLive: false, now: 5)
        XCTAssertNil(chain.link, "no touch, no touch chain")
        chain.begin(key: "D", pid: 13, reason: "dock", outlivesTouch: true, touchLive: false, now: 10)
        XCTAssertEqual(chain.current(now: 12.9), "D", "after the lift: the grace starts now")
        XCTAssertNil(chain.current(now: 13.1))
    }

    // MARK: S03 background writes ask again before each write

    /// Windows A and B are snapped; B's app is paused while A is in front.
    /// A display change re-snaps both: B gets no write. Pausing AOM after the
    /// first write stops the rest of the batch.
    func testBackgroundBatchesSkipPausedAppsAndStopWhenPaused() {
        struct Window { let key: String; let pid: pid_t }
        let windows = [Window(key: "A", pid: 1), Window(key: "B", pid: 2), Window(key: "C", pid: 3)]
        var paused: Set<pid_t> = [2]
        var aomPaused = false
        var writes: [String] = []
        var written = -1
        var pending: [() -> Void] = []
        SwishGatedBatch.run(windows[...], mayWrite: { window in
            !aomPaused && SwishSnap.mayWriteBackground(ownApp: false, appPaused: paused.contains(window.pid))
        }, apply: { window, done in
            writes.append(window.key)
            pending.append(done)                     // lands later, like applySnap
        }, finished: { written = $0 })
        XCTAssertEqual(writes, ["A"], "one at a time")
        aomPaused = true                             // paused while A lands
        pending.removeFirst()()
        XCTAssertEqual(writes, ["A"], "B paused for its app, C after AOM was paused")
        XCTAssertEqual(written, 1)

        writes = []; aomPaused = false; paused = []
        SwishGatedBatch.run(windows[...], mayWrite: { _ in true }, apply: { window, done in
            writes.append(window.key); done()
        }, finished: { written = $0 })
        XCTAssertEqual(writes, ["A", "B", "C"])
        XCTAssertEqual(written, 3)
        XCTAssertFalse(SwishSnap.mayWriteBackground(ownApp: true, appPaused: false), "never AOM's own windows")
    }

    // MARK: S05 delayed full-screen steps re-check when they run

    func testDelayedStepsReCheckPauseLockAndTheApp() {
        var scheduled: [() -> Void] = []
        let tasks = SwishDelayedTasks { _, work in scheduled.append(work) }
        var allowed = true, appPaused = false, locked = false, running = true
        var ran = 0, skipped = 0
        func schedule() {
            tasks.run(after: 0.3, gate: {
                SwishDelayedTasks.mayRun(allowed: allowed, appPaused: appPaused, screenLocked: locked, appRunning: running)
            }, work: { ran += 1 }, skipped: { skipped += 1 })
        }
        schedule(); scheduled.removeFirst()()
        XCTAssertEqual(ran, 1, "nothing changed: it runs")
        for change in 0..<4 {
            (allowed, appPaused, locked, running) = (true, false, false, true)
            schedule()
            switch change {
            case 0: allowed = false        // AOM paused after scheduling
            case 1: appPaused = true       // the window's app paused
            case 2: locked = true          // the screen locked
            default: running = false       // the app quit
            }
            scheduled.removeFirst()()
        }
        XCTAssertEqual(ran, 1, "no full-screen write after any of them")
        XCTAssertEqual(skipped, 4)
        (allowed, appPaused, locked, running) = (true, false, false, true)
        schedule()
        tasks.cancelAll()                  // the snap was switched off
        scheduled.removeFirst()()
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(skipped, 5)
    }

    // MARK: F04 start areas

    func testStartAreas() {
        XCTAssertTrue(SwishSnap.inPreFilterBand(pointerY: 100 + 90, windowTop: 100, anywhere: false),
                      "a native tab bar under a toolbar (about 80–100 pt down)")
        XCTAssertFalse(SwishSnap.inPreFilterBand(pointerY: 100 + 200, windowTop: 100, anywhere: false))
        XCTAssertTrue(SwishSnap.inPreFilterBand(pointerY: 100 + 600, windowTop: 100, anywhere: true), "Super: anywhere")
        XCTAssertFalse(SwishSnap.inPreFilterBand(pointerY: 90, windowTop: 100, anywhere: true), "never above the window")
        XCTAssertTrue(SwishSnap.isStartArea(onTitleBar: false, onTabBar: true, inTitleBand: false, anywhere: false))
        XCTAssertTrue(SwishSnap.isStartArea(onTitleBar: true, onTabBar: false, inTitleBand: false, anywhere: false))
        XCTAssertTrue(SwishSnap.isStartArea(onTitleBar: false, onTabBar: false, inTitleBand: true, anywhere: false))
        XCTAssertFalse(SwishSnap.isStartArea(onTitleBar: false, onTabBar: false, inTitleBand: false, anywhere: false),
                       "document content below the bars")
        XCTAssertTrue(SwishSnap.isStartArea(onTitleBar: false, onTabBar: false, inTitleBand: false, anywhere: true))
        let defaults = UserDefaults(suiteName: "aom.test.swish333.areas.\(UUID().uuidString)")!
        XCTAssertFalse(TitleBarWindowSnap.superAnywhereOn(defaults), "anywhere is off by default")
        XCTAssertTrue(TitleBarWindowSnap.tabGesturesOn(defaults))
    }
}
