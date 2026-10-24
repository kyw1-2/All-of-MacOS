import XCTest
@testable import AllOfMacOS

/// 2.3 behaviour rules for capture surfaces: one-click delete from the card,
/// one close rule for every surface, no double feedback after Copy/Save, a
/// sane auto-close default that never overrides a stored choice, and
/// immediate single-click selection in Capture History.
@MainActor
final class CaptureSurfaceBehaviorTests: XCTestCase {
    func testHoverCurtainHasTrashBesideMore() {
        for isVideo in [false, true] {
            let layout = QuickAccessPolicy.hoverControls(isVideo: isVideo)
            XCTAssertEqual(layout.bottom.suffix(2), [.trash, .more])
            XCTAssertEqual(layout.top.first, .close)
            XCTAssertEqual(layout.center, [.copy, .save])
        }
        XCTAssertEqual(QuickAccessPolicy.hoverControls(isVideo: false).top.last, .pin)
        XCTAssertEqual(QuickAccessPolicy.hoverControls(isVideo: true).top.last, .quickLook)
    }

    func testCommandDeleteTrashesAndOnlyRecordingsConfirm() {
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 51, command: true), .trash)
        XCTAssertNil(QuickAccessPolicy.shortcut(keyCode: 51, command: false))
        XCTAssertTrue(QuickAccessPolicy.confirmsTrash(isVideo: true))
        XCTAssertFalse(QuickAccessPolicy.confirmsTrash(isVideo: false))
    }

    func testOneCloseRuleForEverySurface() {
        XCTAssertTrue(QuickAccessPolicy.closesSurface(afterSucceeded: true, optionPressed: false))
        XCTAssertFalse(QuickAccessPolicy.closesSurface(afterSucceeded: true, optionPressed: true), "⌥ keeps it open")
        XCTAssertFalse(QuickAccessPolicy.closesSurface(afterSucceeded: false, optionPressed: false), "a failure never closes")
    }

    func testAfterCaptureCopyOrSaveShowsNoSecondCard() {
        for action in [AfterCaptureAction.copyToClipboard, .saveToDisk] {
            XCTAssertFalse(QuickAccessPolicy.showsOverlayAfterCapture(action: action, overlayEnabled: true,
                                                                     alsoAfterCopyOrSave: false, actionSucceeded: true))
            XCTAssertTrue(QuickAccessPolicy.showsOverlayAfterCapture(action: action, overlayEnabled: true,
                                                                    alsoAfterCopyOrSave: true, actionSucceeded: true))
            XCTAssertFalse(QuickAccessPolicy.showsOverlayAfterCapture(action: action, overlayEnabled: false,
                                                                     alsoAfterCopyOrSave: true, actionSucceeded: true))
            XCTAssertTrue(QuickAccessPolicy.showsOverlayAfterCapture(action: action, overlayEnabled: false,
                                                                    alsoAfterCopyOrSave: false, actionSucceeded: false),
                          "a failed copy/save still shows the card so the capture is not lost")
        }
        XCTAssertTrue(QuickAccessPolicy.showsOverlayAfterCapture(action: .showOverlay, overlayEnabled: true,
                                                                alsoAfterCopyOrSave: false, actionSucceeded: true))
        XCTAssertFalse(QuickAccessPolicy.showsOverlayAfterCapture(action: .doNothing, overlayEnabled: true,
                                                                 alsoAfterCopyOrSave: true, actionSucceeded: true))
    }

    func testAutoCloseDefaultChangesOnlyForUnsetPreferences() {
        let defaults = UserDefaults.standard
        let modeKey = "AOMCaptureOverlayAutoClose", intervalKey = "AOMCaptureOverlayInterval"
        let savedMode = defaults.object(forKey: modeKey), savedInterval = defaults.object(forKey: intervalKey)
        defer {
            defaults.set(savedMode, forKey: modeKey)
            defaults.set(savedInterval, forKey: intervalKey)
        }
        defaults.removeObject(forKey: modeKey)
        defaults.removeObject(forKey: intervalKey)
        XCTAssertEqual(CaptureSettings.overlayAutoClose, .afterInterval)
        XCTAssertEqual(CaptureSettings.overlayIntervalSeconds, 300)
        // Someone who chose "Never" (or a 5 s delay) keeps exactly that.
        defaults.set(OverlayAutoClose.never.rawValue, forKey: modeKey)
        defaults.set(5, forKey: intervalKey)
        XCTAssertEqual(CaptureSettings.overlayAutoClose, .never)
        XCTAssertEqual(CaptureSettings.overlayIntervalSeconds, 5)
    }

    func testHistorySingleClickDoesNotWaitForDoubleClick() {
        XCTAssertFalse(HistoryClick.isDoubleClick(1))
        XCTAssertFalse(HistoryClick.isDoubleClick(nil))
        XCTAssertTrue(HistoryClick.isDoubleClick(2))
    }

    func testShelfCopyStatusSaysItStaysOpen() {
        XCTAssertTrue(ClipboardPanelState.multiCopyStatus(count: 1).contains("stays open"))
        XCTAssertTrue(ClipboardPanelState.multiCopyStatus(count: 3).hasPrefix("Copied 3 items"))
    }

    func testDragFileIsPrefetchedOffTheMainThreadAndCaptureStaysUnsaved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOMDragTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = CaptureDragFiles(directory: directory)
        let image = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let entry = CaptureHistoryEntry(image: image, kind: .area, capturedAt: Date(), windowTitle: nil, fileURL: nil)
        XCTAssertTrue(CaptureDragFiles.needsDragFile(entry))
        XCTAssertNil(files.readyFile(for: entry))
        files.prefetch(entry)
        for _ in 0..<100 where files.readyFile(for: entry) == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let url = try XCTUnwrap(files.readyFile(for: entry))
        XCTAssertTrue(url.path.hasPrefix(directory.path))
        XCTAssertNil(entry.fileURL, "dragging is not saving")
    }
}
