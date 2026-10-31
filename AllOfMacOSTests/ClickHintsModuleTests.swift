import ApplicationServices
import XCTest
@testable import AllOfMacOS

/// The entry points, the status menu item, and how a target is acted on.
@MainActor
final class ClickHintsModuleTests: XCTestCase {
    func testTheStatusMenuItem() throws {
        let items = ClickHintsModule.statusMenuItems()
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.title, "Click with Keyboard")
        XCTAssertNotNil(item.image, "one symbol per top-level item (b.14)")
        XCTAssertNotNil(item.action)
        XCTAssertNotNil(item.target, "the closure target is retained by the item")
        XCTAssertFalse(item.toolTip?.isEmpty ?? true)
    }

    func testTheShortcutShowsAsTheKeyEquivalent() {
        let item = NSMenuItem(title: "Click with Keyboard", action: nil, keyEquivalent: "")
        ClickHintsModule.applyShortcut(KeyboardShortcut(keyCode: 49, modifiers: [.command, .shift]), to: item)
        XCTAssertEqual(item.keyEquivalent, " ", "Space")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])

        let letter = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        ClickHintsModule.applyShortcut(KeyboardShortcut(keyCode: 38, modifiers: [.control, .option]), to: letter)
        XCTAssertEqual(letter.keyEquivalent, "j")
        XCTAssertEqual(letter.keyEquivalentModifierMask, [.control, .option])

        let function = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        ClickHintsModule.applyShortcut(KeyboardShortcut(keyCode: 96, modifiers: [.command]), to: function)
        XCTAssertEqual(function.keyEquivalent, "", "F5 is left off rather than shown wrong")
    }

    func testShowHintsNeverReadsTheScreenInTests() {
        ClickHintsModule.start()
        ClickHintsModule.showHints()
        XCTAssertFalse(ClickHintsModule.isScanning)
        XCTAssertFalse(ClickHintsModule.isShowing)
        XCTAssertNil(ClickHintsSession.active)
    }

    func testTheShortcutCaseName() {
        // The integrator adds `case showClickHints` to CaptureShortcutAction;
        // until then the module simply has no binding.
        XCTAssertEqual(ClickHintsModule.shortcutActionID, "showClickHints")
        XCTAssertEqual(ClickHintsModule.shortcutAction?.rawValue ?? "showClickHints", "showClickHints")
    }

    // MARK: Acting

    func testHowEachKindOfTargetIsActedOn() {
        let press = kAXPressAction as String
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .press, role: kAXButtonRole, actions: [press, kAXShowMenuAction]),
                       [.action(press), .click(right: false, command: false)])
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .press, role: kAXTextFieldRole, actions: []),
                       [.focus, .click(right: false, command: false)], "a text field gets the focus")
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .press, role: kAXSliderRole, actions: ["AXIncrement"]).first, .focus,
                       "a click would move the knob")
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .press, role: kAXGroupRole, actions: [kAXConfirmAction]),
                       [.action(kAXConfirmAction), .click(right: false, command: false)])
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .press, role: kAXGroupRole, actions: [kAXPickAction]).first,
                       .action(kAXPickAction))
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .press, role: kAXRowRole, actions: []),
                       [.click(right: false, command: false)], "a row without an action is clicked")
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .rightClick, role: kAXButtonRole, actions: [press, kAXShowMenuAction]),
                       [.action(kAXShowMenuAction), .click(right: true, command: false)])
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .rightClick, role: "AXLink", actions: [press]),
                       [.click(right: true, command: false)])
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .commandClick, role: "AXLink", actions: [press]),
                       [.click(right: false, command: true)], "an action can't carry ⌘")
        XCTAssertEqual(ClickHintsPerformer.plan(kind: .movePointer, role: kAXButtonRole, actions: [press]), [.movePointer])
    }

    func testABusyAppGetsNoSecondClick() {
        XCTAssertTrue(ClickHintsPerformer.acted(.success))
        // A button that opens a dialog answers late: no fallback click.
        XCTAssertTrue(ClickHintsPerformer.acted(.cannotComplete))
        XCTAssertFalse(ClickHintsPerformer.acted(.actionUnsupported))
        XCTAssertFalse(ClickHintsPerformer.acted(.attributeUnsupported))
        XCTAssertFalse(ClickHintsPerformer.acted(.failure))
    }

    func testClickKindTitles() {
        XCTAssertEqual(ClickHintsClickKind.press.title, "Click")
        XCTAssertEqual(ClickHintsClickKind.rightClick.title, "Right-Click")
    }

    // MARK: Live reader parsing (no other app involved)

    func testBatchAnswersAreParsed() throws {
        var origin = CGPoint(x: 10, y: 20), size = CGSize(width: 30, height: 40)
        let position = try XCTUnwrap(AXValueCreate(.cgPoint, &origin))
        let extent = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        var error = AXError.attributeUnsupported
        let missing = try XCTUnwrap(AXValueCreate(.axError, &error))
        let answer: [AnyObject] = ["AXButton" as NSString, missing, position, extent, kCFBooleanFalse,
                                   "Save" as NSString, kCFNull, "Name" as NSString, missing]
        let attributes = try XCTUnwrap(ClickHintsLiveReader.parse(answer))
        XCTAssertEqual(attributes.role, "AXButton")
        XCTAssertNil(attributes.subrole)
        XCTAssertEqual(attributes.frame, CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(attributes.enabled, false)
        XCTAssertEqual(attributes.title, "Save")
        XCTAssertNil(attributes.label)
        XCTAssertEqual(attributes.placeholder, "Name")
        XCTAssertEqual(attributes.searchText, "Save Name")
        let noRole: [AnyObject] = [missing, missing, missing, missing, missing, missing, missing, missing, missing]
        XCTAssertNil(ClickHintsLiveReader.parse(noRole))
    }
}
