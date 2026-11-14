import XCTest
@testable import AllOfMacOS

final class RuntimePerformanceTests: XCTestCase {
    func testOwnerLookupSharesPositiveAndNegativeAncestorReads() {
        var reads: [pid_t: Int] = [:]
        let lookup = AudioOwnerLookup<String> { pid in
            reads[pid, default: 0] += 1
            return pid == 42 ? "owner" : nil
        }
        for _ in 0..<100 {
            XCTAssertNil(lookup.value(for: 10))
            XCTAssertEqual(lookup.value(for: 42), "owner")
        }
        XCTAssertEqual(reads, [10: 1, 42: 1])
    }

    func testNextOwnerSweepObservesPIDReuseAndNewlyRegularApps() {
        var identities: [pid_t: String] = [42: "old"]
        let first = AudioOwnerLookup<String> { identities[$0] }
        XCTAssertEqual(first.value(for: 42), "old")
        XCTAssertNil(first.value(for: 10))
        identities = [42: "replacement", 10: "newly regular"]
        let next = AudioOwnerLookup<String> { identities[$0] }
        XCTAssertEqual(next.value(for: 42), "replacement")
        XCTAssertEqual(next.value(for: 10), "newly regular")
    }

    func testWorkspaceObjectAvoidsSecondLookupAndCachesMissingPolicy() {
        let lookup = AudioOwnerLookup<String> { _ in XCTFail("redundant process lookup"); return nil }
        XCTAssertEqual(lookup.value(for: 42, orLoad: { "workspace owner" }), "workspace owner")
        XCTAssertEqual(lookup.value(for: 42), "workspace owner")
        XCTAssertNil(lookup.value(for: 10, orLoad: { nil }))
        XCTAssertNil(lookup.value(for: 10))
    }

    func testEmptyWindowQueryDoesNotEnumerateDesktop() {
        XCTAssertEqual(WindowInfoQuery.descriptions(for: [])?.count, 0)
    }

    @MainActor
    func testWindowPollerDiscardsInvalidatedResultAndAllowsNextRead() async throws {
        let poller = WindowPinSnapshotPoller<Int>()
        let finished = expectation(description: "read finished")
        let stale = expectation(description: "stale result suppressed")
        stale.isInverted = true
        XCTAssertTrue(poller.request(read: { finished.fulfill(); return 1 }, apply: { _ in stale.fulfill() }))
        XCTAssertFalse(poller.request(read: { 2 }, apply: { _ in XCTFail("overlapping read") }))
        poller.invalidate()
        await fulfillment(of: [finished, stale], timeout: 0.2)
        let applied = expectation(description: "next snapshot applied")
        XCTAssertTrue(poller.request(read: { 3 }, apply: { value in
            XCTAssertEqual(value, 3)
            applied.fulfill()
        }))
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertFalse(poller.inFlight)
    }

    // 3.4.43: pollers share one lock reading; notifications override it.
    func testScreenLockPollingCacheQueriesOncePerTTLAndTakesNotifications() {
        var clock: TimeInterval = 100
        var queries = 0
        var locked = false
        let cache = ScreenLockPollingCache(ttl: 3, query: { queries += 1; return locked }, now: { clock })
        for _ in 0..<20 { XCTAssertFalse(cache.value()) }
        XCTAssertEqual(queries, 1)
        cache.store(true)
        XCTAssertTrue(cache.value())
        XCTAssertEqual(queries, 1, "a lock notification must apply without a WindowServer call")
        clock += 3
        locked = false
        XCTAssertFalse(cache.value())
        XCTAssertEqual(queries, 2, "the TTL re-asks in case a notification was missed")
    }

    func testProcessIDCacheDropsOnExitAndExpires() {
        var clock: TimeInterval = 0
        var resolves = 0
        var alive: Set<pid_t> = [10, 20]
        let cache = ProcessIDCache(ttl: 15, isAlive: { alive.contains($0) }, now: { clock }) {
            resolves += 1
            return Array(alive).sorted()
        }
        for _ in 0..<10 { XCTAssertEqual(cache.value(), [10, 20]) }
        XCTAssertEqual(resolves, 1)
        alive = [11, 20]  // the Dock restarted
        XCTAssertEqual(cache.value(), [11, 20])
        XCTAssertEqual(resolves, 2)
        clock = 15
        _ = cache.value()
        XCTAssertEqual(resolves, 3)
    }

    func testAudioDiagnosticsWritesAreThrottledUnlessResetIsRequested() {
        XCTAssertTrue(AudioDiagnostics.shouldWrite(now: 0, lastWrite: -.infinity, resetRequested: false))
        XCTAssertFalse(AudioDiagnostics.shouldWrite(now: 4.9, lastWrite: 0, resetRequested: false))
        XCTAssertTrue(AudioDiagnostics.shouldWrite(now: 4.9, lastWrite: 0, resetRequested: true))
        XCTAssertTrue(AudioDiagnostics.shouldWrite(now: 5, lastWrite: 0, resetRequested: false))
    }

    @available(macOS 14.2, *)
    func testOwnerResolutionTTLIsABackstopNotASweepCadence() {
        XCTAssertGreaterThanOrEqual(AppAudioEngine.ownerResolutionTTL, 30)
    }

    /// The diagnostics histogram keeps the 3.4 JSON keys for readings below
    /// 1.0 and labels higher ones correctly (1.5 used to be filed as "0.15").
    func testTouchPressureHistogramKeepsKeysAndLabelsReadingsAboveOne() {
        var histogram = TouchPressureHistogram()
        for pressure: Float in [0, 0.05, 0.42, 0.99, 1.0, 1.5, 1.5, -0.2, .nan, 100] { histogram.record(pressure) }
        XCTAssertEqual(histogram.labelled, ["0.0": 4, "0.4": 1, "0.9": 1, "1.0": 1, "1.5": 2, "6.3": 1])
        XCTAssertEqual(TouchPressureHistogram.bucket(for: 0.75), 7)
        XCTAssertEqual(TouchPressureHistogram().labelled, [:])
    }
}
