import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardPasteStyleTests: XCTestCase {
    func testNewTextItemAndColoredPinboardRoundTripWithoutTouchingSystemClipboard() async throws {
        let token = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-PasteUI-\(token)")
        let suite = "AOM-PasteUI-\(token)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let pasteboard = NSPasteboard(name: .init(suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
            pasteboard.clearContents()
        }
        let store = ClipboardStore(directory: folder, pasteboard: pasteboard, defaults: defaults)
        await store.ready()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Original text", forType: .string))

        let board = store.createBoard(name: "Important Notes", color: "orange")
        let newItem = try XCTUnwrap(store.createTextItem("Reusable Korean 텍스트\nSecond line"))
        store.pin(entryID: newItem.id, boardID: board.id)

        XCTAssertEqual(pasteboard.string(forType: .string), "Original text",
                       "Creating an item must not replace the user's current pasteboard.")
        XCTAssertEqual(store.filtered(board: board.id).first?.id, newItem.id)
        XCTAssertNil(store.createTextItem("  "), "Empty items must be rejected.")
        await store.flush()

        let reloaded = ClipboardStore(directory: folder,
            pasteboard: NSPasteboard(name: .init("Reload-\(token)")),
            defaults: defaults)
        await reloaded.ready()
        XCTAssertEqual(reloaded.boards.first?.name, "Important Notes")
        XCTAssertEqual(reloaded.boards.first?.color, "orange")
        XCTAssertEqual(reloaded.entries.first?.text, "Reusable Korean 텍스트\nSecond line")
        XCTAssertEqual(reloaded.entries.first?.pinboardIDs, Set([board.id]))
    }

    func testImportantPinboardSwitchKeepsItemsAndClearsStaleSelection() async throws {
        let token = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-Important-\(token)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardStore(directory: folder,
            pasteboard: NSPasteboard(name: .init("AOM-Important-\(token)")))
        await store.ready()
        let important = store.createBoard(name: "Important", color: "green")
        let pinned = try XCTUnwrap(store.createTextItem("Pinned example"))
        let ordinary = try XCTUnwrap(store.createTextItem("Recent, not pinned"))
        store.pin(entryID: pinned.id, boardID: important.id)

        let state = ClipboardPanelState()
        XCTAssertEqual(Set(state.results(in: store).map(\.id)), Set([pinned.id, ordinary.id]))

        state.selected = [ordinary.id]
        state.selectBoard(important.id)
        XCTAssertTrue(state.selected.isEmpty)
        XCTAssertEqual(state.results(in: store).map(\.id), [pinned.id],
                       "Important must display pinned clips, not the full Clipboard history")

        state.selected = [pinned.id]
        state.selectBoard(nil)
        XCTAssertTrue(state.selected.isEmpty)
        XCTAssertEqual(Set(state.results(in: store).map(\.id)), Set([pinned.id, ordinary.id]))
        XCTAssertEqual(store.boards.first?.name, "Important")
        XCTAssertTrue(store.entries.contains(where: { $0.id == ordinary.id }),
                      "Switching pinboards must never erase ordinary clipboard history")
    }

    func testPinboardColorAndSearchAreDataDriven() async throws {
        let token = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-pin-\(token)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardStore(directory: folder, pasteboard:
            NSPasteboard(name: .init("AOM-pin-\(token)")))
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
