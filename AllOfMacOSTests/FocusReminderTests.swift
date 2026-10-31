import XCTest
@testable import AllOfMacOS

/// Break reminders: due after the interval, time away counts as rest, and
/// nothing shows during a focus break or while AOM is paused.
@MainActor
final class FocusReminderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheClockRemindsAfterTheIntervalAndCountsTimeAwayAsRest() {
        var clock = FocusReminderClock(lastRestAt: t0)
        XCTAssertEqual(clock.evaluate(now: t0.addingTimeInterval(600), interval: 1200, secondsSinceInput: 2),
                       .wait(until: t0.addingTimeInterval(1200)))
        XCTAssertEqual(clock.evaluate(now: t0.addingTimeInterval(1201), interval: 1200, secondsSinceInput: 2), .remind)
        XCTAssertEqual(clock.lastRestAt, t0.addingTimeInterval(1201), "the next one counts from the reminder")
        XCTAssertEqual(clock.evaluate(now: t0.addingTimeInterval(3000), interval: 1200, secondsSinceInput: 400), .rested,
                       "five minutes without input is a break already taken")
        XCTAssertEqual(clock.lastRestAt, t0.addingTimeInterval(3000))
    }

    private var world: FocusTestWorld!
    override func setUp() async throws { world = FocusTestWorld() }
    override func tearDown() async throws { world.cleanUp(); world = nil }

    private func makeController() -> FocusReminderController {
        let clock = world.clock
        return FocusReminderController(system: world.system, settings: world.settings, clock: { clock.now }, schedules: false)
    }

    func testEyeAndStandRemindersShowAGentleHUD() {
        world.settings.settings.eyeBreaksEnabled = true
        world.settings.settings.standBreaksEnabled = true
        world.settings.settings.standMinutes = 45
        let controller = makeController()
        controller.refresh()
        world.clock.advance(20 * 60)
        XCTAssertEqual(controller.check(.eyes), .remind)
        XCTAssertEqual(controller.check(.stand), .wait(until: world.clock.now.addingTimeInterval(25 * 60)))
        world.clock.advance(25 * 60)
        XCTAssertEqual(controller.check(.stand), .remind)
        XCTAssertEqual(world.system.huds, ["Eye Break", "Time to Stand"])
    }

    func testRemindersWaitDuringABreakWhilePausedAndAfterSleep() {
        world.settings.settings.eyeBreaksEnabled = true
        let controller = makeController()
        controller.refresh()
        world.clock.advance(21 * 60)
        controller.isOnBreak = { true }
        XCTAssertEqual(controller.check(.eyes), .rested, "a focus break is already a rest")
        controller.isOnBreak = { false }
        world.clock.advance(21 * 60)
        world.system.paused = true
        XCTAssertEqual(controller.check(.eyes), .rested, "Pause AOM")
        world.system.paused = false
        world.clock.advance(19 * 60)
        controller.rested() // the Mac woke from sleep
        world.clock.advance(5 * 60)
        if case .wait = controller.check(.eyes) {} else { XCTFail("sleep counts as rest") }
        XCTAssertTrue(world.system.huds.isEmpty)
    }

    func testOffHoldsNoClock() {
        let controller = makeController()
        controller.refresh()
        XCTAssertTrue(controller.clocks.isEmpty)
        XCTAssertNil(controller.check(.eyes))
        world.settings.settings.standBreaksEnabled = true
        controller.refresh()
        XCTAssertEqual(Array(controller.clocks.keys), [.stand])
        world.settings.settings.standBreaksEnabled = false
        controller.refresh()
        XCTAssertTrue(controller.clocks.isEmpty)
    }
}
