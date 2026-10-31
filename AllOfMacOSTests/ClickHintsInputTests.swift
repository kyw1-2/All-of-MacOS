import XCTest
@testable import AllOfMacOS

/// The typed-filter state machine: letters narrow, a whole label acts,
/// modifiers pick the click, search filters by name.
final class ClickHintsInputTests: XCTestCase {
    /// Ten targets: F J D K S L A G, then HF and HJ.
    private func makeState(startsInSearch: Bool = false) -> ClickHintsInputState {
        let labels = ClickHintsLabels.make(count: 10, alphabet: .homeRow)
        let names = ["Back", "Forward", "Reload", "Share", "Save", "Save As…", "Cancel", "Délai", "저장", "확인"]
        return ClickHintsInputState(labels: labels, searchTexts: names, startsInSearch: startsInSearch)
    }

    private func type(_ text: String, into state: inout ClickHintsInputState,
                      modifiers: ClickHintsModifiers = []) -> [ClickHintsInputState.Outcome] {
        text.map { state.handle(.character($0), modifiers: modifiers) }
    }

    func testTypingNarrowsAndAWholeLabelActs() {
        var state = makeState()
        XCTAssertEqual(state.matches.count, 10)
        XCTAssertEqual(state.handle(.character("h"), modifiers: []), .updated)
        XCTAssertEqual(state.typed, "h")
        XCTAssertEqual(state.matches, [8, 9])
        XCTAssertEqual(state.handle(.character("j"), modifiers: []), .act(target: 9, kind: .press))

        var single = makeState()
        XCTAssertEqual(single.handle(.character("d"), modifiers: []), .act(target: 2, kind: .press), "a one-letter label acts at once")
    }

    func testModifiersPickTheClick() {
        let cases: [(ClickHintsModifiers, ClickHintsClickKind)] = [
            ([], .press), (.shift, .rightClick), (.control, .rightClick), (.command, .commandClick),
            (.option, .movePointer), ([.option, .command], .movePointer), ([.command, .shift], .commandClick)
        ]
        for (modifiers, kind) in cases {
            var state = makeState()
            XCTAssertEqual(state.handle(.character("f"), modifiers: modifiers), .act(target: 0, kind: kind), "\(modifiers)")
            var twoLetters = makeState()
            _ = twoLetters.handle(.character("h"), modifiers: modifiers)
            // The modifiers of the key that completes the label count.
            XCTAssertEqual(twoLetters.handle(.character("f"), modifiers: modifiers), .act(target: 8, kind: kind), "\(modifiers)")
        }
        var late = makeState()
        _ = late.handle(.character("h"), modifiers: [])
        XCTAssertEqual(late.handle(.character("f"), modifiers: .shift), .act(target: 8, kind: .rightClick))
    }

    func testWrongLettersAreRejectedAndChangeNothing() {
        var state = makeState()
        XCTAssertEqual(state.handle(.character("q"), modifiers: []), .rejected, "not a label letter")
        XCTAssertEqual(state.handle(.character("7"), modifiers: []), .rejected)
        _ = state.handle(.character("h"), modifiers: [])
        XCTAssertEqual(state.handle(.character("k"), modifiers: []), .rejected, "no label HK")
        XCTAssertEqual(state.typed, "h")
        XCTAssertEqual(state.matches, [8, 9])
    }

    func testBackspaceEscapeSpaceAndReturn() {
        var state = makeState()
        XCTAssertEqual(state.handle(.backspace, modifiers: []), .unchanged)
        _ = state.handle(.character("h"), modifiers: [])
        XCTAssertEqual(state.handle(.backspace, modifiers: []), .updated)
        XCTAssertEqual(state.typed, "")
        XCTAssertEqual(state.matches.count, 10)
        XCTAssertEqual(state.handle(.space, modifiers: []), .rejected, "ten hints left")
        XCTAssertEqual(state.handle(.returnKey, modifiers: []), .rejected)
        XCTAssertEqual(state.handle(.tab, modifiers: []), .unchanged)
        XCTAssertEqual(state.handle(.escape, modifiers: []), .cancel)

        var only = ClickHintsInputState(labels: ["f"], searchTexts: ["OK"])
        XCTAssertEqual(only.handle(.space, modifiers: []), .act(target: 0, kind: .press))
        XCTAssertEqual(only.handle(.returnKey, modifiers: .shift), .act(target: 0, kind: .rightClick))
    }

    func testSearchFiltersByName() {
        var state = makeState()
        XCTAssertEqual(state.handle(.character("/"), modifiers: []), .updated)
        XCTAssertEqual(state.mode, .search)
        XCTAssertEqual(type("sav", into: &state), [.updated, .updated, .updated])
        XCTAssertEqual(state.matches, [4, 5])
        XCTAssertEqual(state.highlightedTarget, 4)
        XCTAssertEqual(state.handle(.tab, modifiers: []), .updated)
        XCTAssertEqual(state.highlightedTarget, 5)
        XCTAssertEqual(state.handle(.down, modifiers: []), .updated)
        XCTAssertEqual(state.highlightedTarget, 4, "wraps around")
        XCTAssertEqual(state.handle(.up, modifiers: []), .updated)
        XCTAssertEqual(state.handle(.returnKey, modifiers: .command), .act(target: 5, kind: .commandClick))
        XCTAssertEqual(state.handle(.space, modifiers: []), .unchanged, "two matches: a space is ignored")

        _ = type("eas", into: &state)
        XCTAssertEqual(state.matches, [5], "spaces and case don't matter: Save As")
        XCTAssertEqual(state.handle(.space, modifiers: []), .act(target: 5, kind: .press))
    }

