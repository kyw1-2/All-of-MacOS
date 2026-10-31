import XCTest
@testable import AllOfMacOS

/// B (PAGES) 3.4.0: the small rules behind the page and panel overhaul.
@MainActor
final class Pages340Tests: XCTestCase {
    func testCountsUseTheSingularForOne() {
        XCTAssertEqual(ClipboardPreviewCache.counted(1, "line"), "\(1.formatted()) line")
        XCTAssertEqual(ClipboardPreviewCache.counted(0, "file"), "\(0.formatted()) files")
        XCTAssertEqual(ClipboardPreviewCache.counted(2_000, "character"), "\(2_000.formatted()) characters")
    }

    func testAOneLineClipSaysLineNotLines() async {
        let entry = ClipboardEntry(title: "One", text: "Hello world", items: [])
        let content = await ClipboardPreviewCache.shared.content(for: entry)
        XCTAssertEqual(content.summary, "11 characters · 2 words · 1 line")
    }

    func testShelfMessagesStayLongEnoughToRead() {
        XCTAssertEqual(ClipboardStatusTiming.seconds(for: "Copied."), 3.5)
        let eighteenWords = Array(repeating: "word", count: 18).joined(separator: " ")
        XCTAssertEqual(ClipboardStatusTiming.seconds(for: eighteenWords), 6)
        let sixtyWords = Array(repeating: "word", count: 60).joined(separator: " ")
        XCTAssertEqual(ClipboardStatusTiming.seconds(for: sixtyWords), 8, "never longer than 8 s")
    }

    func testTheTextHUDStaysUpLongerForLongerText() {
        let short = TextCaptureHUDController.readingTime(for: "Hi")
        let long = TextCaptureHUDController.readingTime(
            for: Array(repeating: "A line of recognized text", count: 12).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(short, 4)
        XCTAssertGreaterThan(long, short)
        XCTAssertLessThanOrEqual(long, 20)
    }
}
