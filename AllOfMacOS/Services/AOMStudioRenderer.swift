import Foundation
import CoreGraphics
import CoreImage

/// Non-proprietary, deterministic editing model for AOM's local video studio.
/// Keyframes are expressed in *trimmed timeline* seconds. No source MP4 is modified.
struct AOMStudioZoomKeyframe: Equatable, Identifiable {
    let id: UUID
    var time: Double
    var magnification: Double
    var focusX: Double
    var focusY: Double

    init(id: UUID = UUID(), time: Double, magnification: Double,
         focusX: Double = 0.5, focusY: Double = 0.5) {
        self.id = id
        self.time = time
        self.magnification = magnification
        self.focusX = focusX
        self.focusY = focusY
    }
}

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

struct AOMStudioSettings {
    var keyframes: [AOMStudioZoomKeyframe] = []
    var backdrop: AOMStudioBackdrop = .none
    var paddingFraction: Double = 0
    var motionBlurRadius: Double = 0

    var isActive: Bool {
        !keyframes.isEmpty || (backdrop != .none && paddingFraction > 0)
    }
}

/// Pure Core Image compositor for the captured video. It does not attempt to
/// recover cursor events baked into an MP4 or claim CleanShot's Smart Zoom AI.
enum AOMStudioRenderer {
    struct Focus: Equatable {
        var magnification: Double
        var x: Double
        var y: Double
    }

    static func sampledFocus(at time: Double,
                             keyframes: [AOMStudioZoomKeyframe]) -> Focus {
        let origin = Focus(magnification: 1, x: 0.5, y: 0.5)
        let sorted = keyframes.filter {
            $0.time.isFinite && $0.magnification.isFinite &&
            $0.focusX.isFinite && $0.focusY.isFinite &&
            $0.time >= 0 && $0.time < 86_400
        }.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return origin }
        var previousTime = 0.0
        var previous = origin
        for frame in sorted {
            let focus = Focus(magnification: min(4, max(1, frame.magnification)),
                              x: min(1, max(0, frame.focusX)),
                              y: min(1, max(0, frame.focusY)))
            if time <= frame.time {
                let span = frame.time - previousTime
                if span <= 0 { return focus }
                let position = min(1, max(0, (time - previousTime) / span))
                let smooth = position * position * (3 - 2 * position)
                return Focus(magnification: previous.magnification +
                    (focus.magnification - previous.magnification) * smooth,
                             x: previous.x + (focus.x - previous.x) * smooth,
                             y: previous.y + (focus.y - previous.y) * smooth)
            }
            previousTime = frame.time
            previous = focus
        }
        return previous
    }

    static func frame(_ image: CIImage, time: Double,
                      settings: AOMStudioSettings) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, !extent.isInfinite,
              extent.width <= 16384, extent.height <= 16384 else { return image }
        let f = sampledFocus(at: time, keyframes: settings.keyframes)
        let zoom = CGFloat(f.magnification)
        let focusX = extent.minX + CGFloat(f.x) * extent.width
        let focusY = extent.minY + CGFloat(f.y) * extent.height
        let offset = CGAffineTransform(translationX: focusX * (1 - zoom),
                                       y: focusY * (1 - zoom))
            .scaledBy(x: zoom, y: zoom)
        var result = image.transformed(by: offset).cropped(to: extent)

        let blur = min(8, max(0, settings.motionBlurRadius))
        if blur > 0, !settings.keyframes.isEmpty {
            // Bounded low-radius blur only during the 0.35s neighborhood of a
            // keyframe, not across every frame of a static, held zoom.
            let moving = settings.keyframes.contains { abs(time - $0.time) < 0.35 }
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
        return result
    }
}
