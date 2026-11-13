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

    /// 3.4.43: 3.4.42 deadlocked in applicationWillTerminate. The flush waited
    /// for its I/O queue while that queue's `defaults.set` posted a change
    /// notification to a `queue: .main` observer, which waited for main.
    func testFlushWithMainQueueDefaultsObserverCompletesAndPersists() throws {
        let suite = "com.kyw.allofmacos.tests.statistics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                              object: defaults, queue: .main) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let stats = GestureStatistics(defaults: defaults)
        stats.recordFire("swipe")
        stats.flushPendingWrites()
        stats.recordFire("swipe")
        stats.flushPendingWrites()
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(GestureStatistics(defaults: defaults).totalFired, 2)
    }

    /// 3.4.44: the key-remap give-back at quit stored the owned pairs with
    /// `UserDefaults.set` on its own queue while main waited in `queue.sync`,
    /// the same shape as the 3.4.42 hang. The store must now run on main,
    /// after hidutil, with a `queue: .main` defaults observer present.
    func testKeyRemapGiveBackStoresOnMainWithMainQueueObserver() throws {
        let suite = "com.kyw.allofmacos.tests.remap.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                              object: defaults, queue: .main) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var owned = [HIDKeyMapping.pair(0x39, 0x6D)]
        var storedOnMain = true
        var calls: [String] = []
        let service = InputRemapService(hidutil: { arguments in
            calls.append(arguments[1]); return arguments[1] == "--get" ? "" : "ok"
        }, loadOwned: { owned }, saveOwned: { pairs in
            storedOnMain = storedOnMain && Thread.isMainThread
            owned = pairs
            defaults.set(try? JSONEncoder().encode(pairs), forKey: "AOMKeyRemapOwnedPairs")
        })
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(service.giveBackOwnedMappings(timeout: 2))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertTrue(storedOnMain)
        XCTAssertEqual(owned, [])
        XCTAssertEqual(calls, ["--get", "--set"])
        XCTAssertGreaterThan(changes, 0)
    }

    /// A hidutil that never returns must not keep Quit waiting, and the owned
    /// pairs stay recorded so the next launch can still take them back.
    func testKeyRemapGiveBackIsBoundedAndKeepsOwnedPairsOnTimeout() {
        let pairs = [HIDKeyMapping.pair(0x39, 0x6D)]
        var owned = pairs
        let service = InputRemapService(hidutil: { _ in Thread.sleep(forTimeInterval: 1); return "" },
                                        loadOwned: { owned }, saveOwned: { owned = $0 })
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(service.giveBackOwnedMappings(timeout: 0.2))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.8)
        XCTAssertEqual(owned, pairs)
    }

    /// 3.4.44: idle wake-up budgets for the two always-on pollers.
    func testAlwaysOnPollersStayWithinWakeBudget() {
        XCTAssertGreaterThanOrEqual(ClipboardStore.pollInterval(recording: true), 0.15)
        XCTAssertLessThanOrEqual(ClipboardStore.pollInterval(recording: true), 0.2)
        XCTAssertEqual(ClipboardStore.pollInterval(recording: false), 60)
        XCTAssertGreaterThanOrEqual(SecureInputHotKeys.pollInterval, 0.5)
    }

    /// 3.4.44: the master-switch observation fires for its own key only and
    /// delivers on main asynchronously, so a background writer never waits.
    func testAutomationGateObservationIgnoresOtherKeysAndDeliversOnMain() throws {
        let suite = "com.kyw.allofmacos.tests.gate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        var onMain = true
        let observation = AutomationGate.observe(defaults) { calls += 1; onMain = onMain && Thread.isMainThread }
        defer { observation.invalidate() }
        let written = expectation(description: "background write returns")
        DispatchQueue.global().async {
            defaults.set(1, forKey: "AOMUnrelatedKey")
            defaults.set(false, forKey: AutomationGate.masterSwitchKey)
            written.fulfill()
        }
        wait(for: [written], timeout: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(onMain)
    }

    /// 3.4.44: opening with a missing app on the main thread used to report success.
    func testFolderRulesOpenWithMissingAppFailsOnMain() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aom-open-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let missing = URL(fileURLWithPath: "/Applications/AOM Missing \(UUID().uuidString).app")
        XCTAssertFalse(FolderRulesLive.open(file, with: missing))
        XCTAssertTrue(FolderRulesLive.isLaunchableApp(URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
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
