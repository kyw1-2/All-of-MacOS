import AppKit
import ImageIO
import Vision

/// Text inside image items, with where it is (parity gap P04: OCR region
/// search). Indexing keeps each recognised line's box, normalised to the
/// image with a top-left origin, so search can highlight a match inside the
/// picture and a selected region can be read or copied. Everything runs on
/// device through `TextRecognitionService`.
enum ClipboardImageText {
    /// A cap on stored lines keeps a dense screenshot from bloating the archive.
    static let maximumLines = 600

    struct Recognition: Equatable {
        var text: String
        var lines: [ClipboardOCRLine]
    }

    /// The options clipboard indexing has always used: line breaks kept,
    /// Vision only (Live Text is UI-oriented and slower), three script passes.
    static var indexingOptions: TextRecognitionOptions {
        var options = TextRecognitionOptions.fromSettings(keepsLineBreaks: true)
        options.engine = .vision
        options.maximumScriptPasses = 3
        return options
    }

    /// The full-resolution image, upright: EXIF orientation is applied, as in
    /// every preview, so boxes and crops line up with what the user sees.
    static func decodedImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        guard orientation != 1, max(width, height) > 0 else {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Text and line boxes of a whole image; nil when it cannot be read.
    static func recognize(imageData: Data, maximumLength: Int = 100_000) async -> Recognition? {
        guard let image = decodedImage(imageData) else { return nil }
        return await recognize(image, maximumLength: maximumLength)
    }

    static func recognize(_ image: CGImage, maximumLength: Int = 100_000) async -> Recognition? {
        guard let result = try? await TextRecognitionService.recognize(image, options: indexingOptions) else { return nil }
        return Recognition(text: String(result.text.prefix(maximumLength)),
                           lines: normalizedLines(result.lines.map { ($0.text, $0.box) }, imageSize: result.imageSize))
    }

    /// Pixel boxes (top-left origin) to unit boxes, clamped, empty lines
    /// dropped. Four decimals (under half a pixel on a 4,000-pixel image)
    /// keep the history archive small.
    static func normalizedLines(_ lines: [(text: String, box: CGRect)], imageSize: CGSize) -> [ClipboardOCRLine] {
        let width = max(1, imageSize.width), height = max(1, imageSize.height)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        func rounded(_ value: CGFloat) -> CGFloat { (value * 10_000).rounded() / 10_000 }
        return lines.compactMap { line -> ClipboardOCRLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let clamped = CGRect(x: line.box.minX / width, y: line.box.minY / height,
                                 width: line.box.width / width, height: line.box.height / height).intersection(unit)
            guard !text.isEmpty, !clamped.isNull else { return nil }
            let box = CGRect(x: rounded(clamped.minX), y: rounded(clamped.minY),
                             width: rounded(clamped.width), height: rounded(clamped.height))
            guard box.width > 0, box.height > 0 else { return nil }
            return ClipboardOCRLine(text: text, box: box)
        }.prefix(maximumLines).map { $0 }
    }

    /// Unit boxes of every occurrence of `terms` in `lines`. A match covers
    /// its share of the line box, measured in characters, which is close for
    /// the proportional and monospaced text screenshots usually hold.
    static func matchBoxes(in lines: [ClipboardOCRLine], terms: [String], limit: Int = 200) -> [CGRect] {
        let needles = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }
        var boxes: [CGRect] = []
        for line in lines {
            let total = max(1, line.text.count)
            for needle in needles {
                var cursor = line.text.startIndex
                while cursor < line.text.endIndex, boxes.count < limit,
                      let found = line.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                                  range: cursor..<line.text.endIndex) {
                    let start = line.text.distance(from: line.text.startIndex, to: found.lowerBound)
                    let length = max(1, line.text.distance(from: found.lowerBound, to: found.upperBound))
                    boxes.append(CGRect(x: line.box.minX + line.box.width * CGFloat(start) / CGFloat(total),
                                        y: line.box.minY,
                                        width: line.box.width * CGFloat(length) / CGFloat(total),
                                        height: line.box.height))
                    cursor = found.upperBound
                }
            }
        }
        return boxes
    }

    /// The text of stored lines that overlap `region` (unit, top-left), in
    /// reading order. Used when region recognition finds nothing.
    static func text(in region: CGRect, lines: [ClipboardOCRLine]) -> String {
        lines.filter { line in
            let overlap = line.box.intersection(region)
            return !overlap.isNull && overlap.width * overlap.height >= line.box.width * line.box.height * 0.3
        }
        .sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
        .map(\.text).joined(separator: "\n")
    }

    /// A unit region (top-left origin) as whole pixels inside the image, or
    /// nil when it is too small to read. Edges round to the nearest pixel, so
    /// floating-point noise never adds a stray row or column.
    static func pixelRect(for region: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect? {
        let unit = region.standardized
        guard imageWidth > 0, imageHeight > 0, unit.width.isFinite, unit.height.isFinite else { return nil }
        let width = CGFloat(imageWidth), height = CGFloat(imageHeight)
        let minX = (max(0, min(1, unit.minX)) * width).rounded(), maxX = (max(0, min(1, unit.maxX)) * width).rounded()
        let minY = (max(0, min(1, unit.minY)) * height).rounded(), maxY = (max(0, min(1, unit.maxY)) * height).rounded()
        guard maxX - minX >= 4, maxY - minY >= 4 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The selected part of the full-resolution image (never the preview).
    static func croppedImage(imageData: Data, region: CGRect) -> CGImage? {
        guard let image = decodedImage(imageData),
              let rect = pixelRect(for: region, imageWidth: image.width, imageHeight: image.height) else { return nil }
        return image.cropping(to: rect)
    }

    /// Reads the text inside `region`. Small crops are enlarged first, as
    /// Vision misses text only a few pixels tall; stored lines are the
    /// fallback when the crop reads as nothing.
    static func recognizeRegion(imageData: Data, region: CGRect, storedLines: [ClipboardOCRLine] = []) async -> String {
        if let crop = croppedImage(imageData: imageData, region: region) {
            let source = upscaled(crop, minimumSide: 64) ?? crop
            if let result = try? await TextRecognitionService.recognize(source, options: indexingOptions) {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return text(in: region, lines: storedLines)
    }

    private static func upscaled(_ image: CGImage, minimumSide: Int) -> CGImage? {
        let shortest = min(image.width, image.height)
        guard shortest > 0, shortest < minimumSide else { return nil }
        let scale = CGFloat(minimumSide) / CGFloat(shortest)
        let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
        guard width <= 8_192, height <= 8_192,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Where an aspect-fit image of `imageSize` sits inside `container`.
    static func fittedRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// A unit box placed on the fitted image rectangle.
    static func viewRect(for unit: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + unit.minX * fitted.width, y: fitted.minY + unit.minY * fitted.height,
               width: unit.width * fitted.width, height: unit.height * fitted.height)
    }

    /// A view-space rectangle as a unit region of the fitted image.
    static func unitRect(for viewRect: CGRect, in fitted: CGRect) -> CGRect {
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        let clipped = viewRect.standardized.intersection(fitted)
        guard !clipped.isNull else { return .zero }
        return CGRect(x: (clipped.minX - fitted.minX) / fitted.width, y: (clipped.minY - fitted.minY) / fitted.height,
                      width: clipped.width / fitted.width, height: clipped.height / fitted.height)
    }
}
