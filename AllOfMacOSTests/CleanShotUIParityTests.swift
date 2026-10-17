import AppKit
import XCTest
@testable import AllOfMacOS

/// Pure-logic checks for the CleanShot X 4.8.8 UI/UX parity pass
/// (orders, shortcuts, mappings). Reference: CLEANSHOT-UIUX-SPEC.md.
@MainActor
final class CleanShotUIParityTests: XCTestCase {

    // MARK: - Quick Access

    func testQuickAccessContextMenuFollowsCleanShotOrder() {
        let image = QuickAccessMenuCommand.layout(isVideo: false, canScaleRetina: true).compactMap { $0 }
        let cleanShotBlock: [QuickAccessMenuCommand] = [
            .share, .closeAll, .saveAll, .temporarilyHide, .quickLook, .openInFinder,
            .print, .saveAs, .moveToTrash, .openWith,
            .annotate, .pin, .rotateLeft, .flipHorizontal, .scaleRetina, .resize, .extractText,
        ]
        XCTAssertEqual(Array(image.prefix(cleanShotBlock.count)), cleanShotBlock)
        XCTAssertEqual(QuickAccessMenuCommand.annotate.title, "Open Annotation Tool…")
        XCTAssertEqual(QuickAccessMenuCommand.pin.title, "Pin to the Screen")
    }

    func testQuickAccessMenuHidesUnavailableItems() {
        let noRetina = QuickAccessMenuCommand.layout(isVideo: false, canScaleRetina: false).compactMap { $0 }
        XCTAssertFalse(noRetina.contains(.scaleRetina))
        let video = QuickAccessMenuCommand.layout(isVideo: true, canScaleRetina: true).compactMap { $0 }
        for imageOnly in [QuickAccessMenuCommand.annotate, .pin, .rotateLeft, .flipHorizontal,
                          .scaleRetina, .resize, .extractText, .print] {
            XCTAssertFalse(video.contains(imageOnly), "\(imageOnly) must not appear for videos")
        }
        XCTAssertTrue(video.contains(.editVideo))
        // No double or leading separators.
        for layout in [QuickAccessMenuCommand.layout(isVideo: false, canScaleRetina: true),
                       QuickAccessMenuCommand.layout(isVideo: true, canScaleRetina: false)] {
            XCTAssertNotNil(layout.first ?? nil)
            for (a, b) in zip(layout, layout.dropFirst()) { XCTAssertFalse(a == nil && b == nil) }
        }
    }

