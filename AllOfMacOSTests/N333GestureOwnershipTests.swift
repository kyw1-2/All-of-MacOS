import XCTest
import AppKit
@testable import AllOfMacOS

// N333-08 (3.3.3 re-audit, B07): a two-finger touch the Dock, menu-bar or
// Mission Control gestures take is theirs, as a title-bar touch is the
// snap's; the user's two-finger trigger stays quiet on it and runs as before
// anywhere else. The frames go through the shared utility layer with every
// seam replaced (and put back): no app, window, display or Space is touched,
// the quit request is counted, never sent, and no setting is written. The
// gesture families are read as they stand in this process, so each check
// expects what the pure rule says for them (all on but Mission Control and the
// app menu by default).

/// A desktop with nothing on it that records what it was asked to change.
private final class QuietDesktop: GestureDesktop {
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
final class N333GestureOwnershipTests: XCTestCase {
    private typealias Claim = UtilityTouchClaim
    private let service = TrackpadUtilityGestures.shared
    private var desktop: QuietDesktop!
    private var restoreSeams: (() -> Void)?
    private var dockTarget: NSRunningApplication?
    private var inTopBand = false
    private var spot: MenuBarSpot = .empty
    private var allowed = true
    private var quits: [pid_t] = []
    private var later: [() -> Void] = []
    private var uptime: TimeInterval = 10_000
    private var t: Double = 0
    /// Frame time only moves forward across the suite.
    private static var clock: Double = 3_000_000

    override func setUp() {
        super.setUp()
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
        self.desktop = QuietDesktop()
        service.desktop = self.desktop
        service.cursorLocation = { CGPoint(x: 700, y: 30) }
        service.cursorInTopBand = { [unowned self] _ in self.inTopBand }
        service.windowUnderPointer = { _ in nil }
        service.isScreenLocked = { false }
        service.isAllowed = { [unowned self] in self.allowed }
        service.holdCancelSeconds = { 2 }
        service.modifierFlags = { [] }
        service.announce = { _, _ in }
        service.haptic = {}
        service.switchSpace = { _ in }
        service.dockApp = { [unowned self] in self.dockTarget }
        service.quitApplication = { [unowned self] in self.quits.append($0.processIdentifier) }
        service.isAppPaused = { _ in false }
        service.chainWindow = { _ in false }
        service.menuBarSpot = { [unowned self] _ in self.spot }
        service.prefetchMenuBarSpot = { _ in }
        service.missionControlWindow = { _ in nil }
        service.schedule = { [unowned self] _, work in self.later.append(work) }
        service.now = { [unowned self] in self.uptime }
        TitleBarWindowSnap.ownsTouch = false
    }

    override func tearDown() {
        allowed = true
        service.observe(points: [], timestamp: t + 10)
        service.cancelPending()
        later.removeAll()
        restoreSeams?()
        restoreSeams = nil
        ActionExecutor.onActionExecuted = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func two(spread: Float = 0.12) -> [TouchPoint] {
        [TouchPoint(id: 1, x: 0.5 - spread / 2, y: 0.5, size: 0.1), TouchPoint(id: 2, x: 0.5 + spread / 2, y: 0.5, size: 0.1)]
    }

    private func frame(_ points: [TouchPoint], after delay: Double = 1.0 / 60) {
        t += delay
        service.observe(points: points, timestamp: t)
    }

    private func someOtherApp() throws -> NSRunningApplication {
        try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != getpid() && $0.activationPolicy == .regular && !$0.isTerminated
        }, "a regular app besides the test runner")
    }

    /// A trigger engine that asks the shared utility layer, as the real one
    /// does when it feeds the layer, with one trigger counting its runs.
    private func makeMonitor(for gesture: TrackpadGesture, asksTheLayer: Bool = true) -> TrackpadMonitor {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        var trigger = Trigger(name: "Two fingers", input: .trackpadGesture(gesture))
        trigger.actions = [TriggerAction(actionType: .volumeUp)]
        monitor.registerTriggers([trigger])
        if asksTheLayer {
            monitor.utilityClaimsOverride = { asked in
                MainActor.assumeIsolated { TrackpadUtilityGestures.shared.claimsNow(asked) }
            }
        }
        return monitor
    }

