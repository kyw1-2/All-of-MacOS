import XCTest
import AppKit
@testable import AllOfMacOS

// 3.4.0 audit: N333-08 the other way round (a user trigger that already ran
// from a touch, then a Dock gesture in the same touch), and the Mission
// Control poller (Pause AOM, the W/⇧W/M/H keys without the ✕ buttons). The
// utility layer runs with every seam replaced and put back, as in
// N333GestureOwnershipTests: no app, window or Space is touched, the quit
// request is counted, never sent, and no setting is written.

private final class StillDesktop: GestureDesktop {
    private(set) var changes: [String] = []
    func isFrontmost(_ pid: pid_t) -> Bool { false }
    func appName(_ pid: pid_t) -> String? { nil }
    func activate(_ pid: pid_t) -> Bool { changes.append("activate"); return false }
    func hide(_ pid: pid_t) -> Bool { changes.append("hide"); return false }
    func hideOthers(keeping pid: pid_t) -> Bool { changes.append("hide others"); return false }
    func postNewWindow(to pid: pid_t) -> Bool { changes.append("⌘N"); return false }
    func appCycle() -> AppCycle { AppCycle(frontmost: nil, recent: [], running: []) }
    var switcherIsShowing: Bool { false }
    func showSwitcher() { changes.append("switcher") }
    func scrollSwitcher(by offset: Int) -> Bool { false }
    func confirmSwitcher() {}
    func windows(of pid: pid_t) -> [GestureWindow] { [] }
    func focusedWindow(of pid: pid_t) -> GestureWindow? { nil }
    func visibleWindows() -> [(window: GestureWindow, frame: CGRect)] { [] }
    func isMinimized(_ window: GestureWindow) -> Bool { false }
    func setMinimized(_ window: GestureWindow, _ minimized: Bool) -> Bool { changes.append("minimize"); return false }
    func raise(_ window: GestureWindow) -> Bool { changes.append("raise"); return false }
    func screens() -> [(frame: CGRect, visible: CGRect)] { [] }
    func screenIndex(containing point: CGPoint) -> Int? { nil }
    func move(_ window: GestureWindow, to frame: CGRect, anchorIn visible: CGRect?,
              completion: @escaping (CGRect?) -> Void) {
        changes.append("move")
        completion(nil)
    }
    func unsnapFrame(for window: GestureWindow, current: CGRect) -> CGRect? { nil }
    func snappedCell(for window: GestureWindow, current: CGRect) -> CustomSnapZone.Layout? { nil }
    func recordDisplayMove(of window: GestureWindow, from start: CGRect, to actual: CGRect,
                           layout: CustomSnapZone.Layout) {}
    var snapMargin: CGFloat { 0 }
    var snapThirds: Bool { false }
}

@MainActor
final class Audit340GestureTests: XCTestCase {
    private let service = TrackpadUtilityGestures.shared
    private var desktop: StillDesktop!
    private var restoreSeams: (() -> Void)?
    private var dockTarget: NSRunningApplication?
    private var quits: [pid_t] = []
    private var later: [() -> Void] = []
    private var uptime: TimeInterval = 20_000
    private var t: Double = 0
    private static var clock: Double = 5_000_000

