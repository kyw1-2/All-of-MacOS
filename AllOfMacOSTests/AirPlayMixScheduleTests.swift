import XCTest
@testable import AllOfMacOS

/// Audit 2026-10-28 F12, production side: the AirPlay mix clock's catch-up
/// rule driven by a virtual clock, so the result does not depend on how this
/// test process is scheduled, and the timeline the thread keeps of its own
/// start-up and wake-ups.
///
/// Limits of this simulation: it models wake-up lateness, a fixed per-block
/// render cost, whether the scheduler runs the thread realtime, and a
/// consumer draining 48 frames per millisecond from a bridge primed with its
/// 7,200-frame target. It does not model the HAL device clock, resampling,
/// per-app capture queues, CPU contention or the scheduler itself; the two
/// realtime tests in AudioPipelineTests and the bench in
/// work/audit-20261028/s3 run the real thread.
final class AirPlayMixScheduleTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    /// The 3.3.1 production schedule, in nanoseconds.
    private func production(start: UInt64 = 0) -> AirPlayMixSchedule {
        AirPlayMixThread.schedule(start: start) { $0 }
    }

    /// The 3.3.0 rule: four overdue blocks per wake, nothing more.
    private func legacy(start: UInt64 = 0) -> AirPlayMixSchedule {
        AirPlayMixSchedule(start: start, period: 10 * ms, realign: 1_000 * ms,
                           minimumBurst: 4, burstBudget: 0, maximumBurst: 4)
    }

    struct Outcome {
        var blocks = 0
        var minimumFill = Int.max
        var realigns = 0
        var largestBurst = 0
        var longestBurst: UInt64 = 0
        var aheadOfRealTime = false
    }

    /// Runs the mix loop exactly as AirPlayMixThread does, with every wait
    /// overshooting by `lateness`, every block costing `cost`, and the
    /// scheduler running the thread realtime or demoted (`realtime`).
    private func simulate(_ initial: AirPlayMixSchedule, duration: UInt64, cost: UInt64,
                          lateness: UInt64, realtime: Bool = true,
                          stall: (at: UInt64, length: UInt64)? = nil) -> Outcome {
        var schedule = initial
        var outcome = Outcome()
        var now: UInt64 = 0
        var stalled = false
        let prime = 7_200
        func fill(at time: UInt64) -> Int { prime + outcome.blocks * 480 - Int(time / ms) * 48 }
        while now < duration {
            if let stall, !stalled, now >= stall.at { now += stall.length; stalled = true }
            if now < schedule.next { now = schedule.next + lateness; continue }
            let wake = schedule.wake(at: now)
            if wake.realigned { outcome.realigns += 1 }
            outcome.minimumFill = min(outcome.minimumFill, fill(at: now))
            let burstStart = now
            var rendered = 0
            while schedule.shouldRender(now: now, burstStart: burstStart, rendered: rendered, realtime: realtime) {
                now += cost
                outcome.blocks += 1
                schedule.didRender()
                rendered += 1
                // Never more audio than real time allows (one block may lead).
                if UInt64(outcome.blocks - 1) * 10 * ms > now + 10 * ms { outcome.aheadOfRealTime = true }
            }
            outcome.largestBurst = max(outcome.largestBurst, rendered)
            outcome.longestBurst = max(outcome.longestBurst, now - burstStart)
            if schedule.next <= now { now = schedule.resume(after: now, pause: ms) + lateness }
        }
        return outcome
    }

    func testOnTimeWakeUpsRenderOneBlockPerPeriodAndNeverRunAhead() {
        let outcome = simulate(production(), duration: 500 * ms, cost: ms / 20, lateness: 0)
        XCTAssertEqual(outcome.blocks, 50, "0.5 s = 50 blocks of 10 ms")
        XCTAssertEqual(outcome.largestBurst, 1)
        XCTAssertFalse(outcome.aheadOfRealTime)
        XCTAssertEqual(outcome.realigns, 0)
    }

    /// The audit failure, reproduced deterministically: every wait overshoots
    /// by 60 ms (more than the old 40 ms burst, less than the 150 ms bridge).
    func testLateWakeUpsNoLongerStarveTheBridge() {
        let old = simulate(legacy(), duration: 10_000 * ms, cost: ms / 20, lateness: 60 * ms)
        XCTAssertLessThan(old.minimumFill, 0, "3.3.0's four-block cap falls behind and drains the bridge")
        let new = simulate(production(), duration: 10_000 * ms, cost: ms / 20, lateness: 60 * ms)
        XCTAssertGreaterThan(new.minimumFill, 0, "every overdue block is rendered on the next wake")
        XCTAssertEqual(new.realigns, 0, "no audio is skipped")
        XCTAssertFalse(new.aheadOfRealTime, "and the clock still never runs ahead")
        XCTAssertGreaterThanOrEqual(new.blocks, 990, "10 s of audio, less only the 60 ms the last wake is late")
    }

    func testTheAuditsOvershootIsCaughtUpWithinOneWake() {
        // ~190 ms per wait, as measured in the agent-launched test process.
        let new = simulate(production(), duration: 5_000 * ms, cost: ms / 20, lateness: 190 * ms)
        XCTAssertEqual(new.realigns, 0)
        XCTAssertGreaterThanOrEqual(new.largestBurst, 19, "a 190 ms backlog is rendered in one burst")
        XCTAssertLessThanOrEqual(new.longestBurst, AirPlayMixThread.burstBudgetNanoseconds + ms,
                                 "inside the burst budget (plus at most one block)")
        let old = simulate(legacy(), duration: 5_000 * ms, cost: ms / 20, lateness: 190 * ms)
        XCTAssertLessThan(old.blocks, new.blocks / 2, "the old rule produced well under half the audio")
    }

    func testExpensiveBlocksStillRenderTheOldMinimumAndStopAtTheBudget() {
        // A debug build measured ~5 ms per block on this Mac's efficiency cores.
        let new = simulate(production(), duration: 2_000 * ms, cost: 5 * ms, lateness: 30 * ms)
        let old = simulate(legacy(), duration: 2_000 * ms, cost: 5 * ms, lateness: 30 * ms)
        XCTAssertGreaterThanOrEqual(new.blocks, old.blocks, "never fewer blocks than 3.3.0")
        XCTAssertEqual(new.largestBurst, 4, "slow blocks: the four-block minimum, then the budget ends the burst")
    }

    /// The audit environment, debug build: the host demoted the thread
    /// (timeshare, priority 4), wake-ups came ~120 ms late and a block cost
    /// ~5 ms. Time-budgeted like a realtime thread, the clock fell to about
    /// half rate (the session-2 matrix measured −42 % to −47 %); a demoted
    /// thread renders every overdue block and keeps the bridge fed.
    func testADemotedThreadIsNotTimeBudgetedAndKeepsUpWithExpensiveBlocks() {
        let budgeted = simulate(production(), duration: 10_000 * ms, cost: 5 * ms, lateness: 120 * ms, realtime: true)
        XCTAssertLessThan(budgeted.minimumFill, 0, "a 4 ms budget per 120 ms wake-up cannot keep up with 5 ms blocks")
        let demoted = simulate(production(), duration: 10_000 * ms, cost: 5 * ms, lateness: 120 * ms, realtime: false)
        XCTAssertGreaterThan(demoted.minimumFill, 0, "every overdue block is rendered on each wake-up")
        XCTAssertEqual(demoted.realigns, 0)
        XCTAssertFalse(demoted.aheadOfRealTime)
        XCTAssertGreaterThanOrEqual(demoted.blocks, 980, "10 s of audio, less the last wake-up's lateness")
        XCTAssertLessThanOrEqual(demoted.largestBurst, AirPlayMixThread.maximumBurstBlocks)
    }

    func testARealtimeThreadStaysInsideItsBudgetAndADemotedOneOnlyUnderTheCap() {
        // 0.5 s behind with 0.5 ms blocks: realtime stops when the 4 ms budget
        // is spent, demoted renders on until caught up, capped at 100 blocks.
        let cost = ms / 2
        var schedule = production(start: 0)
        _ = schedule.wake(at: 500 * ms)
        var realtimeBlocks = 0, now: UInt64 = 500 * ms
        while schedule.shouldRender(now: now, burstStart: 500 * ms, rendered: realtimeBlocks, realtime: true) {
            schedule.didRender(); realtimeBlocks += 1; now += cost
        }
        XCTAssertEqual(realtimeBlocks, 8, "the four-block minimum (2 ms), then four more inside the 4 ms budget")
        XCTAssertGreaterThan(schedule.lag(at: now), 400 * ms, "and the clock is left behind")
        var demoted = production(start: 0)
        _ = demoted.wake(at: 500 * ms)
        var demotedBlocks = 0
        now = 500 * ms
        while demoted.shouldRender(now: now, burstStart: 500 * ms, rendered: demotedBlocks, realtime: false) {
            demoted.didRender(); demotedBlocks += 1; now += cost
        }
        XCTAssertEqual(demotedBlocks, 53, "caught up: 53 blocks (530 ms of audio) by 526.5 ms")
        XCTAssertEqual(demoted.lag(at: now), 0)
        var capped = production(start: 0)
        _ = capped.wake(at: 1_000 * ms)  // late by exactly the realign horizon: not realigned
        var cappedBlocks = 0
        while capped.shouldRender(now: 1_000 * ms, burstStart: 1_000 * ms, rendered: cappedBlocks, realtime: false) {
            capped.didRender(); cappedBlocks += 1
        }
        XCTAssertEqual(cappedBlocks, AirPlayMixThread.maximumBurstBlocks, "never more than 1 s of audio per wake-up")
        XCTAssertEqual(capped.next, 1_000 * ms, "the 101st overdue block waits for the next wake-up")
    }

    // MARK: - Timeline (start-up and sustained supply, measured by the thread)

    func testTheTimelineKeepsTheLatestWakeUpsInOrder() throws {
        let timeline = AirPlayMixTimeline()
        let count = AirPlayMixTimeline.capacity + 44
        for index in 0..<count {
            timeline.record(.init(at: UInt64(1_000 + index) * 10 * ms, late: UInt64(index) * 1_000, rendered: index % 3 + 1,
                                  totalBlocks: UInt64(index) * 2, burst: 1_234_567, lagAfter: index.isMultiple(of: 5) ? 7 * ms : 0,
                                  realtime: index.isMultiple(of: 2), realigned: index == count - 1))
        }
        let wakes = timeline.wakes
        XCTAssertEqual(wakes.count, AirPlayMixTimeline.capacity, "a bounded ring: the oldest are overwritten")
        XCTAssertEqual(wakes.first?.at, UInt64(1_000 + 44) * 10 * ms)
        XCTAssertEqual(wakes.map(\.at), wakes.map(\.at).sorted())
        let last = try XCTUnwrap(wakes.last)
        XCTAssertEqual(last.totalBlocks, UInt64(count - 1) * 2)
        XCTAssertEqual(last.rendered, (count - 1) % 3 + 1)
        XCTAssertEqual(last.late, UInt64(count - 1) * 1_000)
        XCTAssertEqual(last.burst, 1_234_000, "microsecond resolution")
        XCTAssertEqual(last.realtime, (count - 1).isMultiple(of: 2))
        XCTAssertTrue(last.realigned)
        XCTAssertEqual(wakes[0].lagAfter, 0, "wake-up 44")
        XCTAssertEqual(wakes[1].lagAfter, 7 * ms, "wake-up 45")
    }

    func testSustainedRateIsMeasuredAtBurstEndsAfterTheWarmUp() throws {
        // Throttled but caught up: a wake-up every 120 ms renders the 12
        // blocks that came due, in 1 ms, and leaves no lag.
        var caughtUp: [AirPlayMixTimeline.Wake] = []
        var blocks: UInt64 = 1
        caughtUp.append(.init(at: 0, late: 0, rendered: 1, totalBlocks: 1, burst: 0, lagAfter: 0, realtime: false, realigned: false))
        for wake in 1...25 {
            blocks += 12
            caughtUp.append(.init(at: UInt64(wake) * 120 * ms, late: 110 * ms, rendered: 12, totalBlocks: blocks,
                                  burst: ms, lagAfter: 0, realtime: false, realigned: false))
        }
        let rate = try XCTUnwrap(AirPlayMixTimeline.sustainedRate(of: caughtUp, after: 250 * ms, blockFrames: 480))
        XCTAssertEqual(rate.framesPerSecond, 48_000, accuracy: 1, "12 blocks of 480 frames per 120 ms")
        XCTAssertEqual(rate.worstLagAfterWake, 0)
        XCTAssertEqual(rate.span, 22 * 120 * ms, "from the first burst ending after 250 ms (361 ms) to the last")
        // The 3.3.0 rule in the same conditions: four blocks per wake-up.
        var starved: [AirPlayMixTimeline.Wake] = []
        blocks = 1
        for wake in 0...25 {
            if wake > 0 { blocks += 4 }
            starved.append(.init(at: UInt64(wake) * 120 * ms, late: 110 * ms, rendered: 4, totalBlocks: blocks, burst: ms,
                                 lagAfter: UInt64(wake) * 80 * ms, realtime: true, realigned: false))
        }
        let low = try XCTUnwrap(AirPlayMixTimeline.sustainedRate(of: starved, after: 250 * ms, blockFrames: 480))
        XCTAssertEqual(low.framesPerSecond, 16_000, accuracy: 1, "a third of the rate")
        XCTAssertGreaterThan(low.worstLagAfterWake, 1_000 * ms)
        XCTAssertNil(AirPlayMixTimeline.sustainedRate(of: Array(caughtUp.prefix(2)), after: 250 * ms, blockFrames: 480),
                     "no steady-state interval yet")
    }

    func testTheSchedulerReadingOfAnOrdinaryThreadIsTimeshare() throws {
        var reading: AirPlayMixScheduling.Reading?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { reading = AirPlayMixScheduling.current(); done.signal() }
        thread.start()
        done.wait()
        let value = try XCTUnwrap(reading, "the kernel answers thread_info for the calling thread")
        print("Ordinary thread: priority \(value.priority), host maximum \(value.maximumPriority), clamped \(value.hostClamped)")
        XCTAssertFalse(value.realtime, "an unpromoted thread is never in the realtime band")
        XCTAssertGreaterThanOrEqual(value.priority, 0)
        XCTAssertLessThan(value.priority, 97)
        XCTAssertGreaterThanOrEqual(value.maximumPriority, value.priority)
    }

    func testASchedulerReadingIsStoredAsOneWord() {
        let readings: [AirPlayMixScheduling.Reading] = [
            .init(realtime: true, priority: 97, maximumPriority: 63),
            .init(realtime: false, priority: 4, maximumPriority: 4),
            .init(realtime: false, priority: -1, maximumPriority: -1)
        ]
        for reading in readings {
            XCTAssertEqual(AirPlayMixScheduling.unpack(AirPlayMixScheduling.pack(reading)), reading)
        }
        XCTAssertNil(AirPlayMixScheduling.unpack(AirPlayMixScheduling.pack(nil)))
        XCTAssertTrue(readings[1].hostClamped)
        XCTAssertFalse(readings[0].hostClamped)
        XCTAssertFalse(readings[2].hostClamped, "unknown is not clamped")
        let timeline = AirPlayMixTimeline()
        timeline.note(readings[1])
        XCTAssertEqual(timeline.scheduling, readings[1])
    }

    // MARK: Host diagnosis and verdict (audit N01)

    private let healthyHost = AirPlayHostDiagnosis(
        ordinaryThread: .init(realtime: false, priority: 31, maximumPriority: 63),
        darwinBackground: false, worstTimerLateness: 400_000)

    /// The re-audit's default remote environment: the ceiling stayed 63, so
    /// 3.3.1's `hostClamped` said "not clamped", yet every thread ran
    /// timeshare at priority 4 and woke about 200 ms late.
    func testASuppressedHostWithAHighCeilingIsStillThrottled() {
        let suppressed = AirPlayHostDiagnosis(ordinaryThread: .init(realtime: false, priority: 4, maximumPriority: 63),
                                              darwinBackground: false, worstTimerLateness: 196_000_000)
        XCTAssertFalse(suppressed.ordinaryThread!.hostClamped, "the ceiling alone misses it")
        XCTAssertTrue(suppressed.throttled)
        XCTAssertEqual(suppressed.throttleReasons.count, 2, "\(suppressed.throttleReasons)")
        let mix = AirPlayMixScheduling.Reading(realtime: false, priority: 4, maximumPriority: 63)
        guard case .hostThrottled(let reasons) = AirPlayMixVerdict.judge(host: suppressed, mix: mix, promotionAccepted: true) else {
            return XCTFail("a throttled host is an environment limit, not a promotion failure")
        }
        XCTAssertFalse(reasons.isEmpty)
    }

    func testEachThrottleSignalIsEnoughOnItsOwn() {
        var darwin = healthyHost; darwin.darwinBackground = true
        var clamped = healthyHost; clamped.ordinaryThread = .init(realtime: false, priority: 4, maximumPriority: 4)
        var coalesced = healthyHost; coalesced.worstTimerLateness = 64_000_000
        for host in [darwin, clamped, coalesced] { XCTAssertTrue(host.throttled, "\(host)") }
        XCTAssertFalse(healthyHost.throttled)
        var unprobed = healthyHost; unprobed.worstTimerLateness = nil
        XCTAssertFalse(unprobed.throttled, "an unmeasured timer is not evidence of throttling")
    }

    /// The regression the re-audit asked for: on a host that allows realtime,
    /// a mix thread that does not get it fails instead of being skipped.
    func testAPromotionFailureOnAHealthyHostIsNeverExcused() {
        let timeshare = AirPlayMixScheduling.Reading(realtime: false, priority: 31, maximumPriority: 63)
        guard case .promotionFailed(let accepted) = AirPlayMixVerdict.judge(host: healthyHost, mix: timeshare, promotionAccepted: true),
              case .promotionFailed(let refused) = AirPlayMixVerdict.judge(host: healthyHost, mix: timeshare, promotionAccepted: false),
              case .promotionFailed = AirPlayMixVerdict.judge(host: healthyHost, mix: nil, promotionAccepted: true) else {
            return XCTFail("a non-realtime mix thread on a healthy host is a defect")
        }
        XCTAssertTrue(accepted.contains("accepted"))
        XCTAssertTrue(refused.contains("refused"))
        let realtime = AirPlayMixScheduling.Reading(realtime: true, priority: 97, maximumPriority: 63)
        XCTAssertEqual(AirPlayMixVerdict.judge(host: healthyHost, mix: realtime, promotionAccepted: true), .realtime)
        var throttled = healthyHost; throttled.darwinBackground = true
        XCTAssertEqual(AirPlayMixVerdict.judge(host: throttled, mix: realtime, promotionAccepted: true), .realtime,
                       "a realtime mix thread passes wherever it runs")
    }

    func testMeasuringTheHostReadsAnOrdinaryThread() throws {
        let host = AirPlayHostDiagnosis.measure()
        let thread = try XCTUnwrap(host.ordinaryThread)
        print("Host diagnosis: priority \(thread.priority), ceiling \(thread.maximumPriority), darwin background \(host.darwinBackground), " +
              "worst 2 ms wait \(host.worstTimerLateness.map { String(format: "%.2f ms late", Double($0) / 1e6) } ?? "n/a"), " +
              "throttled \(host.throttled) \(host.throttleReasons)")
        XCTAssertFalse(thread.realtime)
        XCTAssertNotNil(host.worstTimerLateness)
    }

    func testALongStallRealignsInsteadOfBurstingASecondOfAudio() {
        let new = simulate(production(), duration: 3_000 * ms, cost: ms / 20, lateness: 0,
                           stall: (at: 500 * ms, length: 2_000 * ms))
        XCTAssertEqual(new.realigns, 1, "sleep or a debugger: the stale backlog is skipped once")
        XCTAssertLessThanOrEqual(new.largestBurst, AirPlayMixThread.maximumBurstBlocks)
        XCTAssertFalse(new.aheadOfRealTime)
    }

    func testScheduleArithmetic() {
        var schedule = AirPlayMixSchedule(start: 100, period: 10, realign: 1_000, minimumBurst: 2,
                                          burstBudget: 5, maximumBurst: 3)
        XCTAssertEqual(schedule.wake(at: 99).late, 0, "early wake is not late")
        XCTAssertFalse(schedule.shouldRender(now: 99, burstStart: 99, rendered: 0), "nothing is due yet")
        XCTAssertEqual(schedule.wake(at: 135).late, 35)
        XCTAssertTrue(schedule.shouldRender(now: 135, burstStart: 135, rendered: 0))
        schedule.didRender()
        XCTAssertTrue(schedule.shouldRender(now: 140, burstStart: 135, rendered: 1), "below the minimum burst")
        schedule.didRender()
        XCTAssertFalse(schedule.shouldRender(now: 141, burstStart: 135, rendered: 2), "budget (5) spent after the minimum")
        XCTAssertTrue(schedule.shouldRender(now: 138, burstStart: 135, rendered: 2), "budget left")
        schedule.didRender()
        XCTAssertFalse(schedule.shouldRender(now: 138, burstStart: 135, rendered: 3), "hard cap")
        XCTAssertEqual(schedule.resume(after: 138, pause: 1), 139, "still behind: short pause")
        XCTAssertEqual(schedule.next, 130)
        var realigning = AirPlayMixSchedule(start: 0, period: 10, realign: 1_000, minimumBurst: 1, burstBudget: 0, maximumBurst: 1)
        XCTAssertTrue(realigning.wake(at: 5_000).realigned)
        XCTAssertEqual(realigning.next, 5_000)
    }
}
