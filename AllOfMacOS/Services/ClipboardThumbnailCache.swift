import Foundation
import ImageIO

/// Decode bounded previews off the UI thread; selection never decodes full clipboard images.
final class ClipboardThumbnailCache: @unchecked Sendable {
    static let shared = ClipboardThumbnailCache()
    final class Preview: NSObject, @unchecked Sendable {
        let image: CGImage?
        let dimensions: String
        init(image: CGImage?, dimensions: String) { self.image = image; self.dimensions = dimensions }
    }
    private let cache = NSCache<NSString, Preview>()
    private let queue = DispatchQueue(label: "com.kyw.allofmacos.clipboard-thumbnails", qos: .userInitiated)

    private init() { cache.totalCostLimit = 48 * 1024 * 1024; cache.countLimit = 150 }

    func preview(id: UUID, revision: UUID? = nil, data: Data) async -> Preview {
        let key = "\(id.uuidString):\((revision ?? id).uuidString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let cached = cache.object(forKey: key) { continuation.resume(returning: cached); return }
                var image: CGImage?
                var dimensions = "Image"
                if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
                    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let width = properties[kCGImagePropertyPixelWidth] as? Int,
                       let height = properties[kCGImagePropertyPixelHeight] as? Int {
                        dimensions = "\(width) × \(height)"
                    }
                    image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }
                let result = Preview(image: image, dimensions: dimensions)
                cache.setObject(result, forKey: key, cost: (image?.bytesPerRow ?? 0) * (image?.height ?? 0))
                continuation.resume(returning: result)
            }
        }
    }
}
