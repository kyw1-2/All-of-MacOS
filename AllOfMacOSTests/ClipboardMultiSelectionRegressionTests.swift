import AppKit
import XCTest
@testable import AllOfMacOS

/// Exercises real pasteboard serialization using only a named pasteboard,
/// temporary archive and disposable preference suite. Never emits input events.
@MainActor
final class ClipboardMultiSelectionRegressionTests: XCTestCase {
    private func withStore(_ body: (ClipboardStore, NSPasteboard) async throws -> Void) async throws {
        let token = "AOM-multiple-selection-\(UUID().uuidString)"
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
        do {
            try await body(store, pasteboard)
            await store.flush()
        } catch {
            await store.flush()
            throw error
        }
    }

    func testMultipleTextSelectionProducesOneItemInRequestedOrderAndDeduplicatesIDs() async throws {
        try await withStore { store, pasteboard in
            let first = try XCTUnwrap(store.createTextItem("First 한글"))
            let second = try XCTUnwrap(store.createTextItem("Second\nline"))
            let third = try XCTUnwrap(store.createTextItem("Third 😀"))
            XCTAssertTrue(try store.write(entryIDs: [third.id, first.id, third.id, second.id],
                                          separator: " | ", playSound: false))
            XCTAssertEqual(pasteboard.pasteboardItems?.count, 1,
                           "Ordinary text destinations must receive all selected text in one item")
            XCTAssertEqual(pasteboard.string(forType: .string), "Third 😀 | First 한글 | Second\nline")
            XCTAssertEqual(store.entries.count, 3)
            XCTAssertEqual(store.entries.first(where: { $0.id == second.id })?.text, "Second\nline")
        }
    }

    func testSelectedRichAndPlainTextHaveMatchingCombinedTextAndRTF() async throws {
        try await withStore { store, pasteboard in
            let rich = NSAttributedString(string: "Red 한국어", attributes: [
                .foregroundColor: NSColor.red, .font: NSFont.boldSystemFont(ofSize: 18)
            ])
            let rtf = try rich.data(from: NSRange(location: 0, length: rich.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setString(rich.string, forType: .string))
            XCTAssertTrue(item.setData(rtf, forType: .rtf))
            XCTAssertTrue(pasteboard.writeObjects([item]))
            store.poll(sourceName: "Fixture", sourceBundleID: "test.aom.fixture")
            await store.flush()
            let richEntry = try XCTUnwrap(store.entries.first)
            let plainEntry = try XCTUnwrap(store.createTextItem("Plain tail"))
            XCTAssertTrue(try store.write(entryIDs: [richEntry.id, plainEntry.id], playSound: false))
            XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
            let expected = "Red 한국어\nPlain tail"
            XCTAssertEqual(pasteboard.string(forType: .string), expected)
            let restored = try NSAttributedString(data: XCTUnwrap(pasteboard.data(forType: .rtf)),
                options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            XCTAssertEqual(restored.string, expected)
            let color = try XCTUnwrap(restored.attribute(.foregroundColor, at: 0,
                                                         effectiveRange: nil) as? NSColor)
                .usingColorSpace(.deviceRGB)
            XCTAssertGreaterThan(try XCTUnwrap(color).redComponent, 0.9)
            XCTAssertLessThan(try XCTUnwrap(color).greenComponent, 0.1)

            XCTAssertTrue(try store.write(entryIDs: [richEntry.id, plainEntry.id],
                                          plainText: true, playSound: false))
            XCTAssertEqual(pasteboard.string(forType: .string), expected)
            XCTAssertNil(pasteboard.data(forType: .rtf), "Plain-text paste must strip the combined RTF")
        }
    }

    func testMissingSelectionDoesNotPartiallyReplaceExistingPasteboard() async throws {
        try await withStore { store, pasteboard in
            let entry = try XCTUnwrap(store.createTextItem("Selected"))
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("Keep this clipboard", forType: .string))
            let count = pasteboard.changeCount
            XCTAssertThrowsError(try store.write(entryIDs: [entry.id, UUID()], playSound: false))
            XCTAssertEqual(pasteboard.changeCount, count)
            XCTAssertEqual(pasteboard.string(forType: .string), "Keep this clipboard")
            XCTAssertThrowsError(try store.write(entryIDs: [], playSound: false))
            XCTAssertEqual(pasteboard.changeCount, count)
        }
    }

    func testMultipleFileSelectionKeepsSeparateURLItems() async throws {
        try await withStore { store, pasteboard in
            let urls = ["First file.txt", "Second 한글.txt"].map {
                FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\($0)")
            }
            var ids: [UUID] = []
            for url in urls {
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
                store.poll(sourceName: "Fixture", sourceBundleID: "test.aom.fixture")
                await store.flush()
                let entry = try XCTUnwrap(store.entries.first(where: { $0.fileURLs == [url] }))
                ids.append(entry.id)
            }
            XCTAssertTrue(try store.write(entryIDs: ids, playSound: false))
            XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
            let actual = pasteboard.pasteboardItems?.compactMap { item in
                item.string(forType: .fileURL).flatMap(URL.init(string:))
            }
            XCTAssertEqual(actual, urls)
        }
    }

    func testPanelMultiSelectionUsesVisibleOrderAndBoardSwitchClearsIt() async throws {
        try await withStore { store, pasteboard in
            let first = try XCTUnwrap(store.createTextItem("First"))
            let second = try XCTUnwrap(store.createTextItem("Second"))
            let third = try XCTUnwrap(store.createTextItem("Third"))
            let state = ClipboardPanelState()
            let results = state.results(in: store)
            state.select(first.id, in: results)
            state.select(third.id, in: results, extend: true)
            XCTAssertEqual(state.selected, Set([first.id, second.id, third.id]))
            let expected = results.compactMap(\.text).joined(separator: "\n")
            XCTAssertTrue(try store.write(entryIDs: state.selectedIDs(in: store), playSound: false))
            XCTAssertEqual(pasteboard.string(forType: .string), expected)
            let board = store.createBoard(name: "Empty", color: "blue")
            state.selectBoard(board.id)
            XCTAssertTrue(state.selectedIDs(in: store).isEmpty)
            XCTAssertNil(state.focusedID)
        }
    }
}
