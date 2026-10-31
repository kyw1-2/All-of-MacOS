import XCTest
@testable import AllOfMacOS

/// When hint mode may start (lock screen, secure input, pause, excluded
/// apps, Accessibility), and the settings behind it.
final class ClickHintsGateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AOMClickHintsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func context(_ change: (inout ClickHintsGate.Context) -> Void = { _ in }) -> ClickHintsGate.Context {
        var context = ClickHintsGate.Context(bundleID: "com.apple.Safari", appName: "Safari")
        change(&context)
        return context
    }

    func testAllClearStartsHintMode() {
        XCTAssertNil(ClickHintsGate.check(context()))
        XCTAssertNil(ClickHintsGate.check(context { $0.bundleID = nil }), "an app without an identifier is not excluded")
    }

    func testEachRuleBlocks() {
        XCTAssertEqual(ClickHintsGate.check(context { $0.screenLocked = true }), .screenLocked)
        XCTAssertEqual(ClickHintsGate.check(context { $0.secureInput = true }), .secureInput)
        XCTAssertEqual(ClickHintsGate.check(context { $0.masterSwitchOn = false }), .paused)
        XCTAssertEqual(ClickHintsGate.check(context { $0.globallyPaused = true }), .paused)
        XCTAssertEqual(ClickHintsGate.check(context { $0.appPaused = true }), .pausedForApp)
        XCTAssertEqual(ClickHintsGate.check(context { $0.excludedApps = ["com.apple.Safari"] }), .excludedApp("Safari"))
        XCTAssertEqual(ClickHintsGate.check(context { $0.accessibilityTrusted = false }), .accessibilityMissing)
    }

    func testTheRulesRunInOrder() {
        // Everything at once: the lock screen wins, and stays silent.
        var all = context {
            $0.screenLocked = true; $0.secureInput = true; $0.masterSwitchOn = false; $0.appPaused = true
            $0.excludedApps = ["com.apple.Safari"]; $0.accessibilityTrusted = false
        }
        XCTAssertEqual(ClickHintsGate.check(all), .screenLocked)
        XCTAssertNil(ClickHintsBlock.screenLocked.hud)
        all.screenLocked = false
        XCTAssertEqual(ClickHintsGate.check(all), .secureInput)
        all.secureInput = false
        XCTAssertEqual(ClickHintsGate.check(all), .paused)
        all.masterSwitchOn = true
        XCTAssertEqual(ClickHintsGate.check(all), .pausedForApp)
        all.appPaused = false
        XCTAssertEqual(ClickHintsGate.check(all), .excludedApp("Safari"))
        all.excludedApps = []
        XCTAssertEqual(ClickHintsGate.check(all), .accessibilityMissing)
    }

    func testPasswordManagersAreExcludedByDefault() {
        for id in ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                   "com.apple.keychainaccess", "com.apple.Passwords"] {
            XCTAssertEqual(ClickHintsGate.check(context { $0.bundleID = id; $0.appName = nil }), .excludedApp(id), id)
        }
        XCTAssertTrue(ClickHintsGate.isExcluded("COM.APPLE.PASSWORDS", in: ClickHintsSettings.defaultExcludedApps),
                      "identifiers compare without case")
    }

    func testEveryBlockThatSpeaksSaysWhereToGo() {
        XCTAssertEqual(ClickHintsBlock.excludedApp("Bitwarden").hud?.detail.contains("Bitwarden"), true)
        XCTAssertEqual(ClickHintsBlock.accessibilityMissing.hud?.detail.contains("Privacy & Security › Accessibility"), true)
        XCTAssertEqual(ClickHintsBlock.secureInput.hud?.title, "Secure Input Is On")
        for block in [ClickHintsBlock.secureInput, .paused, .pausedForApp, .excludedApp("X"), .accessibilityMissing] {
            XCTAssertNotNil(block.hud, "\(block)")
        }
    }

    // MARK: Settings

    func testDefaults() {
        let settings = ClickHintsSettings(defaults: defaults)
        XCTAssertEqual(settings.alphabet, .homeRow)
        XCTAssertEqual(settings.size, .regular)
        XCTAssertFalse(settings.includesMenuBar)
        XCTAssertFalse(settings.includesDock)
        XCTAssertFalse(settings.startsInSearch)
        XCTAssertEqual(settings.enhancedApps, [])
        XCTAssertEqual(settings.excludedApps, ClickHintsSettings.defaultExcludedApps)
    }

    func testSettingsRoundTripAndAnEmptyListStaysEmpty() {
        let settings = ClickHintsSettings(defaults: defaults)
        settings.alphabet = .numbers
        settings.size = .large
        settings.includesMenuBar = true
        settings.includesDock = true
        settings.startsInSearch = true
        settings.enhancedApps = [" com.google.Chrome ", "com.google.Chrome", "", "com.microsoft.VSCode"]
        settings.excludedApps = []
        let reread = ClickHintsSettings(defaults: defaults)
        XCTAssertEqual(reread.alphabet, .numbers)
        XCTAssertEqual(reread.size, .large)
        XCTAssertTrue(reread.includesMenuBar)
        XCTAssertTrue(reread.includesDock)
        XCTAssertTrue(reread.startsInSearch)
        XCTAssertEqual(reread.enhancedApps, ["com.google.Chrome", "com.microsoft.VSCode"])
        XCTAssertEqual(reread.excludedApps, [], "a cleared list is the person's choice, not the defaults")
        defaults.set("bogus", forKey: ClickHintsSettings.alphabetKey)
        XCTAssertEqual(ClickHintsSettings(defaults: defaults).alphabet, .homeRow)
    }

    func testKeysAreAOMPrefixedAndBackedUp() {
        let keys = ClickHintsSettings.backedUpKeys
        XCTAssertEqual(keys.count, 7)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("AOMClickHints") }, "Reset Preferences clears AOM… keys")
    }

    func testTheHomeRowGrowsOnlyWhenTwoLettersCantLabelEverything() {
        XCTAssertEqual(ClickHintsAlphabet.homeRow.characters(forCount: 81).count, 9)
        XCTAssertEqual(ClickHintsAlphabet.homeRow.characters(forCount: 82).count, 10)
        XCTAssertEqual(ClickHintsAlphabet.homeRow.characters(forCount: 400).count, 20)
        XCTAssertEqual(ClickHintsAlphabet.homeRow.characters(forCount: 5_000).count, 26)
        XCTAssertEqual(ClickHintsAlphabet.letters.characters(forCount: 3).count, 26)
        XCTAssertEqual(String(ClickHintsAlphabet.comfortOrder.sorted()), "abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(ClickHintsAlphabet.homeRow.sample, "F J D K S L A G H")
    }

    func testSizesFollowTextStyles() {
        XCTAssertEqual(ClickHintsSize.regular.height, 22, "design-340 b.17")
        XCTAssertEqual(ClickHintsSize.regular.textStyle, .callout)
        XCTAssertLessThan(ClickHintsSize.small.height, ClickHintsSize.large.height)
    }
}
