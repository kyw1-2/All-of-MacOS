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
}
