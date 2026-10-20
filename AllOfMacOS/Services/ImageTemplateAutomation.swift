import AppKit
import ImageIO

struct ImageMatchPixels: Equatable {
    let width: Int
    let height: Int
    let rgba: [UInt8]
    init(width: Int, height: Int, rgba: [UInt8]) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 16_777_216, rgba.count == width * height * 4 else { throw ImageTemplateError.invalidImage }
        self.width = width; self.height = height; self.rgba = rgba
    }
    static func rasterize(_ image: CGImage, scale: Double) throws -> ImageMatchPixels {
        guard scale.isFinite, scale > 0, scale <= 4 else { throw ImageTemplateError.invalidImage }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard width <= 8192, height <= 8192, width * height <= 16_777_216 else { throw ImageTemplateError.invalidImage }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let success = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw ImageTemplateError.invalidImage }
        return try ImageMatchPixels(width: width, height: height, rgba: bytes)
    }
}

enum ImageTemplateError: LocalizedError, Equatable {
    case invalidImage, oversizedTemplate, cancelled, budgetExceeded, noMatch, permission
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Use a readable local PNG/JPEG/TIFF image with valid pixel dimensions."
        case .oversizedTemplate: return "The template must fit the display and contain at most 1 million pixels."
        case .cancelled: return "Image search cancelled."
        case .budgetExceeded: return "Image search reached its processing limit; use a smaller template or a more distinctive image."
        case .noMatch: return "No screen image matched the template threshold."
        case .permission: return "Image search needs Screen Recording permission; clicking also needs Accessibility permission."
        }
    }
}

/// Same-scale RGB template search. Transparent template pixels are ignored.
/// A distributed sample rejects unlikely candidates; accepted candidates are
/// verified against every opaque template pixel. Work and wall time are bounded.
struct ImageTemplateMatcher {
    struct Match: Equatable { let x: Int; let y: Int; let score: Double }
    static func find(in screen: ImageMatchPixels, template: ImageMatchPixels, threshold: Double,
                     maximumComparisons: Int = 128_000_000, timeout: Double = 3,
                     isCancelled: () -> Bool = { false }) throws -> Match? {
        guard threshold.isFinite, (0.8...1).contains(threshold) else { throw ImageTemplateError.invalidImage }
        guard template.width <= screen.width, template.height <= screen.height,
              template.width * template.height <= 1_048_576 else { throw ImageTemplateError.oversizedTemplate }
        let opaque = stride(from: 0, to: template.rgba.count, by: 4).filter { template.rgba[$0 + 3] >= 250 }
        guard opaque.count >= 4 else { throw ImageTemplateError.invalidImage }
        let samples = (0..<min(16, opaque.count)).map { opaque[$0 * opaque.count / min(16, opaque.count)] }
        let allowedError = (1 - threshold) * 255 * 3 * Double(opaque.count)
        let sampleError = min(1, 1 - threshold + 0.03) * 255 * 3 * Double(samples.count)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var comparisons = 0
        for y in 0...(screen.height - template.height) {
            guard !isCancelled() else { throw ImageTemplateError.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ImageTemplateError.budgetExceeded }
            for x in 0...(screen.width - template.width) {
                let base = (y * screen.width + x) * 4
                func difference(_ offset: Int) -> Int {
                    let pixel = offset / 4
                    let target = base + ((pixel / template.width) * screen.width + pixel % template.width) * 4
                    return abs(Int(screen.rgba[target]) - Int(template.rgba[offset]))
                        + abs(Int(screen.rgba[target + 1]) - Int(template.rgba[offset + 1]))
                        + abs(Int(screen.rgba[target + 2]) - Int(template.rgba[offset + 2]))
                }
                var sampled = 0
                for offset in samples {
                    sampled += difference(offset); comparisons += 1
                    if Double(sampled) > sampleError { break }
                }
                if comparisons > maximumComparisons { throw ImageTemplateError.budgetExceeded }
                guard Double(sampled) <= sampleError else { continue }
                var error = 0
                for offset in opaque {
                    error += difference(offset); comparisons += 1
                    if Double(error) > allowedError { break }
                    if comparisons % 4096 == 0 {
                        guard !isCancelled() else { throw ImageTemplateError.cancelled }
                        guard comparisons <= maximumComparisons, ProcessInfo.processInfo.systemUptime < deadline else { throw ImageTemplateError.budgetExceeded }
                    }
                }
                if Double(error) <= allowedError {
                    guard !isCancelled() else { throw ImageTemplateError.cancelled }
                    guard comparisons <= maximumComparisons, ProcessInfo.processInfo.systemUptime < deadline else { throw ImageTemplateError.budgetExceeded }
                    return Match(x: x, y: y, score: 1 - Double(error) / (255 * 3 * Double(opaque.count)))
                }
            }
        }
        return nil
    }
    static func center(_ match: Match, template: ImageMatchPixels, screen: ImageMatchPixels, bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + (Double(match.x) + Double(template.width) / 2) / Double(screen.width) * bounds.width,
                y: bounds.minY + (Double(match.y) + Double(template.height) / 2) / Double(screen.height) * bounds.height)
    }
}

