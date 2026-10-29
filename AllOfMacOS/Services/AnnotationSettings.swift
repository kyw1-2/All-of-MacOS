import Foundation

/// Annotate-editor preferences added in 3.3.3 (eraser). Kept out of
/// `CaptureSettings` on purpose: that file belongs to the capture/recording
/// stream. Integration should add `backedUpKeys` to the profile backup list.
enum AnnotationSettings {
    enum Key {
        static let eraserMode = "AOMAnnotationEraserMode"
        static let eraserSize = "AOMAnnotationEraserSize"
    }

    static var backedUpKeys: [String] { [Key.eraserMode, Key.eraserSize] }

    /// Object (whole annotations) or stroke (parts of pen strokes). Default object.
    static func eraserMode(_ defaults: UserDefaults = .standard) -> AnnotationEraserMode {
        AnnotationEraserMode(rawValue: defaults.string(forKey: Key.eraserMode) ?? "") ?? .object
    }

    static func setEraserMode(_ mode: AnnotationEraserMode, _ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Key.eraserMode)
    }

    /// Eraser radius in points, clamped to `AnnotationEraser.radiusRange`. Default 8.
    static func eraserSize(_ defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: Key.eraserSize) != nil else { return AnnotationEraser.defaultRadius }
        let value = CGFloat(defaults.double(forKey: Key.eraserSize))
        guard value.isFinite else { return AnnotationEraser.defaultRadius }
        return min(AnnotationEraser.radiusRange.upperBound, max(AnnotationEraser.radiusRange.lowerBound, value))
    }

    static func setEraserSize(_ size: CGFloat, _ defaults: UserDefaults = .standard) {
        guard size.isFinite else { return }
        let clamped = min(AnnotationEraser.radiusRange.upperBound, max(AnnotationEraser.radiusRange.lowerBound, size))
        defaults.set(Double(clamped), forKey: Key.eraserSize)
    }
}
