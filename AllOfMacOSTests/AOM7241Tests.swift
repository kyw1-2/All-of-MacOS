import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.24.1 — the Codex orphan/half-wired audit and agy's §6 review of 7.24
/// (Downloads, 2026-11-28), plus the user's request to keep the tile menus
/// sliding in under the tiles.
@MainActor
final class AOM7241Tests: XCTestCase {
    func testRegexCacheCompilesOnceAndRemembersFailures() {
        let a = AOMRegexCache.regex(#"^\d+$"#, options: [.caseInsensitive])
        let b = AOMRegexCache.regex(#"^\d+$"#, options: [.caseInsensitive])
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b, "the same compiled expression")
        XCTAssertFalse(AOMRegexCache.regex(#"^\d+$"#) === a, "options are part of the key")
        XCTAssertNil(AOMRegexCache.regex("([unclosed"))
        XCTAssertNil(AOMRegexCache.regex("([unclosed"))
    }

    func testMenuItemCacheExpiresAfterTenSeconds() {
        let cache = MenuItemCache()
        let key = MenuItemCache.Key(pid: 42, character: "[", modifiers: 0)
        let element = AXUIElementCreateApplication(42)
        cache.store(element, for: key, now: 100)
        XCTAssertNotNil(cache.item(for: key, now: 109.9))
        XCTAssertNil(cache.item(for: key, now: 110.1))
        cache.store(element, for: key, now: 200)
        cache.forget(key)
        XCTAssertNil(cache.item(for: key, now: 200))
    }

    func testPanelHeightCap() {
        XCTAssertEqual(AOMStatusPanelController.maxHeight(visible: CGRect(x: 0, y: 0, width: 1512, height: 944)), 560)
        XCTAssertEqual(AOMStatusPanelController.maxHeight(visible: CGRect(x: 0, y: 0, width: 1280, height: 700)), 504)
    }

    func testDoNotDisturbIsNotOfferedWhereItCannotRun() {
        XCTAssertFalse(PaletteSystemCommand.fixed.contains { $0.id == "system.dnd" })
    }
}
