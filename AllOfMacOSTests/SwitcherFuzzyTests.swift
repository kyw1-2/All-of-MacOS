import XCTest
@testable import AllOfMacOS

/// The window switcher's fuzzy search and ordering: score tiers, Hangul
/// initials, type-to-filter over app and window titles, grouping by app,
/// the first selection and grid movement.
final class SwitcherFuzzyTests: XCTestCase {
    private struct Window: Equatable {
        let app: String
        let title: String
        let pid: pid_t
    }

    private let windows = [
        Window(app: "Google Chrome", title: "GitHub — swift-format", pid: 1),
        Window(app: "Terminal", title: "~/Projects — zsh", pid: 2),
        Window(app: "Google Chrome", title: "Naver", pid: 1),
        Window(app: "KakaoTalk", title: "카카오톡", pid: 3),
        Window(app: "Notes", title: "Lecture notes — Week 9", pid: 4),
        Window(app: "Finder", title: "Downloads", pid: 5),
    ]

    private func filter(_ query: String) -> [String] {
        SwitcherFilter.filtered(windows, query: query, appName: \.app, title: \.title).map(\.title)
    }

    // MARK: Scores

    func testScoreTiers() throws {
        let exact = try XCTUnwrap(PaletteFuzzy.score("notes", "Notes"))
        let prefix = try XCTUnwrap(PaletteFuzzy.score("note", "Notes"))
        let word = try XCTUnwrap(PaletteFuzzy.score("week", "Lecture notes — Week 9"))
        let contains = try XCTUnwrap(PaletteFuzzy.score("ote", "Notes"))
        let subsequence = try XCTUnwrap(PaletteFuzzy.score("gc", "Google Chrome"))
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, contains)
        XCTAssertGreaterThan(contains, subsequence)
        XCTAssertGreaterThanOrEqual(subsequence, PaletteFuzzy.subsequenceFloor)
        XCTAssertNil(PaletteFuzzy.score("xyz", "Google Chrome"))
        XCTAssertNil(PaletteFuzzy.score("", "Google Chrome"))
        XCTAssertNil(PaletteFuzzy.score("   ", "Google Chrome"))
    }

    func testCaseAccentsAndWidthDontMatter() {
        XCTAssertNotNil(PaletteFuzzy.score("CAFE", "Café Menu"))
        XCTAssertEqual(PaletteFuzzy.score("résumé", "Resume"), PaletteFuzzy.exactScore)
        XCTAssertNotNil(PaletteFuzzy.score("ＡＢＣ", "abc"))
    }

    func testWordStartsBeatScatteredLetters() throws {
        let initials = try XCTUnwrap(PaletteFuzzy.score("gc", "Google Chrome"))
        let scattered = try XCTUnwrap(PaletteFuzzy.score("gc", "Big cache"))
        XCTAssertGreaterThan(initials, scattered, "g and c starting words beat letters in the middle")
        let camel = try XCTUnwrap(PaletteFuzzy.score("vsc", "VisualStudioCode"))
        XCTAssertGreaterThan(camel, PaletteFuzzy.subsequenceFloor + 40, "camel-case humps are word starts")
    }

    func testHangulSyllablesAndInitialConsonants() throws {
        XCTAssertEqual(PaletteFuzzy.score("카카오톡", "카카오톡"), PaletteFuzzy.exactScore)
        XCTAssertNotNil(PaletteFuzzy.score("카카오", "카카오톡"))
        let initials = try XCTUnwrap(PaletteFuzzy.score("ㅋㅋㅇㅌ", "카카오톡"))
        XCTAssertGreaterThan(initials, PaletteFuzzy.wordPrefixScore, "initials of the start rank like a prefix")
        XCTAssertNotNil(PaletteFuzzy.score("ㅅㄹㄷ", "서울시립대학교"), "initials anywhere")
        XCTAssertNotNil(PaletteFuzzy.score("ㅋㅌ", "카카오톡"), "initials in order with gaps")
        XCTAssertNil(PaletteFuzzy.score("ㅎㅎ", "카카오톡"))
        XCTAssertEqual(PaletteFuzzy.initialConsonant(of: "톡"), "ㅌ")
        XCTAssertNil(PaletteFuzzy.initialConsonant(of: "a"))
        XCTAssertTrue(PaletteFuzzy.isConsonantJamo("ㄱ"))
        XCTAssertFalse(PaletteFuzzy.isConsonantJamo("가"))
    }

    // MARK: Filtering and ordering

    func testFilterMatchesAppNamesAndWindowTitles() {
        XCTAssertEqual(filter(""), windows.map(\.title), "no search keeps the switcher's order")
        XCTAssertEqual(filter("term"), ["~/Projects — zsh"], "the app name finds its windows")
        XCTAssertEqual(filter("naver"), ["Naver"])
        XCTAssertEqual(filter("chrome").sorted(), ["GitHub — swift-format", "Naver"])
        XCTAssertEqual(filter("chr git"), ["GitHub — swift-format"], "app and title together")
        XCTAssertEqual(filter("ㅋㅋㅇㅌ"), ["카카오톡"])
        XCTAssertEqual(filter("week"), ["Lecture notes — Week 9"])
        XCTAssertTrue(filter("qqq").isEmpty)
    }

    func testBetterMatchesComeFirstAndTiesKeepRecency() {
        XCTAssertEqual(filter("no").first, "Lecture notes — Week 9", "the app Notes is a prefix match")
        let both = SwitcherFilter.filtered([Window(app: "Notes", title: "A", pid: 1), Window(app: "Notes", title: "B", pid: 1)],
                                           query: "notes", appName: \.app, title: \.title)
        XCTAssertEqual(both.map(\.title), ["A", "B"], "equal scores keep the most recently used first")
        let titleWins = SwitcherFilter.filtered([Window(app: "Safari", title: "Downloads helper", pid: 1),
                                                 Window(app: "Finder", title: "Downloads", pid: 2)],
                                                query: "downloads", appName: \.app, title: \.title)
        XCTAssertEqual(titleWins.first?.app, "Finder", "an exact title beats a prefix")
    }

    func testGroupingByAppKeepsFirstAppearanceOrder() {
        let grouped = SwitcherFilter.groupedByApp(windows, key: \.pid)
        XCTAssertEqual(grouped.map(\.title), ["GitHub — swift-format", "Naver", "~/Projects — zsh", "카카오톡",
                                              "Lecture notes — Week 9", "Downloads"])
    }

    func testFirstSelectionIsThePreviousWindow() {
        XCTAssertEqual(SwitcherFilter.initialSelection(count: 5, firstIsFrontmost: true), 1)
        XCTAssertEqual(SwitcherFilter.initialSelection(count: 5, firstIsFrontmost: false), 0)
        XCTAssertEqual(SwitcherFilter.initialSelection(count: 1, firstIsFrontmost: true), 0)
        XCTAssertEqual(SwitcherFilter.initialSelection(count: 0, firstIsFrontmost: false), 0)
    }

    func testGridMovement() {
        XCTAssertEqual(SwitcherFilter.move(0, by: -1, count: 7, columns: 4, vertical: false), 6, "left from the first wraps")
        XCTAssertEqual(SwitcherFilter.move(6, by: 1, count: 7, columns: 4, vertical: false), 0)
        XCTAssertEqual(SwitcherFilter.move(1, by: 1, count: 7, columns: 4, vertical: true), 5, "down moves a row")
        XCTAssertEqual(SwitcherFilter.move(5, by: 1, count: 7, columns: 4, vertical: true), 5, "no row below: stay")
        XCTAssertEqual(SwitcherFilter.move(2, by: -1, count: 7, columns: 4, vertical: true), 2)
        XCTAssertEqual(SwitcherFilter.move(0, by: 1, count: 0, columns: 4, vertical: false), 0)
    }
}
