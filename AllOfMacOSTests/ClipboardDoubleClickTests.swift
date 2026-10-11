import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardDoubleClickTests: XCTestCase {
    func testDoubleClickWritesStoredItemToPasteboardWithoutAutomaticPaste() async throws {
        let token = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-double-click-\(token)")
        let pasteboard = NSPasteboard(name: .init("AOM-double-click-\(token)"))
        let store = ClipboardStore(directory: dir, pasteboard: pasteboard)
        defer {
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: dir)
        }

        await store.ready()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Selected clip from history", forType: .string))
        store.poll(sourceName: "Test", sourceBundleID: "com.test.clipboard")
        await store.flush()
        let entry = try XCTUnwrap(store.entries.first)

        // Another item is currently on the clipboard. Double-click must copy
        // the chosen history entry, independent of the auto-paste preference.
        XCTAssertTrue(store.settings.pasteDirectly)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Different clipboard", forType: .string))

        XCTAssertTrue(try ClipboardPanelController.copyEntry(entry.id, from: store))
        XCTAssertEqual(pasteboard.string(forType: .string), "Selected clip from history")
        XCTAssertEqual(store.entries.first?.id, entry.id)
    }

    func testDoubleClickCanCopyAsPlainTextAndRejectsMissingItems() async throws {
        let token = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-double-click-plain-\(token)")
        let pasteboard = NSPasteboard(name: .init("AOM-double-click-plain-\(token)"))
        let store = ClipboardStore(directory: dir, pasteboard: pasteboard)
        defer {
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: dir)
        }
        await store.ready()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Plain copy", forType: .string))
        store.poll(sourceName: "Test", sourceBundleID: "com.test.clipboard")
        await store.flush()
        let entry = try XCTUnwrap(store.entries.first)

        XCTAssertTrue(try ClipboardPanelController.copyEntry(entry.id, from: store, plainText: true))
        XCTAssertEqual(pasteboard.string(forType: .string), "Plain copy")

        XCTAssertThrowsError(try ClipboardPanelController.copyEntry(UUID(), from: store))
        XCTAssertEqual(pasteboard.string(forType: .string), "Plain copy",
                       "Failed copying must not clear existing clipboard contents")
    }
}
