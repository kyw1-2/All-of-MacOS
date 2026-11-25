import AppKit
import CoreGraphics

/// 7.19: isolated previews started with `--aom-preview-sample-data` get a
/// dozen drawn captures, so the Capture library, its list mode and inspector
/// can be reviewed on CI. The history of a preview lives in the preview's own
/// temporary directory (`CaptureHistory.defaultDirectory`), never the real one.
@MainActor
enum CapturePreviewSamples {
    private static var seeded = false

    static var isRequested: Bool {
        PresetManager.isUIPreview && ProcessInfo.processInfo.arguments.contains("--aom-preview-sample-data")
    }

    static func seedIfRequested(into history: CaptureHistory) {
        guard isRequested, !seeded, history.entries.isEmpty, PresetManager.previewDirectory != nil else { return }
        seeded = true
        let now = Date()
        let samples: [(CaptureKind, String?, CGSize, [CGFloat])] = [
            (.window, "Safari — Apple Developer", CGSize(width: 1280, height: 800), [0.20, 0.45, 0.85]),
            (.area, nil, CGSize(width: 640, height: 420), [0.95, 0.55, 0.25]),
            (.fullscreen, nil, CGSize(width: 1512, height: 982), [0.30, 0.65, 0.45]),
            (.window, "회의록 — Notes", CGSize(width: 900, height: 700), [0.85, 0.75, 0.30]),
            (.scrolling, nil, CGSize(width: 800, height: 2400), [0.55, 0.40, 0.80]),
            (.area, nil, CGSize(width: 420, height: 300), [0.25, 0.70, 0.75]),
            (.window, "Xcode — AOM", CGSize(width: 1400, height: 900), [0.35, 0.35, 0.40]),
            (.selection, nil, CGSize(width: 520, height: 520), [0.90, 0.35, 0.45]),
            (.area, nil, CGSize(width: 760, height: 480), [0.45, 0.55, 0.95]),
            (.fullscreen, nil, CGSize(width: 1512, height: 982), [0.60, 0.50, 0.35]),
            (.window, "Finder — Downloads", CGSize(width: 980, height: 620), [0.40, 0.60, 0.90]),
            (.area, nil, CGSize(width: 360, height: 240), [0.70, 0.30, 0.60]),
        ]
        // Oldest first, so the newest ends up at the top of the library.
        for (index, sample) in samples.enumerated().reversed() {
            guard let image = draw(size: sample.2, tint: sample.3, seed: index) else { continue }
            let result = CaptureResult(image: image, globalRect: CGRect(origin: .zero, size: sample.2), scale: 1,
                                       kind: sample.0, windowTitle: sample.1,
                                       capturedAt: now.addingTimeInterval(-Double(index) * 37 * 60))
            let entry = history.add(result, url: nil)
            if index == 1 || index == 6 { history.togglePin(entry) }
        }
    }

    /// A gradient with a few window-like blocks: enough structure to read as
    /// a screenshot in a thumbnail.
    private static func draw(size: CGSize, tint: [CGFloat], seed: Int) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let top = CGColor(srgbRed: tint[0], green: tint[1], blue: tint[2], alpha: 1)
        let bottom = CGColor(srgbRed: tint[0] * 0.55, green: tint[1] * 0.55, blue: tint[2] * 0.6, alpha: 1)
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }
        // A window: title bar, sidebar and content lines.
        let inset = min(size.width, size.height) * 0.08
        let window = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
        context.setFillColor(CGColor(gray: 1, alpha: 0.92))
        context.addPath(CGPath(roundedRect: window, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: window.minX, y: window.maxY - 28, width: window.width, height: 28))
        context.setFillColor(CGColor(gray: 0.94, alpha: 1))
        context.fill(CGRect(x: window.minX, y: window.minY, width: window.width * 0.24, height: window.height - 28))
        context.setFillColor(CGColor(gray: 0.78, alpha: 1))
        let lines = 3 + seed % 5
        for line in 0..<lines {
            let y = window.maxY - 56 - CGFloat(line) * 22
            guard y > window.minY + 10 else { break }
            let length = window.width * (0.35 + 0.08 * CGFloat((line + seed) % 5))
            context.fill(CGRect(x: window.minX + window.width * 0.28, y: y, width: length, height: 8))
        }
        return context.makeImage()
    }
}
