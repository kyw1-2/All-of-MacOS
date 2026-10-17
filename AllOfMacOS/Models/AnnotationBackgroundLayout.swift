import AppKit
import CoreGraphics
import ImageIO

/// Pixel layout of the Background Tool canvas. All rects are top-left origin,
/// in output pixels, and integral so redaction edges never straddle a pixel.
struct AnnotationBackgroundLayout: Equatable {
    var canvasSize: CGSize
    /// The rounded frame: image + inset.
    var blockRect: CGRect
    /// Where the cropped image itself lands.
    var imageRect: CGRect

    /// - Parameters:
    ///   - imageSize: the cropped image, in pixels.
    ///   - content: uniform-border analysis of the image (needed for auto-balance).
    static func compute(imageSize: CGSize, background: AnnotationBackground, scale: CGFloat,
                        content: AnnotationContentBounds?) -> AnnotationBackgroundLayout {
        let image = CGRect(origin: .zero, size: imageSize)
        guard background.isExpanded, scale.isFinite, scale > 0 else {
            return AnnotationBackgroundLayout(canvasSize: imageSize, blockRect: image, imageRect: image)
        }
        let inset = (max(0, background.inset) * scale).rounded()
        let pad = (max(0, background.padding) * scale).rounded()
        let block = CGSize(width: imageSize.width + inset * 2, height: imageSize.height + inset * 2)

        // Auto-balance works on the visual content: uniform borders of the
        // screenshot count as empty space, so the content is what gets centred.
        let insets = background.autoBalance ? (content?.insets ?? .zero) : .zero
        let imbalanceX = abs(insets.right - insets.left)
        let imbalanceY = abs(insets.bottom - insets.top)

        var width = block.width + pad * 2
        var height = block.height + pad * 2
        if background.autoBalance {
            // Enough room to shift the content to the visual centre.
            width = max(width, block.width + imbalanceX)
            height = max(height, block.height + imbalanceY)
        }
        if let ratio = background.ratio.value {
            if width / height < ratio { width = (height * ratio).rounded(.up) }
            else { height = (width / ratio).rounded(.up) }
        }

        let column = min(max(background.alignment, 0), 8) % 3
        let row = min(max(background.alignment, 0), 8) / 3
        let freeX = width - block.width
        let freeY = height - block.height
        let x = position(free: freeX, cell: column, balanced: background.autoBalance,
                         leading: insets.left, trailing: insets.right)
        let y = position(free: freeY, cell: row, balanced: background.autoBalance,
                         leading: insets.top, trailing: insets.bottom)
        let blockRect = CGRect(x: x, y: y, width: block.width, height: block.height)
        return AnnotationBackgroundLayout(canvasSize: CGSize(width: width, height: height),
                                          blockRect: blockRect,
                                          imageRect: blockRect.insetBy(dx: inset, dy: inset))
    }

    /// Alignment hugs the chosen edge (0 / free), centres (free / 2) or, with
    /// auto-balance in a centred cell, offsets by half the border imbalance so
    /// equal *visual* margins remain on both sides.
    private static func position(free: CGFloat, cell: Int, balanced: Bool,
                                 leading: CGFloat, trailing: CGFloat) -> CGFloat {
        switch cell {
        case 0: return 0
        case 2: return free
        default:
            let centred = free / 2 + (balanced ? (trailing - leading) / 2 : 0)
            return min(max(0, centred), free).rounded()
        }
    }
}

/// Uniform-border analysis of a screenshot, for Auto Balance and Inset.
///
/// The border colour is the colour shared by most of the four corners (a
/// transparent corner counts as "transparent"). Rows / columns are trimmed
/// from each side while every pixel is within `tolerance` of that colour.
struct AnnotationContentBounds: Equatable {
    struct Insets: Equatable {
        var left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat
        static let zero = Insets(left: 0, top: 0, right: 0, bottom: 0)
    }

    var insets: Insets
    /// RGBA 0…255 of the uniform border (or the top-left pixel).
    var edgeRGBA: (UInt8, UInt8, UInt8, UInt8)

    var edgeColor: CGColor {
        CGColor(srgbRed: CGFloat(edgeRGBA.0) / 255, green: CGFloat(edgeRGBA.1) / 255,
                blue: CGFloat(edgeRGBA.2) / 255, alpha: CGFloat(edgeRGBA.3) / 255)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.insets == rhs.insets && lhs.edgeRGBA == rhs.edgeRGBA
    }

    /// Analysis is O(pixels); the editor re-renders often, so the last few
    /// images are cached by identity.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [(image: CGImage, bounds: AnnotationContentBounds)] = []

    static func cached(for image: CGImage) -> AnnotationContentBounds {
        cacheLock.lock()
        if let hit = cache.first(where: { $0.image === image }) { cacheLock.unlock(); return hit.bounds }
        cacheLock.unlock()
        let bounds = detect(in: image)
        cacheLock.lock()
        cache.insert((image, bounds), at: 0)
        if cache.count > 4 { cache.removeLast() }
        cacheLock.unlock()
        return bounds
    }

