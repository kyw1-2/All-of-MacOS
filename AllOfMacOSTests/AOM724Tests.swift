import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.24.0 — the menu bar spec of 2026-11-28 (Downloads), checked against the
/// code and the 7.23 snapshots first.
@MainActor
final class AOM724Tests: XCTestCase {
    func testAppearanceSettingMapsToAnNSAppearance() {
        XCTAssertEqual(AOMAppAppearance.appearance(for: "dark")?.name, .darkAqua)
        XCTAssertEqual(AOMAppAppearance.appearance(for: "light")?.name, .aqua)
        XCTAssertNil(AOMAppAppearance.appearance(for: "system"))
        XCTAssertNil(AOMAppAppearance.appearance(for: "garbage"))
    }

    func testLaneColourIsCalmedAndFallsBackForWhiteIcons() throws {
        let vivid = NSColor(srgbRed: 0.16, green: 0.38, blue: 0.68, alpha: 1)
        let calm = try XCTUnwrap(MenuBarLaneColor.calmed(vivid).usingColorSpace(.sRGB))
        var s1: CGFloat = 0, s2: CGFloat = 0, b1: CGFloat = 0, b2: CGFloat = 0, h: CGFloat = 0, a: CGFloat = 0
        vivid.getHue(&h, saturation: &s1, brightness: &b1, alpha: &a)
        calm.getHue(&h, saturation: &s2, brightness: &b2, alpha: &a)
        XCTAssertEqual(s2, s1 * 0.55, accuracy: 0.01)
        XCTAssertEqual(b2, b1, accuracy: 0.01)
        XCTAssertNotNil(MenuBarLaneColor.fallback(iconLuminance: 0.95), "white icons get a dark lane")
        XCTAssertNil(MenuBarLaneColor.fallback(iconLuminance: 0.2))
        XCTAssertNil(MenuBarLaneColor.fallback(iconLuminance: nil))
        let white = MenuBarLayoutModel.sampleImage("cloud.fill")
        XCTAssertGreaterThan(MenuBarLaneColor.iconLuminance([white]) ?? 0, 0.8)
    }

    func testPanelSearchScoring() {
        XCTAssertEqual(AOMMenuBarPanelSearch.score("Capture Area", query: "capt"), 0)
        XCTAssertEqual(AOMMenuBarPanelSearch.score("Show All Hidden Icons", query: "hidden"), 1)
        XCTAssertEqual(AOMMenuBarPanelSearch.score("Clipboard History", query: "story"), 2)
        XCTAssertNil(AOMMenuBarPanelSearch.score("Capture Area", query: "window"))
        XCTAssertNil(AOMMenuBarPanelSearch.score("Capture Area", query: "  "))
        XCTAssertEqual(AOMMenuBarPanelSearch.score("Keep Awake", query: "keep awa"), 0)
    }

    func testDefaultQuickActionsComeFromFourTools() {
        let ids = AOMStatusMenuStore.defaultPanelCommandIDs
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(ids.filter { $0.hasPrefix("qa.capture") }.count, 1, "one capture, not three")
        let index = AOMMenuCommandCatalog.index()
        XCTAssertTrue(ids.allSatisfy { index[$0] != nil }, "every default exists: \(ids.filter { index[$0] == nil })")
        XCTAssertEqual(AOMMenuBarPanel.shortTitle(index["qa.captureArea"]!), "Area")
    }

    func testStatusItemDigitsNeverShrink() {
        XCTAssertEqual(AOMStatusItemWidth.padded("9:59", toDigits: 4), "\u{2007}9:59")
        XCTAssertEqual(AOMStatusItemWidth.padded("10:00", toDigits: 4), "10:00")
        XCTAssertEqual(AOMStatusItemWidth.padded("☀︎ 9°", toDigits: 2), "☀︎ \u{2007}9°")
        XCTAssertEqual(AOMStatusItemWidth.padded("Off", toDigits: 3), "Off", "no digits, nothing to pad")
        AOMStatusItemWidth.reset("test")
        XCTAssertEqual(AOMStatusItemWidth.stable("12°", key: "test"), "12°")
        XCTAssertEqual(AOMStatusItemWidth.stable("9°", key: "test"), "\u{2007}9°", "keeps the widest seen")
        AOMStatusItemWidth.reset("test")
    }

    func testRecentCopyAges() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(AOMMenuBarPanel.ago(now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(AOMMenuBarPanel.ago(now.addingTimeInterval(-300), now: now), "5 min")
        XCTAssertEqual(AOMMenuBarPanel.ago(now.addingTimeInterval(-7_300), now: now), "2 h")
        XCTAssertEqual(AOMMenuBarPanel.ago(now.addingTimeInterval(-200_000), now: now), "2 d")
        XCTAssertEqual(AOMMenuBarPanel.symbol(.link), "link")
    }

    func testPanelIsWideEnoughForHalfTiles() {
        // 396 − 2 × 14 padding − 8 gap = 360 → 180 pt a tile (was 152).
        XCTAssertEqual((AOMMenuBarCraftPanel.width - 28 - 8) / 2, 180)
    }

    func testStarterSnapSetsAreValid() {
        for set in SnapZoneStarterCards.sets {
            let zones = set.replacing([])
            XCTAssertEqual(zones.count, set.layouts.count)
            XCTAssertTrue(zones.allSatisfy(\.isValid), set.rawValue)
            XCTAssertLessThanOrEqual(zones.count, 32)
        }
    }
}
