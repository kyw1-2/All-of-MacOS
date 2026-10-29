import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class BTTPresetImportTests: XCTestCase {
    typealias Group = BTTPresetImport.Entry.Group
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func keyboard(_ actions: [[String: Any]], extras: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["BTTTriggerClass": "BTTTriggerTypeKeyboardShortcut", "BTTTriggerType": 0, "BTTTriggerName": "Example", "BTTShortcutKeyCode": 8, "BTTShortcutModifierKeys": NSEvent.ModifierFlags.command.rawValue, "BTTTriggerOnDown": 1, "BTTActionsToExecute": actions]
        result.merge(extras) { _, new in new }; return result
    }
    private func action(_ id: Int, extras: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["BTTPredefinedActionType": id]; result.merge(extras) { _, new in new }; return result
    }

    func testKeyboardAndSixDocumentedSimpleActionsPreserveOrderAndEnabledState() throws {
        let ids = [21, 19, 20, 24, 25, 22]
        let report = try BTTPresetImport.parse(data(keyboard(ids.map { action($0) }, extras: ["BTTTriggerOnDown": 0, "BTTEnabled": 1, "BTTEnabled2": 1])))
        XCTAssertTrue(report.skipped.isEmpty)
        let trigger = try XCTUnwrap(report.triggers.first)
        XCTAssertTrue(trigger.isEnabled, "an exact match keeps BTT's enabled state")
        XCTAssertEqual(trigger.keyboardPhase, .keyUp)
        XCTAssertEqual(trigger.actions.map(\.actionType), [.maximizeWindow, .snapWindowLeft, .snapWindowRight, .volumeUp, .volumeDown, .muteVolume])
        XCTAssertEqual(trigger.input, .keyboardShortcut(KeyboardShortcut(keyCode: 8, modifiers: .command)))
    }

    func testNamedTriggerAndNamedCallKeepNamesWithoutExecuting() throws {
        let named: [String: Any] = ["BTTTriggerClass": "BTTTriggerTypeOtherTriggers", "BTTTriggerType": 643, "BTTTriggerName": "Window Task", "BTTActionsToExecute": [action(248, extras: ["BTTNamedTriggerToTrigger": "Child Task", "BTTAdditionalActionData": [:]])]]
        let report = try BTTPresetImport.parse(data([named]))
        let trigger = try XCTUnwrap(report.triggers.first)
        XCTAssertEqual(trigger.input, .namedTrigger("Window Task"))
        XCTAssertEqual(trigger.actions.first?.parameters.namedTriggerName, "Child Task")
        XCTAssertTrue(trigger.isEnabled)
        XCTAssertTrue(report.reviewText.contains("Named-trigger calls keep their names"))
    }

    func testShortcutPhysicalModifiersMapToAOMWithoutDroppingParameters() throws {
        let shortcut = action(264, extras: ["BTTShortcutToSend": "59,58,55,8", "BTTAdditionalActionData": ["BTTActionSendKeyboardShortcutIncludeCurrentModifiers": false, "BTTActionSendKeyboardShortcutLowLevel": false]])
        let report = try BTTPresetImport.parse(data(keyboard([shortcut])))
        let mapped = try XCTUnwrap(report.triggers.first?.actions.first)
        XCTAssertEqual(mapped.actionType, .sendKeyStroke)
        XCTAssertEqual(mapped.parameters.shortcutKeyCode, 8)
        XCTAssertEqual(mapped.parameters.shortcutModifiers, NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
        for invalid in ["55,58,8", "55,55,8", "55,,8", "55", "-1", "128"] {
            let rejected = try BTTPresetImport.parse(data(keyboard([action(264, extras: ["BTTShortcutToSend": invalid])])))
            XCTAssertTrue(rejected.triggers.isEmpty, invalid)
            XCTAssertEqual(rejected.skipped.count, 1, invalid)
        }
        // Right ⌘ (54) is valid BTT input; AOM sends the plain modifier and says so.
        let rightCommand = try BTTPresetImport.parse(data(keyboard([action(264, extras: ["BTTShortcutToSend": "54,8"])])))
        XCTAssertEqual(rightCommand.triggers.first?.actions.first?.parameters.shortcutModifiers, NSEvent.ModifierFlags.command.rawValue)
        XCTAssertEqual(rightCommand.entries.first?.group, .approximate)
    }

    func testUnsupportedDetailsAreReportedInsteadOfSilentlyDropped() throws {
        let candidates = [
            keyboard([action(21), action(99999)]),
            keyboard([action(21)], extras: ["BTTConditionName": "Conditional"]),
            keyboard([action(21)], extras: ["BTTAppBundleIdentifier": "com.example.App"]),
            keyboard([action(21)], extras: ["BTTKeyboardShortcutMinTime": 0.5]),
            keyboard([action(264, extras: ["BTTShortcutToSend": "55,8", "BTTShortcutUpDown": "onlyDown"])]),
            keyboard([action(264, extras: ["BTTShortcutToSend": "55,8", "BTTAdditionalActionData": ["BTTActionSendKeyboardShortcutIncludeCurrentModifiers": true]])]),
            keyboard([action(248, extras: ["BTTNamedTriggerToTrigger": "Child", "BTTAdditionalActionData": ["variable": "value"]])])
        ]
        let report = try BTTPresetImport.parse(data(candidates))
        let groups = report.entries.filter { $0.kind == .trigger }.map(\.group.rawValue).sorted()
        XCTAssertEqual(groups, [Group.approximate, .approximate, .approximate, .approximate, .imported, .imported, .skipped].map(\.rawValue).sorted())
        XCTAssertTrue(report.entries.filter { $0.group != .imported }.allSatisfy { !$0.reasons.isEmpty })
        XCTAssertEqual(report.triggers.first { $0.appBundleID == "com.example.App" }?.isEnabled, true)
        XCTAssertEqual(report.triggers.first { $0.minHoldMs == 500 }?.isEnabled, true)
        XCTAssertTrue(report.triggers.filter { $0.notes.contains("•") }.allSatisfy { !$0.isEnabled }, "approximate imports are disabled")
        XCTAssertTrue(report.reviewText.contains("Skipped whole triggers"))
    }

    func testUnsupportedEntriesAreReportedWhileIndependentValidTriggersRemainStaged() throws {
        let report = try BTTPresetImport.parse(data([keyboard([action(22)]), ["BTTTriggerClass": "BTTTriggerTypeTrackpadAll", "BTTTriggerType": 209]]))
        XCTAssertEqual(report.candidateCount, 2)
        XCTAssertEqual(report.triggers.count, 1)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(report.skipped.first?.index, 1)
        XCTAssertTrue(report.triggers[0].isEnabled)
    }

    func testMalformedNumbersAndMeaningfulDefaultsFailClosed() throws {
        for extras: [String: Any] in [["BTTShortcutKeyCode": true], ["BTTShortcutKeyCode": -1], ["BTTShortcutModifierKeys": 1], ["BTTTriggerOnDown": 2], ["BTTEnabled": "1"], ["BTTTriggerType": 1]] {
            let report = try BTTPresetImport.parse(data(keyboard([action(21)], extras: extras)))
            XCTAssertTrue(report.triggers.isEmpty)
        }
        let disabled = try BTTPresetImport.parse(data(keyboard([action(21, extras: ["BTTEnabled": 0])])))
        XCTAssertFalse(try XCTUnwrap(disabled.triggers.first?.actions.first).isEnabled)
    }

    func testByteCountDepthActionCountAndWrapperLimits() throws {
        XCTAssertThrowsError(try BTTPresetImport.parse(Data(repeating: 32, count: BTTPresetImport.maximumBytes + 1)))
        XCTAssertThrowsError(try BTTPresetImport.parse(Data((String(repeating: "[", count: 33) + String(repeating: "]", count: 33)).utf8)))
        XCTAssertThrowsError(try BTTPresetImport.parse(data(Array(repeating: keyboard([action(21)]), count: BTTPresetImport.maximumTriggers + 1))))
        XCTAssertThrowsError(try BTTPresetImport.parse(data(["BTTTriggerConfig": keyboard([action(21)])])))
        let excessive = try BTTPresetImport.parse(data(keyboard(Array(repeating: action(21), count: 65))))
        XCTAssertTrue(excessive.triggers.isEmpty)
    }

    func testAddingReviewedTriggersKeepsCurrentPresetAndAlwaysDisablesNewTriggers() throws {
        let state = AppState()
        state.currentPreset = Preset(name: "Existing")
        let existing = Trigger(name: "Keep me", input: .namedTrigger("Keep me"))
        state.currentPreset.addTrigger(existing)
        let originalID = state.currentPreset.id
        var staged = try XCTUnwrap(BTTPresetImport.parse(data(keyboard([action(21)]))).triggers.first)
        staged.isEnabled = true // The legacy merge boundary enforces disabled staging.
        state.addDisabledBTTTriggers([staged])
        XCTAssertEqual(state.currentPreset.id, originalID)
        XCTAssertEqual(state.currentPreset.name, "Existing")
        XCTAssertEqual(state.currentPreset.triggers.first, existing)
        XCTAssertEqual(state.currentPreset.triggers.count, 2)
        XCTAssertFalse(state.currentPreset.triggers[1].isEnabled)
        state.flushPendingWrites()
    }
}
