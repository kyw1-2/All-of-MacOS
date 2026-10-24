import XCTest
import AppKit
import CoreGraphics
@testable import AllOfMacOS

/// Tests for the capture feature.
///
/// The capture itself needs Screen Recording permission and a real display, so
/// it cannot run in the test host. What is tested here is everything that does
/// not: the action model wiring, the settings round-trip, the annotation
/// document's geometry and history, the scrolling stitcher's offset search, and
/// the OCR line assembly. Those are the parts where a mistake is silent.
final class ScreenCaptureTests: XCTestCase {

    // MARK: - Action model

    func testCaptureActionsBelongToTheCaptureCategory() {
        for type in ActionType.allCases where ActionType.describeCaptureAction(type) != type.rawValue {
            XCTAssertEqual(type.category, .screenCapture, "\(type.rawValue) should be a capture action")
        }
    }

    func testEveryCaptureActionHasAnIcon() {
        let captures = ActionType.allCases.filter { $0.category == .screenCapture }
        XCTAssertFalse(captures.isEmpty)
        for type in captures {
            XCTAssertFalse(type.iconName.isEmpty, "\(type.rawValue) has no icon")
        }
    }

    func testCaptureActionsAreListedUnderTheirCategory() {
        let listed = ActionType.actionsForCategory(.screenCapture)
        XCTAssertTrue(listed.contains(.captureArea))
        XCTAssertTrue(listed.contains(.captureText))
        XCTAssertTrue(listed.contains(.annotateLastCapture))
        // A capture action must not also appear in another category.
        for type in listed {
            XCTAssertEqual(type.category, .screenCapture)
        }
    }

    /// A preset written before the capture actions existed must still decode.
    func testNewCaptureParametersDecodeToNilFromAnOldPreset() throws {
        let old = try JSONDecoder().decode(ActionParameters.self, from: Data("{}".utf8))
        XCTAssertNil(old.selfTimerSeconds)
        XCTAssertNil(old.ocrKeepsLineBreaks)
    }

