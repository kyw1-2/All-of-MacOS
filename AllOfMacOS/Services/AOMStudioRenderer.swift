import Foundation
import CoreGraphics
import CoreImage
import AppKit
import AVFoundation

enum AOMStudioBackdrop: String, Codable, CaseIterable, Identifiable {
    case none, graphite, midnight, slate
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "None"
        case .graphite: return "Graphite"
        case .midnight: return "Midnight"
        case .slate: return "Slate"
        }
    }
    var color: CIColor {
        switch self {
        case .none: return CIColor(red: 0, green: 0, blue: 0)
        case .graphite: return CIColor(red: 0.12, green: 0.12, blue: 0.13)
        case .midnight: return CIColor(red: 0.035, green: 0.07, blue: 0.16)
        case .slate: return CIColor(red: 0.16, green: 0.22, blue: 0.29)
        }
    }
}

struct AOMStudioSettings: Codable, Equatable {
    var keyframes: [AOMStudioZoomKeyframe] = []
    var backdrop: AOMStudioBackdrop = .none
    var paddingFraction: Double = 0
    var motionBlurRadius: Double = 0
    var cursorPoints: [AOMCursorPoint] = []
    var cursorOverlaySize: Double = 1

    var clicks: [AOMClickEvent] = []
    var showClickRipples = true
    var cursorStyle: AOMStudioCursorStyle = .arrow
    var keystrokes: [AOMKeystrokeEvent] = []
    var showKeystrokes = true
    var keystrokeScale: Double = 1
    var keystrokeY: Double = 0.9
    var showCamera = true
    var cameraSize: Double = 0.24
    var cameraX: Double = 0.84
    var cameraY: Double = 0.84
    var cameraRoundness: Double = 0.18
    var aspect: AOMStudioAspect = .source
    var resolution: AOMStudioResolution = .source
    /// Light or dark key badges. Optional so Studio projects saved before
    /// 2.3 still decode (nil draws the original dark badge).
    var keystrokeStyle: AOMKeystrokeStyle?

    var isActive: Bool {
        !keyframes.isEmpty || (backdrop != .none && paddingFraction > 0)
            || !cursorPoints.isEmpty || !clicks.isEmpty || !keystrokes.isEmpty || aspect != .source || resolution != .source
    }
}

/// Pure Core Image compositor for the captured video. It does not attempt to
/// recover cursor events baked into an MP4 or claim CleanShot's Smart Zoom AI.
enum AOMStudioRenderer {
    typealias Focus = AOMStudioTimeline.Focus

    static func sampledFocus(at time: Double,
                             keyframes: [AOMStudioZoomKeyframe]) -> Focus {
        AOMStudioTimeline.sampledFocus(at: time, keyframes: keyframes)
    }

    static func frame(_ image: CIImage, time: Double,
                      settings: AOMStudioSettings, cameraImage: CIImage? = nil) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, !extent.isInfinite,
              extent.width <= 16384, extent.height <= 16384 else { return image }
        let f = sampledFocus(at: time, keyframes: settings.keyframes)
        let zoom = CGFloat(f.magnification)
        let center = AOMStudioTimeline.viewportCenter(for: f)
        let focusX = extent.minX + center.x * extent.width
        let focusY = extent.maxY - center.y * extent.height
        let offset = CGAffineTransform(translationX: extent.midX - focusX * zoom,
                                       y: extent.midY - focusY * zoom)
            .scaledBy(x: zoom, y: zoom)
        var result = image.transformed(by: offset).cropped(to: extent)

        let blur = min(8, max(0, settings.motionBlurRadius))
        if blur > 0, !settings.keyframes.isEmpty {
            let before = sampledFocus(at: max(0, time - 1 / 60), keyframes: settings.keyframes)
            let after = sampledFocus(at: time + 1 / 60, keyframes: settings.keyframes)
            let moving = abs(before.magnification - after.magnification) > 0.001 ||
                (f.magnification > 1 && (abs(before.x - after.x) + abs(before.y - after.y)) > 0.001)
            if moving {
                result = result.clampedToExtent()
                    .applyingFilter("CIMotionBlur",
                                    parameters: [kCIInputRadiusKey: blur,
                                                 kCIInputAngleKey: 0])
                    .cropped(to: extent)
            }
        }

