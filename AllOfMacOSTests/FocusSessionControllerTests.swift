import AppKit
import XCTest
@testable import AllOfMacOS

/// The controller around the timer: what a focus phase does to the Mac (and
/// undoes), the log, sounds and HUDs, sleep and wake on the injected clock,
/// and a relaunch in the middle of a session. Nothing real is touched.
@MainActor
final class FocusSessionControllerTests: XCTestCase {
    private var world: FocusTestWorld!

    override func setUp() async throws {
        world = FocusTestWorld()
    }

    override func tearDown() async throws {
        world.cleanUp()
        world = nil
    }

    private func enableEverything() {
        var settings = world.settings.settings
        settings.plan = FocusPlan(focusMinutes: 25, breakMinutes: 5)
        settings.hidesDistractions = true
        settings.mutesSound = true
        settings.keepsAwake = true
        settings.startShortcut = FocusShortcutRef(name: "Do Not Disturb On", identifier: nil)
        settings.endShortcut = FocusShortcutRef(name: "Do Not Disturb Off", identifier: nil)
        world.settings.settings = settings
        world.lists.addDistraction(FocusAppRef(bundleID: "com.example.chat", name: "Chat"))
        world.system.apps = [
            FocusRunningApp(pid: 11, bundleID: "com.example.editor", name: "Editor", isActive: true),
            FocusRunningApp(pid: 12, bundleID: "com.example.chat", name: "Chat")
        ]
    }

    func testAFocusPhaseHidesMutesKeepsAwakeAndRunsTheShortcutThenUndoesItsOwnChanges() {
        enableEverything()
        let session = world.makeSession()
        session.start()
        XCTAssertEqual(world.system.hidden, [12], "the distracting app is hidden at the start")
        XCTAssertTrue(world.system.muted)
        XCTAssertEqual(world.system.keepAwakeBegun, [26], "Keep Awake for the focus plus a minute")
        XCTAssertEqual(world.system.shortcutRuns, ["Do Not Disturb On"])
        XCTAssertTrue(session.effects.active)

        world.clock.advance(25 * 60)
        session.tick()
        XCTAssertFalse(world.system.muted, "Focus's own mute comes off")
        XCTAssertEqual(world.system.keepAwakeEnded.count, 1)
        XCTAssertEqual(world.system.shortcutRuns, ["Do Not Disturb On", "Do Not Disturb Off"])
        XCTAssertEqual(world.system.sounds, ["Glass"], "one end sound")
        XCTAssertEqual(world.system.huds, ["Focus Complete"])
        XCTAssertEqual(session.timer.phase, .shortBreak)
        XCTAssertEqual(session.stats.todaySessions, 1)
        XCTAssertEqual(world.log.entries.count, 1)
    }

    func testAMuteThePersonMadeIsLeftAlone() {
        enableEverything()
        world.system.muted = true
        let session = world.makeSession()
        session.start()
        XCTAssertEqual(world.system.muteToggles, 0, "already muted: Focus does nothing")
        session.stop()
        XCTAssertTrue(world.system.muted, "and does not unmute what it did not mute")

        world.system.muted = false
        session.start()
        XCTAssertEqual(world.system.muteToggles, 1)
        world.system.muted = false // the person unmuted during the focus
        session.stop()
        XCTAssertEqual(world.system.muteToggles, 1, "nothing to undo")
        XCTAssertFalse(world.system.muted)
    }

