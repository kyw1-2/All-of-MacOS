import Foundation
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardSourceFilterTests: XCTestCase {
    private func clip(_ name: String?, _ bundle: String?, _ seconds: TimeInterval) -> ClipboardEntry {
        ClipboardEntry(title: "Clip", text: "hello", sourceName: name,
                       sourceBundleID: bundle, createdAt: Date(timeIntervalSince1970: seconds),
                       items: [["public.utf8-plain-text": Data("hello".utf8)]])
    }

    func testAppListContainsOnlyActuallyRecordedSourcesSortedByRecency() {
        let entries = [
            clip("Safari", "com.apple.Safari", 100),
            clip("TextEdit", "com.apple.TextEdit", 200),
            clip("Safari", "com.apple.Safari", 300),
            clip(nil, nil, 400),
            clip("Terminal", nil, 150),
        ]
        let apps = ClipboardStore.AppSource.collect(from: entries)
        XCTAssertEqual(apps.map(\.name), ["Safari", "TextEdit", "Terminal"])
        XCTAssertEqual(apps.map(\.count), [2, 1, 1])
        XCTAssertEqual(apps.map(\.filterValue), ["com.apple.Safari", "com.apple.TextEdit", "Terminal"])
        XCTAssertNil(apps.last?.bundleID)
        XCTAssertTrue(apps[0].id.hasPrefix("bundle:"))
        XCTAssertTrue(apps[2].id.hasPrefix("name:"))
    }

    func testAppListReflectsAddedAndDeletedClipboardHistory() {
        let first = clip("Notes", "com.apple.Notes", 10)
        let next = clip("Preview", "com.apple.Preview", 20)
        XCTAssertEqual(ClipboardStore.AppSource.collect(from: [first]).map(\.name), ["Notes"])
        XCTAssertEqual(ClipboardStore.AppSource.collect(from: [first, next]).map(\.name), ["Preview", "Notes"])
        XCTAssertEqual(ClipboardStore.AppSource.collect(from: [next]).map(\.name), ["Preview"])
        XCTAssertTrue(ClipboardStore.AppSource.collect(from: []).isEmpty)
    }

    func testLegacyNameOnlySourceIsUsableWithStoreFilter() async throws {
        let entries = [clip("Legacy Browser", nil, 100), clip("Safari", "com.apple.Safari", 200)]
        let sources = ClipboardStore.AppSource.collect(from: entries)
        XCTAssertEqual(sources.map(\.name), ["Safari", "Legacy Browser"])
        let selection = try XCTUnwrap(sources.first(where: { $0.name == "Legacy Browser" }))
        XCTAssertEqual(selection.filterValue, "Legacy Browser")
        XCTAssertEqual(entries.filter {
            $0.sourceBundleID == selection.filterValue || $0.sourceName == selection.filterValue
        }.count, 1)
    }

    func testDuplicateDisplayNamesWithDistinctBundleIDsRemainDistinct() {
        let entries = [clip("Browser", "org.example.a", 10), clip("Browser", "org.example.b", 20)]
        let sources = ClipboardStore.AppSource.collect(from: entries)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(Set(sources.map(\.filterValue)), Set(["org.example.a", "org.example.b"]))
    }
}
