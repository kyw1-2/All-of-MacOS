import XCTest
@testable import AllOfMacOS

/// Insights' activity chart (3.3.6): one bucket per day or hour, counting
/// only automations that ran, with the current bucket marked.
final class InsightsActivityTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testDailyBucketsCountRunsPerDayForSevenDays() {
        let now = date(30, 15)
        let events = [
            GestureEvent(gesture: "a", timestamp: date(30, 9), fired: true),
            GestureEvent(gesture: "a", timestamp: date(30, 10), fired: true),
            GestureEvent(gesture: "a", timestamp: date(30, 11), fired: false), // recognised, not run
            GestureEvent(gesture: "b", timestamp: date(28, 23, 59), fired: true),
            GestureEvent(gesture: "b", timestamp: date(24, 0), fired: true),   // first day of the window
            GestureEvent(gesture: "c", timestamp: date(23, 23), fired: true),  // before the window
        ]
        let buckets = StatisticsView.activityBuckets(events: events, hourly: false, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 7)
        XCTAssertEqual(buckets.map(\.runs), [1, 0, 0, 0, 1, 0, 2])
        XCTAssertEqual(buckets.first?.start, date(24, 0))
        XCTAssertEqual(buckets.filter(\.isCurrent).map(\.start), [date(30, 0)])
    }

    func testHourlyBucketsCoverTheLast24Hours() {
        let now = date(30, 15, 30)
        let events = [
            GestureEvent(gesture: "a", timestamp: date(30, 15, 5), fired: true),
            GestureEvent(gesture: "a", timestamp: date(29, 16, 0), fired: true),  // first hour of the window
            GestureEvent(gesture: "a", timestamp: date(29, 15, 59), fired: true), // just before it
        ]
        let buckets = StatisticsView.activityBuckets(events: events, hourly: true, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets.first?.start, date(29, 16))
        XCTAssertEqual(buckets.first?.runs, 1)
        XCTAssertEqual(buckets.last?.runs, 1)
        XCTAssertTrue(buckets.last?.isCurrent == true)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.runs }, 2)
    }

    func testNoEventsGiveEmptyBucketsNotMadeUpValues() {
        let buckets = StatisticsView.activityBuckets(events: [], hourly: false, now: date(30, 12), calendar: calendar)
        XCTAssertEqual(buckets.count, 7)
        XCTAssertTrue(buckets.allSatisfy { $0.runs == 0 })
    }
}
