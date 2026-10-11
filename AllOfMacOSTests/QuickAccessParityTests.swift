import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class QuickAccessParityTests: XCTestCase {
    func testQuickAccessKeyboardShortcutsAndDoNotStealOthers() {
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 8, command: true), .copy)
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 1, command: true), .save)
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 14, command: true), .edit)
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 35, command: true), .pin)
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 13, command: true), .close)
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 53, command: false), .close)
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 49, command: false), .quickLook)
        XCTAssertNil(QuickAccessPolicy.shortcut(keyCode: 8, command: false))
        XCTAssertNil(QuickAccessPolicy.shortcut(keyCode: 49, command: true))
    }

    func testThreeOverlayStackDisplacesOldestInOrder() {
        let first = QuickAccessPolicy.visibleAfterAdding([1, 2], new: 3)
        XCTAssertEqual(first.visible, [1, 2, 3])
        XCTAssertTrue(first.displaced.isEmpty)
        let overflow = QuickAccessPolicy.visibleAfterAdding([1, 2, 3], new: 4)
        XCTAssertEqual(overflow.visible, [2, 3, 4])
        XCTAssertEqual(overflow.displaced, [1])
    }

    func testDraggingNeverHidesUntilDropIsSuccessful() {
        XCTAssertFalse(QuickAccessPolicy.shouldCloseAfterDrag(mode: .afterDrag,
                          separateToggle: true, succeeded: false))
        XCTAssertFalse(QuickAccessPolicy.shouldCloseAfterDrag(mode: .never,
                          separateToggle: false, succeeded: true))
        XCTAssertTrue(QuickAccessPolicy.shouldCloseAfterDrag(mode: .never,
                         separateToggle: true, succeeded: true))
        XCTAssertTrue(QuickAccessPolicy.shouldCloseAfterDrag(mode: .afterDrag,
                         separateToggle: false, succeeded: true))
    }

    func testHoverPausesAutoCloseAndIntervalModes() {
        XCTAssertEqual(QuickAccessPolicy.effectiveInterval(mode: .afterInterval,
                       configured: 7, forced: nil), 7)
        XCTAssertNil(QuickAccessPolicy.effectiveInterval(mode: .never,
                     configured: 7, forced: nil))
        XCTAssertEqual(QuickAccessPolicy.effectiveInterval(mode: .never,
                       configured: 3, forced: 10), 10)
        XCTAssertEqual(QuickAccessPolicy.elapsedForAutoClose(4, hovered: true, dragging: false), 0)
        XCTAssertEqual(QuickAccessPolicy.elapsedForAutoClose(4, hovered: false, dragging: true), 0)
        XCTAssertEqual(QuickAccessPolicy.elapsedForAutoClose(4, hovered: false, dragging: false), 4)
    }

    func testSwipeDirectionRespectsChosenScreenCorner() {
        XCTAssertTrue(QuickAccessPolicy.shouldDismissForSwipe(75, predicted: 80, isLeftCorner: false))
        XCTAssertFalse(QuickAccessPolicy.shouldDismissForSwipe(-75, predicted: -80, isLeftCorner: false))
        XCTAssertTrue(QuickAccessPolicy.shouldDismissForSwipe(-75, predicted: -80, isLeftCorner: true))
        XCTAssertFalse(QuickAccessPolicy.shouldDismissForSwipe(75, predicted: 80, isLeftCorner: true))
    }

    func testAllFiveOverlaySizesFitImageWithinCard() {
        XCTAssertEqual(OverlaySize.allCases.count, 5)
        XCTAssertEqual(OverlaySize.extraSmall.displayName, "Extra Small")
        XCTAssertEqual(OverlaySize.extraLarge.displayName, "Extra Large")
        for size in OverlaySize.allCases {
            XCTAssertGreaterThan(size.panelWidth, size.thumbnailSide)
        }
    }

    func testOneXAndFlipAreNondestructive() throws {
        let color = CGColorSpaceCreateDeviceRGB()
        let source = try XCTUnwrap(CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: color,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(NSColor.red.cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        source.setFillColor(NSColor.blue.cgColor)
        source.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        let image = try XCTUnwrap(source.makeImage())

        let scaled = try XCTUnwrap(QuickAccessImageTools.downscaleToOneX(image, pointSize: CGSize(width: 50, height: 25)))
        XCTAssertEqual(scaled.width, 50)
        XCTAssertEqual(scaled.height, 25)
        let flipped = try XCTUnwrap(QuickAccessImageTools.flippedHorizontally(image))
        XCTAssertEqual(flipped.width, 100)
        XCTAssertEqual(flipped.height, 50)
        XCTAssertEqual(image.width, 100, "The original image must be unchanged.")
    }
}
