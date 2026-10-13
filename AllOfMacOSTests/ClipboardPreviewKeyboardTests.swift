import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class ClipboardPreviewKeyboardTests: XCTestCase {
    func testSpaceOpensSelectedPreviewButNotWithSystemCommandModifiers() {
        XCTAssertEqual(ClipboardHistoryKeyboard.selectionAction(
            keyCode: 49, characters: " ", modifiers: []), .preview)
        XCTAssertEqual(ClipboardHistoryKeyboard.selectionAction(
            keyCode: 49, characters: " ", modifiers: [.shift]), .preview)
        XCTAssertNil(ClipboardHistoryKeyboard.selectionAction(
            keyCode: 49, characters: " ", modifiers: [.command]))
        XCTAssertNil(ClipboardHistoryKeyboard.selectionAction(
            keyCode: 49, characters: " ", modifiers: [.option]))
    }

    func testCommandEEditsAndCommandRRenamesEvenWithKoreanInputMethod() {
        XCTAssertEqual(ClipboardHistoryKeyboard.selectionAction(
            keyCode: 14, characters: "ㅎ", modifiers: [.command]), .edit)
        XCTAssertEqual(ClipboardHistoryKeyboard.selectionAction(
            keyCode: 15, characters: "ㄱ", modifiers: [.command]), .rename)
        XCTAssertNil(ClipboardHistoryKeyboard.selectionAction(
            keyCode: 14, characters: "e", modifiers: []))
        XCTAssertNil(ClipboardHistoryKeyboard.selectionAction(
            keyCode: 14, characters: "e", modifiers: [.command, .option]))
        XCTAssertNil(ClipboardHistoryKeyboard.selectionAction(
            keyCode: 14, characters: "e", modifiers: [.command, .shift]))
    }

    func testSelectionAfterSearchDoesNotClearOrChangeQuery() {
        let state = ClipboardPanelState()
        state.query = "meeting notes"
        state.searchExpanded = true
        state.searchFieldActive = true
        let entry = ClipboardEntry(title: "meeting notes", text: "sample",
                                   items: [[NSPasteboard.PasteboardType.string.rawValue: Data("sample".utf8)]])
        state.select(entry.id, in: [entry])
        XCTAssertEqual(state.focusedID, entry.id)
        XCTAssertEqual(state.selected, Set([entry.id]))
        XCTAssertEqual(state.query, "meeting notes")
    }

    func testSourceApplicationIconUsesRealBundleWhenAvailable() {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") != nil {
            XCTAssertNotNil(AppMetadataCache.shared.icon(for: "com.apple.finder"))
        }
        XCTAssertNil(AppMetadataCache.shared.icon(for: nil))
    }
}
