import XCTest
@testable import AllOfMacOS

/// 3.3.1, alongside audit 2026-10-28 F09: a denied permission or a partly done batch must
/// not be reported as success. Each case below fails before any event is
/// posted, any window moves or any recording starts.
@MainActor
final class HonestOutcomeTests: XCTestCase {
    private var savedDenied: (() -> Void)?

    override func setUp() {
        super.setUp()
        ActionExecutor.onActionExecuted = nil
        savedDenied = ActionPermissions.screenRecordingDenied
    }

    override func tearDown() {
        ActionPermissions.postEventCheck = { CGPreflightPostEventAccess() }
        ActionPermissions.screenRecordingCheck = { CGPreflightScreenCaptureAccess() }
        if let savedDenied { ActionPermissions.screenRecordingDenied = savedDenied }
        ActionPermissions.resetCache()
        ActionExecutor.onActionExecuted = nil
        super.tearDown()
    }

    private func run(_ type: ActionType, configure: (inout TriggerAction) -> Void = { _ in }) -> Bool? {
        var action = TriggerAction(actionType: type)
        configure(&action)
        let done = expectation(description: type.rawValue)
        var result: Bool?
        ActionExecutor.executeActions([action]) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    func testABatchWithAnyFailureIsAFailure() {
        XCTAssertTrue(ActionOutcome.batch(attempted: 3, failed: 0))
        XCTAssertFalse(ActionOutcome.batch(attempted: 3, failed: 1), "3.3.0 reported success when one of three moved")
        XCTAssertFalse(ActionOutcome.batch(attempted: 0, failed: 0), "nothing done is not success")
    }

    func testPostEventPermissionIsConsultedAndCachedBriefly() {
        var checks = 0
        ActionPermissions.postEventCheck = { checks += 1; return false }
        ActionPermissions.resetCache()
        XCTAssertFalse(ActionPermissions.canPostEvents)
        XCTAssertFalse(ActionPermissions.canPostEvents)
        XCTAssertEqual(checks, 1, "scrolls post many events; one check per second")
        XCTAssertFalse(SyntheticInput.post(nil), "no event is never a success")
    }

    func testRecordingWithoutScreenRecordingPermissionReportsFailure() {
        ActionPermissions.screenRecordingCheck = { false }
        var told = 0
        ActionPermissions.screenRecordingDenied = { told += 1 }
        XCTAssertFalse(ScreenRecordingService.shared.isRecording)
        XCTAssertEqual(run(.recordScreen), false, "3.3.0 reported success before the permission was checked")
        XCTAssertFalse(ScreenRecordingService.shared.isRecording, "and nothing started")
        XCTAssertEqual(told, 1, "the user is told (HUD and system prompt), not just the log")
    }

    func testMovingAWindowToASpaceWithoutPostEventPermissionReportsFailure() {
        ActionPermissions.postEventCheck = { false }
        ActionPermissions.resetCache()
        XCTAssertEqual(run(.moveWindowToNextSpace), false, "the synthetic drag would have been dropped silently")
        XCTAssertEqual(run(.moveWindowToPreviousSpace), false)
    }

    func testForceQuitWithNoMatchingAppIsNotSuccess() {
        // Reaches the legacy switch, whose blanket completion(true) 3.3.0 had.
        XCTAssertEqual(run(.forceQuitApplication) {
            $0.parameters.applicationName = "com.example.aom-audit-not-running-\(UUID().uuidString)"
            $0.parameters.requiresConfirmation = false
        }, false)
    }
}
