import AppKit
import XCTest
@testable import AllOfMacOS

/// Password fields: macOS withholds Option-only hot keys during Secure Event
/// Input, so those shortcuts gain a Control alias there, and typed characters
/// never latch a modifier in the HID system state.
final class SecureInputHotKeyTests: XCTestCase {
    private let p: UInt16 = 35

    func testOnlyOptionAndOptionShiftChordsAreWithheld() {
        let withheld: [NSEvent.ModifierFlags] = [[.option], [.option, .shift]]
        let delivered: [NSEvent.ModifierFlags] = [[.command], [.control], [.control, .option], [.control, .shift],
                                                  [.command, .option], [.command, .shift], [.control, .option, .command]]
        for modifiers in withheld {
            XCTAssertTrue(SecureInputHotKeys.isWithheldDuringSecureInput(KeyboardShortcut(keyCode: p, modifiers: modifiers)))
        }
        for modifiers in delivered {
            XCTAssertFalse(SecureInputHotKeys.isWithheldDuringSecureInput(KeyboardShortcut(keyCode: p, modifiers: modifiers)))
        }
    }

    func testSecureAliasAddsControlToTheSameKey() {
        XCTAssertEqual(SecureInputHotKeys.secureAlias(for: KeyboardShortcut(keyCode: p, modifiers: [.option])),
                       KeyboardShortcut(keyCode: p, modifiers: [.control, .option]))
        XCTAssertEqual(SecureInputHotKeys.secureAlias(for: KeyboardShortcut(keyCode: p, modifiers: [.option, .shift])),
                       KeyboardShortcut(keyCode: p, modifiers: [.control, .option, .shift]))
        XCTAssertNil(SecureInputHotKeys.secureAlias(for: KeyboardShortcut(keyCode: p, modifiers: [.command])))
        XCTAssertNil(SecureInputHotKeys.secureAlias(for: KeyboardShortcut(keyCode: p, modifiers: [.control, .option])))
    }

    func testPlanKeepsEveryChordAndRoutesTheAliasToItsTrigger() {
        let password = KeyboardShortcut(keyCode: p, modifiers: [.option])
        let kakao = KeyboardShortcut(keyCode: 40, modifiers: [.command])
        let plan = SecureInputHotKeys.registrationPlan(for: [password, kakao])
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan[password], password)
        XCTAssertEqual(plan[kakao], kakao)
        XCTAssertEqual(plan[KeyboardShortcut(keyCode: p, modifiers: [.control, .option])], password)
    }

    func testAliasNeverShadowsAnExplicitBinding() {
        let password = KeyboardShortcut(keyCode: p, modifiers: [.option])
        let explicit = KeyboardShortcut(keyCode: p, modifiers: [.control, .option])
        let plan = SecureInputHotKeys.registrationPlan(for: [password, explicit])
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[explicit], explicit)
        XCTAssertEqual(plan[password], password)
    }

    func testHotKeysAreHeldOnlyForModifiedChordsDuringSecureInput() {
        let password = KeyboardShortcut(keyCode: p, modifiers: [.option])
        let kakao = KeyboardShortcut(keyCode: 40, modifiers: [.command])
        let shiftOnly = KeyboardShortcut(keyCode: p, modifiers: [.shift])
        let function = KeyboardShortcut(keyCode: 0, modifiers: [.function, .control])
        let all: Set<KeyboardShortcut> = [password, kakao, shiftOnly, function]
        XCTAssertEqual(SecureInputHotKeys.wantedShortcuts(secureInput: true, screenLocked: false) { all }, [password, kakao])
        var evaluated = false
        XCTAssertEqual(SecureInputHotKeys.wantedShortcuts(secureInput: false, screenLocked: false) { evaluated = true; return all }, [])
        XCTAssertFalse(evaluated, "Outside Secure Input the trigger list is not even consulted")
    }

    func testNothingIsRegisteredWhileTheScreenIsLocked() {
        // The lock screen holds Secure Input itself; a password shortcut there
        // would type into the lock-screen field.
        let password = KeyboardShortcut(keyCode: p, modifiers: [.option])
        var evaluated = false
        XCTAssertEqual(SecureInputHotKeys.wantedShortcuts(secureInput: true, screenLocked: true) { evaluated = true; return [password] }, [])
        XCTAssertFalse(evaluated)
    }

    func testTypedCharactersUseAPrivateSourceAndKeepTheirUnicodePayload() throws {
        for (units, shifted) in [(Array("A".utf16), true), (Array("한".utf16), false), (Array("!".utf16), true)] {
            let (down, up) = try XCTUnwrap(ActionExecutor.textEvents(units, keyCode: 0, shifted: shifted))
            for event in [down, up] {
                // A private source gets its own state ID; never the shared HID state.
                let state = event.getIntegerValueField(.eventSourceStateID)
                XCTAssertNotEqual(state, Int64(CGEventSourceStateID.hidSystemState.rawValue))
                XCTAssertNotEqual(state, Int64(CGEventSourceStateID.combinedSessionState.rawValue))
                XCTAssertEqual(event.flags, shifted ? .maskShift : [])
                var count = 0, output = [UInt16](repeating: 0, count: 20)
                event.keyboardGetUnicodeString(maxStringLength: 20, actualStringLength: &count, unicodeString: &output)
                XCTAssertEqual(Array(output.prefix(count)), units)
            }
        }
    }
}
