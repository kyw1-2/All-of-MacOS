import XCTest
import AppKit
@testable import AllOfMacOS

@MainActor
final class ClipboardIntegrationTests: XCTestCase {
    func testShortcutDisabledStateSurvivesRelaunchAndExactModifiersMatch() {
        let suite = "AOMClipboardIntegration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = ClipboardShortcuts(defaults: defaults)
        XCTAssertEqual(shortcuts.matchingCommand(keyCode: 9, modifiers: [.command, .shift]), .history)
        XCTAssertNil(shortcuts.matchingCommand(keyCode: 9, modifiers: [.command, .shift, .option]))
        shortcuts.setShortcut(nil, for: .history)
        XCTAssertFalse(ClipboardShortcuts(defaults: defaults).hasActiveShortcuts)
    }
    func testBuiltinConsumesDownRepeatAndUpExactlyOnce() {
        let old = UserDefaults.standard.object(forKey: "AOMGlobalEnabled")
        defer { UserDefaults.standard.set(old, forKey: "AOMGlobalEnabled") }
        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
        var fired = 0
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false, builtinHandler: { _, _ in fired += 1; return true })
        XCTAssertTrue(monitor.handleInput(keyCode: 9, modifiers: [.command, .shift], isDown: true))
        XCTAssertTrue(monitor.handleInput(keyCode: 9, modifiers: [.command, .shift], isDown: true, isRepeat: true))
        XCTAssertTrue(monitor.handleInput(keyCode: 9, modifiers: [], isDown: false))
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(monitor.handleInput(keyCode: 9, modifiers: [], isDown: false))
    }
    func testExplicitBindingWinsOverBuiltinAndRecordingPassesThrough() {
        let old = UserDefaults.standard.object(forKey: "AOMGlobalEnabled")
        defer { UserDefaults.standard.set(old, forKey: "AOMGlobalEnabled") }
        UserDefaults.standard.set(true, forKey: "AOMGlobalEnabled")
        var builtinCalls = 0
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false, builtinHandler: { _, _ in builtinCalls += 1; return true })
        let trigger = Trigger(name: "User owns this key", input: .keyboardShortcut(.init(keyCode: 9, modifiers: [.command, .shift])))
        monitor.registerTriggers([trigger])
        XCTAssertTrue(monitor.handleInput(keyCode: 9, modifiers: [.command, .shift], isDown: true))
        XCTAssertEqual(builtinCalls, 0)
        XCTAssertTrue(monitor.handleInput(keyCode: 9, modifiers: [], isDown: false))
        KeyboardMonitor.beginShortcutRecording()
        defer { KeyboardMonitor.endShortcutRecording() }
        XCTAssertFalse(monitor.handleInput(keyCode: 9, modifiers: [.command, .shift], isDown: true))
        XCTAssertEqual(builtinCalls, 0)
        monitor.unregisterAll()
    }
    func testClipboardActionsRoundTripAndHaveOwnCategory() throws {
        for type in [ActionType.showClipboardHistory, .showPasteStack, .pasteNextClipboardItem, .toggleClipboardRecording] {
            XCTAssertEqual(type.category, .clipboard)
            XCTAssertEqual(try JSONDecoder().decode(TriggerAction.self, from: JSONEncoder().encode(TriggerAction(actionType: type))).actionType, type)
        }
    }
}
