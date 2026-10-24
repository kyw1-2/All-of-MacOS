import XCTest
@testable import AllOfMacOS

/// Text expansion (Typed Strings): matching logic, coding stability and the
/// guards that keep expansions out of password fields and AOM's own UI.
@MainActor
final class TypedStringTests: XCTestCase {

    private func trigger(abbreviation: String, replacement: String = "",
                         bundleID: String? = nil) -> Trigger {
        Trigger(name: "Typed \(abbreviation)",
                input: .typedString(TypedStringSpec(abbreviation: abbreviation, replacement: replacement)),
                appBundleID: bundleID)
    }

    func testMatchOnFinalCharacter() {
        let engine = TypedStringEngine.shared
        engine.reset()
        let rules = [trigger(abbreviation: ";email", replacement: "me@example.com")]
        var match: TypedStringEngine.Match?
        for character in ";email" {
            match = engine.observe(text: String(character), bundleID: "com.apple.Safari",
                                   registered: rules, activationGroups: [])
        }
        XCTAssertEqual(match?.backspaces, 5, "the last character is swallowed, the other five are erased")
        engine.reset()
    }

    func testLongestAbbreviationWins() {
        let engine = TypedStringEngine.shared
        engine.reset()
        let rules = [trigger(abbreviation: ";e", replacement: "short"),
                     trigger(abbreviation: ";email", replacement: "longer")]
        var match: TypedStringEngine.Match?
        for character in ";email" {
            match = engine.observe(text: String(character), bundleID: "com.apple.Safari",
                                   registered: rules, activationGroups: [])
        }
        XCTAssertEqual(match?.trigger.input.displayName, "Typed “;email”")
        engine.reset()
    }

    func testNonMatchingTypingNeverMatches() {
        let engine = TypedStringEngine.shared
        engine.reset()
        let rules = [trigger(abbreviation: ";email", replacement: "x")]
        var match: TypedStringEngine.Match?
        for character in ";mail" {
            match = engine.observe(text: String(character), bundleID: "com.apple.Safari",
                                   registered: rules, activationGroups: [])
        }
        XCTAssertNil(match)
        engine.reset()
    }

    func testCaseInsensitiveAndAppSwitchResets() {
        let engine = TypedStringEngine.shared
        engine.reset()
        let rules = [trigger(abbreviation: ";email", replacement: "x")]
        for character in ";EMA" {
            _ = engine.observe(text: String(character), bundleID: "com.apple.Safari",
                               registered: rules, activationGroups: [])
        }
        // An app switch clears the buffer: the fragment must not complete.
        let afterSwitch = engine.observe(text: "i", bundleID: "com.google.Chrome",
                                         registered: rules, activationGroups: [])
        XCTAssertNil(afterSwitch)
        engine.reset()
    }

    func testTypedStringSpecRoundTripsAndCategorizes() throws {
        let input = TriggerInput.typedString(TypedStringSpec(abbreviation: ";sig", replacement: "Kim"))
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(TriggerInput.self, from: data)
        XCTAssertEqual(decoded, input)
        XCTAssertEqual(input.category, .keyboard)
        XCTAssertEqual(input.displayName, "Typed “;sig”")
    }

    func testNewSystemActionsAreDescribedAndCategorized() {
        XCTAssertEqual(ActionType.toggleKeepAwake.category, .systemActions)
        XCTAssertEqual(ActionType.showWindowSwitcher.category, .windowManagement)
        XCTAssertFalse(ActionType.toggleKeepAwake.iconName.isEmpty)
        XCTAssertFalse(ActionType.showWindowSwitcher.iconName.isEmpty)
    }
}
