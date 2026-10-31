import AppKit
import AVFoundation

/// `--aom-ui-preview <dir> --aom-capture-preview`: shows the capture UI
/// (Quick Access stack, pin, history, annotate) with a synthetic image so
/// layouts can be inspected without capturing the screen. Preview-only; the
/// history cache lives inside the preview directory.
@MainActor
enum CaptureUIPreview {
    static var isRequested: Bool {
        PresetManager.isUIPreview && ProcessInfo.processInfo.arguments.contains("--aom-capture-preview")
    }

    /// Forces the first Quick Access card into its hover state for screenshots.
    static var forcesHover: Bool {
        PresetManager.isUIPreview && ProcessInfo.processInfo.arguments.contains("--aom-preview-hover")
    }

    static func show() {
        let args = ProcessInfo.processInfo.arguments
        // 3.4 review hooks that need no capture (isolated previews only).
        if PresetManager.isUIPreview, args.contains("--aom-preview-floating-menus") { previewFloatingMenus() }
        if PresetManager.isUIPreview, args.contains("--aom-preview-btt-report") { BTTImportReportPreview.open() }
        guard isRequested, let image = sampleImage(width: 1280, height: 800) else { return }
        for index in 0..<2 {
            let result = CaptureResult(image: image, globalRect: CGRect(x: 0, y: 0, width: 640, height: 400),
                                       scale: 2, kind: .area, windowTitle: "Preview \(index + 1)")
            let entry = CaptureHistory.shared.add(result, url: nil)
            CaptureCoordinator.shared.restoreToQuickAccess(entry)
        }
        guard let entry = CaptureHistory.shared.mostRecent else { return }
        if args.contains("--aom-preview-pin") { PinnedScreenshotController.shared.pin(entry: entry, url: nil) }
        if args.contains("--aom-preview-history") {
            // Another app coming to the front closes the history (as it
            // should), and parallel previews do that often; the review
            // reopens it for half a minute so a screenshot finds it.
            Task { @MainActor in
                for _ in 0..<30 {
                    MediaHistoryOverlayController.shared.present()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        if args.contains("--aom-preview-annotate") { AnnotationEditorController.shared.open(capture: entry, url: nil) }
        // 3.4: the Capture Text HUD with a sample result (it stays up for review).
        if args.contains("--aom-preview-text-hud") {
            TextCaptureHUDController.shared.show(TextCaptureHUDModel(
                title: "Text Copied", subtitle: "3 lines · English",
                text: "Quarterly report draft\nRevenue grew 12% year over year.\nSee https://www.apple.com/macos/ for details.",
                links: [URL(string: "https://www.apple.com/macos/")!], barcodes: [], languageCode: "en",
                symbol: "text.viewfinder"), anchor: nil, duration: 3600)
        }
        // 3.4: the recording editor on a 2 s synthetic movie written inside the
        // preview folder (never anywhere else).
        if args.contains("--aom-preview-recording"), let directory = PresetManager.previewDirectory {
            Task { @MainActor in
                let movie = directory.appendingPathComponent("Preview Recording.mp4")
                if !FileManager.default.fileExists(atPath: movie.path) {
                    do { try await writeSyntheticMovie(to: movie) } catch { return }
                }
                RecordingExportEditorController.shared.open(source: movie)
            }
        }
    }

    /// The floating menus editor with one sample menu in the preview's own
    /// defaults (the preview app has its own bundle identifier).
    private static func previewFloatingMenus() {
        if FloatingMenuStore.shared.menus.isEmpty {
            var menu = FloatingMenuDefinition()
            menu.name = "Writing"
            menu.columns = 3
            menu.placement = "center"
            var clock = FloatingMenuItem(); clock.title = "Time"; clock.kind = "clock"
            var focus = FloatingMenuItem(); focus.title = "Mission Control"; focus.symbol = "rectangle.3.group"
            focus.actions = [TriggerAction(actionType: .missionControl)]
            var snap = FloatingMenuItem(); snap.title = "Left Half"; snap.symbol = "rectangle.lefthalf.filled"
            snap.actions = [TriggerAction(actionType: .snapWindowLeft)]
            menu.items = [clock, focus, snap]
            try? FloatingMenuStore.shared.save(menu)
        }
        FloatingMenuController.shared.edit()
    }

    /// A 640 × 400, 2 s H.264 movie: the sample picture brightening, so the
    /// editor has real frames, a real duration and a real file to export.
    private static func writeSyntheticMovie(to url: URL) async throws {
        let width = 640, height = 400
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        track.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(track)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let picture = sampleImage(width: width, height: height)
        for index in 0..<60 {
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess,
                  let pixel else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel),
               let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                if let picture { context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height)) }
                context.setFillColor(CGColor(gray: 1, alpha: CGFloat(index) / 120))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            for _ in 0..<100 where !track.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        track.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func sampleImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1),
                      CGColor(red: 0.75, green: 0.30, blue: 0.85, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.85))
        context.fill(CGRect(x: 120, y: 120, width: width - 240, height: height - 240))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        for row in 0..<6 {
            context.fill(CGRect(x: 180, y: 220 + row * 70, width: (row % 2 == 0 ? 700 : 500), height: 24))
        }
        return context.makeImage()
    }
}
