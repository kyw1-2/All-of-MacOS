import XCTest
import AppKit
@testable import AllOfMacOS

/// A key-up that never reaches the tap (Secure Input, a disabled tap) must not
/// make the next ordinary press of that key disappear.
final class KeyboardStalePressTests: XCTestCase {
    private func monitor() -> KeyboardMonitor {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false, builtinHandler: { _, _ in false })
        monitor.registerTriggers([Trigger(name: "Capture", input: .keyboardShortcut(
            KeyboardShortcut(keyCode: 0, modifiers: [.control, .option, .command])))])
        return monitor
    }

    func testFreshPressAfterLostKeyUpIsNotSwallowed() {
        let monitor = monitor()
        let shortcut: NSEvent.ModifierFlags = [.control, .option, .command]
        XCTAssertTrue(monitor.handleInput(keyCode: 0, modifiers: shortcut, isDown: true))
        // The key-up is lost. The next plain "a" must reach the app.
        XCTAssertFalse(monitor.handleInput(keyCode: 0, modifiers: [], isDown: true, text: "a"))
        XCTAssertFalse(monitor.handleInput(keyCode: 0, modifiers: [], isDown: false))
    }

    func testAutorepeatOfSwallowedPressStaysSwallowed() {
        let monitor = monitor()
        let shortcut: NSEvent.ModifierFlags = [.control, .option, .command]
        XCTAssertTrue(monitor.handleInput(keyCode: 0, modifiers: shortcut, isDown: true))
        XCTAssertTrue(monitor.handleInput(keyCode: 0, modifiers: shortcut, isDown: true, isRepeat: true))
        XCTAssertTrue(monitor.handleInput(keyCode: 0, modifiers: shortcut, isDown: false))
    }
}
