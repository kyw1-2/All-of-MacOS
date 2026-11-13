import XCTest
import Combine
@testable import AllOfMacOS

@MainActor
final class MainWindowResponsivenessTests: XCTestCase {
    func testUnityAndInvalidSoftwareGainNeverQueryHardware() {
        for value in [1.0, 2, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(AudioOutputService.resolvedSoftwareGain(value) {
                XCTFail("Unity must not query HAL capabilities")
                return true
            }, 1)
        }
    }

    func testAttenuationPreservesUnsupportedAndMuteBehavior() {
        XCTAssertEqual(AudioOutputService.resolvedSoftwareGain(0.4) { true }, 0.4)
        XCTAssertEqual(AudioOutputService.resolvedSoftwareGain(0.4) { false }, 1)
        XCTAssertEqual(AudioOutputService.resolvedSoftwareGain(-1) { true }, 0)
        XCTAssertEqual(AudioOutputService.resolvedSoftwareGain(0) { false }, 1)
    }

    func testDetectionBurstDoesNotInvalidateDashboardButFireAndEvictionDo() {
        let stats = GestureStatistics(defaults: nil)
        let projection = WorkspaceValueProjection(statistics: stats)
        var updates = 0
        var sourceUpdates = 0
        let subscription = projection.objectWillChange.sink { updates += 1 }
        let sourceSubscription = stats.objectWillChange.sink { sourceUpdates += 1 }
        defer { subscription.cancel(); sourceSubscription.cancel() }
        for _ in 0..<500 { stats.recordDetection("motion") }
        XCTAssertEqual(sourceUpdates, 1_000)
        XCTAssertEqual(updates, 0)
        stats.recordFire("action")
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(projection.value.map(\.gesture), ["action"])
        for _ in 0..<GestureStatistics.recentEventLimit { stats.recordDetection("motion") }
        XCTAssertEqual(updates, 2)
        XCTAssertTrue(projection.value.isEmpty)
        stats.recordFire("next")
        stats.reset()
        XCTAssertTrue(projection.value.isEmpty)
        XCTAssertEqual(updates, 4)
    }

    func testEqualAudioSummariesDoNotInvalidateDashboard() {
        let first = WorkspaceAudioSummary(enabled: true, eqEnabled: false, eqPreset: "Flat", customApps: 2)
        let source = PassthroughSubject<WorkspaceAudioSummary, Never>()
        let projection = WorkspaceValueProjection(initial: first, publisher: source, project: { $0 })
        var updates = 0
        let subscription = projection.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }
        for _ in 0..<200 { source.send(first) }
        XCTAssertEqual(updates, 0)
        var changed = first
        changed.customApps = 3
        source.send(changed)
        source.send(changed)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(projection.value.customApps, 3)
    }

    func testWeekCachePreservesCountsAndExpiresAtMidnightAndTimezoneChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 23)))
        let yesterday = now.addingTimeInterval(-86400)
        let cache = WorkspaceWeekCache()
        let days = cache.days(actions: [now, now, yesterday], captures: [now], copies: [], now: now, calendar: calendar)
        XCTAssertEqual(days.last?.actions, 2)
        XCTAssertEqual(days.last?.captures, 1)
        XCTAssertEqual(days.dropLast().last?.actions, 1)
        XCTAssertEqual(cache.days(actions: [now, now, yesterday], captures: [now], copies: [], now: now, calendar: calendar), days)
        let changed = cache.days(actions: [now], captures: [], copies: [now], now: now, calendar: calendar)
        XCTAssertEqual(changed.last?.actions, 1)
        XCTAssertEqual(changed.last?.captures, 0)
        XCTAssertEqual(changed.last?.copies, 1)
        let tomorrow = cache.days(actions: [now], captures: [], copies: [], now: now.addingTimeInterval(7200), calendar: calendar)
        XCTAssertEqual(tomorrow.last?.actions, 0)
        XCTAssertEqual(tomorrow.dropLast().last?.actions, 1)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let seoul = cache.days(actions: [now], captures: [], copies: [], now: now, calendar: calendar)
        XCTAssertEqual(seoul.last?.actions, 1)
        XCTAssertNotEqual(seoul.last?.date, days.last?.date)
    }

    func testSystemReadLeavesMainActorFreeAndDropsStoppedResult() async {
        let started = expectation(description: "background read started")
        let release = DispatchSemaphore(value: 0)
        let monitor = SystemStatusMonitor { previous, _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            var next = previous
            next.uptime = 123
            return .init(snapshot: next, ticks: nil)
        }
        let first = monitor.sample()
        let duplicate = monitor.sample()
        await fulfillment(of: [started], timeout: 2)
        // This executes on MainActor while the reader remains blocked.
        XCTAssertEqual(monitor.snapshot.uptime, 0)
        monitor.stop()
        release.signal()
        await first.value
        await duplicate.value
        XCTAssertEqual(monitor.snapshot.uptime, 0)
    }

    func testSystemSamplingRefreshesSlowFieldsEveryFifthInterval() async {
        let monitor = SystemStatusMonitor { previous, slow in
            var next = previous
            next.uptime += 1
            if slow { next.disk = .init(available: Int64(next.uptime), total: 100) }
            return .init(snapshot: next, ticks: .init(user: UInt64(next.uptime), system: 0, idle: UInt64(next.uptime), nice: 0))
        }
        for _ in 0..<5 { await monitor.sample().value }
        XCTAssertEqual(monitor.disk?.available, 1)
        XCTAssertEqual(monitor.cpuPercent, 50)
        await monitor.sample().value
        XCTAssertEqual(monitor.disk?.available, 6)
        monitor.stop()
        await monitor.sample().value
        XCTAssertEqual(monitor.disk?.available, 7)
    }
}
