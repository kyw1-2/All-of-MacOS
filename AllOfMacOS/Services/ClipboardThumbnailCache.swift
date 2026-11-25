import Foundation
import ImageIO
import os

/// Decode bounded previews off the UI thread; selection never decodes full clipboard images.
final class ClipboardThumbnailCache: @unchecked Sendable {
    static let shared = ClipboardThumbnailCache()
    final class Preview: NSObject, @unchecked Sendable {
        let image: CGImage?
        let dimensions: String
        init(image: CGImage?, dimensions: String) { self.image = image; self.dimensions = dimensions }
    }
    private let cache = NSCache<NSString, Preview>()
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "com.kyw.allofmacos.clipboard-thumbnails", qos: .userInitiated)) {
        self.queue = queue
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 150
    }

    func preview(id: UUID, revision: UUID? = nil, data: Data) async -> Preview {
        await cancellablePreview(id: id, revision: revision, data: data) ?? Preview(image: nil, dimensions: "Image")
    }

    /// A cancelled request skips queued work and discards results from an
    /// ImageIO call already underway (ImageIO itself isn't interruptible).
    func cancellablePreview(id: UUID, revision: UUID? = nil, data: Data) async -> Preview? {
        guard !Task.isCancelled else { return nil }
        let key = "\(id.uuidString):\((revision ?? id).uuidString)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let preview: Preview? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !cancelled.withLock({ $0 }) else { continuation.resume(returning: nil); return }
                    if let cached = cache.object(forKey: key as NSString) { continuation.resume(returning: cached); return }
                    var image: CGImage?
                    var dimensions = "Image"
                    if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
                        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                           let width = properties[kCGImagePropertyPixelWidth] as? Int,
                           let height = properties[kCGImagePropertyPixelHeight] as? Int {
                            dimensions = "\(width) × \(height)"
                        }
                        guard !cancelled.withLock({ $0 }) else { continuation.resume(returning: nil); return }
                        image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 600,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary)
                    }
                    let result = Preview(image: image, dimensions: dimensions)
                    let didCache = cancelled.withLock { didCancel -> Bool in
                        guard !didCancel else { return false }
                        cache.setObject(result, forKey: key as NSString, cost: (image?.bytesPerRow ?? 0) * (image?.height ?? 0))
                        return true
                    }
                    continuation.resume(returning: didCache ? result : nil)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        return Task.isCancelled ? nil : preview
    }
}
