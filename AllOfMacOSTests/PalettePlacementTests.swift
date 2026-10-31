import XCTest
@testable import AllOfMacOS

/// The 3.4 palette list: pinned rows (calculator, quicklink) first,
/// fallbacks last, fuzzy title matches after substring matches, the Actions
/// panel's order, and the recent-files filter.
final class PalettePlacementTests: XCTestCase {
    private typealias Palette = QuickCommandPalette

    private func item(_ id: String, title: String, subtitle: String = "", section: Palette.Section = .commands,
                      placement: Palette.Placement = .ranked, secondaries: [String] = []) -> Palette.PaletteItem {
        Palette.PaletteItem(id: id, title: title, subtitle: subtitle, icon: "star", section: section,
                            primary: Palette.PaletteAction(title: "Run") {},
                            secondaries: secondaries.map { name in Palette.PaletteAction(title: name) {} },
                            placement: placement)
    }

    func testPinnedRowsLeadAndFallbacksTrail() {
        let items = [
            item("fallback", title: "Search Google for “cap”", section: .fallback, placement: .fallback),
            item("ranked", title: "Capture Area"),
            item("calc", title: "132", section: .calculator, placement: .pinned),
            item("other", title: "Settings"),
        ]
        XCTAssertEqual(Palette.PaletteSearch.results(for: items, query: "cap").map(\.id), ["calc", "ranked", "fallback"],
                       "pinned and fallback rows always show while searching; others must match")
        XCTAssertEqual(Palette.PaletteSearch.results(for: items, query: "").map(\.id), ["ranked", "other"],
                       "an empty query shows neither the calculator nor fallbacks")
    }

    func testFuzzyTitleMatchesRankAfterSubstrings() {
        let items = [
            item("fuzzy", title: "Paste and Match Style"),
            item("contains", title: "Copy as PMS"),
        ]
        XCTAssertEqual(Palette.PaletteSearch.results(for: items, query: "pms").map(\.id), ["contains", "fuzzy"])
        XCTAssertEqual(Palette.PaletteSearch.rank(of: items[0], matching: "pms"), 4)
        XCTAssertNil(Palette.PaletteSearch.rank(of: items[0], matching: "zq"))
    }

    func testCloserFuzzyMatchesComeFirst() {
        let items = [item("weaker", title: "Pick Color from Screen"), item("closer", title: "Paste and Match Style")]
        XCTAssertEqual(Palette.PaletteSearch.results(for: items, query: "pms").map(\.id), ["closer", "weaker"],
                       "all three letters starting words beat one in the middle of a word")
    }

    func testHangulInitialsFindCommands() {
        let items = [item("kakao", title: "카카오톡 열기"), item("other", title: "Capture Area")]
        XCTAssertEqual(Palette.PaletteSearch.results(for: items, query: "ㅋㅋㅇㅌ").map(\.id), ["kakao"])
    }

    func testActionsPanelOrder() {
        let row = item("row", title: "Copy Link to Current Item", secondaries: ["Copy as Markdown", "Copy URL"])
        XCTAssertEqual(row.actions.map(\.title), ["Run", "Copy as Markdown", "Copy URL"])
        XCTAssertEqual(Palette.PaletteSearch.action(at: 2, of: row)?.title, "Copy URL")
        XCTAssertNil(Palette.PaletteSearch.action(at: 3, of: row))
        XCTAssertNil(Palette.PaletteSearch.action(at: -1, of: row))
    }

    func testNewSectionsKeepTheBrowsingOrder() {
        let order = Palette.Section.allCases
        func position(_ section: Palette.Section) -> Int { order.firstIndex(of: section) ?? -1 }
        XCTAssertLessThan(position(.commands), position(.automations))
        XCTAssertLessThan(position(.captures), position(.recentFiles))
        XCTAssertLessThan(position(.recentFiles), position(.navigation))
        XCTAssertEqual(Palette.Section.recentFiles.rawValue, "Recent files", "sentence case")
    }

    // MARK: Recent files

    func testRecentFilesFilter() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let now = Date(timeIntervalSince1970: 2_000_000)
        func file(_ path: String, _ type: String?, ago: TimeInterval) -> (url: URL, contentType: String?, date: Date) {
            (URL(fileURLWithPath: path), type, now.addingTimeInterval(-ago))
        }
        let files = [
            file("/Users/test/Documents/Report.pages", "com.apple.iwork.pages.sffpages", ago: 3600),
            file("/Users/test/Library/Caches/x.db", "public.data", ago: 60),
            file("/Users/test/.config/settings.json", "public.json", ago: 60),
            file("/Users/test/Desktop/Folder", "public.folder", ago: 60),
            file("/Applications/Safari.app", "com.apple.application-bundle", ago: 60),
            file("/Users/test/Downloads/file.zip.download", nil, ago: 60),
            file("/Users/test/Documents/Old.txt", "public.plain-text", ago: 9 * 24 * 3600),
            file("/Users/test/Desktop/Lecture 7.pdf", "com.adobe.pdf", ago: 120),
            file("/Users/test/Desktop/Lecture 7.pdf", "com.adobe.pdf", ago: 7200),
        ]
        let usable = PaletteRecentFilter.usable(files, home: home, now: now, window: 7 * 24 * 3600)
        XCTAssertEqual(usable.map(\.url.lastPathComponent), ["Lecture 7.pdf", "Report.pages"],
                       "newest first, once per path; no Library, hidden, folders, apps, downloads in progress or old files")
    }
}
