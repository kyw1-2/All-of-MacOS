import Foundation
import CoreGraphics
import CoreImage
import AppKit
import AVFoundation
import ImageIO

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

/// An sRGB colour kept as plain numbers, so Studio projects and settings stay
/// readable JSON (3.3.3: video backgrounds, click and highlight colours).
struct AOMRGBAColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    private static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    var isValid: Bool { [red, green, blue, alpha].allSatisfy(\.isFinite) }
    var ciColor: CIColor { ciColor(alpha: alpha) }
    func ciColor(alpha: Double) -> CIColor {
        CIColor(red: CGFloat(Self.unit(red)), green: CGFloat(Self.unit(green)), blue: CGFloat(Self.unit(blue)),
                alpha: CGFloat(Self.unit(alpha)))
    }
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(Self.unit(red)), green: CGFloat(Self.unit(green)), blue: CGFloat(Self.unit(blue)),
                alpha: CGFloat(Self.unit(alpha)))
    }
    /// Converts any colour (a ColorPicker's, for example) to sRGB.
    init?(cgColor: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 4 else { return nil }
        self.init(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]), alpha: Double(parts[3]))
    }
    /// `#RRGGBB` or `#RRGGBBAA`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        let rgba = text.count == 6 ? (value << 8) | 0xFF : value
        self.init(red: Double((rgba >> 24) & 0xFF) / 255, green: Double((rgba >> 16) & 0xFF) / 255,
                  blue: Double((rgba >> 8) & 0xFF) / 255, alpha: Double(rgba & 0xFF) / 255)
    }
    var hex: String {
        func byte(_ value: Double) -> Int { Int((Self.unit(value) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(red), byte(green), byte(blue), byte(alpha))
    }
}

/// CleanShot-style gradient backdrops for exported recordings (C05).
enum AOMGradientPreset: String, Codable, CaseIterable, Identifiable {
    case ocean, sunset, aurora, candy, forest, dusk, graphite, sand
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    /// Drawn from the lower-left corner to the upper-right corner.
    var colors: (start: AOMRGBAColor, end: AOMRGBAColor) {
        switch self {
        case .ocean: return (AOMRGBAColor(red: 0.04, green: 0.32, blue: 0.80), AOMRGBAColor(red: 0.30, green: 0.85, blue: 0.95))
        case .sunset: return (AOMRGBAColor(red: 0.98, green: 0.36, blue: 0.29), AOMRGBAColor(red: 1.00, green: 0.78, blue: 0.35))
        case .aurora: return (AOMRGBAColor(red: 0.15, green: 0.80, blue: 0.62), AOMRGBAColor(red: 0.45, green: 0.30, blue: 0.95))
        case .candy: return (AOMRGBAColor(red: 0.98, green: 0.40, blue: 0.70), AOMRGBAColor(red: 0.55, green: 0.45, blue: 1.00))
        case .forest: return (AOMRGBAColor(red: 0.07, green: 0.35, blue: 0.22), AOMRGBAColor(red: 0.55, green: 0.80, blue: 0.35))
        case .dusk: return (AOMRGBAColor(red: 0.13, green: 0.12, blue: 0.35), AOMRGBAColor(red: 0.85, green: 0.42, blue: 0.55))
        case .graphite: return (AOMRGBAColor(red: 0.10, green: 0.10, blue: 0.12), AOMRGBAColor(red: 0.36, green: 0.37, blue: 0.40))
        case .sand: return (AOMRGBAColor(red: 0.93, green: 0.85, blue: 0.72), AOMRGBAColor(red: 0.80, green: 0.62, blue: 0.48))
        }
    }
}

enum AOMVideoBackgroundKind: String, Codable, CaseIterable, Identifiable {
    case none, solid, gradient, image, wallpaper
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "None"
        case .solid: return "Color"
        case .gradient: return "Gradient"
        case .image: return "Image"
        case .wallpaper: return "Desktop Picture"
        }
    }
}

