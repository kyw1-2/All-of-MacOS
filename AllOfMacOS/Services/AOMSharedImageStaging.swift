import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AOMSharedImageStaging {
    /// Validate image bytes rather than trusting provider filenames. Some valid
    /// providers return an extensionless NSURL even when PNG was requested.
    static func stage(_ item: NSSecureCoding, in directory: URL) throws -> URL? {
        let file = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        if let file, file.isFileURL {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 200_000_000,
                  let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let ext = validatedExtension(source) else { return nil }
            let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: file, to: target)
            return target
        }
        let data = (item as? Data) ?? (item as? NSImage)?.tiffRepresentation
        guard let data, data.count <= 200_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let ext = validatedExtension(source) else { return nil }
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: target, options: .withoutOverwriting)
        return target
    }

    private static func validatedExtension(_ source: CGImageSource) -> String? {
        guard let raw = CGImageSourceGetType(source), let type = UTType(raw as String), type.conforms(to: .image),
              let ext = type.preferredFilenameExtension,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768,
              Int64(width) * Int64(height) <= 100_000_000 else { return nil }
        return ext
    }
}