private final class ImageMatchCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum ImageTemplateAutomation {
    static func perform(_ action: TriggerAction, isCancelled: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            let p = action.parameters
            guard !isCancelled() else { completion(false); return }
            let shouldClick = p.imageMatchClick ?? false
            guard ScreenCaptureService.hasPermission, !shouldClick || AXIsProcessTrusted() else {
                GestureLog.shared.logFromAnyThread(ImageTemplateError.permission.localizedDescription, level: .error)
                completion(false); return
            }
            let point = CGEvent(source: nil)?.location ?? .zero
            let bounds = NSScreen.screens.compactMap { screen -> CGRect? in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return CGDisplayBounds(number.uint32Value)
            }
            guard let display = bounds.first(where: { $0.contains(point) }) ?? bounds.first,
                  let path = TriggerSystemPaths.normalized(p.imageTemplatePath ?? "") else { completion(false); return }
            let token = ImageMatchCancellation()
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in if isCancelled() { token.cancel() } }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            do {
                let capture = try await ScreenCaptureService.shared.captureArea(display, showsCursor: false, pixelSnap: true)
                guard !isCancelled() else { throw ImageTemplateError.cancelled }
                let result = try await Task.detached(priority: .userInitiated) { () -> (ImageTemplateMatcher.Match, CGPoint) in
                    guard !token.isCancelled() else { throw ImageTemplateError.cancelled }
                    let file = URL(fileURLWithPath: path)
                    guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_777_216,
                          let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 1_048_576,
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageTemplateError.invalidImage }
                    let scale = min(1, 1600 / Double(max(capture.image.width, capture.image.height)))
                    let screen = try ImageMatchPixels.rasterize(capture.image, scale: scale)
                    let template = try ImageMatchPixels.rasterize(image, scale: scale)
                    guard let match = try ImageTemplateMatcher.find(in: screen, template: template,
                        threshold: p.imageMatchThreshold ?? 0.98, isCancelled: token.isCancelled) else { throw ImageTemplateError.noMatch }
                    return (match, ImageTemplateMatcher.center(match, template: template, screen: screen, bounds: capture.globalRect))
                }.value
                guard !isCancelled() else { throw ImageTemplateError.cancelled }
                if let name = p.imageMatchVariable, !name.isEmpty {
                    WorkflowVariables.set(name, value: "true")
                    WorkflowVariables.set(name + "_x", value: String(format: "%.2f", result.1.x))
                    WorkflowVariables.set(name + "_y", value: String(format: "%.2f", result.1.y))
                    WorkflowVariables.set(name + "_score", value: String(format: "%.6f", result.0.score))
                }
                if shouldClick {
                    guard !isCancelled(), AXIsProcessTrusted(), ScreenCaptureService.hasPermission,
                          let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: result.1, mouseButton: .left),
                          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: result.1, mouseButton: .left) else { completion(false); return }
                    SyntheticInput.post(down); SyntheticInput.post(up)
                }
                completion(true)
            } catch {
                if let name = p.imageMatchVariable, !name.isEmpty, !isCancelled() {
                    WorkflowVariables.set(name, value: "false")
                    ["_x", "_y", "_score"].forEach { WorkflowVariables.remove(name + $0) }
                }
                GestureLog.shared.logFromAnyThread("Image search: \(error.localizedDescription)", level: .error)
                completion(false)
            }
        }
    }
}
