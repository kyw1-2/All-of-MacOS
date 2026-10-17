import AppKit

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
        guard isRequested, let image = sampleImage(width: 1280, height: 800) else { return }
        let args = ProcessInfo.processInfo.arguments
        for index in 0..<2 {
            let result = CaptureResult(image: image, globalRect: CGRect(x: 0, y: 0, width: 640, height: 400),
                                       scale: 2, kind: .area, windowTitle: "Preview \(index + 1)")
            let entry = CaptureHistory.shared.add(result, url: nil)
            CaptureCoordinator.shared.restoreToQuickAccess(entry)
        }
        guard let entry = CaptureHistory.shared.mostRecent else { return }
        if args.contains("--aom-preview-pin") { PinnedScreenshotController.shared.pin(entry: entry, url: nil) }
        if args.contains("--aom-preview-history") { MediaHistoryOverlayController.shared.present() }
        if args.contains("--aom-preview-annotate") { AnnotationEditorController.shared.open(capture: entry, url: nil) }
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