        if settings.backdrop != .none {
            let inset = min(0.20, max(0, settings.paddingFraction))
            if inset > 0 {
                let factor = CGFloat(1 - 2 * inset)
                let t = CGAffineTransform(translationX: extent.midX * (1 - factor),
                                          y: extent.midY * (1 - factor))
                    .scaledBy(x: factor, y: factor)
                let inner = result.transformed(by: t)
                let background = CIImage(color: settings.backdrop.color).cropped(to: extent)
                result = inner.composited(over: background).cropped(to: extent)
            }
        }
        if settings.cursorStyle != .hidden, !settings.cursorPoints.isEmpty, let glyph = settings.cursorStyle == .arrow ? cursorGlyph : dotGlyph,
           let cursor = AOMCursorTrack(points: settings.cursorPoints).smoothedPosition(at: time) {
            let pointerSize = CGFloat(min(3, max(0.5, settings.cursorOverlaySize)))
            let inset = settings.backdrop == .none ? 0 : min(0.2, max(0, settings.paddingFraction))
            let projected = AOMStudioTimeline.projectedPoint(cursor, focus: f, padding: inset)
            let x = extent.minX + projected.x * extent.width
            let y = extent.maxY - projected.y * extent.height
            // The glyph's actual hotspot is (2, 30), not its bitmap corner.
            let transformed = glyph.transformed(by:
                    CGAffineTransform(scaleX: pointerSize, y: pointerSize))
                .transformed(by: CGAffineTransform(translationX: x - pointerSize * (settings.cursorStyle == .dot ? 6 : 2),
                                                   y: y - pointerSize * (settings.cursorStyle == .dot ? 6 : 30)))
            let videoBounds = extent.insetBy(dx: extent.width * inset, dy: extent.height * inset)
            result = transformed.cropped(to: videoBounds)
                .composited(over: result).cropped(to: extent)
        }
        if settings.showClickRipples {
            for click in AOMStudioTimeline.activeClicks(at: time, clicks: settings.clicks) {
                let progress = (time - click.time) / 0.65
                let inset = settings.backdrop == .none ? 0 : settings.paddingFraction
                let point = AOMStudioTimeline.projectedPoint(CGPoint(x: click.x, y: click.y), focus: f, padding: inset)
                let center = CIVector(x: extent.minX + point.x * extent.width, y: extent.maxY - point.y * extent.height)
                let radius = 8 + progress * 30
                if let ring = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": center,
                    "inputRadius0": radius - 2, "inputRadius1": radius + 2,
                    "inputColor0": CIColor(red: 0.2, green: 0.65, blue: 1, alpha: 0),
                    "inputColor1": CIColor(red: 0.2, green: 0.65, blue: 1, alpha: 0.65 * (1 - progress))])?.outputImage {
                    let box = CGRect(x: center.x - radius - 2, y: center.y - radius - 2, width: 2 * radius + 4, height: 2 * radius + 4)
                    // Crop the gradient to a circular outer boundary.
                    let mask = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": center,
                        "inputRadius0": radius, "inputRadius1": radius + 2,
                        "inputColor0": CIColor.white, "inputColor1": CIColor.clear])!.outputImage!
                    let transparent = CIImage(color: .clear).cropped(to: box)
                    result = ring.cropped(to: box).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: mask]).composited(over: result).cropped(to: extent)
                }
            }
        }
        if settings.showCamera, let cameraImage {
            let side = min(extent.width, extent.height) * min(0.6, max(0.1, settings.cameraSize))
            let x = min(extent.maxX - side, max(extent.minX, extent.minX + settings.cameraX * extent.width - side / 2))
            let y = min(extent.maxY - side, max(extent.minY, extent.maxY - settings.cameraY * extent.height - side / 2))
            let target = CGRect(x: x, y: y, width: side, height: side)
            let scale = max(side / cameraImage.extent.width, side / cameraImage.extent.height)
            let scaled = cameraImage.transformed(by: CGAffineTransform(scaleX: -scale, y: scale))
            let placed = scaled.transformed(by: CGAffineTransform(translationX: target.midX - scaled.extent.midX, y: target.midY - scaled.extent.midY))
            if let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: target), "inputRadius": side * min(0.5, max(0, settings.cameraRoundness)), "inputColor": CIColor.white])?.outputImage {
                result = placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask]).cropped(to: extent)
            }
        }
        if settings.showKeystrokes,
           let key = AOMStudioTimeline.activeKeystroke(at: time, events: settings.keystrokes),
           let glyph = keyGlyph(key.label, style: settings.keystrokeStyle ?? .dark) {
            let scale = min(2, max(0.5, settings.keystrokeScale))
            let scaled = glyph.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let y = extent.maxY - min(1, max(0, settings.keystrokeY)) * extent.height
            result = scaled.transformed(by: CGAffineTransform(translationX: extent.midX - scaled.extent.midX, y: y - scaled.extent.midY)).composited(over: result).cropped(to: extent)
        }
        let size = settings.outputSize(source: extent.size)
        if size != extent.size {
            let target = CGRect(origin: .zero, size: size)
            let factor = min(size.width / extent.width, size.height / extent.height)
            let scaled = result.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            result = scaled.transformed(by: CGAffineTransform(translationX: (size.width - scaled.extent.width) / 2, y: (size.height - scaled.extent.height) / 2)).composited(over: CIImage(color: settings.backdrop.color).cropped(to: target)).cropped(to: target)
        }
        return result
    }

    private static let dotGlyph = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: CGRect(x: 0, y: 0, width: 12, height: 12)), "inputRadius": 6, "inputColor": CIColor.white])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 12, height: 12))

    private static let glyphLock = NSLock()
    private static var keyGlyphs: [String: CIImage] = [:]
    private static func keyGlyph(_ label: String, style: AOMKeystrokeStyle) -> CIImage? {
        glyphLock.lock(); defer { glyphLock.unlock() }
        let cacheKey = style.rawValue + "|" + label
        if let image = keyGlyphs[cacheKey] { return image }
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                                                                  .foregroundColor: style == .light ? NSColor.black : NSColor.white])
        let size = CGSize(width: max(70, text.size().width + 36), height: 58)
        let image = NSImage(size: size)
        image.lockFocus()
        (style == .light ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.75)).setFill()
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).fill()
        text.draw(at: CGPoint(x: (size.width - text.size().width) / 2, y: 12))
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let result = CIImage(cgImage: cg)
        if keyGlyphs.count > 256 { keyGlyphs.removeAll() }
        keyGlyphs[cacheKey] = result
        return result
    }

    private static let cursorGlyph: CIImage? = {
        guard let context = CGContext(data: nil, width: 24, height: 32,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 30))
        for point in [
            CGPoint(x: 2, y: 2), CGPoint(x: 9, y: 11),
            CGPoint(x: 14, y: 3), CGPoint(x: 19, y: 6),
            CGPoint(x: 14, y: 15), CGPoint(x: 22, y: 17)
        ] { path.addLine(to: point) }
        path.closeSubpath()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(path); context.fillPath()
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1.7)
        context.strokePath()
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }()
}

