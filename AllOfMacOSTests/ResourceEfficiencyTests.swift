import Foundation
import XCTest
@testable import AllOfMacOS

final class ResourceEfficiencyTests: XCTestCase {
    func testCountEvictionRetainsRecentlyReadEntry() {
        var cache = BoundedLRUCache<String, Int>(countLimit: 3)
        cache["a"] = 1; cache["b"] = 2; cache["c"] = 3
        XCTAssertEqual(cache["a"], 1)
        cache["d"] = 4
        XCTAssertNil(cache["b"])
        XCTAssertEqual(cache["a"], 1)
        XCTAssertEqual(cache["c"], 3)
        XCTAssertEqual(cache["d"], 4)
        XCTAssertEqual(cache.count, 3)
    }

    func testCostBudgetEvictsOnlyEnoughOldEntries() {
        var cache = BoundedLRUCache<String, String>(countLimit: 10, costLimit: 10)
        cache.insert("a", forKey: "a", cost: 3)
        cache.insert("b", forKey: "b", cost: 3)
        cache.insert("c", forKey: "c", cost: 3)
        _ = cache["a"]
        cache.insert("d", forKey: "d", cost: 4)
        XCTAssertNil(cache["b"])
        XCTAssertEqual(cache["a"], "a")
        XCTAssertEqual(cache["c"], "c")
        XCTAssertEqual(cache.totalCost, 10)
        XCTAssertEqual(cache.count, 3)
    }

    func testOversizedReplacementCannotReturnStaleValueOrFlushOtherKeys() {
        var cache = BoundedLRUCache<String, Int>(countLimit: 4, costLimit: 8)
        cache.insert(1, forKey: "changed", cost: 3)
        cache.insert(2, forKey: "keep", cost: 4)
        cache.insert(3, forKey: "changed", cost: 9)
        XCTAssertNil(cache["changed"])
        XCTAssertEqual(cache["keep"], 2)
        XCTAssertEqual(cache.totalCost, 4)
    }

    func testReplacementAndRemovalAccountForCostAndRecency() {
        var cache = BoundedLRUCache<Int, String>(countLimit: 2, costLimit: 9)
        cache.insert("old", forKey: 1, cost: 6)
        cache.insert("two", forKey: 2, cost: 2)
        cache.insert("new", forKey: 1, cost: 1)
        XCTAssertEqual(cache.totalCost, 3)
        cache.insert("three", forKey: 3, cost: 2)
        XCTAssertNil(cache[2])
        XCTAssertEqual(cache[1], "new")
        cache[1] = nil
        XCTAssertEqual(cache.totalCost, 2)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testExtremeCostsCannotOverflowAndDisabledCacheStaysEmpty() {
        var cache = BoundedLRUCache<Int, Int>(countLimit: 2, costLimit: .max)
        cache.insert(1, forKey: 1, cost: .max)
        cache.insert(2, forKey: 2, cost: 1)
        XCTAssertNil(cache[1])
        XCTAssertEqual(cache.totalCost, 1)
        cache.insert(3, forKey: 3, cost: -1)
        XCTAssertNil(cache[3])
        var disabled = BoundedLRUCache<Int, Int>(countLimit: 0)
        disabled[1] = 1
        XCTAssertEqual(disabled.count, 0)
    }

    func testEvictionReleasesOwnedValue() {
        final class Payload {}
        var cache = BoundedLRUCache<Int, Payload>(countLimit: 1)
        weak var retired: Payload?
        do {
            let first = Payload()
            retired = first
            cache[1] = first
        }
        XCTAssertNotNil(retired)
        cache[2] = Payload()
        XCTAssertNil(retired)
        XCTAssertNotNil(cache[2])
    }

    func testLongMixedWorkloadNeverExceedsEitherBound() {
        var cache = BoundedLRUCache<Int, Int>(countLimit: 7, costLimit: 64)
        for step in 0..<10_000 {
            cache.insert(step, forKey: step % 19, cost: step % 80)
            _ = cache[(step + 5) % 19]
            if step % 7 == 0 { cache.removeValue(forKey: (step + 2) % 19) }
            XCTAssertLessThanOrEqual(cache.count, 7)
            XCTAssertLessThanOrEqual(cache.totalCost, 64)
            XCTAssertGreaterThanOrEqual(cache.totalCost, 0)
        }
    }

    func testBoundedReadPreservesBytesAndAcceptsExactLimit() throws {
        try withFile(Data((0..<150_000).map { UInt8($0 % 251) })) { url, data in
            XCTAssertEqual(try BoundedFileData.read(from: url, maximumBytes: data.count), data)
            XCTAssertEqual(try BoundedFileData.read(from: url, maximumBytes: data.count + 50), data)
        }
    }

    func testOversizedReadFailsRatherThanReturningTruncatedData() throws {
        try withFile(Data(repeating: 42, count: 200_000)) { url, _ in
            XCTAssertThrowsError(try BoundedFileData.read(from: url, maximumBytes: 100_000)) {
                XCTAssertEqual($0 as? BoundedFileData.Failure, .tooLarge(limit: 100_000))
            }
        }
    }

    func testEmptyAndZeroLimitRead() throws {
        try withFile(Data()) { url, _ in
            XCTAssertEqual(try BoundedFileData.read(from: url, maximumBytes: 0), Data())
        }
        try withFile(Data([1])) { url, _ in
            XCTAssertThrowsError(try BoundedFileData.read(from: url, maximumBytes: 0))
        }
    }

    func testReadAfterReplacementUsesCurrentFileBytes() throws {
        try withFile(Data([1])) { url, _ in
            XCTAssertEqual(try BoundedFileData.read(from: url, maximumBytes: 8), Data([1]))
            try Data(repeating: 2, count: 9).write(to: url, options: .atomic)
            XCTAssertThrowsError(try BoundedFileData.read(from: url, maximumBytes: 8))
            try Data([3, 4]).write(to: url, options: .atomic)
            XCTAssertEqual(try BoundedFileData.read(from: url, maximumBytes: 8), Data([3, 4]))
        }
    }

    func testMissingFileReadRemainsAnError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try BoundedFileData.read(from: missing, maximumBytes: 16))
    }

    func testFileWatchPollingOnlySlowsWhenBothKernelWatchesAreReady() {
        XCTAssertEqual(FileWatcherPolling.interval(fileArmed: true, parentArmed: true), 30)
        for pair in [(false, false), (false, true), (true, false)] {
            XCTAssertEqual(FileWatcherPolling.interval(fileArmed: pair.0, parentArmed: pair.1), 1)
        }
    }

    private func withFile(_ data: Data, body: (URL, Data) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture")
        try data.write(to: url)
        try body(url, data)
    }
}
