import XCTest
@testable import AllOfMacOS

/// Menu search: flattening an app's menu bar (fixtures, no Accessibility),
/// key-equivalent text in the HIG order, matching and ranking, the shortcut
/// sheet's grouping, and the per-app cache with its lifetime and size.
final class PaletteMenuIndexTests: XCTestCase {
    private func fixture() -> [PaletteMenuNode] {
        [
            PaletteMenuNode(title: "File", children: [
                PaletteMenuNode(title: "New Window", commandCharacter: "N"),
                PaletteMenuNode(title: ""), // separator
                PaletteMenuNode(title: "Export", children: [
                    PaletteMenuNode(title: "PDF…", commandCharacter: "E", commandModifiers: 1),
                    PaletteMenuNode(title: "Web Archive", isEnabled: false),
                ]),
                PaletteMenuNode(title: "Open Recent", children: [
                    PaletteMenuNode(title: "Notes.txt"),
                    PaletteMenuNode(title: "Notes.txt"),
                ]),
            ]),
            PaletteMenuNode(title: "Edit", children: [
                PaletteMenuNode(title: "Copy", commandCharacter: "c"),
                PaletteMenuNode(title: "Paste and Match Style", commandCharacter: "V", commandModifiers: 3),
                PaletteMenuNode(title: "Delete", commandModifiers: 8, commandGlyph: 0x17),
            ]),
            PaletteMenuNode(title: "View", children: [
                PaletteMenuNode(title: "Show Sidebar", commandCharacter: "S", commandModifiers: 4, markCharacter: "✓"),
                PaletteMenuNode(title: "Previous Tab", commandModifiers: 6, commandGlyph: 0x64),
            ]),
            PaletteMenuNode(title: "편집", children: [PaletteMenuNode(title: "카카오톡 열기", commandCharacter: "K")]),
        ]
    }