/// The canvas an exported recording sits on (3.3.3, audit CS-45 / C05): a
/// colour, a gradient, an image or the desktop picture, with uniform padding,
/// rounded corners and a drop shadow. Laid out on the output canvas, so the
/// aspect presets fill with the background instead of black bars.
struct AOMVideoBackground: Codable, Equatable {
    var kind: AOMVideoBackgroundKind = .none
    var color = AOMRGBAColor(red: 0.12, green: 0.12, blue: 0.13)
    var gradient: AOMGradientPreset = .ocean
    /// A chosen image, or the desktop picture resolved on the main thread when
    /// it was picked. Unreadable files fall back to `gradient`.
    var imagePath: String?
    /// Uniform inset on every side, as a fraction of the canvas's short side.
    var padding: Double = 0.08
    /// Corner radius, as a fraction of the video's short side.
    var cornerRadius: Double = 0.04
    /// Drop-shadow strength, 0…1.
    var shadow: Double = 0.5

    static let paddingRange = 0.0...0.3
    static let cornerRange = 0.0...0.25
    static let shadowRange = 0.0...1.0

    var isActive: Bool { kind != .none }
    var isValid: Bool {
        padding.isFinite && cornerRadius.isFinite && shadow.isFinite && color.isValid
            && (imagePath?.utf8.count ?? 0) <= 4096
    }
}

