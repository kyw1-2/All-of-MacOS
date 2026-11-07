import XCTest
@testable import AllOfMacOS

/// The main window must never be raised by a capture or overlay activation.
/// These pin the decision rule; the AppKit call itself needs a window server.
final class OverlayActivationTests: XCTestCase {
    func testHiddenMainWindowIsRestoredAfterActivation() {
        XCTAssertTrue(AOMOverlayActivation.shouldRestoreHiddenMainWindow(wasVisible: false, isVisibleNow: true))
    }

    func testVisibleMainWindowIsAlsoOrderedOut() {
        XCTAssertTrue(AOMOverlayActivation.shouldRestoreHiddenMainWindow(wasVisible: true, isVisibleNow: true))
    }

    func testAlreadyHiddenWindowIsNotTouched() {
        XCTAssertFalse(AOMOverlayActivation.shouldRestoreHiddenMainWindow(wasVisible: false, isVisibleNow: false))
    }

    func testWindowHiddenByActivationNeedsNoRestore() {
        XCTAssertFalse(AOMOverlayActivation.shouldRestoreHiddenMainWindow(wasVisible: true, isVisibleNow: false))
    }

    func testReopenRaisesMainWindowOnlyWhenNothingIsOnScreen() {
        let past = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(AOMOverlayActivation.shouldShowMainWindowOnReopen(hasVisibleWindows: false, overlayVisible: false, suppressUntil: past))
        XCTAssertFalse(AOMOverlayActivation.shouldShowMainWindowOnReopen(hasVisibleWindows: true, overlayVisible: false, suppressUntil: past))
        XCTAssertFalse(AOMOverlayActivation.shouldShowMainWindowOnReopen(hasVisibleWindows: false, overlayVisible: true, suppressUntil: past))
        XCTAssertFalse(AOMOverlayActivation.shouldShowMainWindowOnReopen(hasVisibleWindows: false, overlayVisible: false, suppressUntil: Date().addingTimeInterval(2)))
    }

    /// Idle Mission Control polling is half the old 0.25 s rate; the burst stays
    /// fast so the ✕ buttons still arrive with the reveal animation.
    func testMissionControlPollingCadence() {
        XCTAssertEqual(MissionControlOverlayService.pollInterval(burst: false), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MissionControlOverlayService.pollInterval(burst: true), 0.2, accuracy: 0.0001)
        XCTAssertLessThan(MissionControlOverlayService.pollInterval(burst: true),
                          MissionControlOverlayService.pollInterval(burst: false))
    }
}
