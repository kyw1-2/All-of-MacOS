import AppKit
import XCTest
@testable import AllOfMacOS

/// The hold-⌘ shortcut sheet: when a ⌘ press counts as a hold, and the
/// settings it reads. No event monitors are installed.
final class PaletteShortcutSheetTests: XCTestCase {
    func testCommandAloneArmsOnce() {
        var detector = PaletteHoldDetector()
        XCTAssertEqual(detector.handle(.modifiers(.command)), .arm)
        XCTAssertEqual(detector.handle(.modifiers(.command)), .none, "a repeated flags event doesn't restart the timer")
        XCTAssertTrue(detector.armed)
        XCTAssertEqual(detector.handle(.modifiers([])), .disarm, "releasing ⌘ hides the sheet")
        XCTAssertEqual(detector.handle(.modifiers([])), .none)
    }

    func testAShortcutIsNotAHold() {
        var detector = PaletteHoldDetector()
        _ = detector.handle(.modifiers(.command))
        XCTAssertEqual(detector.handle(.key), .disarm, "⌘C while holding is a shortcut")
        XCTAssertEqual(detector.handle(.modifiers(.command)), .arm, "⌘ goes down again after the key")
        XCTAssertEqual(detector.handle(.mouse), .disarm, "⌘-click is not a hold")
    }

    func testOtherModifiersCancel() {
        var detector = PaletteHoldDetector()
        XCTAssertEqual(detector.handle(.modifiers([.command, .shift])), .none, "⇧⌘ never arms")
        _ = detector.handle(.modifiers(.command))
        XCTAssertEqual(detector.handle(.modifiers([.command, .option])), .disarm)
        XCTAssertEqual(detector.handle(.modifiers([.command, .capsLock])), .arm, "Caps Lock doesn't count")
        XCTAssertEqual(detector.handle(.modifiers([.command, .function])), .disarm, "fn does")
        XCTAssertEqual(detector.handle(.key), .none, "keys without a hold do nothing")
    }

    @MainActor
    func testSettingsKeysAndHoldRange() {
        XCTAssertEqual(PaletteShortcutSheet.enabledKey, "AOMPaletteShortcutSheetEnabled")
        XCTAssertEqual(PaletteShortcutSheet.holdKey, "AOMPaletteShortcutSheetHoldSeconds")
        XCTAssertEqual(PaletteShortcutSheet.holdRange, 0.8...2.0)
        XCTAssertEqual(PaletteShortcutSheet.defaultHold, 1.2)
    }
}
