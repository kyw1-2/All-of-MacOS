import AppKit
import XCTest
@testable import AllOfMacOS

/// The module's entry points: the status menu item, the test guard on
/// `measure()`, and the overlay refusing stills that do not match the
/// displays. No window is shown and the screen is never read.
@MainActor
final class ScreenRulerModuleTests: XCTestCase {
    func testTheStatusMenuItemShowsTheMeasureScreenShortcut() throws {
        let items = ScreenRulerModule.statusMenuItems()
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.title, "Measure Screen")
        XCTAssertNotNil(item.image)
        XCTAssertNotNil(item.action)
        XCTAssertNotNil(item.target)
        // The current Settings › Shortcuts binding, whatever it is in this host.
        let shortcut = try XCTUnwrap(CaptureShortcuts.shared.shortcut(for: .measureScreen))
        XCTAssertEqual(item.keyEquivalent, keyCodeToString(shortcut.keyCode).lowercased())
        XCTAssertEqual(item.keyEquivalentModifierMask, shortcut.modifiers.intersection([.command, .option, .control, .shift]))
        // The default is ⇧⌘7.
        XCTAssertEqual(CaptureShortcutAction.measureScreen.defaultShortcut, KeyboardShortcut(keyCode: 26, modifiers: [.command, .shift]))
        XCTAssertEqual(KeyboardShortcut(keyCode: 26, modifiers: [.command, .shift]).displayString, "⇧⌘7")
    }

    func testOnlySingleCharacterKeysBecomeMenuKeyEquivalents() {
        let item = NSMenuItem(title: "Measure Screen", action: nil, keyEquivalent: "")
        ScreenRulerModule.applyShortcut(KeyboardShortcut(keyCode: 49, modifiers: [.command]), to: item) // Space
        XCTAssertEqual(item.keyEquivalent, "")
        ScreenRulerModule.applyShortcut(KeyboardShortcut(keyCode: 15, modifiers: [.command, .option]), to: item) // R
        XCTAssertEqual(item.keyEquivalent, "r")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
    }

    func testMeasureNeverCapturesInTests() {
        ScreenRulerModule.measure()
        XCTAssertFalse(ScreenRulerModule.isStarting, "no capture starts in a test host")
        XCTAssertFalse(ScreenRulerModule.isMeasuring)
        XCTAssertNil(ScreenRulerOverlayController.active)
    }

    func testTheOverlayRefusesStillsThatDoNotMatchTheDisplays() throws {
        let canvas = ScreenRulerCanvas(width: 8, height: 8)
        let frame = ScreenRulerFrame(snapshot: canvas.snapshot(id: 0xDEAD_BEEF, scale: 1), image: canvas.image)
        let controller = ScreenRulerOverlayController(frames: [frame], options: ScreenRulerOptions())
        XCTAssertThrowsError(try controller.present()) { error in
            let expected: ScreenRulerError = NSScreen.screens.isEmpty ? .noDisplays : .displaysChanged
            XCTAssertEqual(error as? ScreenRulerError, expected)
        }
        XCTAssertNil(ScreenRulerOverlayController.active, "nothing was put on screen")
    }
}
