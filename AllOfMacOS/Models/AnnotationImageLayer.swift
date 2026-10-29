import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Free image placement (CleanShot "combine images … position it however you
// like", audit CS-21). An inserted image is an annotation object of kind
// `.image`: it moves, resizes and rotates like the other objects, keeps its
// place in the z-order, and is saved inside the project.
//
// Compiled into the Quick Look extensions too (Models/Annotation*.swift).

/// The pixels of an image layer. The PNG travels inside the object, so undo
/// snapshots, the object clipboard and projects carry it; the decoded bitmap
/// is cached per asset.
struct AnnotationImagePayload: Codable, Equatable {
    /// Identifies the pixels; copies of a layer share it (and the cache entry).
    let assetID: UUID
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int

    static let maximumSide = 8192
    static let maximumPixels = 40_000_000
    static let maximumBytes = 80_000_000
    /// Inserted images with a longer side are downsampled before they are stored.
    static let insertionMaximumSide = 4096

    init?(image: CGImage, maximumSide: Int = AnnotationImagePayload.insertionMaximumSide) {
        guard image.width > 0, image.height > 0, maximumSide > 0 else { return nil }
        var stored = image
        let longest = max(image.width, image.height)
        if longest > maximumSide {
            let factor = CGFloat(maximumSide) / CGFloat(longest)
            let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
            let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let resized = context.makeImage() else { return nil }
            stored = resized
        }
        guard stored.width <= Self.maximumSide, stored.height <= Self.maximumSide,
              Int64(stored.width) * Int64(stored.height) <= Int64(Self.maximumPixels),
              let data = Self.png(stored), data.count <= Self.maximumBytes else { return nil }
        assetID = UUID()
        pngData = data
        pixelWidth = stored.width
        pixelHeight = stored.height
        AnnotationImageCache.store(stored, for: self)
    }

    /// Limits checked when a project or a pasted object is read.
    var isValid: Bool {
        pixelWidth > 0 && pixelHeight > 0 && pixelWidth <= Self.maximumSide && pixelHeight <= Self.maximumSide
            && Int64(pixelWidth) * Int64(pixelHeight) <= Int64(Self.maximumPixels)
            && !pngData.isEmpty && pngData.count <= Self.maximumBytes
    }

    /// The decoded bitmap, or nil when the data is not a PNG of the recorded size.
    var cgImage: CGImage? { AnnotationImageCache.image(for: self) }

    /// A smaller copy (new asset id) decoded straight at thumbnail size, for
    /// Quick Look; nil when the data cannot be decoded.
    func downsampled(maximumSide: Int) -> AnnotationImagePayload? {
        guard isValid, maximumSide > 0,
              let source = CGImageSourceCreateWithData(pngData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumSide,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return AnnotationImagePayload(image: thumbnail, maximumSide: maximumSide)
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Decoded image-layer bitmaps. Rendering runs on every canvas update, so the
/// PNG must not be decoded per frame.
enum AnnotationImageCache {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 768 * 1024 * 1024
        return cache
    }()

    private static func key(for payload: AnnotationImagePayload) -> NSString {
        "\(payload.assetID.uuidString)-\(payload.pngData.count)" as NSString
    }

    static func store(_ image: CGImage, for payload: AnnotationImagePayload) {
        cache.setObject(image, forKey: key(for: payload), cost: image.width * image.height * 4)
    }

    static func image(for payload: AnnotationImagePayload) -> CGImage? {
        let key = key(for: payload)
        if let cached = cache.object(forKey: key) { return cached }
        guard payload.isValid,
              let image = decode(payload.pngData, width: payload.pixelWidth, height: payload.pixelHeight) else {
            return nil
        }
        cache.setObject(image, forKey: key, cost: image.width * image.height * 4)
        return image
    }

    /// PNG only (a smaller decoder surface for files from elsewhere), and only
    /// at the size the payload claims.
    static func decode(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return image
    }
}

/// Geometry of rotated objects, in canvas space (top-left origin, points).
/// A positive angle turns clockwise on screen, like SwiftUI's `rotationEffect`.
enum AnnotationTransformGeometry {
    static func rotate(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
        guard angle != 0 else { return point }
        let dx = point.x - center.x, dy = point.y - center.y
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }

    /// Top-left, top-right, bottom-right, bottom-left after rotation.
    static func corners(of rect: CGRect, rotation: CGFloat) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            .map { rotate($0, around: center, by: rotation) }
    }

    static func boundingBox(of rect: CGRect, rotation: CGFloat) -> CGRect {
        guard rotation != 0 else { return rect }
        let points = corners(of: rect, rotation: rotation)
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func contains(_ point: CGPoint, rect: CGRect, rotation: CGFloat, tolerance: CGFloat = 0) -> Bool {
        let local = rotate(point, around: CGPoint(x: rect.midX, y: rect.midY), by: -rotation)
        return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
    }

    /// A handle on the rotated rect. `anchor` is in unit coordinates: x and y
    /// are each -1, 0 or 1 (-1, -1 is the top-left corner, 1, 0 the right edge).
    static func point(at anchor: CGPoint, of rect: CGRect, rotation: CGFloat) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let local = CGPoint(x: center.x + anchor.x * rect.width / 2, y: center.y + anchor.y * rect.height / 2)
        return rotate(local, around: center, by: rotation)
    }

    /// Resizes a rotated rect by dragging the handle at `anchor` to `pointer`.
    /// The opposite handle stays where it is on screen; the rect never flips.
    /// `keepAspect` (⇧) scales both sides by the same factor.
    static func resize(_ rect: CGRect, rotation: CGFloat, anchor: CGPoint, to pointer: CGPoint,
                       keepAspect: Bool, minimum: CGFloat = 4) -> CGRect {
        func unit(_ value: CGFloat) -> CGFloat { value < 0 ? -1 : (value > 0 ? 1 : 0) }
        let ax = unit(anchor.x), ay = unit(anchor.y)
        guard ax != 0 || ay != 0, rect.width > 0, rect.height > 0 else { return rect }
        let fixed = point(at: CGPoint(x: -ax, y: -ay), of: rect, rotation: rotation)
        // The pointer in the rect's own axes, measured from the fixed handle.
        let delta = rotate(pointer, around: fixed, by: -rotation)
        let dx = delta.x - fixed.x, dy = delta.y - fixed.y
        var width = ax == 0 ? rect.width : max(minimum, dx * ax)
        var height = ay == 0 ? rect.height : max(minimum, dy * ay)
        if keepAspect {
            let factor: CGFloat
            if ax != 0 && ay != 0 {
                factor = max(width / rect.width, height / rect.height)
            } else if ax != 0 {
                factor = width / rect.width
            } else {
                factor = height / rect.height
            }
            let floor = max(minimum / rect.width, minimum / rect.height)
            let scaled = max(factor, floor)
            width = rect.width * scaled
            height = rect.height * scaled
        }
        // From the fixed handle, half the new size towards the dragged handle.
        let offset = CGPoint(x: fixed.x + (ax == 0 ? 0 : ax * width / 2), y: fixed.y + (ay == 0 ? 0 : ay * height / 2))
        let center = rotate(offset, around: fixed, by: rotation)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    /// The rotation that points the top edge at `pointer`; ⇧ snaps to 15°.
    static func rotation(center: CGPoint, pointer: CGPoint, snap: Bool) -> CGFloat {
        var angle = atan2(pointer.y - center.y, pointer.x - center.x) + .pi / 2
        if snap {
            let step = CGFloat.pi / 12
            angle = (angle / step).rounded() * step
        }
        return normalized(angle)
    }

    /// The same angle in (-π, π].
    static func normalized(_ angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 0 }
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value <= -.pi { value += 2 * .pi }
        if value > .pi { value -= 2 * .pi }
        return abs(value) < 1e-9 ? 0 : value
    }
}

/// Z-order moves for the Arrange menu.
enum AnnotationArrangement: CaseIterable {
    case bringToFront, bringForward, sendBackward, sendToBack

    var title: String {
        switch self {
        case .bringToFront: return "Bring to Front"
        case .bringForward: return "Bring Forward"
        case .sendBackward: return "Send Backward"
        case .sendToBack: return "Send to Back"
        }
    }
}

extension AnnotationObject {
    /// Rotation in radians (clockwise on screen); non-finite values read as 0.
    var resolvedRotation: CGFloat {
        guard let rotation, rotation.isFinite else { return 0 }
        return rotation
    }

    /// A layer for `payload`, centred on `center`, no larger than `maximumSize`
    /// points, at the image's own point size (`imageScale` pixels per point).
    static func imageLayer(_ payload: AnnotationImagePayload, imageScale: CGFloat,
                           center: CGPoint, maximumSize: CGSize,
                           style: AnnotationStyle = AnnotationStyle()) -> AnnotationObject {
        let pixelsPerPoint = imageScale.isFinite && imageScale > 0 ? imageScale : 1
        var size = CGSize(width: CGFloat(payload.pixelWidth) / pixelsPerPoint,
                          height: CGFloat(payload.pixelHeight) / pixelsPerPoint)
        let fit = min(1, maximumSize.width / size.width, maximumSize.height / size.height)
        if fit.isFinite, fit > 0 { size = CGSize(width: size.width * fit, height: size.height * fit) }
        size = CGSize(width: max(4, size.width), height: max(4, size.height))
        var layerStyle = style
        layerStyle.opacity = 1
        return AnnotationObject(kind: .image,
                                rect: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                             width: size.width, height: size.height),
                                style: layerStyle, image: payload)
    }

    /// Draws an image layer; `rect` is in context space (bottom-left origin, pixels).
    static func drawImageLayer(_ object: AnnotationObject, in context: CGContext, rect: CGRect) {
        guard let image = object.image?.cgImage, rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        let rotation = object.resolvedRotation
        if rotation != 0 {
            // Canvas space turns clockwise for a positive angle; the context's
            // y axis points up, so the same turn is negative here.
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -rotation)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }
}

extension AnnotationDocument {
    /// The cropped image's size in points, where objects live.
    func imagePointSize(scale: CGFloat) -> CGSize {
        let image = croppedImage
        guard scale.isFinite, scale > 0 else { return CGSize(width: image.width, height: image.height) }
        return CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    /// Adds `image` as a movable layer on top of everything (one undo step) and
    /// returns its id. It is centred on `center` (default: the image centre)
    /// and fits in 60 % of the screenshot.
    @discardableResult
    mutating func insertImageLayer(_ image: CGImage, imageScale: CGFloat, scale: CGFloat,
                                   center: CGPoint? = nil, style: AnnotationStyle = AnnotationStyle()) -> UUID? {
        guard scale.isFinite, scale > 0, let payload = AnnotationImagePayload(image: image) else { return nil }
        let bounds = imagePointSize(scale: scale)
        let target = center ?? CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let object = AnnotationObject.imageLayer(payload, imageScale: imageScale, center: target,
                                                 maximumSize: CGSize(width: max(8, bounds.width * 0.6),
                                                                     height: max(8, bounds.height * 0.6)),
                                                 style: style)
        add(object)
        return object.id
    }

    /// Moves `ids` in the z-order as one undo step, keeping their order among
    /// themselves. Returns false when nothing moved.
    @discardableResult
    mutating func arrange(_ ids: Set<UUID>, _ arrangement: AnnotationArrangement) -> Bool {
        let selected = objects.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return false }
        var result = objects
        switch arrangement {
        case .bringToFront:
            result = objects.filter { !ids.contains($0.id) } + selected
        case .sendToBack:
            result = selected + objects.filter { !ids.contains($0.id) }
        case .bringForward:
            var index = result.count - 2
            while index >= 0 {
                if ids.contains(result[index].id), !ids.contains(result[index + 1].id) { result.swapAt(index, index + 1) }
                index -= 1
            }
        case .sendBackward:
            var index = 1
            while index < result.count {
                if ids.contains(result[index].id), !ids.contains(result[index - 1].id) { result.swapAt(index, index - 1) }
                index += 1
            }
        }
        guard result.map(\.id) != objects.map(\.id) else { return false }
        beginChange()
        objects = result
        return true
    }

    /// The screenshot with the image layers in `layers` drawn on it, in image
    /// pixels. Blur, pixelate and secure blur sample this when an image layer
    /// lies under them, so they hide the layer's pixels rather than the
    /// screenshot's.
    func compositeForRedaction(layers: [AnnotationObject], base: CGImage, scale: CGFloat) -> CGImage {
        let images = layers.filter { $0.kind == .image && $0.image != nil }
        guard !images.isEmpty, base.width > 0, base.height > 0,
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return base }
        let imageRect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: imageRect)
        for layer in images {
            context.saveGState()
            context.setAlpha(CGFloat(layer.style.opacity))
            let rect = CGRect(x: layer.rect.minX * scale, y: imageRect.maxY - layer.rect.maxY * scale,
                              width: layer.rect.width * scale, height: layer.rect.height * scale)
            AnnotationObject.drawImageLayer(layer, in: context, rect: rect)
            context.restoreGState()
        }
        return context.makeImage() ?? base
    }
}
