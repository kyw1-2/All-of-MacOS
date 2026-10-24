import AppKit
import XCTest
@testable import AllOfMacOS

/// Paste 7 parity: Erase History keeps pinboards, a smaller limit says how
/// much it deletes and can be undone, and typed filter tokens map onto chips.
@MainActor
final class ClipboardEraseAndChipTests: XCTestCase {
    private func withStore(_ body: (ClipboardStore) async throws -> Void) async throws {
        let token = "AOM-erase-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: token))
        let pasteboard = NSPasteboard(name: .init(token))
        let store = ClipboardStore(directory: directory, pasteboard: pasteboard, defaults: defaults)
        defer {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: token)
            try? FileManager.default.removeItem(at: directory)
        }
        await store.ready()
        try await body(store)
        await store.flush()
    }

    func testEraseHistoryKeepsPinnedItemsAndCanBeUndone() async throws {
        try await withStore { store in
            let board = store.createBoard(name: "Keep")
            let pinned = try XCTUnwrap(store.createTextItem("pinned"))
            store.pin(entryID: pinned.id, boardID: board.id)
            _ = store.createTextItem("one")
            _ = store.createTextItem("two")
            store.eraseHistory()
            XCTAssertEqual(store.entries.map(\.id), [pinned.id])
            XCTAssertEqual(store.boards.map(\.id), [board.id])
            XCTAssertEqual(store.undoDeletion().count, 2)
            XCTAssertEqual(store.entries.count, 3)
        }
    }

    func testReducingTheLimitCountsOnlyUnpinnedAndIsUndoable() async throws {
        try await withStore { store in
            let board = store.createBoard(name: "Keep")
            let pinned = try XCTUnwrap(store.createTextItem("pinned"))
            store.pin(entryID: pinned.id, boardID: board.id)
            for index in 0..<5 { _ = store.createTextItem("item \(index)") }
            XCTAssertEqual(store.itemsRemoved(byMaxEntries: 3), 2)
            XCTAssertEqual(store.itemsRemoved(byMaxEntries: 10), 0)
            store.applyMaxEntries(3)
            XCTAssertEqual(store.entries.filter { $0.pinboardIDs.isEmpty }.count, 3)
            XCTAssertTrue(store.entries.contains { $0.id == pinned.id }, "pinned items are never trimmed")
            XCTAssertTrue(store.canUndoDeletion)
        }
    }

    func testEraseMessageNamesWhatIsKept() {
        XCTAssertTrue(ClipboardEraseCopy.message(unpinned: 4).contains("4 unpinned items"))
        XCTAssertTrue(ClipboardEraseCopy.message(unpinned: 1).contains("Pinboards and pinned items are kept"))
    }

    func testOnlyCompletePositiveTokensBecomeChips() {
        let filters = ClipboardSearchQuery.chipFilters(in: #"type:image from:"Google Chrome" board:Work -type:text after:2026-01-01 hello "#)
        XCTAssertEqual(filters.map(\.field), ["type", "from", "board"])
        XCTAssertEqual(filters.map(\.value), ["image", "Google Chrome", "Work"])
        XCTAssertEqual(ClipboardSearchQuery.chipFilters(in: "app:Safari ").first?.field, "from")
        XCTAssertTrue(ClipboardSearchQuery.chipFilters(in: "from:Saf").isEmpty, "a token still being typed stays text")
    }
}
