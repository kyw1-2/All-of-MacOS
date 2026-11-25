import XCTest
@testable import AllOfMacOS

final class AOMCalmWorkbenchW5Tests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testRollingWindowIncludesItsPartialFirstHour() {
        let now = Date(timeIntervalSince1970: 1_800_001_800)
        let cutoff = now.addingTimeInterval(-86_400)
        let events = [
            GestureEvent(gesture: "outside", timestamp: cutoff.addingTimeInterval(-1), fired: true),
            GestureEvent(gesture: "boundary", timestamp: cutoff, fired: true),
            GestureEvent(gesture: "now", timestamp: now, fired: true),
            GestureEvent(gesture: "future", timestamp: now.addingTimeInterval(1), fired: true)
        ]
        let series = StatisticsView.activitySeries(events: events, period: .day, now: now, calendar: utc)
        XCTAssertEqual(series.buckets.count, 25)
        XCTAssertEqual(series.buckets.first?.runs, 1)
        XCTAssertEqual(series.buckets.last?.runs, 1)
        XCTAssertEqual(series.total, 2)
        let log = AOMActivityLog.events(events, now: now, within: 86_400,
                                       bucketStart: series.buckets.first?.start, hourly: true,
                                       runsOnly: true, calendar: utc, bucketUnit: series.unit)
        XCTAssertEqual(log.map(\.gesture), ["boundary"])
    }

    func testAllTimeIncludesOlderLoggedRunsAndFiltersTheirMonth() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            GestureEvent(gesture: "earlier", timestamp: now.addingTimeInterval(-70 * 86_400), fired: true),
            GestureEvent(gesture: "current", timestamp: now, fired: true)
        ]
        let series = StatisticsView.activitySeries(events: events, period: .all, now: now, calendar: utc)
        let first = try XCTUnwrap(series.buckets.first)
        XCTAssertEqual(series.unit, .month)
        XCTAssertEqual(series.total, 2)
        let log = AOMActivityLog.events(events, now: now, within: nil, bucketStart: first.start, hourly: false,
                                       runsOnly: true, calendar: utc, bucketUnit: series.unit)
        XCTAssertEqual(log.map(\.gesture), ["earlier"])
    }

    func testUndoNoteDistinguishesTrashRecoveryFromPermanentRemoval() {
        XCTAssertEqual(SystemToolUndoNote.note(.resetSavedState, kind: .command), SystemToolUndoNote.trashRecovery)
        XCTAssertEqual(SystemToolUndoNote.note(.uninstall, kind: .command), SystemToolUndoNote.trashRecovery)
        XCTAssertNotEqual(SystemToolUndoNote.note(.freeUpSpace, kind: .sheet), SystemToolUndoNote.trashRecovery)
    }
}
