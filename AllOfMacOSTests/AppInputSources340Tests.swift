import XCTest
@testable import AllOfMacOS

/// Per-app input sources (3.4): the switching decision, the memory and the
/// stored rules. Pure functions and an isolated defaults suite; nothing
/// selects a real input source.
final class AppInputSources340Tests: XCTestCase {
    private let english = "com.apple.keylayout.ABC"
    private let korean = "com.apple.inputmethod.Korean.2SetKorean"
    private lazy var enabled: Set<String> = [english, korean]
    private lazy var rules = [AppInputSourcesRule(bundleID: "com.apple.Terminal", appName: "Terminal", inputSourceID: english),
                              AppInputSourcesRule(bundleID: "com.kakao.KakaoTalkMac", appName: "KakaoTalk", inputSourceID: korean)]

    func testARuleWinsOverMemoryAndFallback() {
        let target = AppInputSourcesPolicy.target(for: "com.apple.Terminal", rules: rules,
                                                  memory: ["com.apple.Terminal": korean], remembers: true,
                                                  fallback: korean, current: korean, enabled: enabled)
        XCTAssertEqual(target, english)
    }

    func testRememberedSourceIsUsedOnlyWithRememberOn() {
        let memory = ["com.apple.Safari": korean]
        XCTAssertEqual(AppInputSourcesPolicy.target(for: "com.apple.Safari", rules: rules, memory: memory, remembers: true,
                                                    fallback: nil, current: english, enabled: enabled), korean)
        XCTAssertNil(AppInputSourcesPolicy.target(for: "com.apple.Safari", rules: rules, memory: memory, remembers: false,
                                                  fallback: nil, current: english, enabled: enabled))
    }

    func testFallbackCoversAppsWithoutRuleOrMemory() {
        XCTAssertEqual(AppInputSourcesPolicy.target(for: "com.apple.Notes", rules: rules, memory: [:], remembers: true,
                                                    fallback: english, current: korean, enabled: enabled), english)
    }

    func testNothingHappensWhenAlreadySelectedDisabledOrUnknown() {
        XCTAssertNil(AppInputSourcesPolicy.target(for: "com.apple.Terminal", rules: rules, memory: [:], remembers: false,
                                                  fallback: nil, current: english, enabled: enabled))
        XCTAssertNil(AppInputSourcesPolicy.target(for: "com.apple.Terminal", rules: rules, memory: [:], remembers: false,
                                                  fallback: nil, current: korean, enabled: [korean]),
                     "A source that is no longer enabled is never selected")
        XCTAssertNil(AppInputSourcesPolicy.target(for: nil, rules: rules, memory: [:], remembers: true,
                                                  fallback: english, current: korean, enabled: enabled))
        XCTAssertNil(AppInputSourcesPolicy.target(for: "com.apple.Notes", rules: rules, memory: [:], remembers: false,
                                                  fallback: nil, current: korean, enabled: enabled))
    }

    func testMemorySkipsRuledAppsKeepsOrderAndLimit() {
        var state = AppInputSourcesPolicy.remembering(korean, for: "com.apple.Terminal", in: [:], order: [], rules: rules)
        XCTAssertTrue(state.memory.isEmpty, "Apps with a rule are never remembered")
        state = AppInputSourcesPolicy.remembering(korean, for: "a", in: state.memory, order: state.order, rules: rules, limit: 2)
        state = AppInputSourcesPolicy.remembering(english, for: "b", in: state.memory, order: state.order, rules: rules, limit: 2)
        state = AppInputSourcesPolicy.remembering(english, for: "a", in: state.memory, order: state.order, rules: rules, limit: 2)
        XCTAssertEqual(state.order, ["b", "a"])
        XCTAssertEqual(state.memory["a"], english)
        state = AppInputSourcesPolicy.remembering(korean, for: "c", in: state.memory, order: state.order, rules: rules, limit: 2)
        XCTAssertEqual(state.order, ["a", "c"])
        XCTAssertNil(state.memory["b"], "The oldest app is dropped past the limit")
        let unchanged = AppInputSourcesPolicy.remembering(nil, for: "d", in: state.memory, order: state.order, rules: rules)
        XCTAssertEqual(unchanged.memory, state.memory)
    }

    func testSettingsRoundTripAndDropDuplicateRules() throws {
        let suite = "AOMInputSourcesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppInputSourcesSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertNil(settings.fallback)
        settings.isEnabled = true
        settings.remembers = true
        settings.fallback = english
        settings.rules = rules + [AppInputSourcesRule(bundleID: "com.apple.Terminal", appName: "Terminal", inputSourceID: korean)]
        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(settings.remembers)
        XCTAssertEqual(settings.fallback, english)
        XCTAssertEqual(settings.rules, rules, "A second rule for the same app is dropped; the first one wins")
        settings.fallback = nil
        XCTAssertNil(settings.fallback)
        XCTAssertTrue([AppInputSourcesSettings.enabledKey, AppInputSourcesSettings.rulesKey, AppInputSourcesSettings.rememberKey,
                       AppInputSourcesSettings.fallbackKey, AppInputSourcesSettings.memoryKey].allSatisfy { $0.hasPrefix("AOM") },
                      "Reset Preferences clears every key")
    }
}