    override func setUp() {
        super.setUp()
        TriggerSuppression.shared.resume()
        let service = self.service
        let desktop = service.desktop, cursorLocation = service.cursorLocation,
            cursorInTopBand = service.cursorInTopBand, windowUnderPointer = service.windowUnderPointer,
            isScreenLocked = service.isScreenLocked, isAllowed = service.isAllowed,
            holdCancelSeconds = service.holdCancelSeconds, modifierFlags = service.modifierFlags,
            announce = service.announce, haptic = service.haptic, switchSpace = service.switchSpace,
            dockApp = service.dockApp, quitApplication = service.quitApplication, isAppPaused = service.isAppPaused,
            chainWindow = service.chainWindow, menuBarSpot = service.menuBarSpot,
            prefetchMenuBarSpot = service.prefetchMenuBarSpot, missionControlWindow = service.missionControlWindow,
            schedule = service.schedule, now = service.now
        restoreSeams = {
            service.desktop = desktop; service.cursorLocation = cursorLocation
            service.cursorInTopBand = cursorInTopBand; service.windowUnderPointer = windowUnderPointer
            service.isScreenLocked = isScreenLocked; service.isAllowed = isAllowed
            service.holdCancelSeconds = holdCancelSeconds; service.modifierFlags = modifierFlags
            service.announce = announce; service.haptic = haptic; service.switchSpace = switchSpace
            service.dockApp = dockApp; service.quitApplication = quitApplication; service.isAppPaused = isAppPaused
            service.chainWindow = chainWindow; service.menuBarSpot = menuBarSpot
            service.prefetchMenuBarSpot = prefetchMenuBarSpot; service.missionControlWindow = missionControlWindow
            service.schedule = schedule; service.now = now
        }
        Self.clock += 1_000
        t = Self.clock
        service.observe(points: [], timestamp: t)
        service.cancelPending()
        self.desktop = StillDesktop()
        service.desktop = self.desktop
        service.cursorLocation = { CGPoint(x: 700, y: 30) }
        service.cursorInTopBand = { _ in false }
        service.windowUnderPointer = { _ in nil }
        service.isScreenLocked = { false }
        service.isAllowed = { true }
        service.holdCancelSeconds = { 2 }
        service.modifierFlags = { [] }
        service.announce = { _, _ in }
        service.haptic = {}
        service.switchSpace = { _ in }
        service.dockApp = { [unowned self] in self.dockTarget }
        service.quitApplication = { [unowned self] in self.quits.append($0.processIdentifier) }
        service.isAppPaused = { _ in false }
        service.chainWindow = { _ in false }
        service.menuBarSpot = { _ in .empty }
        service.prefetchMenuBarSpot = { _ in }
        service.missionControlWindow = { _ in nil }
        service.schedule = { [unowned self] _, work in self.later.append(work) }
        service.now = { [unowned self] in self.uptime }
        TitleBarWindowSnap.ownsTouch = false
    }

    override func tearDown() {
        service.observe(points: [], timestamp: t + 10)
        service.cancelPending()
        later.removeAll()
        restoreSeams?()
        restoreSeams = nil
        ActionExecutor.onActionExecuted = nil
        super.tearDown()
    }

    private func two(spread: Float = 0.12) -> [TouchPoint] {
        [TouchPoint(id: 1, x: 0.5 - spread / 2, y: 0.5, size: 0.1), TouchPoint(id: 2, x: 0.5 + spread / 2, y: 0.5, size: 0.1)]
    }

    private func frame(_ points: [TouchPoint], after delay: Double = 1.0 / 60) {
        t += delay
        service.observe(points: points, timestamp: t)
    }

    private func runLater() {
        let pending = later
        later.removeAll()
        pending.forEach { $0() }
    }

