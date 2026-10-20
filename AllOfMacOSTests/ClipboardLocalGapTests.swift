import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardLocalGapTests: XCTestCase {
    func testNativeDragPreservesEveryFileAndOrderWithoutReadingFiles() throws {
        let urls = [URL(fileURLWithPath: "/missing/one.txt"), URL(fileURLWithPath: "/missing/two.txt"), URL(fileURLWithPath: "/missing/three.txt")]
        let entry = ClipboardEntry(title: "Files", kind: .file, items: urls.map { [NSPasteboard.PasteboardType.fileURL.rawValue: Data($0.absoluteString.utf8)] })
        let writers = ClipboardNativeDragView.fileWriters(for: entry)
        XCTAssertEqual(writers.compactMap { $0.string(forType: .fileURL) }, urls.map(\.absoluteString))
        XCTAssertTrue(writers.allSatisfy { $0.string(forType: NSPasteboard.PasteboardType("com.kyw.allofmacos.clipboard-pinboard-entry")) == entry.id.uuidString })
    }

    func testOldPinboardArchiveDecodesAndManualOrderRoundTrips() throws {
        let id = UUID()
        let oldJSON = "{\"id\":\"\(id.uuidString)\",\"name\":\"Work\",\"color\":\"blue\"}"
        let old = try JSONDecoder().decode(ClipboardPinboard.self, from: Data(oldJSON.utf8))
        XCTAssertNil(old.itemOrder)
        var current = old
        current.itemOrder = [UUID(), UUID()]
        XCTAssertEqual(try JSONDecoder().decode(ClipboardPinboard.self, from: JSONEncoder().encode(current)), current)
    }

    func testPinboardReorderLeavesHistoryAndOtherBoardsUntouched() async throws {
        let store = ClipboardStore()
        await store.ready()
        let first = store.createBoard(name: "First"), second = store.createBoard(name: "Second")
        let a = try XCTUnwrap(store.createTextItem("alpha")), b = try XCTUnwrap(store.createTextItem("beta")), c = try XCTUnwrap(store.createTextItem("gamma"))
        for entry in [a, b, c] { store.pin(entryID: entry.id, boardID: first.id) }
        store.pin(entryID: b.id, boardID: second.id)
        let history = store.entries.map(\.id)
        store.moveItem(a.id, before: c.id, in: first.id)
        XCTAssertEqual(store.filtered(board: first.id).map(\.id), [a.id, c.id, b.id])
        XCTAssertEqual(store.entries.map(\.id), history)
        XCTAssertEqual(store.filtered(board: second.id).map(\.id), [b.id])
        store.moveBoard(second.id, before: first.id)
        XCTAssertEqual(store.boards.map(\.id), [second.id, first.id])
    }

    func testPrivatePreferencesStartOfflineAndKeepExistingSettingsUntouched() {
        let suite = "AOMClipboardGap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("preserved".utf8), forKey: "AOMClipboardSettings.v1")
        let prefs = ClipboardPreferences(defaults: defaults)
        XCTAssertFalse(prefs.networkPreviews)
        XCTAssertEqual(prefs.quickModifier, .command)
        XCTAssertEqual(prefs.plainModifier, .shift)
        prefs.quickModifier = .option; prefs.plainModifier = .control
        XCTAssertTrue(prefs.isQuick(.option))
        XCTAssertTrue(prefs.isQuick([.option, .control]))
        XCTAssertFalse(prefs.isQuick([.option, .command]))
        XCTAssertTrue(prefs.isPlain(.control))
        XCTAssertEqual(ClipboardPreferences(defaults: defaults).quickModifier, .option)
        XCTAssertEqual(defaults.data(forKey: "AOMClipboardSettings.v1"), Data("preserved".utf8))
    }

    func testSearchTokensRespectQuotesAndShowDistantOCRMatch() {
        let query = "invoice from:\"Google Chrome\" type:image -draft"
        XCTAssertEqual(ClipboardSearchQuery.filterTokens(in: query), ["from:\"Google Chrome\"", "type:image"])
        XCTAssertEqual(ClipboardSearchQuery.editableText(in: "type:image needle"), "needle")
        XCTAssertEqual(ClipboardSearchQuery.editableText(in: "from:S"), "from:S", "Incomplete unquoted app filters stay editable until committed")
        XCTAssertEqual(ClipboardSearchQuery.replacing(token: "type:image", with: "type:text", in: query), "invoice from:\"Google Chrome\" type:text -draft")
        XCTAssertEqual(ClipboardSearchQuery.removing(token: "from:\"Google Chrome\"", from: query), "invoice type:image -draft")
        XCTAssertEqual(ClipboardSearchQuery.inserting(token: "type:image", into: "invoice type:im"), "invoice type:image ")
        let highlighted = ClipboardSearchQuery("needle").highlighted(String(repeating: "a", count: 1_000) + " NEEDLE end", limit: 100)
        XCTAssertTrue(String(highlighted.characters).contains("NEEDLE"))
        XCTAssertTrue(highlighted.runs.contains { $0.backgroundColor != nil })
        XCTAssertEqual(ClipboardSearchQuery("type:image -draft").highlightValues, [])
    }

    func testStackReorderRespectsReverseDirectionAndRejectsStaleDrop() {
        let state = ClipboardPanelState()
        let saved = state.stackReversed
        defer { state.stackReversed = saved }
        let a = UUID(), b = UUID(), c = UUID()
        state.stack = [a, b, c]; state.stackReversed = false
        state.reorderStack(from: 2, before: 0, expected: [a, b, c])
        XCTAssertEqual(state.stack, [c, a, b])
        state.reorderStack(from: 0, before: 2, expected: [a, b, c])
        XCTAssertEqual(state.stack, [c, a, b], "Stale drags cannot reorder fresh copies")
        state.stack = [a, b, c]; state.stackReversed = true
        state.reorderStack(from: 0, before: 2, expected: [a, b, c])
        XCTAssertEqual(state.stack, [b, c, a], "The first visual row is the next paste in reverse mode")
    }

    func testNativeColorCaptureAndVisualEditPreserveNativeRepresentation() async throws {
        let color = NSColor(srgbRed: 0.1, green: 0.7, blue: 0.2, alpha: 0.5)
        let native = try XCTUnwrap(color.pasteboardPropertyList(forType: .color) as? Data)
        let entry = ClipboardEntry.captured(items: [[NSPasteboard.PasteboardType.color.rawValue: native]], sourceName: nil, sourceBundleID: nil, at: Date())
        XCTAssertEqual(entry.kind, .color)
        XCTAssertNotNil(entry.text)
        let store = ClipboardStore()
        await store.ready()
        let created = try XCTUnwrap(store.createTextItem("#FF8800"))
        store.editText(entryID: created.id, text: "#00FF0080")
        let edited = try XCTUnwrap(store.entries.first { $0.id == created.id })
        let payload = try XCTUnwrap(edited.items.first?[NSPasteboard.PasteboardType.color.rawValue])
        let decoded = try XCTUnwrap(NSColor(pasteboardPropertyList: payload, ofType: .color)?.usingColorSpace(.sRGB))
        XCTAssertEqual(decoded.greenComponent, 1, accuracy: 0.001)
        XCTAssertEqual(decoded.alphaComponent, 128.0 / 255, accuracy: 0.001)
    }

    func testColorEditorUnderstandsShortAndAlphaHex() throws {
        let short = try XCTUnwrap(ClipboardColorEditor.color("#0F08")?.usingColorSpace(.sRGB))
        XCTAssertEqual(short.greenComponent, 1, accuracy: 0.001)
        XCTAssertEqual(short.alphaComponent, 136.0 / 255, accuracy: 0.001)
        XCTAssertNil(ClipboardColorEditor.color("#oops"))
    }
}