    func testSearchIgnoresAccentsAndMatchesKoreanByItsKeys() {
        var state = makeState(startsInSearch: true)
        XCTAssertEqual(state.mode, .search)
        _ = type("delai", into: &state)
        XCTAssertEqual(state.matches, [7])

        var korean = makeState(startsInSearch: true)
        _ = type("wjwkd", into: &korean)       // 저장 on the 2-Set layout
        XCTAssertEqual(korean.matches, [8])
        var confirm = makeState(startsInSearch: true)
        _ = type("ghkr", into: &confirm)       // 확… (확인)
        XCTAssertEqual(confirm.matches, [9])
        XCTAssertEqual(confirm.handle(.returnKey, modifiers: []), .act(target: 9, kind: .press))

        var none = makeState(startsInSearch: true)
        _ = type("zzz", into: &none)
        XCTAssertEqual(none.matches, [])
        XCTAssertNil(none.highlightedTarget)
        XCTAssertEqual(none.handle(.returnKey, modifiers: []), .rejected)
    }

    func testLeavingSearch() {
        var state = makeState(startsInSearch: true)
        _ = type("re", into: &state)
        XCTAssertEqual(state.handle(.backspace, modifiers: []), .updated)
        XCTAssertEqual(state.query, "r")
        _ = state.handle(.backspace, modifiers: [])
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.handle(.backspace, modifiers: []), .updated, "⌫ on an empty query goes back to labels")
        XCTAssertEqual(state.mode, .labels)
        XCTAssertEqual(state.matches.count, 10)

        var slash = makeState(startsInSearch: true)
        _ = type("ca", into: &slash)
        XCTAssertEqual(slash.handle(.character("/"), modifiers: []), .updated)
        XCTAssertEqual(slash.mode, .labels)
        XCTAssertEqual(slash.query, "")
        XCTAssertEqual(slash.handle(.character("f"), modifiers: []), .act(target: 0, kind: .press))
        var escape = makeState(startsInSearch: true)
        XCTAssertEqual(escape.handle(.escape, modifiers: []), .cancel)
    }

    func testTwoSetKeys() {
        XCTAssertEqual(ClickHintsSearch.twoSetKeys("저장"), "wjwkd")
        XCTAssertEqual(ClickHintsSearch.twoSetKeys("확인"), "ghkrdls")
        XCTAssertEqual(ClickHintsSearch.twoSetKeys("취소"), "cnlth")
        XCTAssertEqual(ClickHintsSearch.twoSetKeys("닭"), "ekfr", "a double final splits into its two keys")
        XCTAssertEqual(ClickHintsSearch.twoSetKeys("ㅃ"), "q", "doubled consonants read as their plain key")
        XCTAssertEqual(ClickHintsSearch.twoSetKeys("Safari 설정"), "Safari tjfwjd")
        XCTAssertEqual(ClickHintsSearch.forms(of: "Save As"), ["saveas"])
        XCTAssertEqual(ClickHintsSearch.forms(of: "설정 Settings"), ["설정settings", "tjfwjdsettings"])
        XCTAssertEqual(ClickHintsSearch.forms(of: "  "), [])
    }

    func testKeysAreReadByPosition() {
        // The layout's character for a key code, as UCKeyTranslate gives it.
        let layout: [UInt16: Character] = [3: "f", 38: "j", 44: "/", 18: "1"]
        let translate: (UInt16) -> Character? = { layout[$0] }
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 3, shift: false, translate: translate), .character("f"))
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 3, shift: true, translate: translate), .character("f"), "⇧ stays a modifier")
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 44, shift: false, translate: translate), .character("/"))
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 53, shift: false, translate: translate), .escape)
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 36, shift: false, translate: translate), .returnKey)
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 76, shift: false, translate: translate), .returnKey)
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 49, shift: false, translate: translate), .space)
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 51, shift: false, translate: translate), .backspace)
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 48, shift: false, translate: translate), .tab)
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 48, shift: true, translate: translate), .backtab)
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 125, shift: false, translate: translate), .down)
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 126, shift: false, translate: translate), .up)
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 122, shift: false, translate: translate), .other, "F1 types nothing")
        XCTAssertEqual(ClickHintsKeyboard.key(keyCode: 0, shift: false, translate: { _ in "A" }), .character("a"))
    }

    func testModifierFlags() {
        XCTAssertEqual(ClickHintsModifiers(NSEvent.ModifierFlags([.command, .shift, .capsLock])), [.command, .shift])
        XCTAssertEqual(ClickHintsModifiers(NSEvent.ModifierFlags([.option, .control])), [.option, .control])
    }
}
