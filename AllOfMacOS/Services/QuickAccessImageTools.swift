import AppKit
import CoreGraphics

enum QuickAccessImageTools {
    /// Retina -> point-resolution pixel output, without changing the source.
    static func downscaleToOneX(_ image: CGImage, pointSize: CGSize) -> CGImage? {
        let width = max(1, Int(pointSize.width.rounded()))
        let height = max(1, Int(pointSize.height.rounded()))
        guard width < image.width || height < image.height else { return image }
        return draw(image, width: width, height: height)
    }

    static func flippedHorizontally(_ image: CGImage) -> CGImage? {
        draw(image, width: image.width, height: image.height, flipX: true)
    }

    static func rotatedLeft(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: image.height, height: image.width,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Counter-clockwise quarter turn: (x, y) -> (H - y, x), so the original
        // top edge becomes the left edge (CleanShot "Rotate Left").
        context.translateBy(x: CGFloat(image.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Arbitrary pixel resize used by the Quick Access "Resize…" command.
    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768 else { return nil }
        return draw(image, width: width, height: height)
    }

    /// Height that keeps the aspect ratio for a requested width (and vice versa).
    static func proportionalSide(_ requested: Int, original: Int, otherOriginal: Int) -> Int {
        guard original > 0 else { return max(1, otherOriginal) }
        return max(1, Int((Double(requested) * Double(otherOriginal) / Double(original)).rounded()))
    }

    private static func draw(_ image: CGImage, width: Int, height: Int,
                             flipX: Bool = false) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        if flipX {
            context.translateBy(x: CGFloat(width), y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
