import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardPasteStyleTests: XCTestCase {
    func testNewTextItemAndColoredPinboardRoundTripWithoutTouchingSystemClipboard() async throws {
        let token = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-PasteUI-(token)")
        let suite = "AOM-PasteUI-(token)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let pasteboard = NSPasteboard(name: .init(suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
            pasteboard.clearContents()
        }
        let store = ClipboardStore(directory: folder, pasteboard: pasteboard, defaults: defaults)
        await store.ready()
        pasteboard.setString("Original text", forType: .string)

        let board = store.createBoard(name: "Important Notes", color: "orange")
        let newItem = try XCTUnwrap(store.createTextItem("Reusable Korean 텍스트\nSecond line"))
        store.pin(entryID: newItem.id, boardID: board.id)

        XCTAssertEqual(pasteboard.string(forType: .string), "Original text",
                       "Creating an item must not replace the user's current pasteboard.")
        XCTAssertEqual(store.filtered(board: board.id).first?.id, newItem.id)
        XCTAssertNil(store.createTextItem("  "), "Empty items must be rejected.")
        await store.flush()

        let reloaded = ClipboardStore(directory: folder,
            pasteboard: NSPasteboard(name: .init("Reload-(token)")),
            defaults: defaults)
        await reloaded.ready()
        XCTAssertEqual(reloaded.boards.first?.name, "Important Notes")
        XCTAssertEqual(reloaded.boards.first?.color, "orange")
        XCTAssertEqual(reloaded.entries.first?.text, "Reusable Korean 텍스트\nSecond line")
        XCTAssertEqual(reloaded.entries.first?.pinboardIDs, Set([board.id]))
    }

    func testPinboardColorAndSearchAreDataDriven() async throws {
        let token = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-pin-(token)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardStore(directory: folder, pasteboard:
            NSPasteboard(name: .init("AOM-pin-(token)")))
        await store.ready()
        let one = try XCTUnwrap(store.createTextItem("Email template A"))
        let two = try XCTUnwrap(store.createTextItem("Accounting case B"))
        let b = store.createBoard(name: "Study", color: "purple")
        store.pin(entryID: two.id, boardID: b.id)
        XCTAssertEqual(store.filtered(board: b.id).map(\.id), [two.id])
        XCTAssertEqual(store.filtered(query: "Email").map(\.id), [one.id])
        store.unpin(entryID: two.id, boardID: b.id)
        XCTAssertTrue(store.filtered(board: b.id).isEmpty)
    }
}
