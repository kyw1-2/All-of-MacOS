import XCTest
@testable import AllOfMacOS

final class FeatureDiscoveryTests: XCTestCase {
    func testEveryDestinationIsDiscoverableExactlyOnce() {
        let tabs = AOMFeatureGroup.allCases.flatMap(\.tabs)
        XCTAssertEqual(Set(tabs), Set(AOMMainTab.allCases.filter { $0 != .home }))
        XCTAssertEqual(tabs.count, Set(tabs).count)
    }

    func testTaskSearchFindsEnglishAndKoreanAliases() {
        for (query, tab) in [("OCR", AOMMainTab.capture), ("창 배치", .snapping),
                             ("홈팟", .audio), ("복사 기록", .clipboard), ("다운로드 정리", .folderRules),
                             ("CLICK HINTS", .textActions)] {
            XCTAssertEqual(AOMFeatureSearch.results(query: query, group: nil), [tab], query)
        }
    }

    func testSettingsAreDiscoverableByHiddenFeatureNames() {
        XCTAssertTrue(SettingsCategory.automation.matchesDiscovery("hyper key"))
        XCTAssertTrue(SettingsCategory.data.matchesDiscovery("백업 복원"))
        XCTAssertTrue(SettingsCategory.permissions.matchesDiscovery("접근성 권한"))
        XCTAssertFalse(SettingsCategory.about.matchesDiscovery("hyper key"))
    }

    func testWhitespaceScopeAndNoMatches() {
        XCTAssertEqual(AOMFeatureSearch.results(query: " \n\t", group: nil).count, AOMMainTab.allCases.count - 1)
        XCTAssertEqual(AOMFeatureSearch.results(query: "", group: .create), [.capture, .clipboard, .textActions])
        XCTAssertTrue(AOMFeatureSearch.results(query: "no-such-tool", group: nil).isEmpty)
        XCTAssertTrue(AOMFeatureSearch.results(query: "volume", group: .create).isEmpty)
    }

    @MainActor
    func testPaletteCanSearchTaskAliasesWithoutDisplayingKeywords() {
        var item = QuickCommandPalette.PaletteItem(id: "audio", title: "Audio", subtitle: "Per-app volume",
                                                   icon: "waveform", section: .navigation,
                                                   primary: .init(title: "Open", run: {}))
        item.keywords = AOMMainTab.audio.discoveryKeywords
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.results(for: [item], query: "홈팟").map(\.id), ["audio"])
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.results(for: [item], query: "홈팟 볼륨").map(\.id), ["audio"])
        XCTAssertEqual(item.subtitle, "Per-app volume")
    }
}