extension AOMVideoBackground {
    /// Missing or unknown fields fall back to their defaults, so a project
    /// written by a later version never loses the whole edit.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(AOMVideoBackgroundKind.self, forKey: .kind)) ?? .none
        color = (try? c.decode(AOMRGBAColor.self, forKey: .color)) ?? AOMRGBAColor(red: 0.12, green: 0.12, blue: 0.13)
        gradient = (try? c.decode(AOMGradientPreset.self, forKey: .gradient)) ?? .ocean
        imagePath = try? c.decodeIfPresent(String.self, forKey: .imagePath)
        padding = (try? c.decode(Double.self, forKey: .padding)) ?? 0.08
        cornerRadius = (try? c.decode(Double.self, forKey: .cornerRadius)) ?? 0.04
        shadow = (try? c.decode(Double.self, forKey: .shadow)) ?? 0.5
    }

    /// The legacy single-colour backdrop as a background (old projects).
    init(legacy backdrop: AOMStudioBackdrop, padding: Double) {
        let c = backdrop.color
        self.init(kind: backdrop == .none ? .none : .solid,
                  color: AOMRGBAColor(red: Double(c.red), green: Double(c.green), blue: Double(c.blue)),
                  padding: min(Self.paddingRange.upperBound, max(0, padding.isFinite ? padding : 0)),
                  cornerRadius: 0, shadow: 0)
    }

    /// The main screen's desktop picture, when it is a plain image file.
    @MainActor static func currentWallpaperPath() -> String? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return nil }
        return url.path
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
    /// 3.3.3 (C05): canvas background. When set it supersedes `backdrop` and
    /// `paddingFraction`; nil keeps the pre-3.3.3 rendering of old projects.
    var background: AOMVideoBackground?

    var isActive: Bool {
        !keyframes.isEmpty || (backdrop != .none && paddingFraction > 0) || background?.isActive == true
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

        // A 3.3.3 background is laid out on the output canvas at the end; the
        // legacy backdrop (old projects) shrinks the video in place here.
        let legacyInset = settings.background == nil && settings.backdrop != .none
            ? min(0.20, max(0, settings.paddingFraction)) : 0
        if legacyInset > 0 {
            let factor = CGFloat(1 - 2 * legacyInset)
            let t = CGAffineTransform(translationX: extent.midX * (1 - factor),
                                      y: extent.midY * (1 - factor))
                .scaledBy(x: factor, y: factor)
            let inner = result.transformed(by: t)
            let background = CIImage(color: settings.backdrop.color).cropped(to: extent)
            result = inner.composited(over: background).cropped(to: extent)
        }
        if settings.cursorStyle != .hidden, !settings.cursorPoints.isEmpty, let glyph = settings.cursorStyle == .arrow ? cursorGlyph : dotGlyph,
           let cursor = AOMCursorTrack(points: settings.cursorPoints).smoothedPosition(at: time) {
            let pointerSize = CGFloat(min(3, max(0.5, settings.cursorOverlaySize)))
            let inset = legacyInset
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
                let inset = legacyInset
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
        if let background = settings.background, background.isActive {
            return onCanvas(result, size: size, background: background)
        }
        if size != extent.size {
            let target = CGRect(origin: .zero, size: size)
            let factor = min(size.width / extent.width, size.height / extent.height)
            let scaled = result.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            // A 3.3.3 background of kind None letterboxes in black, whatever an old backdrop said.
            let bars = settings.background == nil ? settings.backdrop.color : AOMStudioBackdrop.none.color
            result = scaled.transformed(by: CGAffineTransform(translationX: (size.width - scaled.extent.width) / 2, y: (size.height - scaled.extent.height) / 2)).composited(over: CIImage(color: bars).cropped(to: target)).cropped(to: target)
        }
        return result
    }

    /// Lays the finished video (zoom, pointer, clicks, camera and keys
    /// included) on the output canvas: background fill, uniform padding,
    /// rounded corners and a soft drop shadow. The canvas is the output size,
    /// so the 16:9, 4:3, 1:1 and 9:16 presets fill with the background.
    static func onCanvas(_ video: CIImage, size: CGSize, background: AOMVideoBackground) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let source = video.extent
        guard source.width >= 1, source.height >= 1, !source.isInfinite, size.width >= 2, size.height >= 2 else { return video }
        let padding = CGFloat(min(AOMVideoBackground.paddingRange.upperBound, max(0, background.padding.isFinite ? background.padding : 0)))
            * min(size.width, size.height)
        let available = canvas.insetBy(dx: padding, dy: padding)
        let factor = min(available.width / source.width, available.height / source.height)
        // Whole pixels, so the video's edges stay sharp.
        let width = max(1, (source.width * factor).rounded()), height = max(1, (source.height * factor).rounded())
        let card = CGRect(x: ((size.width - width) / 2).rounded(), y: ((size.height - height) / 2).rounded(),
                          width: width, height: height)
        let placed = video
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: card.width / source.width, y: card.height / source.height))
            .transformed(by: CGAffineTransform(translationX: card.minX, y: card.minY))
        let corner = CGFloat(min(AOMVideoBackground.cornerRange.upperBound, max(0, background.cornerRadius.isFinite ? background.cornerRadius : 0)))
            * min(card.width, card.height)
        var result = backgroundFill(background, canvas: canvas)
        let strength = min(1, max(0, background.shadow.isFinite ? background.shadow : 0))
        if strength > 0, padding > 0 {
            let blur = max(2, min(card.width, card.height) * 0.035)
            if let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: card.offsetBy(dx: 0, dy: -blur * 0.6)), "inputRadius": corner,
                "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: 0.6 * strength)])?.outputImage {
                result = shape.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
                    .cropped(to: canvas).composited(over: result)
            }
        }
        if corner >= 0.5, let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: card), "inputRadius": corner, "inputColor": CIColor.white])?.outputImage {
            result = placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result,
                                                                          kCIInputMaskImageKey: mask])
        } else {
            result = placed.cropped(to: card).composited(over: result)
        }
        return result.cropped(to: canvas)
    }

    /// The fill behind the video. An image that cannot be read falls back
    /// to the gradient, so an export never fails over a moved wallpaper.
    static func backgroundFill(_ background: AOMVideoBackground, canvas: CGRect) -> CIImage {
        func gradient(_ preset: AOMGradientPreset) -> CIImage {
            let colors = preset.colors
            let fill = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: canvas.minX, y: canvas.minY), "inputPoint1": CIVector(x: canvas.maxX, y: canvas.maxY),
                "inputColor0": colors.start.ciColor(alpha: 1), "inputColor1": colors.end.ciColor(alpha: 1)])?.outputImage
            return (fill ?? CIImage(color: colors.start.ciColor(alpha: 1))).cropped(to: canvas)
        }
        switch background.kind {
        case .none: return CIImage(color: AOMStudioBackdrop.none.color).cropped(to: canvas)
        case .solid: return CIImage(color: background.color.ciColor(alpha: 1)).cropped(to: canvas)
        case .gradient: return gradient(background.gradient)
        case .image, .wallpaper:
            guard let path = background.imagePath, let image = AOMStudioBackgroundImages.image(atPath: path) else {
                return gradient(background.gradient)
            }
            // Aspect-fill, centred.
            let scale = max(canvas.width / image.extent.width, canvas.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return scaled.transformed(by: CGAffineTransform(translationX: canvas.midX - scaled.extent.midX,
                                                            y: canvas.midY - scaled.extent.midY))
                .composited(over: CIImage(color: AOMStudioBackdrop.none.color)).cropped(to: canvas)
        }
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
    case source, landscape, standard, portrait, square
    var displayName: String {
        switch self { case .source: "Original"; case .landscape: "16:9 Landscape"; case .standard: "4:3 Standard"; case .portrait: "9:16 Portrait"; case .square: "1:1 Square" }
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
            (background?.isValid ?? true) &&
            AOMCursorTrack(points: cursorPoints, clicks: clicks, keystrokes: keystrokes).isValid
    }
    func outputSize(source: CGSize) -> CGSize {
        var ratio = source.width / max(1, source.height)
        switch aspect { case .source: break; case .landscape: ratio = 16 / 9; case .standard: ratio = 4 / 3; case .portrait: ratio = 9 / 16; case .square: ratio = 1 }
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
    /// The project embeds the whole input track (up to ~16 MB for a long,
    /// busy recording) plus edits. Reading used to stop at 16 MB while
    /// writing had no bound, so a long take's project was saved but silently
    /// never restored.
    static let maximumBytes = 40_000_000
    func write(for source: URL) throws {
        guard settings.isValid, sourceDuration.isFinite, sourceDuration > 0, clips.count <= 1000, !clips.isEmpty, clips.allSatisfy({ $0.isValid(duration: sourceDuration) }) else { throw CocoaError(.fileWriteInvalidFileName) }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw AOMCursorTrack.Failure.tooLarge(bytes: data.count) }
        try data.write(to: Self.url(for: source), options: .atomic)
    }
    static func read(for source: URL, duration: Double) -> Self? {
        guard let handle = try? FileHandle(forReadingFrom: url(for: source)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let project = try? JSONDecoder().decode(Self.self, from: data), project.version == 1, project.settings.isValid,
              project.sourceName == source.lastPathComponent,
              project.sourceBytes == (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize),
              abs(project.sourceDuration - duration) < 0.1, !project.clips.isEmpty,
              project.clips.count <= 1000, project.clips.allSatisfy({ $0.isValid(duration: duration) }) else { return nil }
        return project
    }
}

/// Background pictures for the Studio canvas, decoded once (down-sampled to
/// at most 4096 px) and shared by the preview and the export threads.
enum AOMStudioBackgroundImages {
    static let maximumPixels = 4096
    private static let lock = NSLock()
    private static var cache: [String: CIImage] = [:]
    private static var unreadable: Set<String> = []

    static func image(atPath path: String) -> CIImage? {
        guard path.hasPrefix("/"), path.utf8.count <= 4096 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let image = cache[path] { return image }
        if unreadable.contains(path) { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maximumPixels]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              picture.width > 0, picture.height > 0 else {
            if unreadable.count > 64 { unreadable.removeAll() }
            unreadable.insert(path)
            return nil
        }
        let image = CIImage(cgImage: picture)
        if cache.count >= 4 { cache.removeAll() }
        cache[path] = image
        return image
    }

    /// Forget a path, so a file chosen again (or replaced) is read afresh.
    static func invalidate(_ path: String?) {
        guard let path else { return }
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: path)
        unreadable.remove(path)
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