    /// Fires `gesture` through the monitor's normal path; true when the trigger ran.
    private func triggerRuns(_ gesture: TrackpadGesture, on monitor: TrackpadMonitor) -> Bool {
        var runs = 0
        ActionExecutor.onActionExecuted = { _ in runs += 1 }
        monitor.fireGestureForTest(gesture)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        ActionExecutor.onActionExecuted = nil
        return runs > 0
    }

    /// What the pure rule says for this spot with the families as they stand.
    private func expected(_ gesture: TrackpadGesture, _ spot: Claim.Spot, topBand: Bool = false) -> Bool {
        Claim(spot: spot, topBand: topBand).claims(gesture, families: service.claimFamilies)
    }

    // MARK: The rule

    func testEachSpotClaimsOnlyTheGesturesItAnswers() {
        let on = Claim.Families(spaces: true, menuBar: true, dock: true, dockQuit: true, doublePinch: true,
                                missionControl: true)
        let dock = Claim(spot: .dock, topBand: false)
        for gesture in [TrackpadGesture.twoFingerTap, .twoFingerDoubleTap, .twoFingerLongTouch, .twoFingerSwipeUp,
                        .twoFingerSwipeDown, .twoFingerSwipeLeft, .twoFingerSwipeRight, .twoFingerSwipeFromLeftEdge,
                        .twoFingerPinchIn, .twoFingerPinchOut] {
            XCTAssertTrue(dock.claims(gesture, families: on), "Dock: \(gesture)")
            XCTAssertTrue(Claim(spot: .appMenu, topBand: true).claims(gesture, families: on), "app menu: \(gesture)")
        }
        for gesture in [TrackpadGesture.twoFingerRotateLeft, .twoFingerClick, .twoFingerTouchStart,
                        .releaseLastFingerRegardless, .threeFingerSwipeUp, .threeFingerTap, .twoFingerPressDragLeft] {
            XCTAssertFalse(dock.claims(gesture, families: on), "never the Dock's: \(gesture)")
            XCTAssertFalse(UtilityTouchClaim.covers(gesture), "\(gesture)")
        }
        let menuBar = Claim(spot: .menuBar, topBand: true)
        XCTAssertTrue(menuBar.claims(.twoFingerDoubleTap, families: on), "unsnap")
        XCTAssertTrue(menuBar.claims(.twoFingerSwipeDown, families: on), "minimize")
        XCTAssertTrue(menuBar.claims(.twoFingerLongTouch, families: on), "the switcher")
        XCTAssertFalse(menuBar.claims(.twoFingerPinchIn, families: on), "the menu bar does not pinch")
        XCTAssertFalse(menuBar.claims(.twoFingerPinchOut, families: on))
        let thumbnail = Claim(spot: .missionControl, topBand: false)
        XCTAssertTrue(thumbnail.claims(.twoFingerPinchIn, families: on), "close the window")
        XCTAssertTrue(thumbnail.claims(.twoFingerSwipeDown, families: on), "minimize it")
        XCTAssertTrue(thumbnail.claims(.twoFingerSwipeFromTopEdge, families: on), "a swipe down from the edge too")
        XCTAssertFalse(thumbnail.claims(.twoFingerSwipeUp, families: on))
        XCTAssertFalse(thumbnail.claims(.twoFingerTap, families: on))
        // A status item or menu title: only the Space swipe, in the top band.
        let statusItem = Claim(spot: .elsewhere, topBand: true)
        XCTAssertTrue(statusItem.claims(.twoFingerSwipeLeft, families: on))
        XCTAssertTrue(statusItem.claims(.twoFingerSwipeFromLeftEdge, families: on))
        XCTAssertFalse(statusItem.claims(.twoFingerSwipeDown, families: on))
        XCTAssertFalse(statusItem.claims(.twoFingerTap, families: on))
        XCTAssertFalse(Claim(spot: .elsewhere, topBand: false).claims(.twoFingerSwipeLeft, families: on), "elsewhere: nothing")
    }