    func testADistractingAppThatComesForwardIsHiddenAgainWithAGentleHUD() {
        enableEverything()
        let session = world.makeSession()
        session.start()
        world.system.hidden.removeAll()
        session.distractingAppActivated(bundleID: "com.example.chat", pid: 12, name: "Chat")
        XCTAssertEqual(world.system.hidden, [12])
        XCTAssertEqual(world.system.huds.last, "Focus: 25 min left")
        session.distractingAppActivated(bundleID: "com.example.chat", pid: 12, name: "Chat")
        XCTAssertEqual(world.system.hidden, [12, 12])
        XCTAssertEqual(world.system.huds.filter { $0.hasPrefix("Focus:") }.count, 1, "at most one HUD per app every 20 s")
        session.distractingAppActivated(bundleID: "com.example.editor", pid: 11, name: "Editor")
        XCTAssertEqual(world.system.hidden, [12, 12], "apps not on the list are never hidden")

        world.system.paused = true
        session.distractingAppActivated(bundleID: "com.example.chat", pid: 12, name: "Chat")
        XCTAssertEqual(world.system.hidden.count, 2, "Pause AOM pauses the hiding")
        world.system.paused = false

        session.pause()
        session.distractingAppActivated(bundleID: "com.example.chat", pid: 12, name: "Chat")
        XCTAssertEqual(world.system.hidden.count, 2, "nothing is hidden while the focus is paused")
        session.resume()
        session.skip()
        session.distractingAppActivated(bundleID: "com.example.chat", pid: 12, name: "Chat")
        XCTAssertEqual(world.system.hidden.count, 2, "breaks are free")
    }

    func testSleepingThroughTheEndCatchesUpOnWakeQuietly() {
        enableEverything()
        let session = world.makeSession()
        session.start()
        // The lid closes 5 minutes in and opens 40 minutes later.
        world.clock.advance(45 * 60)
        session.tick()
        XCTAssertTrue(session.timer.isIdle, "the focus and its break both ended while asleep")
        XCTAssertEqual(world.log.entries.count, 1)
        XCTAssertEqual(world.log.entries.first?.end, world.clock.now.addingTimeInterval(-20 * 60))
        XCTAssertEqual(world.system.sounds, [], "no sound for time that passed asleep")
        XCTAssertEqual(world.system.huds, ["Break Ended"])
        XCTAssertFalse(world.system.muted)
        XCTAssertEqual(world.system.shortcutRuns.last, "Do Not Disturb Off")
    }

    func testARelaunchContinuesTheSessionWhereTheClockSaysItIs() throws {
        enableEverything()
        let first = world.makeSession()
        first.start()
        world.clock.advance(10 * 60)
        first.tick()
        first.tearDown()
        FocusStorage.flush()

        // AOM quits and comes back four minutes later.
        world.clock.advance(4 * 60)
        let second = world.makeSession()
        second.restoreAfterLaunch()
        let run = try XCTUnwrap(second.timer.run)
        XCTAssertEqual(run.phase, .focus)
        XCTAssertEqual(run.remaining(at: world.clock.now), 11 * 60, accuracy: 0.5)
        XCTAssertEqual(world.system.keepAwakeBegun.count, 2, "the power assertion is taken again")
        XCTAssertEqual(world.system.huds, [], "no HUD at launch")
    }

    func testARelaunchAfterTheSessionEndedUndoesTheMute() {
        enableEverything()
        let first = world.makeSession()
        first.start()
        XCTAssertTrue(world.system.muted)
        first.tearDown()
        FocusStorage.flush()
        world.clock.advance(3 * 3600)
        let second = world.makeSession()
        second.restoreAfterLaunch()
        XCTAssertTrue(second.timer.isIdle)
        XCTAssertFalse(world.system.muted, "the mute Focus left behind is undone")
        XCTAssertEqual(world.log.entries.count, 1)
    }

    func testAFailingShortcutIsReportedAndLogged() {
        enableEverything()
        world.system.shortcutResult = .failure(.failed(status: 1, message: "Couldn't find shortcut"))
        let session = world.makeSession()
        session.start()
        XCTAssertEqual(session.shortcutProblem, "Couldn't run “Do Not Disturb On” because Couldn't find shortcut.")
        XCTAssertEqual(world.activity.items.first?.kind, .shortcutFailed)
        world.system.shortcutResult = .success(())
        session.stop()
        XCTAssertNil(session.shortcutProblem, "a later success clears it")
    }

    func testTheHotkeyTogglesAndAnnouncesOutsideTheWindow() {
        let session = world.makeSession()
        session.toggle(userInitiated: true)
        XCTAssertEqual(session.timer.phase, .focus)
        XCTAssertEqual(world.system.huds, ["Focus · 25 min"])
        world.clock.advance(18 * 60)
        session.toggle(userInitiated: true)
        XCTAssertTrue(session.timer.isIdle)
        XCTAssertEqual(world.system.huds.last, "Focus Stopped")
        XCTAssertEqual(world.log.entries.first?.completed, false)
        XCTAssertEqual(session.stats.todayMinutes, 18)
    }