enum AOMStudioCursorStyle: String, Codable, CaseIterable { case arrow, dot, hidden }
enum AOMKeystrokeStyle: String, Codable, CaseIterable, Identifiable {
    case dark, light
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}
enum AOMStudioAspect: String, Codable, CaseIterable {
    case source, landscape, portrait, square
    var displayName: String {
        switch self { case .source: "Original"; case .landscape: "16:9 Landscape"; case .portrait: "9:16 Portrait"; case .square: "1:1 Square" }
    }
}
enum AOMStudioResolution: String, Codable, CaseIterable {
    case source, hd720, hd1080, uhd2160
    var displayName: String {
        switch self { case .source: "Original size"; case .hd720: "1280 px long edge"; case .hd1080: "1920 px long edge"; case .uhd2160: "3840 px long edge" }
    }
}
extension AOMStudioSettings {
    var isValid: Bool {
        let scalars = [paddingFraction, motionBlurRadius, cursorOverlaySize, keystrokeScale, keystrokeY, cameraSize, cameraX, cameraY, cameraRoundness]
        return scalars.allSatisfy { $0.isFinite } && keyframes.count <= 400 &&
            keyframes.allSatisfy { $0.time.isFinite && $0.time >= 0 && $0.magnification.isFinite && $0.focusX.isFinite && $0.focusY.isFinite } &&
            AOMCursorTrack(points: cursorPoints, clicks: clicks, keystrokes: keystrokes).isValid
    }
    func outputSize(source: CGSize) -> CGSize {
        var ratio = source.width / max(1, source.height)
        switch aspect { case .source: break; case .landscape: ratio = 16 / 9; case .portrait: ratio = 9 / 16; case .square: ratio = 1 }
        let edge: Double
        switch resolution { case .source: edge = max(source.width, source.height); case .hd720: edge = 1280; case .hd1080: edge = 1920; case .uhd2160: edge = 3840 }
        return CGSize(width: max(2, floor((ratio >= 1 ? edge : edge * ratio) / 2) * 2), height: max(2, floor((ratio >= 1 ? edge / ratio : edge) / 2) * 2))
    }
}

