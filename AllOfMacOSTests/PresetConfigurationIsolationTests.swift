import Foundation
import XCTest
@testable import AllOfMacOS

/// User bindings are runtime configuration, not fixtures embedded in the app.
final class PresetConfigurationIsolationTests: XCTestCase {
    func testFreshPresetDoesNotAutomaticallyInstallExampleBindings() {
        let blank = Preset(name: "Fresh Configuration", isMaster: true)
        XCTAssertTrue(blank.triggers.isEmpty)
        XCTAssertTrue(blank.activationGroups.isEmpty)
        XCTAssertEqual(blank.appTargets.count, 1)
    }

    func testNewActionsDoNotHardcodeAppTargetsOrTypingPayloads() {
        let textAction = TriggerAction(actionType: .typeText)
        XCTAssertNil(textAction.parameters.text)

        let activateAction = TriggerAction(actionType: .activateApplication)
        XCTAssertNil(activateAction.parameters.applicationPath)
        XCTAssertNil(activateAction.parameters.applicationName)

        let input = Trigger(name: "Custom binding", input: .trackpadGesture(.fourFingerTap))
        XCTAssertTrue(input.actions.isEmpty)
    }

    func testCustomGestureTextAndAppBindingsRoundTripWithoutGlobalDefaults() throws {
        var preset = Preset(name: "User-controlled")
        var textAction = TriggerAction(actionType: .typeText)
        textAction.parameters.text = "한국어 Unicode test 👋 — custom text only"

        var gesture = Trigger(name: "Custom gesture", input: .trackpadGesture(.fourFingerSwipeDown))
        gesture.actions = [textAction]
        gesture.isEnabled = false
        preset.addTrigger(gesture)

        var appAction = TriggerAction(actionType: .activateApplication)
        appAction.parameters.applicationName = "com.apple.TextEdit"
        var key = Trigger(name: "Custom app launcher", input: .keyboardShortcut(
            KeyboardShortcut(keyCode: 17, modifiers: [.command, .option])))
        key.actions = [appAction]
        preset.addTrigger(key)

        let decoded = try PresetCodec.decode(PresetCodec.encode(preset))
        XCTAssertEqual(decoded.triggers.count, 2)
        let persistedGesture = try XCTUnwrap(decoded.triggers.first(where: { $0.id == gesture.id }))
        XCTAssertFalse(persistedGesture.isEnabled)
        XCTAssertEqual(persistedGesture.actions.first?.actionType, .typeText)
        XCTAssertEqual(persistedGesture.actions.first?.parameters.text,
                       "한국어 Unicode test 👋 — custom text only")
        let persistedKey = try XCTUnwrap(decoded.triggers.first(where: { $0.id == key.id }))
        XCTAssertEqual(persistedKey.actions.first?.parameters.applicationName, "com.apple.TextEdit")
        XCTAssertNil(persistedGesture.actions.first?.parameters.applicationName)
    }

    func testBundledExampleIsDisabledAndCannotLaunchApplications() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let exampleURL = repositoryRoot.appendingPathComponent("Examples/Disabled-Show-HUD.json")
        let sample = try PresetCodec.decode(Data(contentsOf: exampleURL))

        XCTAssertFalse(sample.isEnabled)
        XCTAssertEqual(sample.triggers.count, 1)
        let trigger = try XCTUnwrap(sample.triggers.first)
        XCTAssertFalse(trigger.isEnabled)
        XCTAssertEqual(trigger.actions.map(\.actionType), [.showHUD])
        XCTAssertEqual(trigger.actions.first?.parameters.hudText,
                       "All of MacOS demo — trigger works")
        XCTAssertTrue(trigger.actions.allSatisfy {
            $0.parameters.applicationName == nil &&
            $0.parameters.applicationPath == nil &&
            $0.parameters.text == nil
        })
    }

    func testSupportedTrackpadRecognitionCasesCanBeConfiguredAsData() throws {
        XCTAssertGreaterThan(TrackpadGesture.allCases.count, 60)
        for gesture in TrackpadGesture.allCases {
            let trigger = Trigger(name: gesture.rawValue, input: .trackpadGesture(gesture))
            let restored = try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(trigger))
            XCTAssertEqual(restored.input, trigger.input)
            XCTAssertTrue(restored.actions.isEmpty)
        }
    }
}
