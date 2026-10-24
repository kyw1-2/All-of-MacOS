import XCTest
@testable import AllOfMacOS

/// Non-trackpad inputs (keyboard shortcuts, mouse buttons, drawing patterns,
/// system triggers) reach Insights and the Workspace's last-run times through
/// ActionExecutor, while the trackpad monitor keeps its own counts and must
/// not be double-counted.
@MainActor
final class StatisticsRecordingTests: XCTestCase {

    /// `record…FromAnyThread` hops through the main actor; drain queued tasks
    /// so assertions see the recorded events.
    private func drainMainActor() {
        let exp = expectation(description: "main actor drained")
        Task { @MainActor in exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    private func counts(for key: String) -> (detected: Int, fired: Int) {
        let events = GestureStatistics.shared.events.filter { $0.gesture == key }
        return (events.filter { !$0.fired }.count, events.filter { $0.fired }.count)
    }

    private func makeKeyboardTrigger() -> Trigger {
        var trigger = Trigger(name: "stats keyboard",
                              input: .keyboardShortcut(KeyboardShortcut(keyCode: 40, modifiers: [.command, .option])))
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        return trigger
    }

    func testNonTrackpadFireRecordsDetectionAndFire() {
        let trigger = makeKeyboardTrigger()
        ActionExecutor.registerTriggers([trigger])
        let before = counts(for: trigger.input.displayName)

        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        drainMainActor()

        let after = counts(for: trigger.input.displayName)
        XCTAssertEqual(after.detected, before.detected + 1)
        XCTAssertEqual(after.fired, before.fired + 1)
        ActionExecutor.registerTriggers([])
    }

    func testTrackpadFireIsNotDoubleCounted() {
        let trigger = makeKeyboardTrigger()
        ActionExecutor.registerTriggers([trigger])
        let before = counts(for: trigger.input.displayName)

        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions, fromTrackpad: true)
        drainMainActor()

        let after = counts(for: trigger.input.displayName)
        XCTAssertEqual(after.detected, before.detected, "the trackpad monitor owns its own statistics")
        XCTAssertEqual(after.fired, before.fired)
        ActionExecutor.registerTriggers([])
    }

    func testUnregisteredTriggerRecordsNothing() {
        let key = "definitely-not-a-recorded-input"
        let before = counts(for: key)

        ActionExecutor.fire(triggerID: UUID(), fallbackActions: [TriggerAction(actionType: .showHUD)])
        drainMainActor()

        let after = counts(for: key)
        XCTAssertEqual(after.detected, before.detected)
        XCTAssertEqual(after.fired, before.fired)
    }
}