    func testFlatteningKeepsChoosableItemsWithTheirPaths() {
        let items = PaletteMenuFlattener.flatten(fixture()).map(\.item)
        XCTAssertEqual(items.map(\.title), ["New Window", "PDF…", "Web Archive", "Notes.txt", "Notes.txt", "Copy",
                                            "Paste and Match Style", "Delete", "Show Sidebar", "Previous Tab", "카카오톡 열기"],
                       "separators and submenu parents are not items")
        let pdf = items[1]
        XCTAssertEqual(pdf.path, ["File", "Export"])
        XCTAssertEqual(pdf.fullPath, "File › Export › PDF…")
        XCTAssertEqual(pdf.menu, "File")
        XCTAssertFalse(items[2].isEnabled)
        XCTAssertTrue(items[8].isChecked)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "repeated titles get distinct ids")
        XCTAssertTrue(items[4].id.hasSuffix("#2"))
    }

    func testFlatteningStopsAtTheLimit() {
        let wide = [PaletteMenuNode(title: "Window", children: (0..<50).map { PaletteMenuNode(title: "Window \($0)") })]
        XCTAssertEqual(PaletteMenuFlattener.flatten(wide, limit: 10).count, 10)
    }

    func testShortcutsReadLikeMenus() {
        let shortcuts = PaletteMenuFlattener.flatten(fixture()).map(\.item.shortcut)
        XCTAssertEqual(shortcuts[0], "⌘N")
        XCTAssertEqual(shortcuts[1], "⇧⌘E", "Shift is bit 1")
        XCTAssertEqual(shortcuts[5], "⌘C", "letters are shown upper case")
        XCTAssertEqual(shortcuts[6], "⌥⇧⌘V", "Option is bit 2, and modifiers follow ⌃⌥⇧⌘")
        XCTAssertEqual(shortcuts[7], "⌫", "bit 8 means no ⌘; glyph 0x17 is Delete")
        XCTAssertEqual(shortcuts[8], "⌃⌘S", "Control is bit 4")
        XCTAssertEqual(shortcuts[9], "⌃⌥⌘←")
        XCTAssertNil(shortcuts[3])
    }

    func testSpecialKeysFromCharactersAndVirtualKeys() {
        XCTAssertEqual(PaletteMenuFlattener.shortcut(character: "\u{F700}", modifiers: 2, glyph: nil, virtualKey: nil), "⌥⌘↑")
        XCTAssertEqual(PaletteMenuFlattener.shortcut(character: "\u{F705}", modifiers: 8, glyph: nil, virtualKey: nil), "F2")
        XCTAssertEqual(PaletteMenuFlattener.shortcut(character: "\r", modifiers: 0, glyph: nil, virtualKey: nil), "⌘↩")
        XCTAssertEqual(PaletteMenuFlattener.shortcut(character: nil, modifiers: 0, glyph: nil, virtualKey: 53), "⌘⎋")
        XCTAssertEqual(PaletteMenuFlattener.shortcut(character: nil, modifiers: 1, glyph: 0x6F, virtualKey: nil), "⇧⌘F1")
        XCTAssertNil(PaletteMenuFlattener.shortcut(character: "", modifiers: 0, glyph: 0, virtualKey: nil))
    }

    func testMatchingRanksTitlesOverPathsAndSinksUnavailableItems() {
        let items = PaletteMenuFlattener.flatten(fixture()).map(\.item)
        XCTAssertEqual(PaletteMenuSearch.results(items, query: "pdf").first?.title, "PDF…")
        XCTAssertEqual(PaletteMenuSearch.results(items, query: "export").map(\.title).prefix(2), ["PDF…", "Web Archive"],
                       "the submenu's name finds its items")
        XCTAssertEqual(PaletteMenuSearch.results(items, query: "paste").first?.title, "Paste and Match Style")
        XCTAssertEqual(PaletteMenuSearch.results(items, query: "pms").first?.title, "Paste and Match Style",
                       "initials match word starts")
        XCTAssertEqual(PaletteMenuSearch.results(items, query: "ㅋㅋㅇㅌ").first?.title, "카카오톡 열기",
                       "Hangul initial consonants")
        XCTAssertEqual(PaletteMenuSearch.results(items, query: "web").first?.title, "Web Archive",
                       "an unavailable item still shows when it is the match")
        XCTAssertTrue(PaletteMenuSearch.results(items, query: "zzzz").isEmpty)
        XCTAssertTrue(PaletteMenuSearch.results(items, query: "  ").isEmpty)
        let unavailable = PaletteMenuSearch.results(items, query: "a").filter { !$0.isEnabled }
        XCTAssertEqual(PaletteMenuSearch.results(items, query: "a").suffix(unavailable.count).map(\.id), unavailable.map(\.id))
        XCTAssertEqual(PaletteMenuSearch.results(items, query: "e", limit: 3).count, 3)
    }

    func testShortcutGroupsFollowTheMenuBar() {
        let items = PaletteMenuFlattener.flatten(fixture()).map(\.item)
        let groups = PaletteMenuSearch.shortcutGroups(items)
        XCTAssertEqual(groups.map(\.menu), ["File", "Edit", "View", "편집"])
        XCTAssertEqual(groups[0].items.map(\.title), ["New Window", "PDF…"], "items without keys are left out")
    }

    // MARK: Cache

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    func testCacheLifetimeVersionAndCapacity() {
        let index = PaletteMenuIndex()
        let clock = Clock()
        var reads: [pid_t] = []
        index.now = { clock.now }
        index.isTrusted = { true }
        index.reader = { pid in reads.append(pid); return self.fixture() }

        guard case .success(let first) = index.snapshot(pid: 10, appName: "A", bundleID: "a", version: "1") else {
            return XCTFail("the fixture reads")
        }
        XCTAssertEqual(first.items.count, 11)
        _ = index.snapshot(pid: 10, appName: "A", bundleID: "a", version: "1")
        XCTAssertEqual(reads, [10], "a second search within 60 s uses the cache")
        clock.now.addTimeInterval(61)
        _ = index.snapshot(pid: 10, appName: "A", bundleID: "a", version: "1")
        XCTAssertEqual(reads, [10, 10], "after the palette lifetime the menus are read again")
        _ = index.snapshot(pid: 10, appName: "A", bundleID: "a", version: "1", maxAge: PaletteMenuIndex.sheetLifetime)
        XCTAssertEqual(reads.count, 2, "the shortcut sheet accepts older menus")
        _ = index.snapshot(pid: 10, appName: "A", bundleID: "a", version: "2")
        XCTAssertEqual(reads.count, 3, "a new app version reads again")

        for pid in pid_t(20)..<pid_t(25) { _ = index.snapshot(pid: pid, appName: "X", bundleID: nil, version: nil) }
        XCTAssertNil(index.cached(pid: 10, maxAge: 600), "only the four most recent apps are kept")
        XCTAssertNotNil(index.cached(pid: 24, maxAge: 600))
    }

    func testFailures() {
        let index = PaletteMenuIndex()
        index.isTrusted = { false }
        index.reader = { _ in XCTFail("no read without Accessibility"); return nil }
        XCTAssertEqual(failure(index.snapshot(pid: 1, appName: "A", bundleID: nil, version: nil)), .notTrusted)
        index.isTrusted = { true }
        index.reader = { _ in nil }
        XCTAssertEqual(failure(index.snapshot(pid: 1, appName: "A", bundleID: nil, version: nil)), .unreadable)
        XCTAssertFalse(PaletteMenuIndex.failureReason(.apiDisabled).isEmpty)
    }

    private func failure(_ result: Result<PaletteMenuSnapshot, PaletteMenuIndex.Failure>) -> PaletteMenuIndex.Failure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }
}
