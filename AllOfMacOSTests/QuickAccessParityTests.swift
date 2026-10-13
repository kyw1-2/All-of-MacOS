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

    func testStackLayoutKeepsMultipleCardsSeparatedOnSmallScreens() {
        let ordinary = QuickAccessPolicy.stackStride(visibleHeight: 800,
            cardHeight: 200, count: 3)
        XCTAssertEqual(ordinary, 212)
        let constrained = QuickAccessPolicy.stackStride(visibleHeight: 400,
            cardHeight: 230, count: 3)
        XCTAssertEqual(constrained, 65)
        XCTAssertGreaterThan(constrained, 0)
        XCTAssertLessThanOrEqual(constrained * 2 + 230 + 40, 400)
        XCTAssertEqual(QuickAccessPolicy.stackStride(
            visibleHeight: 900, cardHeight: 200, count: 1), 0)
    }

    func testRecentlyClosedRestoresOnlyExistingHistoryIDs() {
        let preserved = UUID()
        let unknown = UUID()
        let restored = QuickAccessPolicy.restoredIDs(
            [unknown.uuidString, preserved.uuidString, "not-a-uuid"],
            present: Set([preserved]))
        XCTAssertEqual(restored, [preserved])
        XCTAssertTrue(QuickAccessPolicy.restoredIDs([], present: []).isEmpty)
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

    func testOptionReversesDragCloseOnlyAfterSuccessfulDrop() {
        let choices: [(OverlayAutoClose, Bool, Bool)] = [
            (.never, false, false),
            (.never, true, true),
            (.afterDrag, false, true),
            (.afterDrag, true, true)
        ]
        for (mode, toggle, baseClose) in choices {
            XCTAssertEqual(QuickAccessPolicy.shouldCloseAfterDrag(
                mode: mode, separateToggle: toggle, succeeded: true,
                optionPressed: false), baseClose)
            XCTAssertEqual(QuickAccessPolicy.shouldCloseAfterDrag(
                mode: mode, separateToggle: toggle, succeeded: true,
                optionPressed: true), !baseClose)
            XCTAssertFalse(QuickAccessPolicy.shouldCloseAfterDrag(
                mode: mode, separateToggle: toggle, succeeded: false,
                optionPressed: true))
        }
    }

    func testOptionReversesSaveDestinationPromptWithoutChangingPreference() {
        XCTAssertFalse(QuickAccessPolicy.shouldPromptSave(
            asksForName: false, optionPressed: false))
        XCTAssertTrue(QuickAccessPolicy.shouldPromptSave(
            asksForName: false, optionPressed: true))
        XCTAssertTrue(QuickAccessPolicy.shouldPromptSave(
            asksForName: true, optionPressed: false))
        XCTAssertFalse(QuickAccessPolicy.shouldPromptSave(
            asksForName: true, optionPressed: true))
    }

    func testSaveBeforeAutoCloseAndTenMinuteIntervalPreferences() {
        let old = CaptureSettings.overlayAutoCloseSave
        let oldSeconds = CaptureSettings.overlayIntervalSeconds
        defer {
            CaptureSettings.overlayAutoCloseSave = old
            CaptureSettings.overlayIntervalSeconds = oldSeconds
        }
        CaptureSettings.overlayAutoCloseSave = true
        XCTAssertTrue(CaptureSettings.overlayAutoCloseSave)
        CaptureSettings.overlayIntervalSeconds = 600
        XCTAssertEqual(CaptureSettings.overlayIntervalSeconds, 600)
        CaptureSettings.overlayIntervalSeconds = 100000
        XCTAssertEqual(CaptureSettings.overlayIntervalSeconds, 600)
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

    func testImportedCapturePreservesExternalImageBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aom-import-\(UUID().uuidString).png")
        let image = try XCTUnwrap(CGContext(data: nil, width: 18, height: 12,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]))
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let previousEnabled = CaptureSettings.overlayEnabled
        let previousCapacity = CaptureSettings.historyCapacity
        CaptureSettings.overlayEnabled = false
        CaptureSettings.historyCapacity = 40
        defer {
            CaptureSettings.overlayEnabled = previousEnabled
            CaptureSettings.historyCapacity = previousCapacity
        }
        CaptureCoordinator.shared.importQuickAccessFiles([url])
        let imported = try XCTUnwrap(CaptureHistory.shared.entries.first(where: {
            $0.fileURL == url
        }))
        XCTAssertEqual(imported.image.width, 18)
        XCTAssertEqual(imported.image.height, 12)
        XCTAssertEqual(try Data(contentsOf: url), data)
        CaptureHistory.shared.remove(imported)
        XCTAssertEqual(try Data(contentsOf: url), data,
                       "History removal must not delete an external original.")
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