    func testWithTheirFamiliesOffNoSpotClaimsAnything() {
        let off = Claim.Families()
        let all = TrackpadGesture.allCases
        for spot in [Claim.Spot.menuBar, .appMenu, .dock, .missionControl, .elsewhere] {
            for topBand in [false, true] {
                XCTAssertFalse(all.contains { Claim(spot: spot, topBand: topBand).claims($0, families: off) }, "\(spot)")
            }
        }
        XCTAssertFalse(all.contains { UtilityTouchClaim.mayClaim($0, families: off) }, "nothing is looked up")
        // Dock quit alone: only the pinch in is the Dock's.
        let quitOnly = Claim.Families(dockQuit: true)
        let dock = Claim(spot: .dock, topBand: false)
        XCTAssertTrue(dock.claims(.twoFingerPinchIn, families: quitOnly))
        XCTAssertFalse(dock.claims(.twoFingerPinchOut, families: quitOnly))
        XCTAssertFalse(dock.claims(.twoFingerSwipeUp, families: quitOnly))
        XCTAssertFalse(dock.claims(.twoFingerDoubleTap, families: quitOnly))
        // Pinch twice without the quit: the pinch in still waits for its second half.
        XCTAssertTrue(dock.claims(.twoFingerPinchIn, families: Claim.Families(dock: true, doublePinch: true)))
        // The Space swipe alone: sideways swipes in the top band, nothing else.
        let spaces = Claim.Families(spaces: true)
        XCTAssertTrue(Claim(spot: .menuBar, topBand: true).claims(.twoFingerSwipeRight, families: spaces))
        XCTAssertFalse(Claim(spot: .menuBar, topBand: true).claims(.twoFingerSwipeUp, families: spaces))
        XCTAssertFalse(Claim(spot: .menuBar, topBand: true).claims(.twoFingerDoubleTap, families: spaces))
    }

    // MARK: Through the trigger engine

    /// A pinch on a Dock icon: the trigger engine recognises it first and
    /// leaves it to the Dock; the Dock's own pinch then runs alone, after
    /// the lift; nothing on screen was asked to change.
    func testATriggerStaysQuietOnADockTouchAndTheDockActsAlone() throws {
        let app = try someOtherApp()
        dockTarget = app
        let monitor = makeMonitor(for: .twoFingerPinchIn)
        defer { monitor.unregisterAll() }
        let dockClaims = expected(.twoFingerPinchIn, .dock)

        frame(two(spread: 0.30), after: 1)
        XCTAssertEqual(triggerRuns(.twoFingerPinchIn, on: monitor), !dockClaims,
                       "the touch landed on a Dock icon: its pinch is the Dock's")
        frame(two(spread: 0.12), after: 0.05)
        frame([], after: 0.05)
        XCTAssertEqual(service.claimsNow(.twoFingerPinchIn), dockClaims, "still the Dock's as the fingers lift")
        let pending = later
        later.removeAll()
        pending.forEach { $0() }
        XCTAssertEqual(quits, service.dockQuitEnabled ? [app.processIdentifier] : [], "the Dock's pinch ran by itself")
        XCTAssertEqual(desktop.changes, [])
    }

    /// Anywhere the utility gestures have nothing (an ordinary window, the
    /// desktop), the trigger runs as before.
    func testATriggerRunsOnATouchNoUtilityGestureTook() {
        dockTarget = nil
        inTopBand = false
        let pinch = makeMonitor(for: .twoFingerPinchIn)
        let swipe = makeMonitor(for: .twoFingerSwipeDown)
        defer { pinch.unregisterAll(); swipe.unregisterAll() }
        frame(two(), after: 1)
        XCTAssertFalse(service.claimsNow(.twoFingerPinchIn))
        XCTAssertTrue(triggerRuns(.twoFingerPinchIn, on: pinch))
        XCTAssertTrue(triggerRuns(.twoFingerSwipeDown, on: swipe))
        frame([], after: 0.05)
        XCTAssertEqual(desktop.changes, [])
    }