    func testCaptureParametersRoundTrip() throws {
        var action = TriggerAction(actionType: .captureSelfTimer)
        action.parameters.selfTimerSeconds = 7
        let decoded = try JSONDecoder().decode(TriggerAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(decoded, action)
        XCTAssertEqual(decoded.parameters.selfTimerSeconds, 7)
    }

    // MARK: - Settings

    func testCaptureSettingsRoundTripThroughUserDefaults() {
        let previousFormat = CaptureSettings.format
        let previousQuality = CaptureSettings.quality
        let previousTimer = CaptureSettings.selfTimerSeconds
        defer {
            CaptureSettings.format = previousFormat
            CaptureSettings.quality = previousQuality
            CaptureSettings.selfTimerSeconds = previousTimer
        }

        CaptureSettings.format = .heic
        XCTAssertEqual(CaptureSettings.format, .heic)
        XCTAssertEqual(CaptureSettings.format.fileExtension, "heic")
        XCTAssertTrue(CaptureSettings.format.isLossy)

        CaptureSettings.format = .png
        XCTAssertFalse(CaptureSettings.format.isLossy)
        XCTAssertEqual(CaptureSettings.format.fileExtension, "png")

        // Quality is clamped rather than accepted verbatim, so a bad value from
        // a hand-edited plist cannot produce an unencodable image.
        CaptureSettings.quality = 4.0
        XCTAssertEqual(CaptureSettings.quality, 1.0)
        CaptureSettings.quality = -1
        XCTAssertEqual(CaptureSettings.quality, 0.1)

        CaptureSettings.selfTimerSeconds = 999
        XCTAssertEqual(CaptureSettings.selfTimerSeconds, 60)
        CaptureSettings.selfTimerSeconds = -5
        XCTAssertEqual(CaptureSettings.selfTimerSeconds, 0)
    }

    func testLastAreaRoundTripsAndRejectsCorruptValues() {
        let previous = CaptureSettings.lastArea
        defer { CaptureSettings.lastArea = previous }

        let rect = CGRect(x: 100, y: 200, width: 640, height: 480)
        CaptureSettings.lastArea = rect
        XCTAssertEqual(CaptureSettings.lastArea, rect)

        CaptureSettings.lastArea = nil
        XCTAssertNil(CaptureSettings.lastArea)

        // A malformed string must read back as "no previous area" rather than
        // throwing or producing a nonsense rect.
        UserDefaults.standard.set("not,a,rect", forKey: "AOMCaptureLastArea")
        XCTAssertNil(CaptureSettings.lastArea)
        UserDefaults.standard.set("1,2,3", forKey: "AOMCaptureLastArea")
        XCTAssertNil(CaptureSettings.lastArea)
        UserDefaults.standard.set("1,2,0,50", forKey: "AOMCaptureLastArea")
        XCTAssertNil(CaptureSettings.lastArea, "a zero-width area is not a usable previous area")
    }

    func testOverlayGeometryHelpers() {
        XCTAssertTrue(OverlayCorner.topLeft.isLeft)
        XCTAssertTrue(OverlayCorner.topLeft.isTop)
        XCTAssertFalse(OverlayCorner.bottomRight.isLeft)
        XCTAssertFalse(OverlayCorner.bottomRight.isTop)
        // The panel has to be wide enough for the thumbnail plus its padding.
        for size in OverlaySize.allCases {
            XCTAssertGreaterThan(size.panelWidth, size.thumbnailSide)
        }
    }

    func testCaptureFilenameTemplatesAreSafeAndDeterministic() {
        let epoch = Date(timeIntervalSince1970: 0)
        let name = CaptureNaming.templateName(
            "{prefix}-{date}-{time}-{kind}-{width}x{height}",
            date: epoch, kind: "Area", windowTitle: nil,
            width: 640, height: 480, utc: true)
        XCTAssertEqual(name, "Screenshot-1970-01-01-00.00.00-Area-640x480")
        let attemptedTraversal = CaptureNaming.templateName(
            "../../{window}/../../{kind}", date: epoch, kind: "Window",
            windowTitle: "/private/secret", width: 2, height: 2, utc: true)
        XCTAssertFalse(attemptedTraversal.contains("/"))
        XCTAssertFalse(attemptedTraversal.hasPrefix("."))
        XCTAssertFalse(attemptedTraversal.contains(":"))
        XCTAssertTrue(attemptedTraversal.count <= 120)
        XCTAssertEqual(CaptureNaming.templateName(" .. / ", date: epoch, kind: "",
                                                  windowTitle: nil, width: 1, height: 1,
                                                  utc: true), "")
    }

    func testAOMCaptureDeepLinksAreExplicitAndCollisionSafe() {
        func parsed(_ value: String) -> AOMCaptureDeepLink? {
            guard let url = URL(string: value) else { return nil }
            return AOMCaptureDeepLink.parse(url)
        }
        XCTAssertEqual(parsed("aom://all-in-one"), .allInOne)
        XCTAssertEqual(parsed("aom://capture-area"), .captureArea)
        XCTAssertEqual(parsed("aom://capture-fullscreen"), .captureFullscreen)
        XCTAssertEqual(parsed("aom://capture-window"), .captureWindow)
        XCTAssertEqual(parsed("aom://capture-previous-area"), .previousArea)
        XCTAssertEqual(parsed("aom://scrolling-capture"), .scrollingCapture)
        XCTAssertEqual(parsed("aom://self-timer"), .selfTimer)
        XCTAssertEqual(parsed("aom://record-screen"), .recordScreen)
        XCTAssertEqual(parsed("aom://capture-text"), .captureText(keepsLineBreaks: true))
        XCTAssertEqual(parsed("aom://capture-text?linebreaks=false"), .captureText(keepsLineBreaks: false))
        XCTAssertEqual(parsed("aom://open-history"), .openHistory)
        XCTAssertEqual(parsed("aom://open-settings"), .openSettings)
        XCTAssertEqual(parsed("aom://restore-recently-closed"), .restoreRecentlyClosed)
        XCTAssertEqual(parsed("aom://pin"), .pin)
        XCTAssertEqual(parsed("aom://open-annotate"), .openAnnotate)
        XCTAssertEqual(parsed("aom://open-from-clipboard"), .openFromClipboard)
        XCTAssertEqual(parsed("aom://add-quick-access-overlay?filepath=%2Ftmp%2Fclip.png"),
                       .addQuickAccessOverlay(URL(fileURLWithPath: "/tmp/clip.png")))

        // Never claim or intercept the reference application's URLs.
        XCTAssertNil(parsed("cleanshot://capture-area"))
        XCTAssertNil(parsed("https://capture-area"))
        XCTAssertNil(parsed("aom://capture-area?filepath=%2Fetc%2Fpasswd"))
        XCTAssertNil(parsed("aom://capture-text?linebreaks=garbage"))
        XCTAssertNil(parsed("aom://capture-text?linebreaks=true&linebreaks=false"))
        XCTAssertNil(parsed("aom://add-quick-access-overlay?filepath=https%3A%2F%2Fexample.com%2Ftest.png"))
        XCTAssertNil(parsed("aom://add-quick-access-overlay?filepath=%2Ftmp%2Ffile.exe"))
        XCTAssertNil(parsed("aom://capture-area/extra"))
        XCTAssertNil(parsed("aom://unknown-action"))
    }

    // MARK: - Annotation document

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @MainActor
    func testCaptureHistoryDeleteSelectionLeavesRecordingFileUntouched() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aom-delete-\(UUID().uuidString).mp4")
        try Data("example".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = CaptureResult(image: makeImage(width: 32, height: 24),
                                   globalRect: CGRect(x: 0, y: 0, width: 32, height: 24),
                                   scale: 1, kind: .videoRecording)
        let entry = CaptureHistory.shared.add(result, url: url)
        XCTAssertTrue(CaptureHistory.shared.entries.contains { $0.id == entry.id })
        CaptureHistory.shared.remove(entry)
        XCTAssertFalse(CaptureHistory.shared.entries.contains { $0.id == entry.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Removing a history card must never delete a saved MP4")
    }

    @MainActor
    func testHistoryBackspaceAndForwardDeleteKeyCodes() {
        XCTAssertTrue(MediaHistoryOverlayController.isDeleteKey(51))
        XCTAssertTrue(MediaHistoryOverlayController.isDeleteKey(117))
        XCTAssertFalse(MediaHistoryOverlayController.isDeleteKey(53))
        XCTAssertFalse(MediaHistoryOverlayController.isDeleteKey(49))
    }

    func testRecordingHistoryUsesMP4FileAndNeverItsThumbnail() throws {
        let movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("aom-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: movieURL) }
        try Data([0, 0, 0, 20]).write(to: movieURL)
        let previewFrame = makeImage(width: 32, height: 24)
        let video = CaptureHistoryEntry(image: previewFrame, kind: .videoRecording,
                                        capturedAt: Date(), windowTitle: nil, fileURL: movieURL)
        XCTAssertEqual(video.playableVideoURL, movieURL)
        let screenshot = CaptureHistoryEntry(image: previewFrame, kind: .area,
                                             capturedAt: Date(), windowTitle: nil, fileURL: movieURL)
        XCTAssertNil(screenshot.playableVideoURL, "A still image must not open as a movie")
        try FileManager.default.removeItem(at: movieURL)
        XCTAssertNil(video.playableVideoURL, "Missing video should not be disguised as a PNG")
    }

    func testAnnotationAddRemoveAndReorder() {
        var document = AnnotationDocument(baseImage: makeImage(width: 400, height: 300))
        let first = AnnotationObject(kind: .rectangle, rect: CGRect(x: 10, y: 10, width: 50, height: 50))
        let second = AnnotationObject(kind: .ellipse, rect: CGRect(x: 20, y: 20, width: 50, height: 50))
        document.add(first)
        document.add(second)
        XCTAssertEqual(document.objects.map(\.id), [first.id, second.id])

        document.reorder(second.id, offset: -1)
        XCTAssertEqual(document.objects.map(\.id), [second.id, first.id])

        // Reordering past the ends must be a no-op, not a crash.
        document.reorder(second.id, offset: -1)
        XCTAssertEqual(document.objects.map(\.id), [second.id, first.id])

        document.remove(first.id)
        XCTAssertEqual(document.objects.map(\.id), [second.id])
    }

    func testAnnotationUndoAndRedoRestoreEveryStep() {
        var document = AnnotationDocument(baseImage: makeImage(width: 200, height: 200))
        let object = AnnotationObject(kind: .rectangle, rect: CGRect(x: 5, y: 5, width: 40, height: 40))
        XCTAssertFalse(document.canUndo)

        document.add(object)
        XCTAssertTrue(document.canUndo)
        XCTAssertFalse(document.canRedo)
        XCTAssertEqual(document.objects.count, 1)

        document.undo()
        XCTAssertTrue(document.objects.isEmpty)
        XCTAssertTrue(document.canRedo)

        document.redo()
        XCTAssertEqual(document.objects.count, 1)
        XCTAssertFalse(document.canRedo)
    }

    /// A new edit after an undo must discard the redo branch, which is what every
    /// editor does and what stops a redo from resurrecting a stale object.
    func testNewEditAfterUndoClearsTheRedoBranch() {
        var document = AnnotationDocument(baseImage: makeImage(width: 200, height: 200))
        document.add(AnnotationObject(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        document.undo()
        XCTAssertTrue(document.canRedo)
        document.add(AnnotationObject(kind: .ellipse, rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertFalse(document.canRedo)
    }

    func testUndoAlsoRestoresTheCrop() {
        var document = AnnotationDocument(baseImage: makeImage(width: 400, height: 400))
        XCTAssertNil(document.cropRect)
        document.setCrop(CGRect(x: 10, y: 10, width: 100, height: 100))
        XCTAssertEqual(document.cropRect, CGRect(x: 10, y: 10, width: 100, height: 100))
        document.undo()
        XCTAssertNil(document.cropRect)
    }

    func testRenderProducesAnImageOfTheDocumentSize() throws {
        var document = AnnotationDocument(baseImage: makeImage(width: 320, height: 240))
        document.add(AnnotationObject(kind: .rectangle, rect: CGRect(x: 10, y: 10, width: 60, height: 40),
                                      style: AnnotationStyle()))
        let rendered = try XCTUnwrap(document.render(scale: 1))
        XCTAssertEqual(rendered.width, 320)
        XCTAssertEqual(rendered.height, 240)
    }

    func testRenderGrowsWithBackgroundPadding() throws {
        var document = AnnotationDocument(baseImage: makeImage(width: 200, height: 100))
        document.background.padding = 20
        document.background.kind = .solid
        let rendered = try XCTUnwrap(document.render(scale: 1))
        XCTAssertEqual(rendered.width, 240)
        XCTAssertEqual(rendered.height, 140)
    }

    func testCropIsClampedToTheImage() throws {
        var document = AnnotationDocument(baseImage: makeImage(width: 100, height: 100))
        // A crop larger than the image, and one starting outside it.
        document.setCrop(CGRect(x: -50, y: -50, width: 500, height: 500))
        let cropped = document.croppedImage
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 100)
    }

    func testEveryAnnotationKindHasADisplayNameAndIcon() {
        for kind in AnnotationKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind.rawValue) has no display name")
            XCTAssertFalse(kind.iconName.isEmpty, "\(kind.rawValue) has no icon")
        }
    }

    func testToolbarCoversEveryTool() {
        XCTAssertEqual(Set(AnnotationKind.toolbarOrder), Set(AnnotationKind.allCases))
    }

    func testShapeAndFreehandClassification() {
        XCTAssertTrue(AnnotationKind.rectangle.isShape)
        XCTAssertTrue(AnnotationKind.highlighter.isShape, "the highlighter is dragged out like a shape")
        XCTAssertFalse(AnnotationKind.text.isShape)
        XCTAssertFalse(AnnotationKind.crop.isShape)
        XCTAssertTrue(AnnotationKind.draw.isFreehand)
        XCTAssertTrue(AnnotationKind.drawHighlight.isFreehand)
        XCTAssertFalse(AnnotationKind.rectangle.isFreehand)
    }

    func testEveryAnnotationColourHasADistinctValue() {
        let colors = AnnotationColor.allCases.map { $0.nsColor }
        for (index, color) in colors.enumerated() {
            XCTAssertNotNil(color.usingColorSpace(.sRGB))
            for other in colors[(index + 1)...] {
                XCTAssertNotEqual(color, other, "two preset colours are identical")
            }
        }
    }

    // MARK: - Scrolling capture stitching

    /// A vertical shift between two frames must be recovered exactly.
    func testVerticalShiftFindsTheScrollOffset() throws {
        let width = 40, height = 200
        // The matcher downsamples to a bounded width, so a 40px-wide image is
        // sampled 1:1 and the recovered offset is in real pixels.
        let source = try XCTUnwrap(makeGradientImage(width: width, height: height, offset: 0))
        let shifted = try XCTUnwrap(makeGradientImage(width: width, height: height, offset: 30))
        let found = try XCTUnwrap(ScrollingCaptureService.verticalShift(from: source, to: shifted))
        XCTAssertEqual(found, 30, "the exact scroll offset should be recovered")
    }

    func testVerticalShiftRecoversDifferentOffsets() throws {
        for offset in [8, 17, 45, 90] {
            let source = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 0))
            let shifted = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: offset))
            let found = try XCTUnwrap(ScrollingCaptureService.verticalShift(from: source, to: shifted),
                                      "no offset found for a \(offset) row scroll")
            XCTAssertEqual(found, CGFloat(offset))
        }
    }

    func testThreeFrameScrollStitchUsesLatestViewportInsteadOfAccumulatedHeight() throws {
        let first = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 0))
        let second = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 30))
        let third = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 60))
        let combined1 = try XCTUnwrap(ScrollingCaptureService.appendFrame(second, after: first, to: first))
        XCTAssertEqual(combined1.shift, 30)
        XCTAssertEqual(combined1.image.height, 230)
        let combined2 = try XCTUnwrap(ScrollingCaptureService.appendFrame(
            third, after: second, to: combined1.image))
        XCTAssertEqual(combined2.shift, 30)
        XCTAssertEqual(combined2.image.height, 260)
        XCTAssertEqual(try XCTUnwrap(rowValues(combined2.image, row: 0)), 0)
        XCTAssertEqual(try XCTUnwrap(rowValues(combined2.image, row: 259)), 3)
    }

    func testRetinaScrollMatchConvertsDownsampledShiftBackToSourcePixels() throws {
        let first = try XCTUnwrap(makeGradientImage(width: 640, height: 400, offset: 0))
        let second = try XCTUnwrap(makeGradientImage(width: 640, height: 400, offset: 80))
        let delta = try XCTUnwrap(ScrollingCaptureService.verticalShift(from: first, to: second))
        XCTAssertEqual(delta, 80, accuracy: 5,
                       "The overlap detector must report source-image pixels, not 160px analysis pixels.")
        let combined = try XCTUnwrap(ScrollingCaptureService.appendFrame(second, after: first, to: first))
        XCTAssertEqual(combined.image.height, 400 + combined.shift)
    }

    func testHorizontalScrollStitchesThreeViewports() throws {
        let first = try XCTUnwrap(makeColumnGradientImage(width: 80, height: 40, offset: 0))
        let next = try XCTUnwrap(makeColumnGradientImage(width: 80, height: 40, offset: 12))
        let third = try XCTUnwrap(makeColumnGradientImage(width: 80, height: 40, offset: 24))
        let one = try XCTUnwrap(ScrollingCaptureService.appendFrame(
            next, after: first, to: first, direction: .horizontal))
        XCTAssertEqual(one.shift, 12)
        XCTAssertEqual(one.image.width, 92)
        let two = try XCTUnwrap(ScrollingCaptureService.appendFrame(
            third, after: next, to: one.image, direction: .horizontal))
        XCTAssertEqual(two.shift, 12)
        XCTAssertEqual(two.image.width, 104)
        XCTAssertEqual(two.image.height, 40)
    }

    func testHorizontalShiftAtRetinaWidthReportsSourcePixels() throws {
        let current = try XCTUnwrap(makeColumnGradientImage(width: 640, height: 240, offset: 0))
        let next = try XCTUnwrap(makeColumnGradientImage(width: 640, height: 240, offset: 80))
        let shift = try XCTUnwrap(ScrollingCaptureService.horizontalShift(from: current, to: next))
        XCTAssertEqual(shift, 80, accuracy: 5)
    }

    func testVerticalShiftIsNilForUnrelatedFrames() throws {
        let a = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 0))
        // Noise rather than a shifted copy: no offset should match confidently.
        let b = try XCTUnwrap(makeNoiseImage(width: 40, height: 200))
        XCTAssertNil(ScrollingCaptureService.verticalShift(from: a, to: b))
    }

    func testVerticalShiftRejectsMismatchedSizes() throws {
        let a = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 0))
        let b = try XCTUnwrap(makeGradientImage(width: 80, height: 200, offset: 0))
        XCTAssertNil(ScrollingCaptureService.verticalShift(from: a, to: b))
    }

    func testAppendGrowsTheImageByTheNewlyRevealedRows() throws {
        let current = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 0))
        let next = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 30))
        let stitched = try XCTUnwrap(ScrollingCaptureService.append(next, to: current, shift: 30))
        XCTAssertEqual(stitched.width, 40)
        // Scrolling down by 30 rows reveals exactly 30 new rows, so the image
        // grows by the shift — not by the whole remaining height.
        XCTAssertEqual(stitched.height, 230)
    }

    /// The stitched image must actually be taller content, not a stretched copy:
    /// the last row of the result should carry the last row of the new frame.
    func testAppendKeepsTheNewlyRevealedContent() throws {
        let current = try XCTUnwrap(makeGradientImage(width: 8, height: 100, offset: 0))
        let next = try XCTUnwrap(makeGradientImage(width: 8, height: 100, offset: 20))
        let stitched = try XCTUnwrap(ScrollingCaptureService.append(next, to: current, shift: 20))
        XCTAssertEqual(stitched.height, 120)

        let topRow = try XCTUnwrap(rowValues(stitched, row: 0))
        let bottomRow = try XCTUnwrap(rowValues(stitched, row: 119))
        // Row 0 is the original top; the bottom is the newly revealed row 119 of
        // the scrolled content, which is grey 119 on this ramp.
        XCTAssertEqual(topRow, 0)
        XCTAssertEqual(bottomRow, 119)
    }

    /// Reads one row's first pixel as a luminance value, in top-down order.
    private func rowValues(_ image: CGImage, row: Int) -> Int? {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard row >= 0, row < height else { return nil }
        return Int(buffer[row * width])
    }

    func testAppendIgnoresANonPositiveShift() throws {
        let current = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 0))
        let next = try XCTUnwrap(makeGradientImage(width: 40, height: 200, offset: 0))
        // A zero shift means nothing new was revealed, so the image is unchanged.
        XCTAssertEqual(ScrollingCaptureService.append(next, to: current, shift: 0)?.height, 200)
    }

    /// A gradient whose rows are distinct, so a shifted copy has exactly one
    /// matching offset.
    ///
    /// The fill is drawn at `height - 1 - row` because a `CGContext` bitmap is
    /// bottom-up while the stitcher's row order is top-down: drawing at `row`
    /// directly would build the image upside down and the offset search would
    /// find nothing. That mistake is what this fixture originally did.
    private func makeGradientImage(width: Int, height: Int, offset: Int) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let context else { return nil }
        for row in 0..<height {
            let value = CGFloat((row + offset) % 256) / 255
            context.setFillColor(NSColor(srgbRed: value, green: value, blue: value, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: height - 1 - row, width: width, height: 1))
        }
        return context.makeImage()
    }

    private func makeColumnGradientImage(width: Int, height: Int, offset: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        for column in 0..<width {
            let value = CGFloat((column + offset) % 256) / 255
            context.setFillColor(NSColor(srgbRed: value, green: value, blue: value, alpha: 1).cgColor)
            context.fill(CGRect(x: column, y: 0, width: 1, height: height))
        }
        return context.makeImage()
    }

    private func makeNoiseImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let context else { return nil }
        var generator = SystemRandomNumberGenerator()
        for row in 0..<height {
            let value = CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255
            context.setFillColor(NSColor(srgbRed: value, green: value, blue: value, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        return context.makeImage()
    }

    // MARK: - Naming

    func testCaptureFileNamesAreTimestampedAndUnique() {
        let image = makeImage(width: 10, height: 10)
        let first = CaptureResult(image: image, globalRect: .zero, scale: 1, kind: .area,
                                  capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = CaptureResult(image: image, globalRect: .zero, scale: 1, kind: .area,
                                   capturedAt: Date(timeIntervalSince1970: 1_700_000_001))
        let a = CaptureNaming.defaultName(for: first)
        let b = CaptureNaming.defaultName(for: second)
        XCTAssertTrue(a.hasPrefix("Screenshot "))
        XCTAssertNotEqual(a, b, "two captures a second apart must not collide")
    }

    func testWindowCaptureNameIncludesTheWindowTitle() {
        let image = makeImage(width: 10, height: 10)
        let result = CaptureResult(image: image, globalRect: .zero, scale: 1, kind: .window,
                                   windowTitle: "Report.rtf — Pages", capturedAt: Date())
        let name = CaptureNaming.defaultName(for: result)
        XCTAssertTrue(name.contains("Report"), "got \(name)")
    }

    // MARK: - Encoding

    func testEveryFormatEncodes() throws {
        let image = makeImage(width: 60, height: 40)
        let result = CaptureResult(image: image, globalRect: .zero, scale: 1, kind: .area)
        for format in CaptureFormat.allCases {
            let data = try ScreenCaptureService.shared.encode(result, format: format, quality: 0.8)
            XCTAssertFalse(data.isEmpty, "\(format.displayName) produced no data")
            // A recognisable header proves the encoder honoured the format rather
            // than silently falling back to one of the others.
            let header = [UInt8](data.prefix(12))
            switch format {
            case .png:
                XCTAssertEqual(Array(header.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
            case .jpeg:
                XCTAssertEqual(Array(header.prefix(2)), [0xFF, 0xD8])
            case .tiff:
                XCTAssertTrue(Array(header.prefix(2)) == [0x49, 0x49] || Array(header.prefix(2)) == [0x4D, 0x4D])
            case .webp:
                XCTAssertEqual(String(decoding: header.prefix(4), as: UTF8.self), "RIFF")
                XCTAssertEqual(String(decoding: header[8..<12], as: UTF8.self), "WEBP")
            case .heic:
                // ftyp box, with the brand at bytes 8…11.
                XCTAssertEqual(String(decoding: header[4..<8], as: UTF8.self), "ftyp")
            }
        }
    }

    func testWriteToDiskDoesNotOverwriteAnExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aom-capture-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let image = makeImage(width: 20, height: 20)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let result = CaptureResult(image: image, globalRect: .zero, scale: 1, kind: .area, capturedAt: stamp)

        let first = try ScreenCaptureService.shared.writeToDisk(result, directory: directory, format: .png)
        let second = try ScreenCaptureService.shared.writeToDisk(result, directory: directory, format: .png)
        XCTAssertNotEqual(first, second, "the second write must not clobber the first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    /// F-04D: the Save As helper encodes the requested format at a caller-chosen
    /// URL, replaces an existing file (the panel already confirmed overwrite),
    /// and surfaces a write failure instead of reporting a false success.
    func testWriteToURLAsyncHonoursFormatOverwritesAndThrows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aom-capture-url-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let image = makeImage(width: 20, height: 20)
        let result = CaptureResult(image: image, globalRect: .zero, scale: 1, kind: .area)
        let destination = directory.appendingPathComponent("chosen.png")

        // Stale bytes at the panel's URL must be replaced by the encoded image.
        try Data("stale".utf8).write(to: destination)
        try await ScreenCaptureService.shared.writeToURLAsync(result, to: destination, format: .png)

        let data = try Data(contentsOf: destination)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47],
                       "the helper must encode the requested format at the caller's URL")

        // A destination under a missing directory must throw to the caller.
        let missing = directory.appendingPathComponent("missing").appendingPathComponent("out.jpg")
        do {
            try await ScreenCaptureService.shared.writeToURLAsync(result, to: missing, format: .jpeg)
            XCTFail("writing under a missing directory must throw")
        } catch {
            // expected: the encode/write failure reaches the awaiting save path
        }
    }

    // MARK: - History

    @MainActor
    func testHistoryIsBoundedByTheConfiguredCapacity() {
        let previous = CaptureSettings.historyCapacity
        defer {
            CaptureSettings.historyCapacity = previous
            CaptureHistory.shared.removeAll()
        }
        CaptureSettings.historyCapacity = 3
        CaptureHistory.shared.removeAll()

        let image = makeImage(width: 8, height: 8)
        // Recent timestamps: 1970 dates would be removed by the age limit
        // (default 30 days) before the count limit is even exercised.
        let base = Date().addingTimeInterval(-60)
        for index in 0..<6 {
            let result = CaptureResult(image: image, globalRect: .zero, scale: 1, kind: .area,
                                       capturedAt: base.addingTimeInterval(TimeInterval(index)))
            CaptureHistory.shared.add(result, url: nil)
        }
        XCTAssertEqual(CaptureHistory.shared.entries.count, 3)
        // Newest first, so the most recent capture is the one the "Last Capture"
        // actions operate on.
        XCTAssertEqual(CaptureHistory.shared.entries.first?.capturedAt,
                       base.addingTimeInterval(5))
    }

    @MainActor
    func testZeroCapacityDisablesHistory() {
        let previous = CaptureSettings.historyCapacity
        defer {
            CaptureSettings.historyCapacity = previous
            CaptureHistory.shared.removeAll()
        }
        CaptureSettings.historyCapacity = 0
        CaptureHistory.shared.removeAll()
        let image = makeImage(width: 8, height: 8)
        CaptureHistory.shared.add(CaptureResult(image: image, globalRect: .zero, scale: 1, kind: .area), url: nil)
        XCTAssertTrue(CaptureHistory.shared.entries.isEmpty)
        XCTAssertNil(CaptureHistory.shared.mostRecent)
    }

    // MARK: - Capture kinds

    func testEveryCaptureKindHasADisplayName() {
        let kinds: [CaptureKind] = [.fullscreen, .area, .window, .windowUnderCursor,
                                    .previousArea, .scrolling, .selection]
        for kind in kinds {
            XCTAssertFalse(kind.displayName.isEmpty)
        }
    }

    // MARK: - Capture Shortcuts

    @MainActor
    func testCaptureShortcutsDefaultsMatchCleanShotX() {
        let suite = "AOMCaptureShortcuts-Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = CaptureShortcuts(defaults: defaults)
        shortcuts.resetToDefaults()

        XCTAssertTrue(shortcuts.hasActiveShortcuts)
        for action in CaptureShortcutAction.allCases {
            let sc = shortcuts.shortcut(for: action)
            // The window-pin commands are optional like All-In-One: new installs
            // must not reserve five more global shortcuts without asking.
            if action == .allInOne || action == .openProject || action == .choosePinnedWindow
                || action == .selectPinnedWindow || action == .togglePinFrontWindow
                || action == .togglePinWindowUnderCursor || action == .unpinAllWindows {
                XCTAssertNil(sc, "Optional commands must not reserve a default global shortcut")
            } else {
                XCTAssertNotNil(sc, "\(action.displayName) should have a default shortcut")
            }
        }

        // Verify specific key combinations:
        // Area = ⇧⌘4 (keyCode 21)
        XCTAssertEqual(shortcuts.shortcut(for: .captureArea)?.keyCode, 21)
        XCTAssertEqual(shortcuts.shortcut(for: .captureArea)?.modifiers, [.command, .shift])

        // Fullscreen = ⇧⌘3 (keyCode 20)
        XCTAssertEqual(shortcuts.shortcut(for: .captureFullscreen)?.keyCode, 20)
        XCTAssertEqual(shortcuts.shortcut(for: .captureFullscreen)?.modifiers, [.command, .shift])

        // Window = ⇧⌘5 (keyCode 23)
        XCTAssertEqual(shortcuts.shortcut(for: .captureWindow)?.keyCode, 23)
        XCTAssertEqual(shortcuts.shortcut(for: .captureWindow)?.modifiers, [.command, .shift])

        // History = ⇧⌘6 (keyCode 22)
        XCTAssertEqual(shortcuts.shortcut(for: .history)?.keyCode, 22)
        XCTAssertEqual(shortcuts.shortcut(for: .history)?.modifiers, [.command, .shift])
    }

    @MainActor
    func testCaptureShortcutsCustomAssignmentAndClear() {
        let suite = "AOMCaptureShortcuts-Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = CaptureShortcuts(defaults: defaults)

        // Set custom shortcut for Area: ⌃⌥⌘A (keyCode 0)
        let custom = KeyboardShortcut(keyCode: 0, modifiers: [.control, .option, .command])
        shortcuts.setShortcut(custom, for: .captureArea)
        XCTAssertEqual(shortcuts.shortcut(for: .captureArea)?.keyCode, 0)
        XCTAssertEqual(shortcuts.shortcut(for: .captureArea)?.modifiers, [.control, .option, .command])

        // Clear shortcut
        shortcuts.setShortcut(nil, for: .captureArea)
        XCTAssertNil(shortcuts.shortcut(for: .captureArea))
        XCTAssertNil(CaptureShortcuts(defaults: defaults).shortcut(for: .captureArea),
                     "A cleared shortcut must remain disabled after relaunch")

        // Reset
        shortcuts.resetToDefaults()
        XCTAssertNotNil(shortcuts.shortcut(for: .captureArea))
    }

    @MainActor
    func testCaptureShortcutMatchingIsStableAndRespectsFunctionModifier() {
        let suite = "AOMCaptureShortcuts-Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = CaptureShortcuts(defaults: defaults)
        let combination = KeyboardShortcut(keyCode: 0, modifiers: [.command, .function])
        shortcuts.setShortcut(combination, for: .captureFullscreen)
        shortcuts.setShortcut(combination, for: .captureArea)
        for _ in 0..<20 {
            XCTAssertEqual(shortcuts.matchingAction(keyCode: 0, modifiers: [.command, .function]), .captureArea)
        }
        XCTAssertNil(shortcuts.matchingAction(keyCode: 0, modifiers: [.command]))
        XCTAssertEqual(shortcuts.matchingAction(keyCode: 0, modifiers: [.command, .function, .capsLock]), .captureArea)
    }

    @MainActor
    func testCaptureShortcutExecutionLeavesTheEventTapBeforeRunning() async {
        let suite = "AOMCaptureShortcuts-Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var executed: [CaptureShortcutAction] = []
        let completion = expectation(description: "Capture action dispatched")
        let shortcuts = CaptureShortcuts(defaults: defaults) { action in
            executed.append(action)
            completion.fulfill()
        }
        XCTAssertTrue(shortcuts.handleKeyEvent(keyCode: 21, modifiers: [.command, .shift]))
        XCTAssertTrue(executed.isEmpty, "Event tap handling must not present capture UI synchronously")
        await fulfillment(of: [completion], timeout: 1)
        XCTAssertEqual(executed, [.captureArea])
    }

    @MainActor
    func testEscapeDismissesActiveSelectionOverlay() async {
        let cancelExpectation = expectation(description: "Selection cancelled on ESC")
        let overlay = SelectionOverlayController { rect in
            if rect == nil { cancelExpectation.fulfill() }
        }
        overlay.present()
        XCTAssertTrue(SelectionOverlayController.isActive)

        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        let handled = monitor.handleInput(keyCode: 53, modifiers: [], isDown: true)
        XCTAssertTrue(handled, "ESC key must be consumed when selection overlay is active")
        XCTAssertFalse(SelectionOverlayController.isActive, "Selection overlay must be deactivated after ESC")
        // Completion is dispatched to the main runloop after window teardown;
        // a busy test host can delay that runloop beyond one second.
        await fulfillment(of: [cancelExpectation], timeout: 5)
    }

    @MainActor
    func testEscapeDismissesMediaHistoryOverlay() {
        let historyController = MediaHistoryOverlayController.shared
        historyController.present()
        XCTAssertTrue(historyController.isPresented)

        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        let handled = monitor.handleInput(keyCode: 53, modifiers: [], isDown: true)
        XCTAssertTrue(handled, "ESC key must be consumed when media history overlay is presented")
        XCTAssertFalse(historyController.isPresented, "Media history overlay must be dismissed after ESC")
    }
}
