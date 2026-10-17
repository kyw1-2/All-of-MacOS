import XCTest
@testable import AllOfMacOS

final class TriggerManagementTests: XCTestCase {
    func testDuplicatingTriggerKeepsSettingsAndRenewsNestedActionIdentities() throws {
        var source = Trigger(name: "Work", input: .trackpadGesture(.threeFingerTap))
        source.notes = "Meeting notes"; source.folder = "Work"; source.colorLabel = "Blue"
        source.delayBeforeTriggeringMs = 120
        var group = TriggerAction(actionType: .ifElse)
        group.parameters.children = [TriggerAction(actionType: .showHUD)]
        group.parameters.elseChildren = [TriggerAction(actionType: .showHUD)]
        source.actions = [group]
        let copy = TriggerClipboard.duplicate(source)
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.notes, source.notes)
        XCTAssertEqual(copy.folder, source.folder)
        XCTAssertEqual(copy.delayBeforeTriggeringMs, 120)
        XCTAssertNotEqual(copy.actions[0].id, group.id)
        XCTAssertNotEqual(copy.actions[0].parameters.children![0].id, group.parameters.children![0].id)
        XCTAssertNotEqual(copy.actions[0].parameters.elseChildren![0].id, group.parameters.elseChildren![0].id)
        XCTAssertNil(ActionTree.problem(source.actions + copy.actions))
        XCTAssertEqual(try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(copy)), copy)
    }

    func testGlobalSensitivityFallbackAndIndividualOverride() {
        let suite = "AOMSensitivityTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gesture = TrackpadGesture.threeFingerSwipeUp
        XCTAssertEqual(GestureSensitivity.velocity(for: gesture, defaults: defaults), 200)
        defaults.set(400, forKey: GestureSensitivity.globalVelocityKey)
        XCTAssertEqual(GestureSensitivity.velocity(for: gesture, defaults: defaults), 400)
        defaults.set(800, forKey: "AOMSwipeMinVelocity_\(gesture.rawValue)")
        XCTAssertEqual(GestureSensitivity.velocity(for: gesture, defaults: defaults), 800)
        defaults.removeObject(forKey: "AOMSwipeMinVelocity_\(gesture.rawValue)")
        XCTAssertEqual(GestureSensitivity.velocity(for: gesture, defaults: defaults), 400)
        defaults.set(Double.infinity, forKey: GestureSensitivity.globalVelocityKey)
        XCTAssertEqual(GestureSensitivity.velocity(for: gesture, defaults: defaults), 200)
    }

    func testVariableChangesNotifyWithoutTouchingAppDefaults() {
        let name = "management_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let before = UserDefaults.standard.dictionary(forKey: "AOMWorkflowVariables") as? [String: String]
        defer { WorkflowVariables.remove(name) }
        let changed = expectation(forNotification: WorkflowVariables.changed, object: nil)
        XCTAssertTrue(WorkflowVariables.set(name, value: "hello"))
        wait(for: [changed], timeout: 2)
        XCTAssertEqual(WorkflowVariables.snapshot()[name], "hello")
        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: "AOMWorkflowVariables") as? [String: String], before)
        XCTAssertFalse(WorkflowVariables.set("bad name", value: "x"))
        WorkflowVariables.remove(name)
        XCTAssertNil(WorkflowVariables.value(name))
    }
}
