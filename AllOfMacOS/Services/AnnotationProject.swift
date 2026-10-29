import AppKit
import ImageIO
import UniformTypeIdentifiers

/// AOM-owned, versioned document. The original pixels and editable objects are
/// intentionally retained; use image export when sharing a flattened redaction.
struct AnnotationProject: Codable {
    static let contentType = UTType(exportedAs: "com.kyw.allofmacos.annotation-project", conformingTo: .data)
    var version: Int = 1
    var imagePNG: Data
    var scale: CGFloat
    var crop: CGRect?
    var objects: [AnnotationObject]
    var background: AnnotationBackground

    init(document: AnnotationDocument, scale: CGFloat) throws {
        guard let data = NSBitmapImageRep(cgImage: document.baseImage).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        imagePNG = data
        self.scale = scale
        crop = document.cropRect
        objects = document.objects
        background = document.background
    }

    func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL, thumbnailMaxPixelSize: Int? = nil) throws -> (AnnotationDocument, CGFloat) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 300_000_000 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let project = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard project.version == 1, project.scale.isFinite, (0.25...8).contains(project.scale),
              project.objects.count <= 20_000,
              let source = CGImageSourceCreateWithData(project.imagePNG as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768,
              Int64(width) * Int64(height) <= 100_000_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func validRect(_ rect: CGRect) -> Bool {
            [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
                && rect.width >= 0 && rect.height >= 0
        }
        // 3.3.3: text styles, rotation and image layers are checked as well.
        func validAdditions(_ object: AnnotationObject) -> Bool {
            guard object.style.hasValidTextStyle else { return false }
            if let rotation = object.rotation, !(rotation.isFinite && abs(rotation) <= 100) { return false }
            if let image = object.image, !image.isValid { return false }
            return true
        }
        let imageBytes = project.objects.reduce(0) { $0 + ($1.image?.pngData.count ?? 0) }
        guard imageBytes <= 280_000_000, project.objects.allSatisfy(validAdditions) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard project.crop.map(validRect) ?? true,
              project.objects.allSatisfy({ object in
                  validRect(object.rect) && object.points.count <= 200_000 && object.text.utf8.count <= 1_000_000 &&
                  object.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 } &&
                  [object.style.thickness, object.style.fontSize, object.style.pixelBlockSize,
                   object.style.blurRadius, object.style.cornerRadius].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 10_000 } &&
                  object.style.opacity.isFinite && (0...1).contains(object.style.opacity)
              }), project.background.isValid else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let image: CGImage
        let renderScale: CGFloat
        if let maximum = thumbnailMaxPixelSize {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: min(1024, max(32, maximum)),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            image = thumbnail
            renderScale = project.scale * min(CGFloat(image.width) / CGFloat(width), CGFloat(image.height) / CGFloat(height))
        } else {
            guard let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
            image = original
            renderScale = project.scale
        }
        var document = AnnotationDocument(baseImage: image)
        document.cropRect = project.crop.map { rect in
            CGRect(x: rect.minX * CGFloat(image.width) / CGFloat(width),
                   y: rect.minY * CGFloat(image.height) / CGFloat(height),
                   width: rect.width * CGFloat(image.width) / CGFloat(width),
                   height: rect.height * CGFloat(image.height) / CGFloat(height))
        }
        document.objects = project.objects
        document.background = project.background
        if let maximum = thumbnailMaxPixelSize {
            // Quick Look thumbnails: decode image layers small too, under a new
            // asset id so a full-size open in the same process never sees them.
            let side = min(1024, max(32, maximum))
            document.objects = document.objects.map { object in
                guard let payload = object.image, max(payload.pixelWidth, payload.pixelHeight) > side else { return object }
                var small = object
                small.image = payload.downsampled(maximumSide: side)
                return small
            }
        }
        if thumbnailMaxPixelSize != nil {
            let canvas = document.backgroundLayout(scale: renderScale).canvasSize
            guard canvas.width <= 4096, canvas.height <= 4096, canvas.width * canvas.height <= 4_194_304 else {
                throw CocoaError(.fileReadTooLarge)
            }
        }
        return (document, renderScale)
    }
}

struct AnnotationStylePreset: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var style: AnnotationStyle

    static func load() -> [Self] {
        guard let data = UserDefaults.standard.data(forKey: "AOMAnnotationStylePresets") else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
    static func save(_ presets: [Self]) {
        guard let data = try? JSONEncoder().encode(Array(presets.prefix(30))) else { return }
        UserDefaults.standard.set(data, forKey: "AOMAnnotationStylePresets")
    }
}
