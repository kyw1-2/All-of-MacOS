import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardRenameRegressionTests: XCTestCase {
    func testInlineRenameIsStoredAndSurvivesReloadWithoutChangingClipContent() async throws {
        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-rename-\(identifier)")
        let suite = "AOM-rename-\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AOM-rename-\(identifier)"))
        let store = ClipboardStore(directory: directory, pasteboard: pasteboard, defaults: defaults)
        await store.ready()

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Preserve the original clipboard data", forType: .string))
        store.poll(sourceName: "Regression Test", sourceBundleID: "com.test.aom")
        await store.flush()
        let original = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(original.text, "Preserve the original clipboard data")

        store.rename(entryID: original.id, title: "  Edited and saved  ")
        XCTAssertEqual(store.entries.first?.title, "Edited and saved")
        await store.flush()

        let reopened = ClipboardStore(directory: directory,
                                     pasteboard: NSPasteboard(name: NSPasteboard.Name("AOM-reload-\(identifier)")),
                                     defaults: defaults)
        await reopened.ready()
        XCTAssertEqual(reopened.entries.first?.id, original.id)
        XCTAssertEqual(reopened.entries.first?.title, "Edited and saved")
        XCTAssertEqual(reopened.entries.first?.text, "Preserve the original clipboard data")
    }

    func testBlankTitleDoesNotDiscardExistingName() async throws {
        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-blank-\(identifier)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AOM-blank-\(identifier)"))
        let store = ClipboardStore(directory: directory, pasteboard: pasteboard)
        await store.ready()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("An entry", forType: .string))
        store.poll(sourceName: "Regression Test", sourceBundleID: "com.test.aom")
        await store.flush()
        let original = try XCTUnwrap(store.entries.first)
        store.rename(entryID: original.id, title: "   ")
        XCTAssertEqual(store.entries.first?.title, original.title)
    }
}
