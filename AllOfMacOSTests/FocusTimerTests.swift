import XCTest
@testable import AllOfMacOS

/// The session state machine: start, pause, resume, skip, stop, breaks, long
/// breaks and sleep/wake, all on an injected clock.
final class FocusTimerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private let plan = FocusPlan(focusMinutes: 25, breakMinutes: 5, longBreakMinutes: 15, sessionsBeforeLongBreak: 4)

    private func logged(_ events: [FocusTimerEvent]) -> [FocusLogEntry] {
        events.compactMap { if case .logged(let entry) = $0 { return entry }; return nil }
    }

    func testStartRunsAFocusPhaseOfThePlanLength() throws {
        var timer = FocusTimer()
        XCTAssertTrue(timer.isIdle)
        XCTAssertEqual(timer.start(plan: plan, at: t0), [.started(.focus, at: t0)])
        let run = try XCTUnwrap(timer.run)
        XCTAssertEqual(run.phase, .focus)
        XCTAssertEqual(run.length, 25 * 60)
        XCTAssertEqual(run.remaining(at: at(7)), 18 * 60, accuracy: 0.001)
        XCTAssertEqual(timer.nextDeadline, at(25))
        XCTAssertEqual(timer.start(plan: plan, at: at(1)), [], "a second start while running does nothing")
    }

    func testPauseFreezesTheCountdownAndResumeContinuesIt() throws {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        XCTAssertEqual(timer.pause(at: at(10)), [.paused(.focus, at: at(10))])
        XCTAssertTrue(timer.isPaused)
        XCTAssertNil(timer.nextDeadline, "nothing ends while paused")
        XCTAssertEqual(try XCTUnwrap(timer.run).remaining(at: at(60)), 15 * 60, accuracy: 0.001)
        XCTAssertEqual(timer.advance(to: at(90)), [], "paused time never completes the phase")
        XCTAssertEqual(timer.resume(at: at(100)), [.resumed(.focus, at: at(100))])
        XCTAssertEqual(timer.nextDeadline, at(115), "15 minutes were left")
        XCTAssertEqual(timer.resume(at: at(101)), [], "resume while running does nothing")
    }

    func testAFocusThatRunsToItsEndIsASessionAndTheBreakStarts() throws {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        let events = timer.advance(to: at(25))
        XCTAssertEqual(events.first, .completed(.focus, at: at(25)))
        let entry = try XCTUnwrap(logged(events).first)
        XCTAssertTrue(entry.completed)
        XCTAssertEqual(entry.focusedSeconds, 25 * 60)
        XCTAssertEqual(entry.start, t0)
        XCTAssertEqual(entry.end, at(25))
        XCTAssertEqual(events.last, .started(.shortBreak, at: at(25)))
        XCTAssertEqual(timer.phase, .shortBreak)
        XCTAssertEqual(timer.nextDeadline, at(30))
        XCTAssertEqual(timer.completedInCycle, 1)
    }

    func testABreakEndsIdleUnlessTheNextFocusStartsByItself() {
        var waits = FocusTimer()
        _ = waits.start(plan: plan, at: t0)
        _ = waits.advance(to: at(25))
        XCTAssertEqual(waits.advance(to: at(30)), [.completed(.shortBreak, at: at(30))])
        XCTAssertTrue(waits.isIdle, "Focus waits for the person after a break")

        var auto = plan
        auto.autoStartsNextSession = true
        var chains = FocusTimer()
        _ = chains.start(plan: auto, at: t0)
        _ = chains.advance(to: at(25))
        XCTAssertEqual(chains.advance(to: at(30)), [.completed(.shortBreak, at: at(30)), .started(.focus, at: at(30))])
        XCTAssertEqual(chains.nextDeadline, at(55), "the next focus starts at the break's end, not later")
    }

    func testEveryFourthSessionGetsTheLongBreakAndTheCycleStartsAgain() {
        var auto = plan
        auto.autoStartsNextSession = true
        var timer = FocusTimer()
        _ = timer.start(plan: auto, at: t0)
        var minute = 0.0
        var breaks: [FocusPhase] = []
        for _ in 0..<4 {
            minute += 25
            let events = timer.advance(to: at(minute))
            if let started = events.compactMap({ event -> FocusPhase? in
                if case .started(let phase, _) = event { return phase }; return nil }).last {
                breaks.append(started)
            }
            minute += Double(auto.minutes(of: timer.phase ?? .shortBreak))
            _ = timer.advance(to: at(minute))
        }
        XCTAssertEqual(breaks, [.shortBreak, .shortBreak, .shortBreak, .longBreak])
        XCTAssertEqual(timer.completedInCycle, 0, "the long break starts a new cycle")
        XCTAssertEqual(timer.phase, .focus)
    }

    func testLongBreaksCanBeTurnedOffAndBreaksToo() {
        var noLong = plan
        noLong.longBreaksEnabled = false
        noLong.sessionsBeforeLongBreak = 2
        noLong.autoStartsNextSession = true
        var timer = FocusTimer()
        _ = timer.start(plan: noLong, at: t0)
        _ = timer.advance(to: at(25)); _ = timer.advance(to: at(30))
        _ = timer.advance(to: at(55))
        XCTAssertEqual(timer.phase, .shortBreak, "the second session still gets a short break")

        var noBreaks = plan
        noBreaks.breaksEnabled = false
        var single = FocusTimer()
        _ = single.start(plan: noBreaks, at: t0)
        let events = single.advance(to: at(25))
        XCTAssertEqual(events.count, 2, "completed and logged, nothing started")
        XCTAssertTrue(single.isIdle)
    }

    func testSkippingAFocusKeepsItsMinutesButIsNotASession() throws {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        let events = timer.skip(at: at(12))
        XCTAssertEqual(events.first, .skipped(.focus, at: at(12)))
        let entry = try XCTUnwrap(logged(events).first)
        XCTAssertFalse(entry.completed)
        XCTAssertEqual(entry.focusedSeconds, 12 * 60, accuracy: 0.001)
        XCTAssertEqual(timer.phase, .shortBreak)
        XCTAssertEqual(timer.completedInCycle, 0)
        XCTAssertEqual(timer.nextDeadline, at(17))
    }

    func testSkippingABreakStartsTheNextFocusNow() {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        _ = timer.advance(to: at(25))
        XCTAssertEqual(timer.skip(at: at(26)), [.skipped(.shortBreak, at: at(26)), .started(.focus, at: at(26))])
        XCTAssertEqual(timer.nextDeadline, at(51))
    }

    func testStopEndsTheSessionAndKeepsTheFocusedMinutes() throws {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        _ = timer.pause(at: at(5))
        _ = timer.resume(at: at(20))
        let events = timer.stop(at: at(23))
        XCTAssertEqual(events.first, .stopped(.focus, at: at(23)))
        let entry = try XCTUnwrap(logged(events).first)
        XCTAssertEqual(entry.focusedSeconds, 8 * 60, accuracy: 0.001, "paused time is not focus")
        XCTAssertTrue(timer.isIdle)

        var brief = FocusTimer()
        _ = brief.start(plan: plan, at: t0)
        XCTAssertTrue(logged(brief.stop(at: t0.addingTimeInterval(40))).isEmpty, "under a minute is not logged")
    }

    func testStoppingDuringABreakLogsNothingMore() {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        _ = timer.advance(to: at(25))
        let events = timer.stop(at: at(27))
        XCTAssertEqual(events, [.stopped(.shortBreak, at: at(27))])
        XCTAssertTrue(timer.isIdle)
    }

    // MARK: Sleep and wake

    func testTimePassesWhileTheMacSleeps() throws {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        // Asleep from minute 5 to minute 20: no events arrive, then wake.
        XCTAssertEqual(timer.advance(to: at(20)), [])
        XCTAssertEqual(try XCTUnwrap(timer.run).remaining(at: at(20)), 5 * 60, accuracy: 0.001)
    }

    func testWakingAfterTheFocusEndedCompletesItAtItsEndAndRunsTheBreakOnSchedule() throws {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        // Asleep from minute 10 to minute 27.
        let events = timer.advance(to: at(27))
        XCTAssertEqual(events.first, .completed(.focus, at: at(25)), "completed at its end, not at wake")
        XCTAssertEqual(logged(events).first?.end, at(25))
        XCTAssertEqual(timer.phase, .shortBreak)
        XCTAssertEqual(try XCTUnwrap(timer.run).remaining(at: at(27)), 3 * 60, accuracy: 0.001)
    }

    func testALongSleepNeverStartsAFocusRetroactively() {
        var auto = plan
        auto.autoStartsNextSession = true
        var timer = FocusTimer()
        _ = timer.start(plan: auto, at: t0)
        // Asleep for three hours: the focus and its break both ended.
        let events = timer.advance(to: at(180))
        XCTAssertEqual(events.map(\.date), [at(25), at(25), at(25), at(30)])
        XCTAssertTrue(timer.isIdle, "nobody was there to focus, so no session starts in the past")
        XCTAssertEqual(logged(events).count, 1)
    }

    func testTheCycleStartsAgainAfterTwoHoursWithoutFocus() {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        _ = timer.advance(to: at(25))
        _ = timer.stop(at: at(26))
        XCTAssertEqual(timer.completedInCycle, 1)
        _ = timer.start(at: at(60))
        XCTAssertEqual(timer.completedInCycle, 1, "an hour later the cycle continues")
        _ = timer.stop(at: at(61))
        _ = timer.start(at: at(61 + 121))
        XCTAssertEqual(timer.completedInCycle, 0, "after two hours a new cycle begins")
    }

    func testTheTimerSurvivesARelaunchAsJSON() throws {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        _ = timer.pause(at: at(3))
        let data = try JSONEncoder().encode(timer)
        let restored = try JSONDecoder().decode(FocusTimer.self, from: data)
        XCTAssertEqual(restored, timer)
    }

    func testPlansAreClampedWhenDecoded() throws {
        let json = #"{"focusMinutes":0,"breakMinutes":999,"sessionsBeforeLongBreak":1}"#
        let plan = try JSONDecoder().decode(FocusPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.focusMinutes, 1)
        XCTAssertEqual(plan.breakMinutes, 60)
        XCTAssertEqual(plan.sessionsBeforeLongBreak, 2)
        XCTAssertEqual(plan.longBreakMinutes, 15, "missing values take their default")
        XCTAssertEqual(FocusPlan().applying(.flow).preset, .flow)
        XCTAssertEqual(FocusLengthPreset.all.map(\.title), ["25/5", "50/10", "90/15"])
    }

    // MARK: Announcements

    func testThePhaseThatEndedDecidesTheAnnouncement() {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        let events = timer.advance(to: at(25))
        let done = FocusAnnouncement.make(for: events, timer: timer, now: at(25), userInitiated: false, todaySessions: 1)
        XCTAssertEqual(done?.title, "Focus Complete")
        XCTAssertEqual(done?.detail, "Take a 5 min break")
        XCTAssertEqual(done?.playsSound, true)

        let ended = timer.advance(to: at(30))
        let over = FocusAnnouncement.make(for: ended, timer: timer, now: at(30), userInitiated: false, todaySessions: 1)
        XCTAssertEqual(over?.title, "Break Over")
        XCTAssertEqual(over?.playsSound, true)
    }

    func testCatchingUpAfterSleepIsQuiet() {
        var timer = FocusTimer()
        _ = timer.start(plan: plan, at: t0)
        let events = timer.advance(to: at(90))
        let note = FocusAnnouncement.make(for: events, timer: timer, now: at(90), userInitiated: false, todaySessions: 1)
        XCTAssertEqual(note?.playsSound, false, "no sound for a phase that ended while the Mac slept")
        XCTAssertEqual(note?.title, "Break Ended")
    }

    func testStartsAndStopsAreAnnouncedOnlyWhenAskedOutsideTheWindow() {
        var timer = FocusTimer()
        let started = timer.start(plan: plan, at: t0)
        XCTAssertNil(FocusAnnouncement.make(for: started, timer: timer, now: t0, userInitiated: false, todaySessions: 0))
        XCTAssertEqual(FocusAnnouncement.make(for: started, timer: timer, now: t0, userInitiated: true, todaySessions: 0)?.title,
                       "Focus · 25 min")
        let stopped = timer.stop(at: at(18))
        let note = FocusAnnouncement.make(for: stopped, timer: timer, now: at(18), userInitiated: true, todaySessions: 0)
        XCTAssertEqual(note?.title, "Focus Stopped")
        XCTAssertEqual(note?.detail, "18 min focused")
        XCTAssertEqual(note?.playsSound, false)
    }

    func testDurationsReadAsCountdownsAndShortPhrases() {
        XCTAssertEqual(FocusDurationFormat.countdown(18 * 60 + 22), "18:22")
        XCTAssertEqual(FocusDurationFormat.countdown(0.2), "0:01", "a started second still shows")
        XCTAssertEqual(FocusDurationFormat.countdown(3909), "1:05:09")
        XCTAssertEqual(FocusDurationFormat.short(45), "45 s")
        XCTAssertEqual(FocusDurationFormat.short(42 * 60), "42 min")
        XCTAssertEqual(FocusDurationFormat.short(65 * 60), "1 h 5 min")
        XCTAssertEqual(FocusDurationFormat.minutes(1499), 25)
    }
}
