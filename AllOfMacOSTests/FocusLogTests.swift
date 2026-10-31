import XCTest
@testable import AllOfMacOS

/// Session-log aggregation: today and this week, counts and minutes,
/// midnight and week boundaries, the seven-day chart, and the file.
@MainActor
final class FocusLogTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }()

    /// Wednesday 2027-01-13 15:00 in Seoul.
    private var now: Date { calendar.date(from: DateComponents(year: 2027, month: 1, day: 13, hour: 15))! }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour, minute: minute))!
    }

    private func entry(_ start: Date, minutes: Double, completed: Bool = true, focused: Double? = nil) -> FocusLogEntry {
        FocusLogEntry(start: start, end: start.addingTimeInterval(minutes * 60), plannedMinutes: Int(minutes),
                      focusedSeconds: (focused ?? minutes) * 60, completed: completed)
    }

    func testTodayCountsCompletedSessionsAndAllFocusedMinutes() {
        let entries = [
            entry(date(13, 9), minutes: 25),
            entry(date(13, 10), minutes: 25),
            entry(date(13, 11), minutes: 25, completed: false, focused: 12),
            entry(date(12, 9), minutes: 50)
        ]
        let stats = FocusStatsCalculator.stats(for: entries, now: now, calendar: calendar)
        XCTAssertEqual(stats.todaySessions, 2, "a stopped focus is not a session")
        XCTAssertEqual(stats.todayMinutes, 62, "but its minutes count")
        XCTAssertEqual(stats.todaySummary, "2 sessions · 62 min today")
        XCTAssertEqual(stats.weekSessions, 3)
        XCTAssertEqual(stats.weekMinutes, 112)
    }

    func testTheWeekStartsOnTheCalendarsFirstWeekday() {
        // Monday the 11th is in this week; Sunday the 10th is not.
        let entries = [entry(date(11, 8), minutes: 25), entry(date(10, 20), minutes: 25)]
        let monday = FocusStatsCalculator.stats(for: entries, now: now, calendar: calendar)
        XCTAssertEqual(monday.weekSessions, 1)
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let sunday = FocusStatsCalculator.stats(for: entries, now: now, calendar: sundayFirst)
        XCTAssertEqual(sunday.weekSessions, 2)
    }

    func testASessionAcrossMidnightSplitsItsMinutesAndCountsOnTheDayItEnded() {
        let late = entry(date(12, 23, 50), minutes: 25) // 23:50 → 00:15
        let stats = FocusStatsCalculator.stats(for: [late], now: now, calendar: calendar)
        XCTAssertEqual(stats.todaySessions, 1)
        XCTAssertEqual(stats.todayMinutes, 15)
        let yesterday = stats.lastSevenDays[stats.lastSevenDays.count - 2]
        XCTAssertEqual(yesterday.minutes, 10)
        XCTAssertEqual(yesterday.sessions, 0)
        XCTAssertEqual(stats.lastSevenDays.last?.sessions, 1)
    }

    func testPausesSpreadEvenlyWhenSplitting() {
        // 20 focused minutes over a 40-minute span from 23:40 to 00:20.
        let paused = FocusLogEntry(start: date(12, 23, 40), end: date(13, 0, 20), plannedMinutes: 25,
                                   focusedSeconds: 20 * 60, completed: false)
        let parts = FocusStatsCalculator.split(paused, calendar: calendar)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].1, 10 * 60, accuracy: 0.01)
        XCTAssertEqual(parts[1].1, 10 * 60, accuracy: 0.01)
    }

    func testTheChartHasSevenDaysEndingToday() {
        let entries = [entry(date(13, 9), minutes: 25), entry(date(7, 9), minutes: 50), entry(date(6, 9), minutes: 90)]
        let stats = FocusStatsCalculator.stats(for: entries, now: now, calendar: calendar)
        XCTAssertEqual(stats.lastSevenDays.count, 7)
        XCTAssertEqual(stats.lastSevenDays.first?.day, calendar.startOfDay(for: date(7, 12)))
        XCTAssertEqual(stats.lastSevenDays.first?.minutes, 50)
        XCTAssertEqual(stats.lastSevenDays.last?.minutes, 25)
        XCTAssertEqual(stats.lastSevenDays.map(\.minutes).reduce(0, +), 75, "the 6th is outside the chart")
    }

    func testAnEmptyLogReadsZero() {
        let stats = FocusStatsCalculator.stats(for: [], now: now, calendar: calendar)
        XCTAssertEqual(stats.todaySessions, 0)
        XCTAssertEqual(stats.weekMinutes, 0)
        XCTAssertEqual(stats.todaySummary, "0 sessions · 0 min today")
        XCTAssertEqual(stats.lastSevenDays.count, 7)
    }

    func testTheLogIsKeptOnDiskAndPruned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOMFocusLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusLogStore(directory: directory)
        store.append(entry(date(13, 9), minutes: 25), now: now)
        store.append(entry(calendar.date(byAdding: .day, value: -500, to: now)!, minutes: 25), now: now)
        XCTAssertEqual(store.entries.count, 1, "older than about a year is dropped")
        FocusStorage.flush()
        let reopened = FocusLogStore(directory: directory)
        XCTAssertEqual(reopened.entries, store.entries)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sessions.json").path))
        XCTAssertEqual(reopened.stats(now: now, calendar: calendar).todaySessions, 1)
    }
}