    static func detect(in image: CGImage, tolerance: Int = 10) -> AnnotationContentBounds {
        guard let buffer = AnnotationSecureRedaction.rgba(image) else {
            return AnnotationContentBounds(insets: .zero, edgeRGBA: (255, 255, 255, 255))
        }
        return detect(in: buffer, tolerance: tolerance)
    }

    static func detect(in buffer: AnnotationSecureRedaction.Buffer, tolerance: Int = 10) -> AnnotationContentBounds {
        let w = buffer.width, h = buffer.height
        let p = buffer.pixels
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]), Int(p[i + 3]))
        }
        func close(_ a: (Int, Int, Int, Int), _ b: (Int, Int, Int, Int)) -> Bool {
            if a.3 < 16 && b.3 < 16 { return true }
            return abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance
                && abs(a.2 - b.2) <= tolerance && abs(a.3 - b.3) <= tolerance
        }
        let corners = [pixel(0, 0), pixel(w - 1, 0), pixel(0, h - 1), pixel(w - 1, h - 1)]
        // The corner colour that the most corners agree on (ties: top-left first).
        let reference = corners.max { a, b in
            corners.filter { close($0, a) }.count < corners.filter { close($0, b) }.count
        } ?? corners[0]
        let edge = (UInt8(reference.0), UInt8(reference.1), UInt8(reference.2), UInt8(reference.3))

        func rowUniform(_ y: Int) -> Bool { (0..<w).allSatisfy { close(pixel($0, y), reference) } }
        func columnUniform(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            y0 > y1 || (y0...y1).allSatisfy { close(pixel(x, $0), reference) }
        }
        var top = 0
        while top < h && rowUniform(top) { top += 1 }
        guard top < h else {
            // Entirely uniform: nothing to balance.
            return AnnotationContentBounds(insets: .zero, edgeRGBA: edge)
        }
        var bottom = 0
        while bottom < h - top - 1 && rowUniform(h - 1 - bottom) { bottom += 1 }
        let y0 = top, y1 = h - 1 - bottom
        var left = 0
        while left < w && columnUniform(left, y0, y1) { left += 1 }
        var right = 0
        while right < w - left - 1 && columnUniform(w - 1 - right, y0, y1) { right += 1 }
        return AnnotationContentBounds(
            insets: Insets(left: CGFloat(left), top: CGFloat(top), right: CGFloat(right), bottom: CGFloat(bottom)),
            edgeRGBA: edge)
    }
}

/// macOS system desktop pictures, discovered at runtime (nothing is bundled).
///
/// `.madesktop` descriptors point at a small thumbnail; loose `.heic` files are
/// full-resolution. The rendered background uses the best file available.
enum AnnotationWallpaperLibrary {
    struct Wallpaper: Identifiable, Hashable {
        var id: String { path }
        var name: String
        /// File drawn behind the screenshot.
        var path: String
        /// Small preview for the sidebar grid.
        var thumbnailPath: String
    }

    static let systemDirectory = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var catalogCache: [String: [Wallpaper]] = [:]
    private static let imageCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 48
        return cache
    }()

    static func catalog(in directory: URL = systemDirectory) -> [Wallpaper] {
        lock.lock(); defer { lock.unlock() }
        if let cached = catalogCache[directory.path] { return cached }
        let found = scan(directory)
        catalogCache[directory.path] = found
        return found
    }

    static func scan(_ directory: URL) -> [Wallpaper] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let thumbs = directory.appendingPathComponent(".thumbnails", isDirectory: true)
        var result: [Wallpaper] = []
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let url = directory.appendingPathComponent(name)
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent
            if ["heic", "jpg", "jpeg", "png"].contains(ext) {
                let thumb = thumbs.appendingPathComponent(base + ".heic").path
                result.append(Wallpaper(name: base, path: url.path,
                                        thumbnailPath: fm.fileExists(atPath: thumb) ? thumb : url.path))
            } else if ext == "madesktop",
                      let data = try? Data(contentsOf: url), data.count < 64_000,
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let thumb = plist["thumbnailPath"] as? String,
                      thumb.hasPrefix(directory.path), fm.fileExists(atPath: thumb) {
                result.append(Wallpaper(name: base, path: thumb, thumbnailPath: thumb))
            }
        }
        return result
    }

    /// A decoded, downsampled wallpaper (cached).
    static func image(atPath path: String, maxPixelSize: Int) -> CGImage? {
        let size = max(64, min(8192, maxPixelSize))
        // Bucket sizes so a slider drag does not decode at every pixel.
        let bucket = Int(pow(2, ceil(log2(Double(size)))))
        let key = "\(path)#\(bucket)" as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }
}