    /// The claim ends with the touch: a tap on a Dock icon is the Dock's as
    /// it lifts (the trigger engine fires taps on the lift), not once the
    /// lift's grace is over, and not for the next touch elsewhere.
    func testTheClaimEndsWithTheTouch() throws {
        dockTarget = try someOtherApp()
        let monitor = makeMonitor(for: .twoFingerTap)
        defer { monitor.unregisterAll() }
        let dockClaims = expected(.twoFingerTap, .dock)

        frame(two(), after: 1)
        frame([], after: 0.08)
        XCTAssertEqual(triggerRuns(.twoFingerTap, on: monitor), !dockClaims, "the lifted tap is the Dock's")
        uptime += TrackpadUtilityGestures.claimLiftGrace + 0.5
        XCTAssertFalse(service.claimsNow(.twoFingerTap), "released once the lift's grace is over")
        XCTAssertTrue(triggerRuns(.twoFingerTap, on: monitor))

        // Lifted on the Dock, then two fingers land elsewhere: that touch is the trigger's.
        frame(two(), after: 1)
        frame([], after: 0.08)
        XCTAssertEqual(service.claimsNow(.twoFingerTap), dockClaims)
        dockTarget = nil
        frame(two(), after: 1)
        XCTAssertFalse(service.claimsNow(.twoFingerTap), "the next touch decides afresh")
        XCTAssertTrue(triggerRuns(.twoFingerTap, on: monitor))
        frame([], after: 0.3)
        XCTAssertEqual(desktop.changes, [])
    }

    /// The menu bar claims what it answers; a pinch there stays the trigger's.
    /// Over a status item only the Space swipe is AOM's.
    func testOnTheMenuBarOnlyItsOwnGesturesAreClaimed() {
        inTopBand = true
        spot = .empty
        let pinch = makeMonitor(for: .twoFingerPinchIn)
        defer { pinch.unregisterAll() }
        frame(two(), after: 1)
        XCTAssertEqual(service.claimsNow(.twoFingerSwipeLeft), expected(.twoFingerSwipeLeft, .menuBar, topBand: true))
        XCTAssertEqual(service.claimsNow(.twoFingerSwipeDown), expected(.twoFingerSwipeDown, .menuBar, topBand: true))
        XCTAssertFalse(service.claimsNow(.twoFingerPinchIn))
        XCTAssertTrue(triggerRuns(.twoFingerPinchIn, on: pinch), "the menu bar does not pinch")
        frame([], after: 0.3)

        spot = .statusItem
        frame(two(), after: 1)
        XCTAssertEqual(service.claimsNow(.twoFingerSwipeRight), service.spacesEnabled, "the Space swipe")
        XCTAssertFalse(service.claimsNow(.twoFingerSwipeDown), "a status item's own")
        frame([], after: 0.3)
        XCTAssertEqual(desktop.changes, [])
    }

    /// A pause lets the touch go, as it does for the utility gestures.
    func testAPauseReleasesTheClaim() throws {
        dockTarget = try someOtherApp()
        frame(two(), after: 1)
        XCTAssertEqual(service.claimsNow(.twoFingerSwipeUp), expected(.twoFingerSwipeUp, .dock))
        allowed = false
        frame(two())
        XCTAssertFalse(service.claimsNow(.twoFingerSwipeUp))
        allowed = true
        frame([], after: 0.3)
    }

    /// A trigger engine that never fed the utility layer (tests, the event
    /// path without the raw stream) never defers to it: existing behavior.
    func testAMonitorThatDoesNotFeedTheLayerNeverDefersToIt() throws {
        dockTarget = try someOtherApp()
        let plain = makeMonitor(for: .twoFingerPinchIn, asksTheLayer: false)
        defer { plain.unregisterAll() }
        frame(two(spread: 0.30), after: 1)
        XCTAssertEqual(service.claimsNow(.twoFingerPinchIn), expected(.twoFingerPinchIn, .dock), "the layer would claim it")
        XCTAssertTrue(triggerRuns(.twoFingerPinchIn, on: plain))
        frame([], after: 0.3)
    }
}
