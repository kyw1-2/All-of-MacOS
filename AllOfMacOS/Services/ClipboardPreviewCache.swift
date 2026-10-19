import AppKit
import Foundation
import ImageIO

/// Keeps full-clip statistics and bounded preview decoding off the input loop.
/// Cached immutable render content includes attributed text; its UTF-16 size
/// contributes to the cache budget. Original image bytes are not retained.
final class ClipboardPreviewCache: @unchecked Sendable {
    static let shared = ClipboardPreviewCache()

    final class Content: NSObject, @unchecked Sendable {
        let summary: String
        let characterCount: Int?
        let image: CGImage?
        let attributedText: NSAttributedString?

        init(summary: String, characterCount: Int?, image: CGImage?, attributedText: NSAttributedString? = nil) {
            self.summary = summary
            self.characterCount = characterCount
            self.image = image
            self.attributedText = attributedText
        }
    }

    private let cache = NSCache<NSString, Content>()
    private let queue = DispatchQueue(label: "com.kyw.allofmacos.clipboard-preview", qos: .userInitiated)

    private init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 200
    }

    func content(for entry: ClipboardEntry) async -> Content {
        let key = "\(entry.id.uuidString):\(entry.contentVersion.uuidString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let cached = cache.object(forKey: key) {
                    continuation.resume(returning: cached)
                    return
                }
                let result = Self.makeContent(for: entry)
                let cost = (result.image?.bytesPerRow ?? 0) * (result.image?.height ?? 0)
                    + result.summary.utf8.count + (result.attributedText?.length ?? 0) * 2
                cache.setObject(result, forKey: key, cost: cost)
                continuation.resume(returning: result)
            }
        }
    }

    private static func makeContent(for entry: ClipboardEntry) -> Content {
        var image: CGImage?
        var dimensions: String?
        if let data = entry.imageData,
           let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                dimensions = "\(width) × \(height) pixels"
            }
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_200,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }

        let summary: String
        let characterCount: Int?
        let attributedText: NSAttributedString?
        if let text = entry.text {
            let characters = text.count
            let words = text.split(whereSeparator: \.isWhitespace).count
            let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
            summary = "\(characters.formatted()) characters · \(words.formatted()) words · \(lines.formatted()) lines"
            characterCount = characters
            if let rtf = entry.items.first?[NSPasteboard.PasteboardType.rtf.rawValue],
               let rich = try? NSAttributedString(data: rtf,
                    options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
               rich.string == text {
                attributedText = rich
            } else {
                attributedText = NSAttributedString(string: text,
                    attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
            }
        } else {
            characterCount = nil
            attributedText = nil
            let files = entry.fileURLs
            if !files.isEmpty { summary = "\(files.count) file(s)" }
            else { summary = dimensions ?? entry.kind.displayName }
        }
        return Content(summary: summary, characterCount: characterCount, image: image, attributedText: attributedText)
    }
}
