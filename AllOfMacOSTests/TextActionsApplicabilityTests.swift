import XCTest
@testable import AllOfMacOS

/// Text Actions: which actions the bar offers for which text, in which
/// field, and how the items are built.
final class TextActionsApplicabilityTests: XCTestCase {
    private func traits(_ text: String) -> TextSelectionTraits { TextSelectionClassifier.classify(text) }
    private let editable = TextActionContext(editability: .editable, calculation: nil, chatGPTInstalled: false, clipboardHasContent: true)
    private let readOnly = TextActionContext(editability: .readOnly, calculation: nil, chatGPTInstalled: false, clipboardHasContent: true)

    private func applying(_ text: String, _ context: TextActionContext) -> Set<TextActionID> {
        Set(TextActionID.allCases.filter { TextActionApplicability.applies($0, traits: traits(text), context: context) })
    }

    func testTheMatrix() {
        let always: Set<TextActionID> = [.copy, .pinToClipboard, .count, .urlCoding, .base64, .markdown, .search, .githubSearch]
        // Plain English in a read-only web page.
        XCTAssertEqual(applying("The quick brown fox", readOnly),
                       always.union([.lookUp, .translate, .speak, .changeCase]))
        // The same text in a field: Cut and Paste join.
        XCTAssertEqual(applying("The quick brown fox", editable),
                       always.union([.lookUp, .translate, .speak, .changeCase, .cut, .paste]))
        // A link: Open Link, not Look Up or Translate.
        XCTAssertEqual(applying("github.com/apple/swift", readOnly),
                       always.union([.openLink, .speak, .changeCase]))
        // An address: New Email only.
        XCTAssertEqual(applying("kim@naver.com", readOnly),
                       always.union([.newEmail, .speak, .changeCase]))
        // Korean: no Change Case (no letter case).
        XCTAssertEqual(applying("안녕하세요", readOnly), always.union([.lookUp, .translate, .speak]))
        // JSON: Format JSON, not Translate or Look Up.
        XCTAssertEqual(applying(#"{"name": "AOM"}"#, readOnly),
                       always.union([.formatJSON, .speak, .changeCase]))
        // A number: no Translate, Look Up or Change Case; Speak reads digits.
        XCTAssertEqual(applying("42", readOnly), always.union([.speak]))
        // Several lines: no Look Up.
        XCTAssertFalse(applying("one\ntwo", readOnly).contains(.lookUp))
    }

    func testCutAndPasteNeedAnEditableFieldAndPasteAClipboard() {
        XCTAssertFalse(TextActionApplicability.applies(.cut, traits: traits("x"), context: readOnly))
        var unknown = editable
        unknown.editability = .unknown
        XCTAssertFalse(TextActionApplicability.applies(.cut, traits: traits("x"), context: unknown), "text read with ⌘C is not known to be editable")
        var empty = editable
        empty.clipboardHasContent = false
        XCTAssertFalse(TextActionApplicability.applies(.paste, traits: traits("x"), context: empty))
        XCTAssertTrue(TextActionApplicability.applies(.cut, traits: traits("x"), context: empty))
    }

    func testCalculateNeedsAResultThatSaysSomethingNew() {
        var context = readOnly
        context.calculation = AOMCalculator.Result(value: 132, display: "132")
        XCTAssertTrue(TextActionApplicability.applies(.calculate, traits: traits("12 × 11"), context: context))
        XCTAssertFalse(TextActionApplicability.applies(.calculate, traits: traits("hello"), context: context), "not a sum")
        context.calculation = AOMCalculator.Result(value: 42, display: "42")
        XCTAssertFalse(TextActionApplicability.applies(.calculate, traits: traits("42"), context: context), "a lone number")
        context.calculation = AOMCalculator.Result(value: 7, display: "7")
        XCTAssertFalse(TextActionApplicability.applies(.calculate, traits: traits("3 + 4"), context: TextActionContext()),
                       "no result, no Calculate (the calculator returns nil)")
        context.calculation = AOMCalculator.Result(value: nil, display: "10 km = 6.214 mi")
        XCTAssertTrue(TextActionApplicability.applies(.calculate, traits: traits("10 km to mi"), context: context))
    }

    func testAskChatGPTNeedsTheApp() {
        XCTAssertFalse(TextActionApplicability.applies(.askChatGPT, traits: traits("x"), context: readOnly))
        var installed = readOnly
        installed.chatGPTInstalled = true
        XCTAssertTrue(TextActionApplicability.applies(.askChatGPT, traits: traits("x"), context: installed))
    }

    func testLimits() {
        let long = String(repeating: "a", count: TextActionApplicability.searchLimit + 1)
        XCTAssertFalse(TextActionApplicability.applies(.search, traits: traits(long), context: readOnly))
        XCTAssertFalse(TextActionApplicability.applies(.lookUp, traits: traits(String(repeating: "a", count: 41)), context: readOnly))
        XCTAssertTrue(TextActionApplicability.applies(.copy, traits: traits(long), context: readOnly))
        XCTAssertFalse(TextActionApplicability.applies(.copy, traits: traits("   "), context: readOnly), "blank text has no actions")
    }

    func testTransformVariants() {
        XCTAssertEqual(TextActionApplicability.variants(for: .changeCase, traits: traits("x")).count, 6)
        XCTAssertEqual(TextActionApplicability.variants(for: .urlCoding, traits: traits("a b")), [.urlEncode])
        XCTAssertEqual(TextActionApplicability.variants(for: .urlCoding, traits: traits("a%20b")), [.urlDecode, .urlEncode])
        XCTAssertEqual(TextActionApplicability.variants(for: .base64, traits: traits("hello")), [.base64Encode])
        XCTAssertEqual(TextActionApplicability.variants(for: .base64, traits: traits("SGVsbG8gd29ybGQ=")), [.base64Decode, .base64Encode])
        XCTAssertEqual(TextActionApplicability.variants(for: .formatJSON, traits: traits("x")), [])
        XCTAssertEqual(TextActionApplicability.variants(for: .markdown, traits: traits("x")).count, 4)
    }

    func testTheBarFollowsTheUsersOrderAndSwitches() {
        var settings = TextActionsSettings()
        settings.moveAction(.translate, before: .copy)
        settings.setAction(.search, isOn: false)
        let actions = TextActionApplicability.actions(settings: settings, traits: traits("hello"), context: readOnly)
        XCTAssertEqual(actions.first, .translate)
        XCTAssertFalse(actions.contains(.search))
        XCTAssertFalse(actions.contains(.cut), "read-only text")
    }

    func testItems() {
        var context = editable
        context.calculation = AOMCalculator.Result(value: 132, display: "132")
        let sum = traits("12 × 11")
        let items = TextActionBarItems.make([.copy, .calculate, .count, .urlCoding, .changeCase, .speak], traits: sum,
                                            context: context, speaking: true)
        XCTAssertEqual(items.map(\.id), [.copy, .calculate, .count, .urlCoding, .changeCase, .speak])
        XCTAssertEqual(items[1].kind, .result)
        XCTAssertEqual(items[1].title, "= 132")
        XCTAssertTrue(items[1].help.contains("⌥-click"), "editable text: ⌥-click replaces")
        XCTAssertEqual(items[2].kind, .chip)
        XCTAssertEqual(items[2].title, "7 chars · 2 words", "operators are not words")
        XCTAssertEqual(items[3].kind, .transform(.urlEncode), "one rewrite runs directly")
        XCTAssertEqual(items[3].title, "URL Encode")
        if case .menu(let variants) = items[4].kind { XCTAssertEqual(variants.count, 6) } else { XCTFail("Change Case opens its styles") }
        XCTAssertEqual(items[5].title, "Stop", "Speak becomes Stop while speaking")

        let readOnlyItems = TextActionBarItems.make([.calculate], traits: sum, context: TextActionContext(
            editability: .readOnly, calculation: context.calculation, chatGPTInstalled: false, clipboardHasContent: true), speaking: false)
        XCTAssertFalse(readOnlyItems[0].help.contains("⌥-click"))
        XCTAssertTrue(TextActionBarItems.make([.calculate], traits: traits("hello"), context: context, speaking: false).isEmpty)
    }

    @MainActor
    func testWhichActionsHideTheBarBeforeTheyRun() {
        let copy = TextActionBarItem(id: .copy, kind: .action, title: "Copy", symbol: "doc.on.doc", help: "", accessibilityLabel: "Copy")
        let paste = TextActionBarItem(id: .paste, kind: .action, title: "Paste", symbol: "", help: "", accessibilityLabel: "")
        let upper = TextActionBarItem(id: .changeCase, kind: .menu([]), title: "", symbol: "", help: "", accessibilityLabel: "")
        let result = TextActionBarItem(id: .calculate, kind: .result, title: "= 1", symbol: "", help: "", accessibilityLabel: "")
        XCTAssertFalse(TextActionPerformer.hidesBarFirst(copy, variant: nil, alternate: false, editability: .editable))
        XCTAssertTrue(TextActionPerformer.hidesBarFirst(paste, variant: nil, alternate: false, editability: .editable))
        XCTAssertTrue(TextActionPerformer.hidesBarFirst(upper, variant: .changeCase(.upper), alternate: false, editability: .editable))
        XCTAssertFalse(TextActionPerformer.hidesBarFirst(upper, variant: .changeCase(.upper), alternate: true, editability: .editable),
                       "⌥-click copies the result: the bar confirms it")
        XCTAssertFalse(TextActionPerformer.hidesBarFirst(upper, variant: .changeCase(.upper), alternate: false, editability: .readOnly))
        XCTAssertTrue(TextActionPerformer.hidesBarFirst(result, variant: nil, alternate: true, editability: .editable))
        XCTAssertFalse(TextActionPerformer.hidesBarFirst(result, variant: nil, alternate: false, editability: .editable))
    }
}
