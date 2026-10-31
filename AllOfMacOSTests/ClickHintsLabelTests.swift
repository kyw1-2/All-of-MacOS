import XCTest
@testable import AllOfMacOS

/// Hint labels: unique, prefix-free, shortest and home row first, for every
/// count up to 1,000.
final class ClickHintsLabelTests: XCTestCase {
    private func assertPrefixFree(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        // After sorting, a label that starts another one sits right before it.
        let sorted = labels.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.hasPrefix(a) {
            XCTFail("\(a) starts \(b)", file: file, line: line)
            return
        }
    }

    func testEveryCountUpTo1000IsUniquePrefixFreeAndShortestFirst() {
        for alphabet in ClickHintsAlphabet.allCases {
            for count in 0...1_000 {
                let labels = ClickHintsLabels.make(count: count, alphabet: alphabet)
                XCTAssertEqual(labels.count, count, "\(alphabet) \(count)")
                XCTAssertEqual(Set(labels).count, count, "\(alphabet) \(count) has duplicates")
                assertPrefixFree(labels)
                XCTAssertEqual(labels.map(\.count), labels.map(\.count).sorted(), "\(alphabet) \(count): shortest first")
                let allowed = Set(alphabet.characters(forCount: count))
                XCTAssertTrue(labels.allSatisfy { $0.allSatisfy(allowed.contains) }, "\(alphabet) \(count)")
            }
        }
    }

    func testLabelsStayShort() {
        for count in 1...1_000 {
            let longest = ClickHintsLabels.make(count: count, alphabet: .homeRow).map(\.count).max() ?? 0
            switch count {
            case ...9: XCTAssertEqual(longest, 1, "\(count)")
            case ...676: XCTAssertLessThanOrEqual(longest, 2, "\(count): two letters while the alphabet can grow")
            default: XCTAssertLessThanOrEqual(longest, 3, "\(count)")
            }
        }
        XCTAssertEqual(ClickHintsLabels.make(count: 26, alphabet: .letters).map(\.count).max(), 1)
        XCTAssertEqual(ClickHintsLabels.make(count: 676, alphabet: .letters).map(\.count).max(), 2)
        XCTAssertEqual(ClickHintsLabels.make(count: 100, alphabet: .numbers).map(\.count).max(), 2)
        XCTAssertEqual(ClickHintsLabels.make(count: 1_000, alphabet: .numbers).map(\.count).max(), 3)
    }

    func testHomeRowComesFirst() {
        XCTAssertEqual(ClickHintsLabels.make(count: 9, alphabet: .homeRow), ["f", "j", "d", "k", "s", "l", "a", "g", "h"])
        // Ten targets: the eight best keys stay single, the weakest becomes the prefix.
        XCTAssertEqual(ClickHintsLabels.make(count: 10, alphabet: .homeRow), ["f", "j", "d", "k", "s", "l", "a", "g", "hf", "hj"])
        // Up to 81 targets only the home row is used.
        let home = Set("fjdkslagh")
        for count in [20, 50, 81] {
            XCTAssertTrue(ClickHintsLabels.make(count: count, alphabet: .homeRow).allSatisfy { $0.allSatisfy(home.contains) }, "\(count)")
        }
        // 82 needs a tenth letter: the top row's best, r.
        let grown = ClickHintsLabels.make(count: 82, alphabet: .homeRow)
        XCTAssertTrue(grown.contains { $0.contains("r") })
        XCTAssertEqual(grown.prefix(2), ["f", "j"])
        // Letters start with the home row too.
        XCTAssertEqual(Array(ClickHintsLabels.make(count: 30, alphabet: .letters).prefix(9)), ["f", "j", "d", "k", "s", "l", "a", "g", "h"])
    }

    func testNumbers() {
        XCTAssertEqual(ClickHintsLabels.make(count: 10, alphabet: .numbers), Array("1234567890").map { String($0) })
        XCTAssertEqual(ClickHintsLabels.make(count: 11, alphabet: .numbers),
                       ["1", "2", "3", "4", "5", "6", "7", "8", "9", "01", "02"])
    }

    func testEveryPrefixGroupHasAtLeastTwoLabels() {
        // A prefix with one label would cost a keystroke for nothing.
        for count in 10...700 {
            let labels = ClickHintsLabels.make(count: count, alphabet: .homeRow)
            let groups = Dictionary(grouping: labels.filter { $0.count > 1 }) { $0.dropLast() }
            XCTAssertTrue(groups.values.allSatisfy { $0.count >= 2 }, "\(count)")
        }
    }

    func testTheMostLikelyTargetGetsTheShortestLabel() {
        let labels = ClickHintsLabels.make(count: 10, alphabet: .homeRow)
        // Targets 7, 2 and 9 are the most likely, in that order.
        let ranked = [7, 2, 9, 0, 1, 3, 4, 5, 6, 8]
        let assigned = ClickHintsLabels.assign(labels, toRanked: ranked, targetCount: 10)
        XCTAssertEqual(assigned[7], "f")
        XCTAssertEqual(assigned[2], "j")
        XCTAssertEqual(assigned[9], "d")
        XCTAssertEqual(assigned[8], "hj")
        XCTAssertEqual(assigned.compactMap { $0 }.count, 10)
    }

    func testOddAlphabets() {
        XCTAssertEqual(ClickHintsLabels.make(count: 0, alphabet: Array("ab")), [])
        XCTAssertEqual(ClickHintsLabels.make(count: 3, alphabet: Array("a")), ["a"])
        // Duplicates and capitals collapse.
        XCTAssertEqual(ClickHintsLabels.make(count: 3, alphabet: Array("aAbB")), ["a", "ba", "bb"])
    }
}
