import XCTest
@testable import AllOfMacOS

/// Exercises the command palette's pure logic: empty-query grouping versus
/// the ranked search list, the Esc state machine, and the secondary-action
/// cap. Items are built locally with inert closures; no shared store is read,
/// so the cases cannot disturb the installed app.
final class QuickCommandPaletteTests: XCTestCase {

    private func item(_ id: String, title: String, subtitle: String = "",
                      section: QuickCommandPalette.Section = .commands) -> QuickCommandPalette.PaletteItem {
        QuickCommandPalette.PaletteItem(id: id, title: title, subtitle: subtitle, icon: "star",
                                        section: section,
                                        primary: QuickCommandPalette.PaletteAction(title: "Run") {})
    }

    private func results(_ items: [QuickCommandPalette.PaletteItem],
                         query: String) -> [QuickCommandPalette.PaletteItem] {
        QuickCommandPalette.PaletteSearch.results(for: items, query: query)
    }

    // MARK: Grouping vs searching

    func testEmptyQueryGroupsBySectionOrder() {
        let items = [
            item("go", title: "Settings", section: .navigation),
            item("clip", title: "Receipt", section: .clipboard),
            item("cap", title: "Screenshot", section: .captures),
            item("auto", title: "Morning Backup", section: .automations),
            item("cmd", title: "Capture Area"),
        ]
        XCTAssertEqual(results(items, query: "").map(\.id), ["cmd", "auto", "clip", "cap", "go"])
    }

    func testBlankQueryBehavesLikeEmpty() {
        let items = [item("clip", title: "Receipt", section: .clipboard),
                     item("cmd", title: "Capture Area")]
        XCTAssertEqual(results(items, query: "   ").map(\.id), ["cmd", "clip"])
    }

    func testTitlePrefixOutranksTitleContains() {
        let items = [item("recapture", title: "Recapture Region"),
                     item("area", title: "Capture Area")]
        XCTAssertEqual(results(items, query: "cap").map(\.id), ["area", "recapture"])
    }

    func testSubtitleMatchOutranksSectionMatch() {
        let items = [item("paste", title: "Paste", section: .clipboard),
                     item("trim", title: "Trim", subtitle: "Clipboard trimmer")]
        XCTAssertEqual(results(items, query: "clip").map(\.id), ["trim", "paste"])
    }

    func testEqualRankKeepsDeclarationOrder() {
        let items = [item("two", title: "Backup Now"),
                     item("one", title: "Backup Preset")]
        XCTAssertEqual(results(items, query: "backup").map(\.id), ["two", "one"])
    }

    func testNonMatchingItemsAreExcluded() {
        let items = [item("a", title: "Capture Area"), item("b", title: "Settings")]
        XCTAssertTrue(results(items, query: "zzz").isEmpty)
    }

    // MARK: Esc

    func testEscapeClearsNonEmptyQuery() {
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.escapeOutcome(query: "cap"), .clearQuery)
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.escapeOutcome(query: " trailing "), .clearQuery)
    }

    func testEscapeClosesOnEmptyOrBlankQuery() {
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.escapeOutcome(query: ""), .close)
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.escapeOutcome(query: "  "), .close)
    }

    // MARK: Secondary actions

    func testSecondariesAreCappedAtThree() {
        let actions = (1...4).map { QuickCommandPalette.PaletteAction(title: "S\($0)") {} }
        let capped = QuickCommandPalette.PaletteItem(id: "cmd", title: "Command", subtitle: "", icon: "star",
                                                     section: .commands,
                                                     primary: QuickCommandPalette.PaletteAction(title: "Run") {},
                                                     secondaries: actions)
        XCTAssertEqual(QuickCommandPalette.PaletteItem.secondaryLimit, 3)
        XCTAssertEqual(capped.secondaries.count, 3)
        XCTAssertEqual(capped.secondaries.map(\.title), ["S1", "S2", "S3"])
    }

    func testSecondariesDefaultToEmpty() {
        XCTAssertTrue(item("cmd", title: "Command").secondaries.isEmpty)
    }
}