struct AOMStudioProject: Codable {
    var version = 1
    var sourceName: String
    var sourceBytes: Int
    var sourceDuration: Double
    var clips: [AOMStudioClip]
    var settings: AOMStudioSettings
    var muteAudio = false
    static func url(for source: URL) -> URL { source.appendingPathExtension("aom-studio.json") }
    func write(for source: URL) throws {
        guard settings.isValid, sourceDuration.isFinite, sourceDuration > 0, clips.count <= 1000, !clips.isEmpty, clips.allSatisfy({ $0.isValid(duration: sourceDuration) }) else { throw CocoaError(.fileWriteInvalidFileName) }
        try JSONEncoder().encode(self).write(to: Self.url(for: source), options: .atomic)
    }
    static func read(for source: URL, duration: Double) -> Self? {
        guard let handle = try? FileHandle(forReadingFrom: url(for: source)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_000_001), data.count <= 16_000_000,
              let project = try? JSONDecoder().decode(Self.self, from: data), project.version == 1, project.settings.isValid,
              project.sourceName == source.lastPathComponent,
              project.sourceBytes == (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize),
              abs(project.sourceDuration - duration) < 0.1, !project.clips.isEmpty,
              project.clips.count <= 1000, project.clips.allSatisfy({ $0.isValid(duration: duration) }) else { return nil }
        return project
    }
}

/// Camera remains a separate movie so disabling/moving it never damages screen pixels.
final class AOMStudioCameraFrames: @unchecked Sendable {
    static func url(for source: URL) -> URL { source.appendingPathExtension("aom-camera.mp4") }
    private let generator: AVAssetImageGenerator
    private let lock = NSLock()
    init?(source: URL) {
        let url = Self.url(for: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
    }
    func frame(at time: Double) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let image = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else { return nil }
        return CIImage(cgImage: image)
    }
}

/// The exported presentation is self-contained. Its adjacent local link lets
/// AOM reopen the untouched screen/camera/telemetry sources for later editing.
enum AOMStudioSourceLink {
    static func url(for movie: URL) -> URL { movie.appendingPathExtension("aom-source.json") }
    static func write(presentation: URL, source: URL) throws {
        guard presentation.deletingLastPathComponent() == source.deletingLastPathComponent(), presentation != source else { throw CocoaError(.fileWriteInvalidFileName) }
        try JSONEncoder().encode(source.lastPathComponent).write(to: url(for: presentation), options: .atomic)
    }
    static func resolve(_ movie: URL) -> URL {
        guard let handle = try? FileHandle(forReadingFrom: url(for: movie)) else { return movie }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096,
              let name = try? JSONDecoder().decode(String.self, from: data),
              !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("/"), !name.contains("\\"), name != movie.lastPathComponent else { return movie }
        let original = movie.deletingLastPathComponent().appendingPathComponent(name)
        guard original.pathExtension.lowercased() == "mp4", FileManager.default.isReadableFile(atPath: original.path) else { return movie }
        return original
    }
}
