import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardResponsivenessTests: XCTestCase {
    func testCardTitleKeepsWhitespaceAndNewlineSemantics() {
        let values = ["", "  \n  ", "   Title  \nBody", "  Title  ", "한국어 제목\n내용",
                      String(repeating: "가", count: 120), String(repeating: "A", count: 98) + "   "]
        for text in values {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = String(trimmed.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(100) ?? "Text".prefix(100))
            XCTAssertEqual(ClipboardCardText.automaticTitle(text), expected)
        }
    }

    func testHugeSingleLineKoreanTitleDoesNotWalkEntireClip() {
        let text = String(repeating: "한국어 캡처 ", count: 300_000)
        let start = Date()
        for _ in 0..<100 {
            XCTAssertEqual(ClipboardCardText.automaticTitle(text), String(text.prefix(100)))
        }
        let elapsed = Date().timeIntervalSince(start)
        print("Clipboard bounded title, 100 × large Korean clip: \(elapsed) s")
        XCTAssertLessThan(elapsed, 0.25, "Only the first 101 characters should be visited per card render")
    }

    func testHugeWhitespacePrefixAlsoHasBoundedTitleWork() {
        let text = String(repeating: " ", count: 4_000_000) + "Stored title"
        let start = Date()
        for _ in 0..<100 { XCTAssertEqual(ClipboardCardText.automaticTitle(text), "Text") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
    }

    func testLargeCaptureReturnsToInputLoopBeforeDecoding() async throws {
        let token = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-responsive-\(token)")
        let board = NSPasteboard(name: .init(token))
        let defaults = UserDefaults(suiteName: token)!
        let store = ClipboardStore(directory: directory, pasteboard: board, defaults: defaults)
        defer {
            board.clearContents()
            defaults.removePersistentDomain(forName: token)
            try? FileManager.default.removeItem(at: directory)
        }
        await store.ready()
        let text = String(repeating: "한국어 클립보드 캡처 성능\n", count: 80_000)
        board.clearContents()
        XCTAssertTrue(board.setString(text, forType: .string))
        let start = Date()
        store.poll(sourceName: "Test", sourceBundleID: "test.responsiveness")
        let elapsed = Date().timeIntervalSince(start)
        print("Clipboard poll before background decode: \(elapsed) s")
        XCTAssertLessThan(elapsed, 0.2, "Synchronous poll should only snapshot pasteboard representations")
        XCTAssertTrue(store.entries.isEmpty, "Classification and digest are a background transaction")
        await store.finishPendingCaptures()
        XCTAssertEqual(store.entries.first?.text, text)
        XCTAssertEqual(store.entries.first?.sourceBundleID, "test.responsiveness")
        await store.flush()
    }

    func testCapturePausedWhileBackgroundDecodeRunsIsDiscarded() async throws {
        let token = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        let board = NSPasteboard(name: .init(token))
        let store = ClipboardStore(directory: directory, pasteboard: board)
        defer { board.clearContents(); try? FileManager.default.removeItem(at: directory) }
        await store.ready()
        board.clearContents()
        board.setString(String(repeating: "private test data ", count: 20_000), forType: .string)
        store.poll()
        store.paused = true
        await store.finishPendingCaptures()
        XCTAssertTrue(store.entries.isEmpty, "Moving decode must preserve the pause-generation privacy boundary")
    }

    func testQuickPasteUsesVisibleOrderAndCapsAtNine() async throws {
        let token = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        let board = NSPasteboard(name: .init(token))
        let store = ClipboardStore(directory: directory, pasteboard: board)
        defer { board.clearContents(); try? FileManager.default.removeItem(at: directory) }
        await store.ready()
        for index in 0..<30 { _ = store.createTextItem("Item \(index)") }
        let state = ClipboardPanelState()
        let ids = state.results(in: store).map(\.id)
        XCTAssertEqual(state.quickPasteIDs(in: store), Array(ids.prefix(9)))
        state.visibleCardIDs = Array(ids[10..<25].reversed())
        XCTAssertEqual(state.quickPasteIDs(in: store), Array(ids[10..<19]))
        await store.flush()
    }
}
