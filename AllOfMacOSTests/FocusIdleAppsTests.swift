import XCTest
@testable import AllOfMacOS

/// Idle time from activation events, hide and quit decisions with every
/// exclusion, memory-pressure ordering, and the controller acting on a fake
/// system (no real app is hidden or quit).
@MainActor
final class FocusIdleAppsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func app(_ pid: pid_t, _ id: String, active: Bool = false, hidden: Bool = false) -> FocusRunningApp {
        FocusRunningApp(pid: pid, bundleID: id, name: id.components(separatedBy: ".").last ?? id, isHidden: hidden, isActive: active)
    }

    private func rule(_ id: String, hide: Int? = 10, quit: Int? = 30, pressure: Bool = true, on: Bool = true) -> FocusIdleRule {
        FocusIdleRule(bundleID: id, name: id, hideAfterMinutes: hide, quitAfterMinutes: quit, quitsUnderMemoryPressure: pressure, isEnabled: on)
    }

    // MARK: Idle tracking

    func testAnAppIsIdleFromTheMomentItStopsBeingInFront() {
        var tracker = FocusIdleTracker(startedAt: t0, frontmost: "com.example.editor")
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.editor", at: at(10)), 0, "the front app is never idle")
        tracker.activated("com.example.chat", at: at(10))
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.editor", at: at(25)), 15 * 60)
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.chat", at: at(25)), 0)
        tracker.activated("com.example.editor", at: at(30))
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.chat", at: at(42)), 12 * 60)
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.editor", at: at(42)), 0)
    }

    func testAppsNotSeenInFrontCountFromWhenTrackingBeganOrTheyLaunched() {
        var tracker = FocusIdleTracker(startedAt: t0)
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.mail", at: at(20)), 20 * 60, "never longer than AOM could see")
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.mail", launchedAt: at(5), at: at(20)), 15 * 60)
        tracker.launched("com.example.notes", at: at(8))
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.notes", at: at(20)), 12 * 60, "a launch counts as use")
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.old", launchedAt: t0.addingTimeInterval(-86_400), at: at(1)), 60)
        tracker.activated("com.example.notes", at: at(21))
        tracker.terminated("com.example.notes")
        XCTAssertNil(tracker.frontmost)
        XCTAssertEqual(tracker.idleSeconds(for: "com.example.notes", at: at(22)), 22 * 60, "a quit app starts over")
    }

    // MARK: Decisions

    private var openContext: FocusIdleContext { FocusIdleContext(now: at(60), audio: FocusAudioActivity()) }

    func testThresholdsHideThenQuit() {
        let chat = app(20, "com.example.chat")
        let r = rule("com.example.chat", hide: 10, quit: 30)
        var context = openContext
        XCTAssertNil(FocusIdlePolicy.decide(app: chat, rule: r, idleSeconds: 5 * 60, context: context).action)
        let hide = FocusIdlePolicy.decide(app: chat, rule: r, idleSeconds: 12 * 60, context: context)
        XCTAssertEqual(hide.action, .hide)
        XCTAssertEqual(hide.nextThreshold, context.now.addingTimeInterval(18 * 60), "then the quit threshold")
        XCTAssertNil(FocusIdlePolicy.decide(app: app(20, "com.example.chat", hidden: true), rule: r, idleSeconds: 12 * 60,
                                            context: context).action, "a hidden app is not hidden again")
        XCTAssertEqual(FocusIdlePolicy.decide(app: chat, rule: r, idleSeconds: 31 * 60, context: context).action, .quit)
        context.now = at(61)
        let hideOnly = rule("com.example.chat", hide: 10, quit: nil)
        XCTAssertEqual(FocusIdlePolicy.decide(app: chat, rule: hideOnly, idleSeconds: 999 * 60, context: context).action, .hide)
        XCTAssertNil(FocusIdlePolicy.decide(app: app(20, "com.example.chat", hidden: true), rule: hideOnly, idleSeconds: 999 * 60,
                                            context: context).action, "a hide-only rule never quits")
    }

    func testEveryExclusionHoldsTheActionBack() {
        let r = rule("com.example.chat", hide: 1, quit: 1)
        let idle: TimeInterval = 3600
        func exclusion(_ app: FocusRunningApp, _ change: (inout FocusIdleContext) -> Void = { _ in },
                       rule: FocusIdleRule? = nil) -> FocusIdleExclusion? {
            var context = openContext
            change(&context)
            let decision = FocusIdlePolicy.decide(app: app, rule: rule ?? r, idleSeconds: idle, context: context)
            XCTAssertTrue(decision.exclusion == nil || decision.action == nil, "an excluded app never gets an action")
            return decision.exclusion
        }
        let chat = app(20, "com.example.chat")
        XCTAssertEqual(exclusion(app(1, "com.apple.finder")), .finder)
        XCTAssertEqual(exclusion(app(2, "com.kyw.allofmacos")), .aom)
        XCTAssertEqual(exclusion(app(3, "com.kyw.allofmacos.preview")), .aom)
        XCTAssertEqual(exclusion(app(20, "com.example.chat", active: true)), .frontmost)
        XCTAssertEqual(exclusion(chat) { $0.audio = FocusAudioActivity(playing: [20]) }, .playingAudio)
        XCTAssertEqual(exclusion(chat) { $0.audio = FocusAudioActivity(recording: [20]) }, .recording)
        XCTAssertEqual(exclusion(chat) { $0.audio = FocusAudioActivity(playing: [20], recording: [20]) }, .recording)
        XCTAssertEqual(exclusion(chat) { $0.audio = nil }, .audioUnknown, "without audio state nothing is touched")
        XCTAssertEqual(exclusion(chat) { $0.pausedApps = ["com.example.chat"] }, .pausedForApp)
        XCTAssertEqual(exclusion(chat) { $0.aomPaused = true }, .aomPaused)
        XCTAssertEqual(exclusion(chat) { $0.waitingToQuit = [20] }, .waitingToQuit)
        XCTAssertEqual(exclusion(chat, rule: rule("com.example.chat", on: false)), .ruleOff)
        XCTAssertNil(exclusion(chat))
        XCTAssertEqual(FocusIdlePolicy.decide(app: chat, rule: r, idleSeconds: idle, context: openContext).action, .quit)
        // Someone else playing audio does not protect this app.
        XCTAssertNil(exclusion(chat) { $0.audio = FocusAudioActivity(playing: [99], recording: [98]) })
        XCTAssertTrue(FocusIdlePolicy.isProtected("com.apple.finder"))
        XCTAssertTrue(FocusIdlePolicy.isProtected("com.kyw.allofmacos"))
        XCTAssertFalse(FocusIdlePolicy.isProtected("com.example.chat"))
    }

    func testMemoryPressureQuitsTheIdlestListedAppsFirst() {
        let apps = [app(1, "com.example.a"), app(2, "com.example.b"), app(3, "com.example.c"), app(4, "com.example.d"),
                    app(5, "com.example.e", active: true), app(6, "com.example.f"), app(7, "com.example.unlisted")]
        let idle: [pid_t: TimeInterval] = [1: 20 * 60, 2: 90 * 60, 3: 45 * 60, 4: 45 * 60, 5: 300 * 60, 6: 2 * 60, 7: 999 * 60]
        let rules = [rule("com.example.a"), rule("com.example.b"), rule("com.example.c"), rule("com.example.d"),
                     rule("com.example.e"), rule("com.example.f"), rule("com.example.g")]
        var context = openContext
        context.audio = FocusAudioActivity(playing: [3])
        let order = FocusIdlePolicy.pressureCandidates(apps: apps, rules: rules, idle: { idle[$0.pid] ?? 0 },
                                                       footprints: [4: 800 << 20], minimumIdle: 5 * 60, context: context)
        XCTAssertEqual(order.map(\.app.pid), [2, 4, 1],
                       "idlest first; c plays audio, e is in front, f was used 2 min ago, the unlisted app is never touched")
        let noPressureRule = rules.map { r -> FocusIdleRule in
            var copy = r
            if copy.bundleID == "com.example.b" { copy.quitsUnderMemoryPressure = false }
            return copy
        }
        XCTAssertEqual(FocusIdlePolicy.pressureCandidates(apps: apps, rules: noPressureRule, idle: { idle[$0.pid] ?? 0 },
                                                          footprints: [:], minimumIdle: 5 * 60, context: context).first?.app.pid,
                       4, "a rule can opt out of pressure quits")
    }

    func testQuitNowIgnoresTheGlobalPauseButNothingElse() {
        let apps = [app(1, "com.example.a"), app(2, "com.example.b", active: true), app(3, "com.example.c")]
        let rules = [rule("com.example.a"), rule("com.example.b"), rule("com.example.c", hide: 5, quit: nil, pressure: false)]
        var context = openContext
        context.aomPaused = true
        let candidates = FocusIdlePolicy.quitNowCandidates(apps: apps, rules: rules, idle: { _ in 60 }, context: context)
        XCTAssertEqual(candidates.map(\.app.pid), [1], "the front app and a hide-only rule are left alone")
        context.pausedApps = ["com.example.a"]
        XCTAssertTrue(FocusIdlePolicy.quitNowCandidates(apps: apps, rules: rules, idle: { _ in 60 }, context: context).isEmpty)
    }

    // MARK: Controller

    private var world: FocusTestWorld!

    override func setUp() async throws { world = FocusTestWorld() }
    override func tearDown() async throws { world.cleanUp(); world = nil }

    private func makeController(rules: [FocusIdleRule]) -> FocusIdleAppsController {
        world.lists.lists.idleRules = rules
        world.settings.settings.idleAppsEnabled = true
        let controller = world.makeIdleApps()
        controller.refresh()
        return controller
    }

    func testTheControllerHidesAndQuitsByRuleAndLogsWhatFreedMemory() {
        world.system.apps = [app(10, "com.example.editor", active: true), app(20, "com.example.chat"), app(30, "com.example.mail")]
        world.system.footprints = [20: 400 << 20]
        let controller = makeController(rules: [rule("com.example.chat", hide: 10, quit: 30), rule("com.example.mail", hide: 5, quit: nil)])
        XCTAssertTrue(controller.isActive)
        world.clock.advance(6 * 60)
        controller.evaluate()
        XCTAssertEqual(world.system.hidden, [30], "mail hides after 5 minutes")
        world.clock.advance(5 * 60)
        controller.evaluate()
        XCTAssertEqual(world.system.hidden, [30, 20], "chat after 10")
        XCTAssertTrue(world.system.terminated.isEmpty)
        world.clock.advance(20 * 60)
        controller.evaluate()
        XCTAssertEqual(world.system.terminated, [20], "chat quits after 30 minutes, the normal way")
        world.system.finishQuitting(pid: 20)
        controller.appTerminated(bundleID: "com.example.chat", pid: 20)
        let quit = world.activity.items.first
        XCTAssertEqual(quit?.kind, .quit)
        XCTAssertEqual(quit?.memoryBytes, 400 << 20)
        XCTAssertEqual(controller.freedToday, 400 << 20)
        XCTAssertEqual(world.activity.items.filter { $0.kind == .hid }.count, 2)
    }

    func testUsingAnAppResetsItsIdleTime() {
        world.system.apps = [app(10, "com.example.editor", active: true), app(20, "com.example.chat")]
        let controller = makeController(rules: [rule("com.example.chat", hide: 10, quit: nil)])
        world.clock.advance(9 * 60)
        controller.appActivated(bundleID: "com.example.chat", pid: 20)
        world.clock.advance(60)
        controller.appActivated(bundleID: "com.example.editor", pid: 10)
        world.clock.advance(5 * 60)
        controller.evaluate()
        XCTAssertTrue(world.system.hidden.isEmpty, "only 5 minutes since chat was last in front")
        XCTAssertEqual(controller.rows(now: world.clock.now).first?.idleSeconds, 5 * 60)
    }

    func testNothingHappensWhilePausedAsleepOrJustAfterWaking() {
        world.system.apps = [app(10, "com.example.editor", active: true), app(20, "com.example.chat")]
        let controller = makeController(rules: [rule("com.example.chat", hide: 1, quit: 2)])
        world.clock.advance(10 * 60)
        world.system.paused = true
        controller.evaluate()
        XCTAssertTrue(world.system.hidden.isEmpty && world.system.terminated.isEmpty, "Pause AOM")
        world.system.paused = false
        controller.wentAway()
        controller.evaluate()
        XCTAssertTrue(world.system.terminated.isEmpty, "the screen is asleep")
        controller.cameBack()
        controller.evaluate()
        XCTAssertTrue(world.system.terminated.isEmpty, "two minutes back belong to the person")
        world.clock.advance(FocusIdleAppsController.wakeGrace + 1)
        controller.evaluate()
        XCTAssertEqual(world.system.terminated, [20])
    }

    func testAnAppStillOpenAfterAQuitIsAskedOnceAndReportedOnce() {
        world.system.apps = [app(10, "com.example.editor", active: true), app(20, "com.example.pages")]
        let controller = makeController(rules: [rule("com.example.pages", hide: nil, quit: 1)])
        world.clock.advance(2 * 60)
        controller.evaluate()
        XCTAssertEqual(world.system.terminated, [20])
        world.clock.advance(30)
        controller.evaluate()
        XCTAssertEqual(world.system.terminated, [20], "never asked twice while it decides")
        world.clock.advance(60)
        controller.evaluate()
        XCTAssertEqual(world.activity.items.first?.kind, .quitDeclined, "probably asking to save")
        controller.evaluate()
        XCTAssertEqual(world.activity.items.filter { $0.kind == .quitDeclined }.count, 1)
        XCTAssertEqual(world.system.terminated, [20], "and left alone until someone uses it")
    }

    func testTheFeatureOffHoldsNothing() {
        world.system.apps = [app(10, "com.example.editor", active: true), app(20, "com.example.chat")]
        world.lists.lists.idleRules = [rule("com.example.chat", hide: 1, quit: 1)]
        let controller = world.makeIdleApps()
        controller.refresh()
        XCTAssertFalse(controller.isActive, "off by default")
        world.clock.advance(3600)
        controller.evaluate()
        XCTAssertTrue(world.system.hidden.isEmpty && world.system.terminated.isEmpty)
        XCTAssertNil(controller.rows(now: world.clock.now).first?.idleSeconds, "no idle time without watching")
    }

    func testMemoryPressureQuitsOneAtATimeUntilNormal() {
        world.system.apps = [app(10, "com.example.editor", active: true), app(20, "com.example.a"), app(30, "com.example.b"),
                             app(40, "com.example.c")]
        world.settings.settings.memoryPressureEnabled = true
        let controller = makeController(rules: [rule("com.example.a", hide: nil, quit: nil), rule("com.example.b", hide: nil, quit: nil),
                                                rule("com.example.c", hide: nil, quit: nil)])
        controller.appActivated(bundleID: "com.example.c", pid: 40)
        world.clock.advance(60)
        controller.appActivated(bundleID: "com.example.editor", pid: 10)
        world.clock.advance(10 * 60)
        // Warning now, still warning after the first quit, normal after the second.
        world.system.pressureLevels = [.warning, .normal]
        controller.pressureChanged(.warning)
        XCTAssertEqual(world.system.terminated, [20, 30], "a and b were idle longest; c was used 10 minutes ago")
        XCTAssertEqual(controller.pressure, .normal)
        world.system.terminated.removeAll()
        controller.pressureChanged(.critical)
        XCTAssertTrue(world.system.terminated.isEmpty, "a cooldown follows an episode")
    }

    func testRowsShowLiveStateAndWhatHappensNext() {
        world.system.apps = [app(10, "com.example.editor", active: true), app(20, "com.example.chat")]
        world.system.audio = FocusAudioActivity(playing: [])
        let controller = makeController(rules: [rule("com.example.chat", hide: 10, quit: 30), rule("com.example.closed")])
        world.clock.advance(4 * 60)
        let rows = controller.rows(now: world.clock.now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].nextAction, .hide)
        XCTAssertEqual(rows[0].statusLine(now: world.clock.now), "Idle 4 min · hides in 6 min")
        XCTAssertEqual(rows[1].statusLine(now: world.clock.now), "Not open")
        world.system.audio = FocusAudioActivity(playing: [20])
        XCTAssertEqual(controller.rows(now: world.clock.now)[0].statusLine(now: world.clock.now), "Playing audio")
    }

    func testRulesAreNeverMadeForFinderOrAOM() {
        XCTAssertNil(world.lists.addIdleRule(for: FocusAppRef(bundleID: "com.apple.finder", name: "Finder")))
        XCTAssertNil(world.lists.addIdleRule(for: FocusAppRef(bundleID: "com.kyw.allofmacos", name: "All of MacOS")))
        XCTAssertNotNil(world.lists.addIdleRule(for: FocusAppRef(bundleID: "com.example.chat", name: "Chat")))
        XCTAssertNil(world.lists.addIdleRule(for: FocusAppRef(bundleID: "com.example.chat", name: "Chat")), "one rule per app")
        world.lists.addDistraction(FocusAppRef(bundleID: "com.apple.finder", name: "Finder"))
        XCTAssertTrue(world.lists.lists.distractingApps.isEmpty)
    }

    func testFootprintsIncludeChildProcesses() {
        // 100 is the app; 101 and 102 its helpers; 103 a helper's child; 200 another app; 300 launchd's.
        let parents: [pid_t: pid_t] = [100: 1, 101: 100, 102: 100, 103: 101, 200: 1, 201: 200, 300: 1]
        let sizes: [pid_t: UInt64] = [100: 100, 101: 10, 102: 20, 103: 5, 200: 7, 201: 3, 300: 1000]
        let totals = FocusSystemProbes.appFootprints(for: [100, 200], parents: parents, footprint: { sizes[$0] })
        XCTAssertEqual(totals[100], 135)
        XCTAssertEqual(totals[200], 10)
        XCTAssertNil(totals[300])
        XCTAssertEqual(FocusMemoryPressure(sysctlLevel: 1), .normal)
        XCTAssertEqual(FocusMemoryPressure(sysctlLevel: 2), .warning)
        XCTAssertEqual(FocusMemoryPressure(sysctlLevel: 4), .critical)
        XCTAssertEqual(FocusMemoryPressure(.warning), .warning)
        XCTAssertNotNil(FocusSystemProbes.footprint(of: getpid()), "the test process can read its own footprint")
        XCTAssertNotEqual(FocusSystemProbes.memoryPressure(), .unknown, "the sysctl exists on this Mac")
    }
}
