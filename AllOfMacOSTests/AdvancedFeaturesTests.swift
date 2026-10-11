import XCTest
@testable import AllOfMacOS

final class AdvancedFeaturesTests: XCTestCase {
    private func stroke(_ key: UInt16, _ flags: UInt = 0) -> KeySequenceStroke {
        KeySequenceStroke(keyCode: key, modifiers: flags)
    }
    func testRepeatedKeySequenceRequiresPhysicalRelease() {
        let detector = KeySequenceDetector()
        XCTAssertTrue(detector.press(stroke(0), at: 10, in: "com.apple.Safari"))
        XCTAssertFalse(detector.press(stroke(0), at: 10.1, in: "com.apple.Safari"))
        detector.release(0)
        XCTAssertTrue(detector.press(stroke(0), at: 10.3, in: "com.apple.Safari"))
        XCTAssertTrue(detector.matches([stroke(0),stroke(0)], maxGapMs: 450))
        XCTAssertFalse(detector.matches([stroke(0),stroke(0)], maxGapMs: 200))
    }
    func testModifierSequenceAndAppChangeReset() {
        let detector = KeySequenceDetector()
        _ = detector.press(stroke(55), at: 0, in: "test.app")
        detector.release(55)
        _ = detector.press(stroke(55), at: 0.2, in: "test.app")
        XCTAssertTrue(detector.matches([stroke(55),stroke(55)], maxGapMs: 400))
        detector.release(55)
        _ = detector.press(stroke(55), at: 0.3, in: "another.app")
        XCTAssertFalse(detector.matches([stroke(55),stroke(55)], maxGapMs: 400))
    }
    func testDisplayIndependentCustomSnapGeometry() {
        let normalized = WindowGeometry.normalizedRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        XCTAssertNotNil(normalized)
        XCTAssertEqual(WindowGeometry.snapFrame(normalized: normalized!, visible: CGRect(x: 50, y: 80, width: 1000, height: 500)),
                       CGRect(x: 250, y: 130, width: 600, height: 400))
        XCTAssertNil(WindowGeometry.normalizedRect(x: 0.7, y: 0, width: 0.5, height: 1))
        XCTAssertNil(WindowGeometry.normalizedRect(x: .nan, y: 0, width: 0.5, height: 1))
    }
    func testBranchComparisonsAndMissingVariable() {
        var p = ActionParameters()
        p.conditionKind = "variable"; p.variableName = "mode"
        p.conditionOperator = "equals"; p.conditionValue = "study"
        XCTAssertTrue(WorkflowBranchCondition.matches(p, app: "", title: "", mouseX: 0, mouseY: 0,
            variable: { $0 == "mode" ? "study" : nil }))
        XCTAssertFalse(WorkflowBranchCondition.matches(p, app: "", title: "", mouseX: 0, mouseY: 0, variable: { _ in nil }))
        p.conditionKind = "window"; p.conditionOperator = "regex"; p.conditionValue = "(?i)chrome.*video"
        XCTAssertTrue(WorkflowBranchCondition.matches(p, app: "", title: "Chrome - Video", mouseX: 0, mouseY: 0, variable: { _ in nil }))
        p.conditionKind = "mouseX"; p.conditionOperator = "greater"; p.conditionValue = "0.5"
        XCTAssertTrue(WorkflowBranchCondition.matches(p, app: "", title: "", mouseX: 0.9, mouseY: 0, variable: { _ in nil }))
    }
    func testIfElseRunsOnlySelectedBranchAndContinues() {
        var branch = TriggerAction(actionType: .ifElse)
        let thenStep = TriggerAction(actionType: .showHUD)
        let elseStep = TriggerAction(actionType: .setVariable)
        let lastStep = TriggerAction(actionType: .typeText)
        branch.parameters.children = [thenStep]
        branch.parameters.elseChildren = [elseStep]
        var called: [ActionType] = []
        let done = expectation(description: "Sequence completes")
        let runner = ActionSequenceRunner(perform: { step, next in called.append(step.actionType); next(true) },
                                          branchMatches: { _ in false })
        runner.run([branch, lastStep]) { ok in
            XCTAssertTrue(ok)
            XCTAssertEqual(called, [.setVariable, .typeText])
            done.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
    func testV5RoundtripAndV4Import() throws {
        var preset = Preset(name: "Advanced")
        var t = Trigger(name: "Double Command", input: .keySequence([stroke(55), stroke(55)]))
        t.sequenceMaxGapMs = 330
        var condition = TriggerAction(actionType: .ifElse)
        var snap = TriggerAction(actionType: .customSnapWindow)
        snap.parameters.snapX = 0.25; snap.parameters.snapWidth = 0.5
        condition.parameters.children = [snap]
        condition.parameters.elseChildren = [TriggerAction(actionType: .showHUD)]
        t.actions = [condition]
        preset.triggers = [t]
        let blob = try PresetCodec.encode(preset, envelope: true)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: blob) as? [String:Any])?["schemaVersion"] as? Int, 9)
        let restored = try PresetCodec.decode(blob)
        XCTAssertEqual(restored.triggers.first?.sequenceMaxGapMs, 330)
        XCTAssertEqual(restored.triggers.first?.actions.first?.parameters.elseChildren?.count, 1)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: blob) as? [String:Any])
        old["schemaVersion"] = 4
        XCTAssertEqual(try PresetCodec.decode(JSONSerialization.data(withJSONObject: old)).triggers.count, 1)
    }
}

extension AdvancedFeaturesTests {
    func testSnapZoneHotAreaOnlyAndPresetRoundtrip() throws {
        var zone = CustomSnapZone(name: "Hot Corner")
        XCTAssertTrue(zone.isValid)
        XCTAssertTrue(zone.hit(x: 0.95, y: 0.1))
        XCTAssertFalse(zone.hit(x: 0.2, y: 0.1))
        zone.isEnabled = false
        XCTAssertFalse(zone.hit(x: 0.95, y: 0.1))
        zone.isEnabled = true
        var preset = Preset(name: "Window Zones")
        preset.customSnapZones = [zone]
        let roundtrip = try PresetCodec.decode(PresetCodec.encode(preset))
        XCTAssertEqual(roundtrip.customSnapZones, [zone])
        zone.targetX = 0.9
        XCTAssertFalse(zone.isValid)
        preset.customSnapZones = [zone]
        XCTAssertThrowsError(try PresetCodec.decode(PresetCodec.encode(preset)))
    }
    func testRegexRunOnlyWhen() {
        var action = TriggerAction(actionType: .showHUD)
        action.parameters.windowTitleRegex = "^Project [0-9]{2}"
        XCTAssertTrue(ActionSequenceRunner.matches(action, bundleID: "any", windowTitle: "Project 14 - Documents"))
        XCTAssertFalse(ActionSequenceRunner.matches(action, bundleID: "any", windowTitle: "Other Project"))
        action.parameters.windowTitleRegex = "[invalid"
        XCTAssertFalse(ActionSequenceRunner.matches(action, bundleID: "any", windowTitle: "Project 14"))
    }
}
