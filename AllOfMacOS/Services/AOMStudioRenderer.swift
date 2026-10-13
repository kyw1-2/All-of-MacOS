import Foundation
import CoreGraphics
import CoreImage

enum AOMStudioBackdrop: String, CaseIterable, Identifiable {
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

struct AOMStudioSettings: Equatable {
    var keyframes: [AOMStudioZoomKeyframe] = []
    var backdrop: AOMStudioBackdrop = .none
    var paddingFraction: Double = 0
    var motionBlurRadius: Double = 0
    var cursorPoints: [AOMCursorPoint] = []
    var cursorOverlaySize: Double = 1

    var isActive: Bool {
        !keyframes.isEmpty || (backdrop != .none && paddingFraction > 0)
            || !cursorPoints.isEmpty
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
                      settings: AOMStudioSettings) -> CIImage {
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
        if !settings.cursorPoints.isEmpty, let glyph = cursorGlyph,
           let cursor = AOMCursorTrack(points: settings.cursorPoints).smoothedPosition(at: time) {
            let pointerSize = CGFloat(min(3, max(0.5, settings.cursorOverlaySize)))
            let inset = settings.backdrop == .none ? 0 : min(0.2, max(0, settings.paddingFraction))
            let projected = AOMStudioTimeline.projectedPoint(cursor, focus: f, padding: inset)
            let x = extent.minX + projected.x * extent.width
            let y = extent.maxY - projected.y * extent.height
            // The glyph's actual hotspot is (2, 30), not its bitmap corner.
            let transformed = glyph.transformed(by:
                    CGAffineTransform(scaleX: pointerSize, y: pointerSize))
                .transformed(by: CGAffineTransform(translationX: x - pointerSize * 2,
                                                   y: y - pointerSize * 30))
            let videoBounds = extent.insetBy(dx: extent.width * inset, dy: extent.height * inset)
            result = transformed.cropped(to: videoBounds)
                .composited(over: result).cropped(to: extent)
        }
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
