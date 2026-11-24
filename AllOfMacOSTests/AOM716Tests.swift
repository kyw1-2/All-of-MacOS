import XCTest
@testable import AllOfMacOS

/// 7.16: GPT's independent review of 7.15 (V01–V16).
final class AOM716Tests: XCTestCase {
    // V01: a selection that disappears falls back; Return can't index past the end.
    func testActionPanelSelectionSurvivesAShrinkingList() {
        let ten = (0..<10).map { "a\($0)" }
        XCTAssertEqual(AOMActionPanelSelection.step("a8", by: 1, in: ten), "a9")
        XCTAssertEqual(AOMActionPanelSelection.step("a9", by: 1, in: ten), "a9", "clamped at the end")
        let three = ["a0", "a1", "a2"]
        XCTAssertNil(AOMActionPanelSelection.resolve("a9", in: three), "a removed action must not select or execute a different action")
        XCTAssertEqual(AOMActionPanelSelection.step("a9", by: 1, in: three), "a0")
        XCTAssertEqual(AOMActionPanelSelection.resolve(nil, in: three), "a0")
        XCTAssertNil(AOMActionPanelSelection.resolve("a1", in: []))
        XCTAssertNil(AOMActionPanelSelection.step("a1", by: 1, in: []))
        XCTAssertEqual(AOMActionPanelSelection.step(nil, by: -1, in: three), "a0")
    }

    // V07: off, unreadable, not read yet and empty are different; apps count once.
    func testMenuBarHeadlineStates() {
        XCTAssertEqual(MenuBarHeadline.text(hidingOn: false, canRead: true, readOnce: true, hiddenOwners: []), "Menu bar hiding is off")
        XCTAssertEqual(MenuBarHeadline.text(hidingOn: true, canRead: false, readOnce: true, hiddenOwners: ["a"]), "AOM can't read the menu bar")
        XCTAssertEqual(MenuBarHeadline.text(hidingOn: true, canRead: true, readOnce: false, hiddenOwners: []), "Reading the menu bar…")
        XCTAssertEqual(MenuBarHeadline.text(hidingOn: true, canRead: true, readOnce: true, hiddenOwners: []), "Nothing is hidden")
        XCTAssertEqual(MenuBarHeadline.text(hidingOn: true, canRead: true, readOnce: true,
                                            hiddenOwners: ["com.a", "com.a", "com.b", nil, ""]), "2 apps are hidden")
    }

    // V06: hysteresis around 860 pt.
    func testMenuBarPaneLayoutHysteresis() {
        XCTAssertTrue(MenuBarPaneNavigation.sideBySide(width: 900, current: false))
        XCTAssertFalse(MenuBarPaneNavigation.sideBySide(width: 800, current: true))
        XCTAssertTrue(MenuBarPaneNavigation.sideBySide(width: 859, current: true), "inside the band it stays")
        XCTAssertFalse(MenuBarPaneNavigation.sideBySide(width: 861, current: false), "inside the band it stays")
    }

    // V04: an old writer's late clear doesn't remove the new writer's context.
    @MainActor
    func testBarContextClearOnlyByItsOwner() {
        let contexts = AOMBarContexts.shared
        let old = UUID(), new = UUID()
        contexts.set(AOMBarContext(title: "old"), for: .files, writer: old)
        contexts.set(AOMBarContext(title: "new"), for: .files, writer: new)
        contexts.clear(.files, writer: old)
        XCTAssertEqual(contexts.contexts[.files]?.title, "new")
        contexts.clear(.files, writer: new)
        XCTAssertNil(contexts.contexts[.files])
    }

    // V15: a comparison of the same small pair is answered at once and kept.
    @MainActor
    func testDiffJobAnswersSmallPairsInline() {
        let job = PaletteDiffJob.shared
        job.clear()
        let changes = job.changes("a\nb", "a\nc", ready: {})
        XCTAssertEqual(changes?.count, 1)
        job.clear()
    }
}
