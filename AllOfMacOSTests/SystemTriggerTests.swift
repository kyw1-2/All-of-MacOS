import XCTest
import AppKit
@testable import AllOfMacOS

/// System (Other Triggers) tests. The clock is driven directly rather than
/// waited on, so these run instantly and do not depend on wall-clock timing.
final class SystemTriggerTests: XCTestCase {

    override func tearDown() {
        ActionExecutor.onActionExecuted = nil
        super.tearDown()
    }

    private func date(hour: Int, minute: Int, weekday: Int = 2) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 1
        // 2026-01-04 is a Sunday, so day 3 + n lands on Calendar weekday n
        // (1 = Sunday ... 7 = Saturday).
        components.day = 3 + weekday
        components.hour = hour; components.minute = minute; components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    // MARK: - Category and naming

    func testSystemEventsBelongToOtherTriggers() {
        XCTAssertEqual(TriggerInput.systemEvent(.displayChanged).category, .otherTriggers)
        XCTAssertEqual(TriggerInput.systemEvent(.daily(hour: 9, minute: 0)).category, .otherTriggers)
        XCTAssertEqual(TriggerInput.namedTrigger("x").category, .otherTriggers)
    }

    func testScheduleDescriptionsReadNaturally() {
        XCTAssertEqual(SystemTriggerKind.daily(hour: 9, minute: 5).displayName, "Every day at 09:05")
        XCTAssertEqual(SystemTriggerKind.everyMinutes(1).displayName, "Every minute")
        XCTAssertEqual(SystemTriggerKind.everyMinutes(30).displayName, "Every 30 minutes")
        XCTAssertEqual(SystemTriggerKind.screenLocked.displayName, "Screen locks")
    }

    func testWeekdayNamesCollapseCommonSets() {
        XCTAssertEqual(SystemTriggerKind.weekdayNames(Array(1...7)), "Every day")
        XCTAssertEqual(SystemTriggerKind.weekdayNames([2, 3, 4, 5, 6]), "Weekdays")
        XCTAssertEqual(SystemTriggerKind.weekdayNames([1, 7]), "Weekends")
        XCTAssertEqual(SystemTriggerKind.weekdayNames([2]), "Mon")
        XCTAssertEqual(SystemTriggerKind.weekdayNames([]), "No days")
        // Out-of-range days are ignored rather than producing a bogus label.
        XCTAssertEqual(SystemTriggerKind.weekdayNames([0, 9, 3]), "Tue")
    }

