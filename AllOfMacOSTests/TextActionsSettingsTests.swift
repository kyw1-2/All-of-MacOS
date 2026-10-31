import XCTest
@testable import AllOfMacOS

/// Text Actions settings: defaults, saving and loading (in a throwaway
/// defaults suite), older or damaged values, reordering, and the Workspace
/// status line.
final class TextActionsSettingsTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "AOMTextActionsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDefaults() {
        let settings = TextActionsSettings()
        XCTAssertFalse(settings.isOn, "the bar is off until switched on")
        XCTAssertEqual(settings.enabledActions, [.copy, .cut, .paste, .search, .openLink, .newEmail, .lookUp, .translate,
                                                 .calculate, .pinToClipboard])
        XCTAssertTrue(TextActionID.allCases.filter(\.isTransform).allSatisfy { !settings.isOn($0) }, "transforms start off")
        XCTAssertEqual(settings.actions.map(\.id), TextActionID.allCases, "every action once, in the default order")
        for id in ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"] {
            XCTAssertTrue(settings.excludes(id), id)
        }
        XCTAssertTrue(settings.showsOnDrag)
        XCTAssertTrue(settings.showsOnDoubleClick)
        XCTAssertFalse(settings.showsOnKeyboardSelection, "⇧-arrow selection is off by default")
        XCTAssertFalse(settings.readsWithCopy, "the ⌘C fallback is off by default")
        XCTAssertEqual(settings.position, .above)
    }

    func testDefaultsForPeopleWhoReadKorean() {
        XCTAssertEqual(TextActionsSettings.defaultTranslator(preferred: ["en-KR", "ko-KR", "ko"]), .papago)
        XCTAssertEqual(TextActionsSettings.defaultTargetLanguage(preferred: ["en-KR", "ko-KR", "ko"]), "ko")
        XCTAssertEqual(TextActionsSettings.defaultTranslator(preferred: ["en-US"]), .google)
        XCTAssertEqual(TextActionsSettings.defaultTargetLanguage(preferred: ["en-US"]), "en")
        XCTAssertEqual(TextActionsSettings.defaultTargetLanguage(preferred: ["zh-Hant-TW", "en"]), "zh-TW")
        XCTAssertEqual(TextActionsSettings.defaultTargetLanguage(preferred: ["xx-YY"]), "en")
        XCTAssertEqual(TextTranslateLanguage.code(forPreferredLanguage: "ja_JP"), "ja")
    }

    func testSavingAndLoading() {
        let defaults = suite()
        var settings = TextActionsSettings()
        settings.isOn = true
        settings.searchEngine = .naver
        settings.translator = .papago
        settings.translateTo = "ja"
        settings.excludedApps.append("com.tinyspeck.slackmacgap")
        settings.moveAction(.translate, before: .copy)
        settings.pinboardID = UUID()
        settings.save(to: defaults)
        XCTAssertNotNil(defaults.data(forKey: TextActionsSettings.defaultsKey))
        XCTAssertEqual(TextActionsSettings.load(from: defaults), settings.bounded)
        XCTAssertEqual(TextActionsSettings.load(from: suite()), TextActionsSettings(), "nothing saved: the defaults")
    }

    func testOlderOrDamagedValuesKeepEverythingThatStillReads() throws {
        let legacy = #"{"isOn":true,"actions":[{"id":"search","isOn":true},{"id":"future","isOn":true},{"id":"copy","isOn":false}],"showDelay":"bad","position":"sideways"}"#
        let decoded = try JSONDecoder().decode(TextActionsSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.isOn)
        XCTAssertEqual(decoded.actions.prefix(2).map(\.id), [.search, .copy], "the saved order stays")
        XCTAssertFalse(decoded.isOn(.copy))
        XCTAssertEqual(decoded.actions.count, TextActionID.allCases.count, "an unknown id is dropped, new actions are added")
        XCTAssertEqual(decoded.showDelay, 0.2, "a damaged field falls back alone")
        XCTAssertEqual(decoded.position, .above)
        XCTAssertEqual(decoded.excludedApps, TextActionsSettings.defaultExcludedApps, "missing fields take their defaults")

        let defaults = suite()
        defaults.set(Data("not json".utf8), forKey: TextActionsSettings.defaultsKey)
        XCTAssertEqual(TextActionsSettings.load(from: defaults), TextActionsSettings())
    }

    func testBoundedKeepsValuesInRange() {
        var settings = TextActionsSettings()
        settings.showDelay = 9
        settings.hideDelay = -1
        settings.excludedApps = [" com.a ", "com.a", "COM.A", "", "com.b"]
        settings.translateFrom = "klingon"
        settings.translateTo = "auto"
        settings.actions = [.init(id: .copy, isOn: false), .init(id: .copy, isOn: true)]
        let bounded = settings.bounded
        XCTAssertEqual(bounded.showDelay, TextActionsSettings.showDelayRange.upperBound)
        XCTAssertEqual(bounded.hideDelay, TextActionsSettings.hideDelayRange.lowerBound)
        XCTAssertEqual(bounded.excludedApps, ["com.a", "com.b"])
        XCTAssertEqual(bounded.translateFrom, "auto")
        XCTAssertEqual(bounded.translateTo, "en")
        XCTAssertEqual(bounded.actions.count, TextActionID.allCases.count)
        XCTAssertFalse(bounded.isOn(.copy), "the first of a repeated action wins")
    }

    func testReordering() {
        var settings = TextActionsSettings()
        settings.moveAction(.markdown, before: .copy)
        XCTAssertEqual(settings.actions.first?.id, .markdown)
        settings.moveAction(.markdown, before: nil)
        XCTAssertEqual(settings.actions.last?.id, .markdown)
        settings.moveAction(.copy, by: 1)
        XCTAssertEqual(settings.actions.prefix(2).map(\.id), [.cut, .copy])
        settings.moveAction(.cut, by: -5)
        XCTAssertEqual(settings.actions.first?.id, .cut, "moves stop at the ends")
        settings.moveAction(.copy, before: .copy)
        XCTAssertEqual(settings.actions.count, TextActionID.allCases.count)
    }

    func testTheWorkspaceStatusLine() {
        var settings = TextActionsSettings()
        XCTAssertEqual(TextActionsController.statusDetail(settings, paused: false), "Off")
        settings.isOn = true
        XCTAssertEqual(TextActionsController.statusDetail(settings, paused: false), "10 actions · not in 5 apps")
        XCTAssertEqual(TextActionsController.statusDetail(settings, paused: true), "Paused with AOM")
        settings.excludedApps = ["com.a"]
        for id in TextActionID.allCases { settings.setAction(id, isOn: id == .copy) }
        XCTAssertEqual(TextActionsController.statusDetail(settings, paused: false), "1 action · not in 1 app")
        settings.excludedApps = []
        XCTAssertEqual(TextActionsController.statusDetail(settings, paused: false), "1 action")
    }

    @MainActor
    func testPreferencesInTestsNeverTouchADefaultsDomain() {
        let preferences = TextActionsPreferences(defaults: nil)
        preferences.settings.isOn = true
        XCTAssertTrue(preferences.settings.isOn)
        preferences.reload()
        XCTAssertTrue(preferences.settings.isOn, "nothing to reload from")
        XCTAssertFalse(TextActionsPreferences.shared.settings.isOn, "the shared store starts from the defaults in tests")
    }

    @MainActor
    func testPreferencesReloadAfterAResetOrARestore() {
        let defaults = suite()
        let preferences = TextActionsPreferences(defaults: defaults)
        preferences.settings.isOn = true
        XCTAssertTrue(TextActionsSettings.load(from: defaults).isOn, "saved on change")
        defaults.removeObject(forKey: TextActionsSettings.defaultsKey)   // Reset Preferences
        preferences.reload()
        XCTAssertFalse(preferences.settings.isOn)
    }
}
