import Foundation
import XCTest
@testable import AllOfMacOS

/// Per-app input sources: which source an app gets and what is remembered.
/// Pure: no input source is switched and no file outside a temporary folder is written.
final class FolderRulesInputSourceTests: XCTestCase {
    private let abc = "com.apple.keylayout.ABC"
    private let korean = "com.apple.inputmethod.Korean.2SetKorean"

    private func settings(remember: Bool = true) -> AppInputSourceSettings {
        var settings = AppInputSourceSettings()
        settings.isEnabled = true
        settings.remembersLastUsed = remember
        settings.rules = [AppInputSourceRule(bundleID: "com.apple.Terminal", appName: "Terminal", sourceID: abc, sourceName: "ABC"),
                          AppInputSourceRule(bundleID: "com.kakao.KakaoTalkMac", appName: "KakaoTalk", sourceID: korean,
                                             sourceName: "2-Set Korean")]
        settings.remembered = ["com.apple.Safari": korean, "com.apple.Notes": "com.example.removed"]
        settings.excludedBundleIDs = ["com.example.Game"]
        return settings
    }

    func testFixedSourcesWinThenTheRememberedOne() {
        let available: Set<String> = [abc, korean]
        let settings = settings()
        XCTAssertEqual(AppInputSourcePolicy.target(for: "com.apple.Terminal", settings: settings, available: available), abc)
        XCTAssertEqual(AppInputSourcePolicy.target(for: "com.kakao.KakaoTalkMac", settings: settings, available: available), korean)
        XCTAssertEqual(AppInputSourcePolicy.target(for: "com.apple.Safari", settings: settings, available: available), korean)
        XCTAssertNil(AppInputSourcePolicy.target(for: "com.apple.Notes", settings: settings, available: available),
                     "a remembered source that is no longer enabled is ignored")
        XCTAssertNil(AppInputSourcePolicy.target(for: "com.apple.Mail", settings: settings, available: available), "nothing known: leave it")
        XCTAssertNil(AppInputSourcePolicy.target(for: "com.example.Game", settings: settings, available: available), "excluded apps")
        XCTAssertNil(AppInputSourcePolicy.target(for: "com.apple.Terminal", settings: settings, available: [korean]),
                     "a fixed source that was removed from the Mac")
        XCTAssertNil(AppInputSourcePolicy.target(for: "com.apple.Safari", settings: self.settings(remember: false), available: available))
        var off = settings
        off.isEnabled = false
        XCTAssertNil(AppInputSourcePolicy.target(for: "com.apple.Terminal", settings: off, available: available))
    }

    func testOnlyThePersonsOwnSwitchesAreRemembered() throws {
        let settings = settings()
        let next = try XCTUnwrap(AppInputSourcePolicy.remembering(abc, for: "com.apple.Safari", settings: settings, changedByAOM: false))
        XCTAssertEqual(next.remembered["com.apple.Safari"], abc)
        XCTAssertNil(AppInputSourcePolicy.remembering(abc, for: "com.apple.Safari", settings: settings, changedByAOM: true),
                     "AOM's own switch isn't a choice")
        XCTAssertNil(AppInputSourcePolicy.remembering(korean, for: "com.apple.Terminal", settings: settings, changedByAOM: false),
                     "apps with a fixed source keep it")
        XCTAssertNil(AppInputSourcePolicy.remembering(korean, for: "com.apple.Safari", settings: settings, changedByAOM: false),
                     "already remembered")
        XCTAssertNil(AppInputSourcePolicy.remembering(abc, for: "com.example.Game", settings: settings, changedByAOM: false))
        XCTAssertNil(AppInputSourcePolicy.remembering(abc, for: "com.apple.Safari", settings: self.settings(remember: false), changedByAOM: false))
        var full = settings
        for index in 0..<210 { full.remembered["com.example.app\(index)"] = abc }
        let capped = try XCTUnwrap(AppInputSourcePolicy.remembering(korean, for: "com.apple.Mail", settings: full, changedByAOM: false))
        XCTAssertLessThan(capped.remembered.count, full.remembered.count + 1)
        XCTAssertEqual(capped.remembered["com.apple.Mail"], korean)
    }

    func testSettingsRoundTripAndDecodeLeniently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aom-inputsources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppInputSourceStore(directory: directory)
        XCTAssertEqual(store.load(), AppInputSourceSettings(), "nothing saved: off with no rules")
        XCTAssertFalse(store.load().isEnabled)
        let saved = settings()
        try store.save(saved)
        XCTAssertEqual(store.load(), saved)
        try Data(#"{"isEnabled":true}"#.utf8).write(to: store.url)
        let lenient = store.load()
        XCTAssertTrue(lenient.isEnabled)
        XCTAssertTrue(lenient.remembersLastUsed)
        XCTAssertEqual(lenient.rules, [])
    }
}