    func testNewLengthsApplyToTheNextPhases() throws {
        let session = world.makeSession()
        session.start()
        session.setPlan(FocusPlan().applying(.flow))
        XCTAssertEqual(try XCTUnwrap(session.timer.run).length, 25 * 60, "the running focus keeps its length")
        world.clock.advance(25 * 60)
        session.tick()
        XCTAssertEqual(try XCTUnwrap(session.timer.run).length, 10 * 60, "the break uses the new plan")
        XCTAssertEqual(world.settings.settings.plan.focusMinutes, 50)
    }

    func testTheStatusBoardSummary() {
        var timer = FocusTimer()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var stats = FocusStats()
        XCTAssertEqual(FocusModule.statusSummary(timer: timer, stats: stats, now: now, idleRulesOn: false),
                       .init(isOn: false, count: 0, unit: "sessions", detail: "No session today"))
        XCTAssertEqual(FocusModule.statusSummary(timer: timer, stats: stats, now: now, idleRulesOn: true).isOn, true,
                       "on while idle-app rules are on")
        stats.todaySessions = 2
        stats.todaySeconds = 50 * 60
        XCTAssertEqual(FocusModule.statusSummary(timer: timer, stats: stats, now: now, idleRulesOn: false).detail,
                       "2 sessions · 50 min today")
        _ = timer.start(plan: FocusPlan(), at: now)
        let running = FocusModule.statusSummary(timer: timer, stats: stats, now: now.addingTimeInterval(398), idleRulesOn: false)
        XCTAssertEqual(running, .init(isOn: true, count: 2, unit: "sessions", detail: "18:22 left"))
        XCTAssertEqual(FocusModule.sessionMenuTitle(timer: timer, plan: FocusPlan(), now: now.addingTimeInterval(398)),
                       "Stop Focus · 18:22 left")
        XCTAssertEqual(FocusModule.sessionMenuTitle(timer: FocusTimer(), plan: FocusPlan(), now: now), "Start Focus · 25 min")
        _ = timer.pause(at: now.addingTimeInterval(398))
        XCTAssertEqual(FocusModule.sessionMenuTitle(timer: timer, plan: FocusPlan(), now: now.addingTimeInterval(999)),
                       "Stop Focus · Paused, 18:22 left")
    }

    func testTheStatusMenuOffersFocusAndQuitIdleAppsOnlyWithRules() {
        let items = FocusModule.statusMenuItems()
        XCTAssertTrue(items.first?.title.hasPrefix("Start Focus · ") == true || items.first?.title.hasPrefix("Stop Focus · ") == true)
        XCTAssertNotNil(items.first?.image)
        XCTAssertNotNil(items.first?.target)
        let hasRules = FocusModule.environment.idleApps.hasRules
        XCTAssertEqual(items.contains { $0.title == "Quit Idle Apps Now" }, hasRules)
    }

    func testSettingsDecodeWithDefaultsAndClamps() throws {
        let json = #"{"plan":{"focusMinutes":50},"standMinutes":5,"idleAppsEnabled":true,"unknown":1}"#
        let settings = try JSONDecoder().decode(FocusSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.plan.focusMinutes, 50)
        XCTAssertEqual(settings.plan.breakMinutes, 5)
        XCTAssertEqual(settings.standMinutes, 20, "clamped")
        XCTAssertTrue(settings.idleAppsEnabled)
        XCTAssertTrue(settings.showsMenuBarCountdown, "missing values keep their default")

        world.settings.settings.keepsAwake = true
        let reread = FocusSettingsStore(defaults: world.defaults)
        XCTAssertTrue(reread.settings.keepsAwake, "stored under one key")
        world.defaults.removeObject(forKey: FocusSettingsStore.defaultsKey)
        world.settings.reload()
        XCTAssertEqual(world.settings.settings, FocusSettings(), "Reset Preferences brings the defaults back")
        XCTAssertNil(world.defaults.object(forKey: FocusSettingsStore.defaultsKey), "and reload never writes them back")
        XCTAssertTrue(FocusSettingsStore.defaultsKey.hasPrefix("AOMFocus"))
    }
}
