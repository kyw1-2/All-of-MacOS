import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class CraftBehaviorTests: XCTestCase {
    func testDismissBeforeShowAndIgnoreLateClose() throws {
        let coordinator = AOMOverlayCoordinator()
        var events: [String] = []
        var first: AOMOverlayCoordinator.Presentation?
        coordinator.present(.launcher, dismiss: { events.append("hide launcher") }) {
            first = $0
            events.append("show launcher")
        }
        coordinator.present(.clipboardShelf, dismiss: { events.append("hide shelf") }) { _ in events.append("show shelf") }
        coordinator.present(.launcher, dismiss: {}) { _ in events.append("reopen launcher") }
        coordinator.didDismiss(try XCTUnwrap(first))
        XCTAssertEqual(coordinator.activeSurface, .launcher)
        XCTAssertEqual(events, ["show launcher", "hide launcher", "show shelf", "hide shelf", "reopen launcher"])
        coordinator.dismissAll()
        XCTAssertNil(coordinator.activeSurface)
    }

    func testNewRequestDuringDismissWins() {
        let coordinator = AOMOverlayCoordinator()
        coordinator.present(.launcher, dismiss: {
            coordinator.present(.windowSwitcher, dismiss: {}) { _ in }
        }) { _ in }
        coordinator.present(.clipboardShelf, dismiss: {}) { _ in XCTFail("Obsolete request") }
        XCTAssertEqual(coordinator.activeSurface, .windowSwitcher)
    }

    func testDismissAllDuringHandoffCancelsPendingShow() {
        let coordinator = AOMOverlayCoordinator()
        coordinator.present(.menuBarPanel, dismiss: { coordinator.dismissAll() }) { _ in }
        coordinator.present(.dropShelf, dismiss: {}) { _ in XCTFail("Cancelled request") }
        XCTAssertNil(coordinator.activeSurface)
    }

    func testVolumeMappingAndDetent() {
        for level in [0.0, 0.25, 0.5, 1, 2, 3, 4] {
            XCTAssertEqual(AOMVolumeScale.volume(for: AOMVolumeScale.position(for: level)), level, accuracy: 0.000001)
        }
        XCTAssertEqual(AOMVolumeScale.volume(for: 0.61), 1)
        XCTAssertEqual(AOMVolumeScale.clamped(.nan), 0)
        XCTAssertEqual(AOMVolumeScale.clamped(5), 4)
    }

    func testSwatchInkForSaturatedAndNeutralColors() {
        func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        XCTAssertTrue(AOMSwatchContrast.prefersBlack(color(1, 0, 0)))
        XCTAssertFalse(AOMSwatchContrast.prefersBlack(color(0, 0, 1)))
        XCTAssertTrue(AOMSwatchContrast.prefersBlack(color(0.5, 0.5, 0.5)))
    }
}
