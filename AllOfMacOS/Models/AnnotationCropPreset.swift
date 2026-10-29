import CoreGraphics

/// Aspect ratios offered by the crop toolbar (3.3.3 adds the portrait,
/// photo and ultrawide ratios and "Original").
///
/// Compiled into the Quick Look extensions too (Models/Annotation*.swift).
enum AnnotationCropPreset: String, CaseIterable, Identifiable {
    case freeform, original, square, r16x9, r4x3, r3x2, r21x9, r9x16, r3x4, r2x3, r4x5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeform: return "Freeform"
        case .original: return "Original"
        case .square: return "Square"
        case .r16x9: return "16:9"
        case .r4x3: return "4:3"
        case .r3x2: return "3:2"
        case .r21x9: return "21:9"
        case .r9x16: return "9:16"
        case .r3x4: return "3:4"
        case .r2x3: return "2:3"
        case .r4x5: return "4:5"
        }
    }

    /// Width ÷ height; 0 means freeform. "Original" uses `imageSize`.
    func ratio(imageSize: CGSize) -> CGFloat {
        switch self {
        case .freeform: return 0
        case .original:
            guard imageSize.width > 0, imageSize.height > 0 else { return 0 }
            return imageSize.width / imageSize.height
        case .square: return 1
        case .r16x9: return 16.0 / 9.0
        case .r4x3: return 4.0 / 3.0
        case .r3x2: return 3.0 / 2.0
        case .r21x9: return 21.0 / 9.0
        case .r9x16: return 9.0 / 16.0
        case .r3x4: return 3.0 / 4.0
        case .r2x3: return 2.0 / 3.0
        case .r4x5: return 4.0 / 5.0
        }
    }

    /// The largest rect of `ratio` inside `bounds`, centred on `bounds` (what
    /// picking a preset selects before the user adjusts it).
    static func centredRect(ratio: CGFloat, in bounds: CGRect) -> CGRect {
        guard ratio > 0, ratio.isFinite, bounds.width > 0, bounds.height > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / ratio)
        if size.height > bounds.height { size = CGSize(width: bounds.height * ratio, height: bounds.height) }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