    private func someOtherApp() throws -> NSRunningApplication {
        try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != getpid() && $0.activationPolicy == .regular && !$0.isTerminated
        }, "a regular app besides the test runner")
    }

    // MARK: The other way round

    /// The user's trigger ran from a touch on a Dock icon (the Dock gestures
    /// had not claimed that gesture); a pinch in the same touch then quit the
    /// app as well. Now the rest of the touch is the trigger engine's.
    func testATriggerThatRanKeepsTheDockFromActingOnTheSameTouch() throws {
        let app = try someOtherApp()
        dockTarget = app
        frame(two(spread: 0.30), after: 1)
        service.triggerEngineTookTouch()
        frame(two(spread: 0.12), after: 0.05)
        frame([], after: 0.05)
        runLater()
        XCTAssertEqual(quits, [], "the Dock does not also quit the app")
        XCTAssertFalse(service.claimsNow(.twoFingerPinchIn), "and claims nothing of that touch any more")

        // The next touch on the Dock is the Dock's again.
        frame(two(spread: 0.30), after: 1)
        frame(two(spread: 0.12), after: 0.05)
        frame([], after: 0.05)
        runLater()
        XCTAssertEqual(quits, service.dockQuitEnabled ? [app.processIdentifier] : [])
        XCTAssertEqual(desktop.changes, [])
    }

    /// A pinch the Dock already holds (it waits for a second one) is taken back.
    func testATriggerThatRanTakesBackAPinchStillWaiting() throws {
        dockTarget = try someOtherApp()
        frame(two(spread: 0.30), after: 1)
        frame(two(spread: 0.12), after: 0.05)
        service.triggerEngineTookTouch()
        frame([], after: 0.05)
        runLater()
        XCTAssertEqual(quits, [])
    }

    /// A touch that has lifted is left alone: the next one is not spent.
    func testALiftedTouchIsLeftAlone() throws {
        let app = try someOtherApp()
        dockTarget = app
        service.triggerEngineTookTouch()
        frame(two(spread: 0.30), after: 1)
        frame(two(spread: 0.12), after: 0.05)
        frame([], after: 0.05)
        runLater()
        XCTAssertEqual(quits, service.dockQuitEnabled ? [app.processIdentifier] : [])
    }

    /// The trigger engine tells the layer only for gestures the layer could
    /// also answer, and only when a trigger ran.
    func testTheTriggerEngineHandsOverOnlyTouchesItsTriggerTook() {
        var told: [TrackpadGesture] = []
        ActionExecutor.onActionExecuted = { _ in }
        func monitor(_ gesture: TrackpadGesture) -> TrackpadMonitor {
            let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
            var trigger = Trigger(name: "Two fingers", input: .trackpadGesture(gesture))
            trigger.actions = [TriggerAction(actionType: .volumeUp)]
            monitor.registerTriggers([trigger])
            monitor.utilityTookTouchOverride = { told.append($0) }
            return monitor
        }
        let swipe = monitor(.twoFingerSwipeUp), rotate = monitor(.twoFingerRotateLeft)
        defer { swipe.unregisterAll(); rotate.unregisterAll() }
        swipe.fireGestureForTest(.twoFingerSwipeUp)
        rotate.fireGestureForTest(.twoFingerRotateLeft)
        swipe.fireGestureForTest(.twoFingerPinchIn) // no trigger for it
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(told, [.twoFingerSwipeUp], "a rotation stays both layers' (as before); no trigger, no hand-over")
    }

    // MARK: The Mission Control poller

    func testTheMissionControlPollerHonoursPauseAndServesTheKeysAlone() {
        typealias S = MissionControlOverlayService
        XCTAssertTrue(S.shouldProbe(buttons: true, hotkeys: true, automationOn: true, paused: false, locked: false))
        XCTAssertFalse(S.shouldProbe(buttons: true, hotkeys: true, automationOn: true, paused: true, locked: false),
                       "Pause AOM: no ✕ buttons over Mission Control")
        XCTAssertTrue(S.shouldProbe(buttons: false, hotkeys: true, automationOn: true, paused: false, locked: false),
                      "the W/⇧W/M/H keys work with the ✕ buttons off")
        XCTAssertTrue(S.shouldProbe(buttons: true, hotkeys: false, automationOn: true, paused: false, locked: false))
        XCTAssertFalse(S.shouldProbe(buttons: false, hotkeys: false, automationOn: true, paused: false, locked: false))
        XCTAssertFalse(S.shouldProbe(buttons: true, hotkeys: true, automationOn: false, paused: false, locked: false))
        XCTAssertFalse(S.shouldProbe(buttons: true, hotkeys: true, automationOn: true, paused: false, locked: true))
        var asked = false
        XCTAssertFalse(S.shouldProbe(buttons: true, hotkeys: true, automationOn: true, paused: true,
                                     locked: { asked = true; return false }()))
        XCTAssertFalse(asked, "nothing asks the window server while paused")
    }
}
