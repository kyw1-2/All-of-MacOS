import XCTest
@testable import AllOfMacOS

final class SettingsSearchTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(SettingsSearch.matches(query: "", title: "Cursor", subtitle: "Show pointer", keywords: []))
        XCTAssertTrue(SettingsSearch.matches(query: "   ", title: "Cursor", subtitle: "Show pointer", keywords: []))
    }

    func testMatchesTitleCaseInsensitively() {
        XCTAssertTrue(SettingsSearch.matches(query: "CURSOR", title: "Show Cursor", subtitle: "", keywords: []))
    }

    func testMatchesSubtitleAndKeywords() {
        XCTAssertTrue(SettingsSearch.matches(query: "백업", title: "Backups", subtitle: "자동 백업, 보관 개수", keywords: []))
        XCTAssertTrue(SettingsSearch.matches(query: "btt", title: "Import", subtitle: "프리셋", keywords: ["btt", "preset"]))
    }

    func testRequiresEveryToken() {
        XCTAssertFalse(SettingsSearch.matches(query: "cursor backup", title: "Show Cursor", subtitle: "pointer", keywords: []))
        XCTAssertTrue(SettingsSearch.matches(query: "cursor pointer", title: "Show Cursor", subtitle: "pointer", keywords: []))
    }

    func testNoMatch() {
        XCTAssertFalse(SettingsSearch.matches(query: "nonexistent-setting", title: "Show Cursor", subtitle: "pointer", keywords: ["mouse"]))
    }
}
