import XCTest
@testable import AllOfMacOS

/// A stand-in for an app asked to quit from the Dock. It records every
/// request; `quitsOnRequest == false` models an app showing "Save changes?".
private final class FakeQuitTarget: PoliteQuitTarget {
    let localizedName: String? = "Draft Editor"
    var quitsOnRequest: Bool
    private(set) var terminateRequests = 0
    private(set) var forceTerminateRequests = 0
    private(set) var isTerminated = false
    init(quitsOnRequest: Bool) { self.quitsOnRequest = quitsOnRequest }
    func terminate() -> Bool {
        terminateRequests += 1
        if quitsOnRequest { isTerminated = true }
        return true
    }
    /// Present so a regression that reaches for force termination would be
    /// counted rather than silently allowed.
    func forceTerminate() -> Bool { forceTerminateRequests += 1; isTerminated = true; return true }
}

/// Audit 2026-10-28 F01 (no automatic force termination) and F04 (one pause
/// check for every input layer), plus the multi-trackpad part of R02.
@MainActor
final class AutomationGateTests: XCTestCase {
    private let service = TrackpadUtilityGestures.shared

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AutomationGate.masterSwitchKey)
        UserDefaults.standard.removeObject(forKey: TrackpadUtilityGestures.spacesEnabledKey)
        UserDefaults.standard.removeObject(forKey: TrackpadUtilityGestures.dockQuitEnabledKey)
        TriggerSuppression.shared.resume()
        service.cursorLocation = { CGPoint(x: 700, y: 895) }
        service.cursorInTopBand = { _ in true }
        // The real window-server lookup would depend on the host's screen.
        service.windowUnderPointer = { _ in nil }
        service.isScreenLocked = { false }
        service.isAllowed = { AutomationGate.allows(.trackpad) }
        // Keep the Dock pinch out of the way: its AX lookup is real.
        UserDefaults.standard.set(false, forKey: TrackpadUtilityGestures.dockQuitEnabledKey)
        service.observe(points: [], timestamp: 0)
    }

    override func tearDown() {
        service.observe(points: [], timestamp: 0)
        service.switchSpace = { _ in }
        service.quitApplication = { TrackpadUtilityGestures.politeQuit($0) }
        service.dockApp = { TrackpadUtilityGestures.shared.dockAppUnderCursor() }
        service.cursorLocation = { NSEvent.mouseLocation }
        service.cursorInTopBand = { TrackpadUtilityGestures.cursorInTopBand($0) }
        service.windowUnderPointer = { DockLookup.windowUnder($0) }
        service.isScreenLocked = { ScreenLock.isLocked }
        service.isAllowed = { AutomationGate.allows(.trackpad) }
        UserDefaults.standard.removeObject(forKey: AutomationGate.masterSwitchKey)
        UserDefaults.standard.removeObject(forKey: TrackpadUtilityGestures.spacesEnabledKey)
        UserDefaults.standard.removeObject(forKey: TrackpadUtilityGestures.dockQuitEnabledKey)
        TriggerSuppression.shared.resume()
        super.tearDown()
    }

    private func pair(_ left: Float, _ right: Float, y: Float = 0.5) -> [TouchPoint] {
        [TouchPoint(id: 0, x: left, y: y, size: 0.1), TouchPoint(id: 1, x: right, y: y, size: 0.1)]
    }

    /// The shared service debounces fires by timestamp, so every swipe in
    /// this suite runs later than the one before, whatever the test order.
    private static var clock: Double = 1_000

    /// The audit's GateProbe: a 0.2 swipe in the top band.
    private func swipe(device: UInt64 = 0) {
        Self.clock += 10
        let t = Self.clock
        service.observe(points: pair(0.3, 0.5), timestamp: t, device: device)
        service.observe(points: pair(0.5, 0.7), timestamp: t + 0.5, device: device)
        service.observe(points: [], timestamp: t + 0.6, device: device)
    }

    // MARK: F04

    func testSpaceSwipeDoesNothingWhileAutomationIsSwitchedOff() {
        var fired = 0
        service.switchSpace = { _ in fired += 1 }
        UserDefaults.standard.set(false, forKey: AutomationGate.masterSwitchKey)
        swipe()
        XCTAssertEqual(fired, 0, "a paused AOM must not switch Spaces (GateProbe fired 1)")
        XCTAssertFalse(service.anyLayerEnabled, "and it releases the trackpad stream")
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
        swipe()
        XCTAssertEqual(fired, 1, "switching AOM back on restores the gesture")
        XCTAssertTrue(service.anyLayerEnabled)
    }

    func testSpaceSwipeHonoursTheRuntimePause() {
        var fired = 0
        service.switchSpace = { _ in fired += 1 }
        TriggerSuppression.shared.pauseUntilResumed()
        swipe()
        XCTAssertEqual(fired, 0, "Pause until resumed covers the gesture layers too")
        TriggerSuppression.shared.resume()
        swipe()
        XCTAssertEqual(fired, 1)
    }

    /// A swipe that starts while AOM is on and is paused before it completes
    /// fires nothing, even after AOM is back on (the audit's mid-gesture case).
    func testSpaceSwipeStopsWhenAOMIsPausedMidGesture() {
        var fired = 0
        service.switchSpace = { _ in fired += 1 }
        Self.clock += 10
        let t = Self.clock
        service.observe(points: pair(0.3, 0.5), timestamp: t)
        UserDefaults.standard.set(false, forKey: AutomationGate.masterSwitchKey)
        service.observe(points: pair(0.5, 0.7), timestamp: t + 0.5)
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
        service.observe(points: pair(0.55, 0.75), timestamp: t + 0.55)
        service.observe(points: [], timestamp: t + 0.6)
        XCTAssertEqual(fired, 0, "the paused frame reset the gesture; its remains do not fire after resuming")
    }

    /// Dock pinch to quit, counted through the quit seam. The Dock lookup
    /// returns the test process itself, which the counting seam never quits.
    func testDockPinchQuitsNothingWhileAOMIsOffPausedOrPausedMidGesture() {
        var quits = 0
        service.quitApplication = { _ in quits += 1 }
        service.dockApp = { NSRunningApplication.current }
        UserDefaults.standard.set(true, forKey: TrackpadUtilityGestures.dockQuitEnabledKey)
        func pinch(pauseHalfway: Bool = false) {
            Self.clock += 10
            let t = Self.clock
            service.observe(points: pair(0.3, 0.6), timestamp: t)          // spread 0.30
            if pauseHalfway { UserDefaults.standard.set(false, forKey: AutomationGate.masterSwitchKey) }
            service.observe(points: pair(0.4, 0.5), timestamp: t + 0.3)    // spread 0.10
            service.observe(points: [], timestamp: t + 0.4)
            UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
        }
        UserDefaults.standard.set(false, forKey: AutomationGate.masterSwitchKey)
        Self.clock += 10
        service.observe(points: pair(0.3, 0.6), timestamp: Self.clock)
        service.observe(points: pair(0.4, 0.5), timestamp: Self.clock + 0.3)
        service.observe(points: [], timestamp: Self.clock + 0.4)
        XCTAssertEqual(quits, 0, "switched off")
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
        TriggerSuppression.shared.pauseUntilResumed()
        pinch()
        XCTAssertEqual(quits, 0, "paused until resumed")
        TriggerSuppression.shared.resume()
        pinch(pauseHalfway: true)
        XCTAssertEqual(quits, 0, "paused mid-pinch")
        pinch()
        XCTAssertEqual(quits, 1, "on again: one pinch, one polite quit request")
    }

    /// Registered trackpad gestures run through `TrackpadMonitor`, which
    /// also has to keep quiet while AOM is switched off — including a
    /// gesture whose fingers were already down when it was switched off.
    func testRegisteredTrackpadGesturesFireNothingWhileAOMIsOff() {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false)
        var trigger = Trigger(name: "Four", input: .trackpadGesture(.fourFingerTap))
        trigger.actions = [TriggerAction(actionType: .volumeUp)]
        monitor.registerTriggers([trigger])
        var count = 0
        ActionExecutor.onActionExecuted = { _ in count += 1 }
        defer { monitor.unregisterAll(); ActionExecutor.onActionExecuted = nil }
        let fingers = (0..<4).map { TouchPoint(id: $0, x: 0.2 + Float($0) * 0.15, y: 0.5, size: 0.1) }
        func tap(at t: Double, switchOffHalfway: Bool = false) {
            monitor.processTouchFrame(fingers, count: 4, timestamp: t, pressedButtons: 0, deviceID: 1)
            if switchOffHalfway { UserDefaults.standard.set(false, forKey: AutomationGate.masterSwitchKey) }
            monitor.processTouchFrame([], count: 0, timestamp: t + 0.1, pressedButtons: 0, deviceID: 1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        UserDefaults.standard.set(false, forKey: AutomationGate.masterSwitchKey)
        tap(at: 1)
        XCTAssertEqual(count, 0, "switched off")
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
        tap(at: 3, switchOffHalfway: true)
        XCTAssertEqual(count, 0, "switched off with the fingers down")
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
        tap(at: 5)
        XCTAssertEqual(count, 1, "on: the same tap runs its action")
    }

    func testTheGateCombinesTheMasterSwitchAndEverySuppressionRule() throws {
        let suite = "AOMAutomationGateTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let suppression = TriggerSuppression(defaults: defaults, frontmostBundleID: { "test.front" },
                                             heldModifiers: { 0 }, secondsSinceLastKeyDown: { .infinity },
                                             schedulesExpiry: false)
        XCTAssertTrue(AutomationGate.allows(.trackpad, suppression: suppression, defaults: defaults), "on by default")
        defaults.set(false, forKey: AutomationGate.masterSwitchKey)
        XCTAssertFalse(AutomationGate.isOn(defaults))
        for kind in [TriggerSuppressionKind.trackpad, .keyboard, .mouse, .drawing, .system] {
            XCTAssertFalse(AutomationGate.allows(kind, suppression: suppression, defaults: defaults), "\(kind) is paused by the master switch")
        }
        defaults.set(true, forKey: AutomationGate.masterSwitchKey)
        suppression.pauseApp("test.front")
        XCTAssertFalse(AutomationGate.allows(.trackpad, suppression: suppression, defaults: defaults), "per-app pause")
        suppression.resume()
        XCTAssertTrue(AutomationGate.allows(.trackpad, suppression: suppression, defaults: defaults))
    }

    // MARK: R02 — several trackpads

    func testASecondTrackpadCannotEndOrBendAGestureInProgress() {
        var fired: [Bool] = []
        service.switchSpace = { fired.append($0) }
        // Two fingers start on the built-in trackpad (device 1)…
        service.observe(points: pair(0.3, 0.5), timestamp: 10.00, device: 1)
        // …while a resting thumb on a Magic Trackpad (device 2) reports one finger.
        service.observe(points: [TouchPoint(id: 9, x: 0.9, y: 0.9, size: 0.1)], timestamp: 10.01, device: 2)
        service.observe(points: pair(0.4, 0.6), timestamp: 10.02, device: 1)
        service.observe(points: [TouchPoint(id: 9, x: 0.9, y: 0.9, size: 0.1)], timestamp: 10.03, device: 2)
        service.observe(points: pair(0.5, 0.7), timestamp: 10.04, device: 1)
        XCTAssertEqual(fired, [], "armed: the Space switches when device 1's fingers lift (3.3.2)")
        service.observe(points: [TouchPoint(id: 9, x: 0.9, y: 0.9, size: 0.1)], timestamp: 10.05, device: 2)
        XCTAssertEqual(fired, [], "device 2's frame is no lift of this gesture")
        service.observe(points: [], timestamp: 10.06, device: 1)
        XCTAssertEqual(fired, [true], "the swipe on device 1 fires once despite device 2's frames")
    }

    func testAQuietTrackpadHandsTheGestureOver() {
        var fired = 0
        service.switchSpace = { _ in fired += 1 }
        service.observe(points: pair(0.3, 0.5), timestamp: Self.clock + 9, device: 1)   // device 1 goes silent
        swipe(device: 2)                                                                 // device 2 swipes a second later
        XCTAssertEqual(fired, 1)
    }

    // MARK: F01

    func testDockQuitNeverForcesAnAppThatIsStillAskingToSave() {
        let app = FakeQuitTarget(quitsOnRequest: false)
        var reports: [String] = []
        var later: [() -> Void] = []
        TrackpadUtilityGestures.politeQuit(app, gracePeriod: 1.5, report: { title, detail in reports.append(title + " — " + detail) },
                                           after: { _, work in later.append(work) })
        XCTAssertEqual(app.terminateRequests, 1, "one polite quit request")
        later.forEach { $0() }     // the grace period elapses; the app is still open
        XCTAssertEqual(app.forceTerminateRequests, 0, "never escalated (3.3.0 force-terminated after 1.5 s)")
        XCTAssertFalse(app.isTerminated, "the unsaved document survives")
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].contains("Still Open"), reports[0])
        XCTAssertTrue(reports[0].contains("never forces"), "the HUD says why nothing happened")
    }

    func testDockQuitStaysQuietWhenTheAppQuits() {
        let app = FakeQuitTarget(quitsOnRequest: true)
        var reports = 0
        TrackpadUtilityGestures.politeQuit(app, gracePeriod: 1.5, report: { _, _ in reports += 1 },
                                           after: { _, work in work() })
        XCTAssertEqual(app.terminateRequests, 1)
        XCTAssertEqual(reports, 0)
        XCTAssertEqual(app.forceTerminateRequests, 0)
    }

    /// Source guard for F01: the only force quit AOM has is the explicit,
    /// confirmed Force Quit Application action (SIGKILL after a dialog).
    /// No code path may call `forceTerminate()` on its own.
    func testNoCodePathForceTerminatesAnApplication() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AllOfMacOS")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100)
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains("forceTerminate(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "automatic force termination is not allowed")
    }
}
