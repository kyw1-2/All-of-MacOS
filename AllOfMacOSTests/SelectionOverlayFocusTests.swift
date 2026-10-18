import XCTest
@testable import AllOfMacOS

/// Deterministic tests for the pure focus-restoration decision used by the
/// selection overlay's cancel path.
///
/// The live activation (`NSWorkspace`/`NSRunningApplication`) needs a real
/// macOS session, so what is pinned here is the policy: restore only when the
/// overlay actually took activation, the user has not switched away, and the
/// previous app is not already frontmost. No GUI behaviour is asserted.
final class SelectionOverlayFocusTests: XCTestCase {

    private typealias Snapshot = SelectionOverlayFocusPolicy.Snapshot
    private let ownPID: pid_t = 999

    func testRestoresWhenOverlayStillHoldsActivation() {
        let previous = Snapshot(processIdentifier: 100, bundleIdentifier: "com.example.textedit")
        let current = Snapshot(processIdentifier: ownPID, bundleIdentifier: "com.kyw.allofmacos")
        XCTAssertTrue(SelectionOverlayFocusPolicy.shouldRestore(
            previous: previous, current: current, ownProcessIdentifier: ownPID))
    }

    func testDoesNotRestoreWhenUserSwitchedToAnotherApp() {
        let previous = Snapshot(processIdentifier: 100, bundleIdentifier: "com.example.textedit")
        let current = Snapshot(processIdentifier: 200, bundleIdentifier: "com.example.other")
        XCTAssertFalse(SelectionOverlayFocusPolicy.shouldRestore(
            previous: previous, current: current, ownProcessIdentifier: ownPID))
    }

    func testDoesNotRestoreWhenAlreadyBackOnPreviousApp() {
        // AppKit (or the user) already reactivated the previous app: activating
        // it again would be the duplicate activation this fix must avoid.
        let previous = Snapshot(processIdentifier: 100, bundleIdentifier: "com.example.textedit")
        XCTAssertFalse(SelectionOverlayFocusPolicy.shouldRestore(
            previous: previous, current: previous, ownProcessIdentifier: ownPID))
    }

    func testDoesNotRestoreWhenNoAppWasDisplaced() {
        XCTAssertFalse(SelectionOverlayFocusPolicy.shouldRestore(
            previous: nil, current: Snapshot(processIdentifier: ownPID, bundleIdentifier: nil),
            ownProcessIdentifier: ownPID))
    }

    func testDoesNotRestoreWhenOverlayWasAlreadyFrontmost() {
        let previous = Snapshot(processIdentifier: ownPID, bundleIdentifier: "com.kyw.allofmacos")
        let current = Snapshot(processIdentifier: ownPID, bundleIdentifier: "com.kyw.allofmacos")
        XCTAssertFalse(SelectionOverlayFocusPolicy.shouldRestore(
            previous: previous, current: current, ownProcessIdentifier: ownPID))
    }

    func testDoesNotRestoreWithoutACurrentFrontmostApp() {
        let previous = Snapshot(processIdentifier: 100, bundleIdentifier: "com.example.textedit")
        XCTAssertFalse(SelectionOverlayFocusPolicy.shouldRestore(
            previous: previous, current: nil, ownProcessIdentifier: ownPID))
    }
}