    func testEverySystemEventHasAnIcon() {
        let kinds: [SystemTriggerKind] = [
            .daily(hour: 1, minute: 0), .weekly(days: [2], hour: 1, minute: 0),
            .everyMinutes(5), .displayChanged, .appLaunched("com.apple.Safari"),
            .appQuit("com.apple.Safari"), .powerSourceChanged(ac: true),
            .screenLocked, .screenUnlocked
        ]
        for kind in kinds {
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) needs an icon")
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind) needs a label")
        }
    }

    // MARK: - Serialization

    func testSystemTriggerInputRoundTrips() throws {
        let inputs: [TriggerInput] = [
            .systemEvent(.daily(hour: 7, minute: 30)),
            .systemEvent(.weekly(days: [2, 4, 6], hour: 18, minute: 0)),
            .systemEvent(.everyMinutes(15)),
            .systemEvent(.displayChanged),
            .systemEvent(.appLaunched("com.apple.TextEdit")),
            .systemEvent(.powerSourceChanged(ac: false)),
            .systemEvent(.screenLocked)
        ]
        for input in inputs {
            let data = try JSONEncoder().encode(input)
            XCTAssertEqual(try JSONDecoder().decode(TriggerInput.self, from: data), input)
        }
    }

    func testPresetWrittenBeforeSystemTriggersStillDecodes() throws {
        // A preset from before this feature has no systemEvent case at all.
        let legacy = Data(#"{"namedTrigger":{"_0":"hello"}}"#.utf8)
        let decoded = try JSONDecoder().decode(TriggerInput.self, from: legacy)
        XCTAssertEqual(decoded, .namedTrigger("hello"))
    }

    // MARK: - Scheduling

    func testDailyTriggerFiresOnceAtTheConfiguredMinute() {
        let monitor = SystemTriggerMonitor()
        var trigger = Trigger(name: "morning", input: .systemEvent(.daily(hour: 9, minute: 0)))
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        ActionExecutor.registerTriggers([trigger])
        monitor.registerTriggers([trigger])

        monitor.tick(now: date(hour: 8, minute: 59))
        XCTAssertEqual(fired, 0, "must not fire before the minute")

        monitor.tick(now: date(hour: 9, minute: 0))
        XCTAssertEqual(fired, 1)

        // A second tick inside the same minute must not repeat it.
        monitor.tick(now: date(hour: 9, minute: 0))
        XCTAssertEqual(fired, 1, "same minute must not fire twice")

        // The next day at the same time fires again.
        monitor.tick(now: date(hour: 9, minute: 0, weekday: 3))
        XCTAssertEqual(fired, 2)
        monitor.unregisterAll()
    }

    func testWeeklyTriggerOnlyFiresOnSelectedDays() {
        let monitor = SystemTriggerMonitor()
        // Monday(2) and Wednesday(4) only.
        var trigger = Trigger(name: "mw", input: .systemEvent(.weekly(days: [2, 4], hour: 10, minute: 0)))
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        ActionExecutor.registerTriggers([trigger])
        monitor.registerTriggers([trigger])

        monitor.tick(now: date(hour: 10, minute: 0, weekday: 3))   // Tuesday
        XCTAssertEqual(fired, 0)
        monitor.tick(now: date(hour: 10, minute: 0, weekday: 2))   // Monday
        XCTAssertEqual(fired, 1)
        monitor.tick(now: date(hour: 10, minute: 0, weekday: 4))   // Wednesday
        XCTAssertEqual(fired, 2)
        monitor.unregisterAll()
    }

    func testIntervalTriggerWaitsForItsPeriod() {
        let monitor = SystemTriggerMonitor()
        var trigger = Trigger(name: "tick", input: .systemEvent(.everyMinutes(5)))
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        ActionExecutor.registerTriggers([trigger])
        // Registration anchors the period, so the clock can be advanced from
        // a known start without the first tick firing immediately.
        let start = Date()
        monitor.registerTriggers([trigger])
        monitor.tick(now: start)
        XCTAssertEqual(fired, 0, "a fresh interval entry waits one full period")

        monitor.tick(now: start.addingTimeInterval(60))
        XCTAssertEqual(fired, 0, "one minute is inside the five-minute period")

        monitor.tick(now: start.addingTimeInterval(301))
        XCTAssertEqual(fired, 1, "past the period fires")

        // The anchor advances, so it does not fire again immediately after.
        monitor.tick(now: start.addingTimeInterval(310))
        XCTAssertEqual(fired, 1, "the period restarts from the last fire")
        monitor.unregisterAll()
    }

    func testDisabledTriggerNeverFires() {
        let monitor = SystemTriggerMonitor()
        var trigger = Trigger(name: "off", input: .systemEvent(.daily(hour: 9, minute: 0)))
        trigger.isEnabled = false
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        ActionExecutor.registerTriggers([trigger])
        monitor.registerTriggers([trigger])
        monitor.tick(now: date(hour: 9, minute: 0))
        XCTAssertEqual(fired, 0)
        monitor.unregisterAll()
    }

    func testUnregisterStopsFiring() {
        let monitor = SystemTriggerMonitor()
        var trigger = Trigger(name: "x", input: .systemEvent(.daily(hour: 9, minute: 0)))
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        ActionExecutor.registerTriggers([trigger])
        monitor.registerTriggers([trigger])
        monitor.unregisterAll()
        monitor.tick(now: date(hour: 9, minute: 0))
        XCTAssertEqual(fired, 0)
    }

    func testNonSystemTriggersAreIgnoredByThisMonitor() {
        let monitor = SystemTriggerMonitor()
        let triggers = [
            Trigger(name: "g", input: .trackpadGesture(.twoFingerTap)),
            Trigger(name: "n", input: .namedTrigger("other"))
        ]
        monitor.registerTriggers(triggers)
        // Registering nothing system means the timer never starts; ticking is a no-op.
        monitor.tick(now: date(hour: 9, minute: 0))
        monitor.unregisterAll()
    }

    // MARK: - App scoping

    func testSystemTriggerHonoursAppScoping() {
        let monitor = SystemTriggerMonitor()
        var trigger = Trigger(name: "scoped", input: .systemEvent(.daily(hour: 9, minute: 0)))
        // Bound to an app that is not frontmost, so the shared resolver skips it.
        trigger.appBundleID = "com.example.notfrontmost"
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        ActionExecutor.registerTriggers([trigger])
        monitor.registerTriggers([trigger])
        monitor.tick(now: date(hour: 9, minute: 0))
        XCTAssertEqual(fired, 0, "an app-scoped system trigger must respect the frontmost app")
        monitor.unregisterAll()
    }

    // MARK: - Power

    func testPowerStateReadsWithoutShellingOut() {
        // Must not hang or crash; the value itself depends on the machine.
        _ = SystemTriggerMonitor.isOnACPower()
    }
}