    func testQuickAccessHoverShortcuts() {
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 8, command: true), .copy)    // ⌘C
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 1, command: true), .save)    // ⌘S
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 13, command: true), .close)  // ⌘W
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 14, command: true), .edit)   // ⌘E
        XCTAssertEqual(QuickAccessPolicy.shortcut(keyCode: 49, command: false), .quickLook) // Space
    }

    func testSwipeTowardScreenEdgeDismissesRegardlessOfNaturalScrolling() {
        // Deltas follow the fingers with natural scrolling and are reversed
        // without it; both must normalise to "fingers moved left" (negative).
        let leftNatural = QuickAccessPolicy.fingerDelta(-80, invertedFromDevice: true)
        let leftClassic = QuickAccessPolicy.fingerDelta(80, invertedFromDevice: false)
        XCTAssertEqual(leftNatural, -80)
        XCTAssertEqual(leftClassic, -80)
        XCTAssertEqual(QuickAccessPolicy.swipeGesture(fingerDX: -80, fingerDY: 0, isLeftCorner: true), .dismiss)
        XCTAssertNil(QuickAccessPolicy.swipeGesture(fingerDX: -80, fingerDY: 0, isLeftCorner: false))
        XCTAssertEqual(QuickAccessPolicy.swipeGesture(fingerDX: 80, fingerDY: 10, isLeftCorner: false), .dismiss)
        XCTAssertNil(QuickAccessPolicy.swipeGesture(fingerDX: 30, fingerDY: 0, isLeftCorner: false),
                     "Small movements must not dismiss")
        XCTAssertEqual(QuickAccessPolicy.swipeGesture(fingerDX: 5, fingerDY: 90, isLeftCorner: true), .hideAll)
        XCTAssertNil(QuickAccessPolicy.swipeGesture(fingerDX: 5, fingerDY: -90, isLeftCorner: true),
                     "Swiping up does nothing")
    }

    func testOverlaySettingsMatchCleanShotChoices() {
        XCTAssertEqual(OverlaySize.allCases.map(\.sliderIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(OverlaySize.fromSliderIndex(1), .small)
        XCTAssertEqual(OverlaySize.fromSliderIndex(-3), .extraSmall)
        XCTAssertEqual(OverlaySize.fromSliderIndex(99), .extraLarge)
        XCTAssertEqual(OverlayAutoCloseInterval.choices, [5, 10, 15, 30, 60, 120, 300, 600])
        XCTAssertEqual(OverlayAutoCloseInterval.label(15), "15 s")
        XCTAssertEqual(OverlayAutoCloseInterval.label(120), "2 min")
        XCTAssertEqual(OverlayCorner.pickerOrder.prefix(2).map(\.positionName), ["Left", "Right"])
        for size in OverlaySize.allCases {
            XCTAssertGreaterThan(size.panelWidth, size.thumbnailSide)
        }
    }

    func testRotateLeftIsCounterClockwise() throws {
        // 2×1: left pixel red, right pixel blue. Rotating left puts the right
        // edge on top, so the 1×2 result has blue on top and red at the bottom.
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let source = try XCTUnwrap(context.makeImage())
        let rotated = try XCTUnwrap(QuickAccessImageTools.rotatedLeft(source))
        XCTAssertEqual(rotated.width, 1)
        XCTAssertEqual(rotated.height, 2)
        let rep = NSBitmapImageRep(cgImage: rotated)
        let top = try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(rep.colorAt(x: 0, y: 1)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.blueComponent, 0.9)
        XCTAssertLessThan(top.redComponent, 0.1)
        XCTAssertGreaterThan(bottom.redComponent, 0.9)
    }

    func testResizeHelpers() throws {
        XCTAssertEqual(QuickAccessImageTools.proportionalSide(100, original: 200, otherOriginal: 50), 25)
        XCTAssertEqual(QuickAccessImageTools.proportionalSide(0, original: 200, otherOriginal: 50), 1)
        let image = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let resized = try XCTUnwrap(QuickAccessImageTools.resized(image, width: 10, height: 5))
        XCTAssertEqual(resized.width, 10)
        XCTAssertEqual(resized.height, 5)
        XCTAssertNil(QuickAccessImageTools.resized(image, width: 0, height: 5))
    }

    func testInPlaceEditDetachesSavedFileInsteadOfOverwriting() throws {
        let image = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let file = URL(fileURLWithPath: "/tmp/aom-never-written-\(UUID()).png")
        let entry = CaptureHistoryEntry(image: image, kind: .area, capturedAt: Date(),
                                        windowTitle: nil, fileURL: file, scale: 2)
        let rotated = try XCTUnwrap(QuickAccessImageTools.rotatedLeft(image))
        CaptureHistory.shared.replaceImage(of: entry, with: rotated, scale: entry.scale)
        XCTAssertNil(entry.fileURL, "The next Save must write a new file")
        XCTAssertEqual(entry.pointSize, CGSize(width: 2, height: 4))
        XCTAssertEqual(entry.thumbnail.size.width < entry.thumbnail.size.height, true)
    }

    func testHistoryIsIsolatedFromTheInstalledApp() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllOfMacOS/CaptureHistory", isDirectory: true)
        XCTAssertNotEqual(CaptureHistory.defaultDirectory.standardizedFileURL, real.standardizedFileURL,
                          "Tests must never touch the user's real capture history")
    }

    // MARK: - Menu bar

    func testStatusMenuFollowsCleanShotOrder() {
        let titles = CaptureMenuCommand.layout.map { $0?.title() ?? "—" }
        XCTAssertEqual(titles, [
            "All-In-One", "Capture Area", "Capture Previous Area", "Capture Fullscreen", "Capture Window",
            "Scrolling Capture", "Self-Timer", "Capture Text (OCR)", "Record Screen",
            "—", "Hide Desktop Icons",
            "—", "Open…", "Open from Clipboard", "Pin to the Screen…",
            "—", "Capture History…",
        ])
        XCTAssertEqual(CaptureMenuCommand.recordScreen.title(isRecording: true), "Stop Recording")
        XCTAssertEqual(CaptureMenuCommand.toggleDesktopIcons.title(desktopIconsVisible: false), "Show Desktop Icons")
    }

    func testStatusMenuShortcutLabelsOnlyWhereTheShortcutDoesThatCommand() {
        XCTAssertEqual(CaptureMenuCommand.allInOne.shortcutAction, .allInOne)
        XCTAssertEqual(CaptureMenuCommand.captureArea.shortcutAction, .captureArea)
        XCTAssertEqual(CaptureMenuCommand.captureHistory.shortcutAction, .history)
        XCTAssertEqual(CaptureMenuCommand.captureText.shortcutAction, .ocr)
        XCTAssertNil(CaptureMenuCommand.captureWindow.shortcutAction,
                     "The window shortcut captures the active window, not interactive selection")
    }

    // MARK: - All-In-One

    func testAllInOneToolbarOrderTooltipsAndKeys() {
        XCTAssertEqual(IntegratedCaptureMode.allCases,
                       [.area, .fullscreen, .window, .scrolling, .timer, .text, .recording])
        XCTAssertEqual(IntegratedCaptureMode.allCases.map(\.tooltip), [
            "Capture Area (A)", "Capture Fullscreen (F)", "Capture Window (Space/W)",
            "Scrolling Capture (S)", "Self-Timer (T)", "Capture Text (O)", "Record Screen (R)",
        ])
        let keys: [String: IntegratedCaptureMode] = ["a": .area, "F": .fullscreen, "w": .window,
                                                     "s": .scrolling, "t": .timer, "o": .text, "r": .recording]
        for (key, mode) in keys { XCTAssertEqual(IntegratedCaptureMode.forKey(key), mode) }
        XCTAssertNil(IntegratedCaptureMode.forKey("x"))
    }

    func testAllInOneSelectionNudgeClampAndResize() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertEqual(AllInOneSelection.nudged(rect, keyCode: 124, large: false, within: bounds)?.minX, 11)
        XCTAssertEqual(AllInOneSelection.nudged(rect, keyCode: 125, large: true, within: bounds)?.minY, 20)
        XCTAssertEqual(AllInOneSelection.nudged(rect, keyCode: 123, large: true, within: bounds)?.minX, 0)
        XCTAssertNil(AllInOneSelection.nudged(rect, keyCode: 0, large: false, within: bounds))
        let resized = AllInOneSelection.resized(rect, pixelWidth: 80, pixelHeight: nil, scale: 2, within: bounds)
        XCTAssertEqual(resized.width, 40)
        XCTAssertEqual(resized.height, 20)
        let clamped = AllInOneSelection.clamped(CGRect(x: 90, y: 90, width: 50, height: 50), within: bounds)
        XCTAssertTrue(bounds.contains(clamped))
    }

    func testCrosshairModes() {
        XCTAssertTrue(CrosshairMode.always.showsCrosshair(commandPressed: false))
        XCTAssertFalse(CrosshairMode.whileCommand.showsCrosshair(commandPressed: false))
        XCTAssertTrue(CrosshairMode.whileCommand.showsCrosshair(commandPressed: true))
        XCTAssertFalse(CrosshairMode.disabled.showsCrosshair(commandPressed: true))
        XCTAssertEqual(SelfTimerInterval.choices, [2, 5, 10, 15])
    }

    // MARK: - Annotate

    func testAnnotateToolOrderAndShortcuts() {
        XCTAssertEqual(Array(AnnotationToolbarItem.segments.prefix(12)), [
            .move, .rectangle, .filledRectangle, .ellipse, .line, .arrow, .text,
            .redact, .spotlight, .counter, .draw, .highlighter,
        ])
        let expected: [Character: AnnotationToolbarItem] = [
            "v": .move, "r": .rectangle, "f": .filledRectangle, "e": .ellipse, "l": .line,
            "a": .arrow, "t": .text, "p": .redact, "h": .spotlight, "c": .counter,
            "d": .draw, "m": .highlighter, "k": .crop, "b": .background,
        ]
        for (key, item) in expected {
            XCTAssertEqual(AnnotationToolbarItem.forShortcut(key), item, "key \(key)")
            XCTAssertEqual(AnnotationToolbarItem.forShortcut(Character(key.uppercased())), item)
        }
        XCTAssertNil(AnnotationToolbarItem.forShortcut("z"))
        let shortcuts = AnnotationToolbarItem.allCases.compactMap(\.shortcut)
        XCTAssertEqual(shortcuts.count, Set(shortcuts).count, "Duplicate tool shortcut")
        // Every toolbar kind is reachable from a toolbar item.
        for kind in AnnotationKind.allCases where kind != .cursor {
            XCTAssertNotNil(AnnotationToolbarItem.item(for: kind), "\(kind) unreachable")
        }
        XCTAssertEqual(AnnotationToolbarItem.redact.kinds, [.pixelate, .blur, .redact])
        XCTAssertEqual(AnnotationRedactionStyle(kind: .redact), .blackOut)
    }

    func testAnnotatePaletteOrder() {
        XCTAssertEqual(AnnotationColor.palette.map(\.displayName),
                       ["Black", "Red", "Orange", "Yellow", "Green", "Turquoise", "Blue", "Purple", "Pink", "White"])
        // Persisted raw values are unchanged by the reorder.
        XCTAssertEqual(AnnotationColor(rawValue: "red"), .red)
        XCTAssertEqual(AnnotationColor(rawValue: "gray"), .gray)
    }

    func testAnnotateClosePrompt() {
        XCTAssertEqual(AnnotationClosePrompt.message,
                       "Do you want to save the changes you made to the screenshot?")
        XCTAssertEqual(AnnotationClosePrompt.buttons, ["Save", "Don't Save", "Cancel"])
        XCTAssertEqual(AnnotationClosePrompt.choice(for: .alertFirstButtonReturn), .save)
        XCTAssertEqual(AnnotationClosePrompt.choice(for: .alertSecondButtonReturn), .dontSave)
        XCTAssertEqual(AnnotationClosePrompt.choice(for: .alertThirdButtonReturn), .cancel)
    }

    // MARK: - Pin

    func testPinnedGeometry() {
        let size = PinnedGeometry.initialSize(pointSize: CGSize(width: 400, height: 200),
                                              visible: CGSize(width: 1440, height: 900))
        XCTAssertEqual(size, CGSize(width: 400, height: 200), "Pins open at 100 %")
        let big = PinnedGeometry.initialSize(pointSize: CGSize(width: 4000, height: 1000),
                                             visible: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(big.width, 700, accuracy: 0.5)
        XCTAssertEqual(PinnedGeometry.zoom(contentWidth: 200, pointWidth: 400), 0.5)
        XCTAssertGreaterThan(PinnedGeometry.zoom(1, scrollDelta: 10, precise: true), 1)
        XCTAssertLessThan(PinnedGeometry.zoom(1, scrollDelta: -10, precise: true), 1)
        XCTAssertEqual(PinnedGeometry.zoom(8, scrollDelta: 100, precise: false), PinnedGeometry.maximumZoom)
        XCTAssertEqual(PinnedGeometry.opacityPresets.first, 1)
    }

    // MARK: - History

    func testHistoryFiltersAndRetentionMapping() {
        XCTAssertEqual(MediaHistoryFilter.primary.map(\.rawValue), ["All", "Screenshots", "Videos"])
        XCTAssertEqual(MediaHistoryRetention.allCases.map(\.title), ["Never", "1 Day", "3 Days", "1 Week", "1 Month"])
        XCTAssertEqual(MediaHistoryRetention.current(capacity: 0, retentionDays: 3), .never)
        XCTAssertEqual(MediaHistoryRetention.current(capacity: 40, retentionDays: 3), .threeDays)
        XCTAssertNil(MediaHistoryRetention.current(capacity: 40, retentionDays: 14))
        XCTAssertEqual(MediaHistoryRetention.never.apply(capacity: 40, retentionDays: 7).capacity, 0)
        let reenabled = MediaHistoryRetention.oneWeek.apply(capacity: 0, retentionDays: 3)
        XCTAssertEqual(reenabled.capacity, 40)
        XCTAssertEqual(reenabled.retentionDays, 7)

        let image = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let scrolling = CaptureHistoryEntry(image: image, kind: .scrolling, capturedAt: Date(),
                                            windowTitle: nil, fileURL: nil)
        let video = CaptureHistoryEntry(image: image, kind: .videoRecording, capturedAt: Date(),
                                        windowTitle: nil, fileURL: nil)
        XCTAssertTrue(MediaHistoryFilter.screenshots.includes(scrolling), "Screenshots covers every image")
        XCTAssertFalse(MediaHistoryFilter.screenshots.includes(video))
        XCTAssertTrue(MediaHistoryFilter.recordings.includes(video))
    }
}
