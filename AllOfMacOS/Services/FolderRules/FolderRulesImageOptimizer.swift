import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optimize Image (Clop-style): resizes images above a maximum side,
/// re-encodes JPEG and HEIC at a chosen quality, strips location, and can
/// turn PNG screenshots into JPEG or HEIC. The plan is pure; encoding uses
/// ImageIO. The original goes to the Trash (undoable) or is overwritten,
/// as the action says; a format change always keeps it in the Trash.
enum FolderRulesImageOptimizer {
    enum Format: String, Equatable {
        case jpeg, heic, png

        static func of(_ typeIdentifier: String?) -> Format? {
            guard let typeIdentifier, let type = UTType(typeIdentifier) else { return nil }
            if type.conforms(to: .jpeg) { return .jpeg }
            if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
            if type.conforms(to: .png) { return .png }
            return nil
        }

        var type: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .png: return .png
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .png: return "png"
            }
        }

        var title: String {
            switch self {
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .png: return "PNG"
            }
        }

        var isLossy: Bool { self != .png }
    }

    struct Plan: Equatable {
        var input: Format
        var output: Format
        var width: Int
        var height: Int
        var targetWidth: Int
        var targetHeight: Int
        /// Lossy outputs only.
        var quality: Double?
        var stripsLocation: Bool

        var resizes: Bool { targetWidth != width || targetHeight != height }
        var changesFormat: Bool { input != output }
    }

    /// The size that fits `maxDimension` on the longer side, keeping the
    /// aspect ratio; unchanged when it already fits or `maxDimension` is 0.
    static func targetSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard maxDimension > 0, longest > maxDimension, width > 0, height > 0 else { return (width, height) }
        let scale = Double(maxDimension) / Double(longest)
        let scaledWidth = width >= height ? maxDimension : max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = height > width ? maxDimension : max(1, Int((Double(height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }

    /// What the action would do with an image, or why it leaves it alone.
    static func plan(typeIdentifier: String?, width: Int, height: Int, isScreenshot: Bool,
                     options: FolderRuleImageOptions) -> Result<Plan, FolderRuleFailure> {
        guard let input = Format.of(typeIdentifier) else {
            return .failure(FolderRuleFailure("Only JPEG, HEIC and PNG images are optimized."))
        }
        guard width > 0, height > 0 else { return .failure(FolderRuleFailure("The image has no size.")) }
        var output = input
        if input == .png, isScreenshot {
            switch options.screenshotOutput {
            case .keep: break
            case .jpeg: output = .jpeg
            case .heic: output = .heic
            }
        }
        let target = targetSize(width: width, height: height, maxDimension: options.maxDimension)
        return .success(Plan(input: input, output: output, width: width, height: height,
                             targetWidth: target.width, targetHeight: target.height,
                             quality: output.isLossy ? options.clampedQuality : nil,
                             stripsLocation: options.stripLocation))
    }

    static var canEncodeHEIC: Bool {
        ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(UTType.heic.identifier)
    }

    /// Writes the image per `plan` to `destination` (a new file).
    static func encode(_ source: URL, plan: Plan, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw FolderRuleFailure("“\(source.lastPathComponent)” isn't a readable image.")
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        let image: CGImage?
        if plan.resizes {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(plan.targetWidth, plan.targetHeight),
                kCGImageSourceShouldCacheImmediately: true
            ]
            image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
            // The pixels are upright now.
            properties[kCGImagePropertyOrientation] = 1
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any], let image {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
        } else {
            image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else { throw FolderRuleFailure("“\(source.lastPathComponent)” couldn't be decoded.") }
        if plan.stripsLocation { properties.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyFileSize] {
            properties.removeValue(forKey: key)
        }
        if plan.changesFormat { properties.removeValue(forKey: kCGImagePropertyPNGDictionary) }
        if let quality = plan.quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if plan.output == .jpeg, hasAlpha {
            // JPEG has no transparency: a white background instead of black.
            properties[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1)
        }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, plan.output.type.identifier as CFString, 1, nil) else {
            throw FolderRuleFailure("This Mac can't write \(plan.output.title) images.")
        }
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw FolderRuleFailure("Couldn't write the optimized \(plan.output.title) image.")
        }
    }

    /// The pixel size as shown (EXIF orientations 5–8 swap the sides).
    static func orientedSize(_ properties: [CFString: Any]) -> (width: Int, height: Int)? {
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    static func optimize(_ item: URL, info: FolderRuleFileInfo, options: FolderRuleImageOptions,
                         environment: FolderRulesEnvironment) throws -> FolderRuleExecutor.Step {
        func skipped(_ reason: String) -> FolderRuleExecutor.Step {
            FolderRuleExecutor.Step(record: FolderRuleStepRecord(action: .optimizeImage, result: .skipped, summary: reason), next: item)
        }
        if FolderRuleMetadata.attribute(FolderRuleMetadata.optimizedAttribute, at: item.path) != nil {
            return skipped("Already optimized")
        }
        guard !info.isDirectory,
              let source = CGImageSourceCreateWithURL(item as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw FolderRuleFailure("“\(item.lastPathComponent)” isn't a readable image.")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            return skipped("Skipped: “\(item.lastPathComponent)” holds several images (animated or a sequence).")
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        guard let size = orientedSize(properties) else { throw FolderRuleFailure("“\(item.lastPathComponent)” has no pixel size.") }
        let typeIdentifier = (CGImageSourceGetType(source) as String?) ?? info.contentType
        let plan: Plan
        switch self.plan(typeIdentifier: typeIdentifier, width: size.width, height: size.height,
                         isScreenshot: info.isScreenCapture, options: options) {
        case .failure(let reason): return skipped("Skipped: \(reason.message)")
        case .success(let made): plan = made
        }
        if plan.output == .heic, !canEncodeHEIC { throw FolderRuleFailure("This Mac can't write HEIC images.") }
        let hasLocation = properties[kCGImagePropertyGPSDictionary] != nil
        let stripping = plan.stripsLocation && hasLocation
        guard plan.resizes || plan.changesFormat || plan.quality != nil || stripping else {
            FolderRuleMetadata.setAttribute(FolderRuleMetadata.optimizedAttribute, Data("1".utf8), at: item.path)
            return skipped("Nothing to optimize")
        }

        let fileManager = FileManager.default
        let parent = item.deletingLastPathComponent()
        let finalName = plan.changesFormat ? "\(info.baseName).\(plan.output.fileExtension)" : item.lastPathComponent
        // Hidden while it is written, so no rule picks up the half-made file.
        let temporary = parent.appendingPathComponent(".\(UUID().uuidString).aom-optimizing")
        defer { if FolderRulesSafety.exists(temporary.path) { try? fileManager.removeItem(at: temporary) } }
        try encode(item, plan: plan, to: temporary)

        let oldBytes = Int64((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int(info.size))
        let newBytes = Int64((try? temporary.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if !plan.resizes, !plan.changesFormat, !stripping, newBytes >= oldBytes {
            FolderRuleMetadata.setAttribute(FolderRuleMetadata.optimizedAttribute, Data("1".utf8), at: item.path)
            return skipped("Already optimized: re-encoding wouldn't make it smaller")
        }
        carryMetadata(from: item, to: temporary)
        FolderRuleMetadata.setAttribute(FolderRuleMetadata.optimizedAttribute, Data("1".utf8), at: temporary.path)

        var details = [sizeChange(oldBytes, newBytes)]
        if plan.resizes { details.append("\(plan.width)×\(plan.height) → \(plan.targetWidth)×\(plan.targetHeight)") }
        if stripping { details.append("location removed") }

        if options.original == .overwrite, !plan.changesFormat {
            _ = try fileManager.replaceItemAt(item, withItemAt: temporary)
            let summary = "Optimized: \(details.joined(separator: ", "))"
            return FolderRuleExecutor.Step(record: FolderRuleStepRecord(action: .optimizeImage, result: .done, summary: summary),
                                           next: item, produced: item)
        }
        let trashed = try environment.trash(item)
        let target = FolderRulePatterns.uniqueURL(parent.appendingPathComponent(finalName)) { FolderRulesSafety.exists($0.path) }
        do {
            try fileManager.moveItem(at: temporary, to: target)
        } catch {
            // Put the original back where it was before reporting.
            try? fileManager.moveItem(at: trashed, to: item)
            throw FolderRuleFailure.wrapping(error, "Couldn't save the optimized image.")
        }
        let formatNote = plan.changesFormat ? " as \(plan.output.title)" : ""
        let summary = "Optimized\(formatNote): \(details.joined(separator: ", ")); the original is in the Trash"
        return FolderRuleExecutor.Step(record: FolderRuleStepRecord(action: .optimizeImage, result: .done, summary: summary,
                                                                    undo: .restoreOriginal(trashed: trashed.path, original: item.path,
                                                                                           replacement: target.path)),
                                       next: target, produced: target)
    }

    /// "2.4 MB → 610 KB (−75%)".
    static func sizeChange(_ old: Int64, _ new: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let percent = old > 0 ? Int((Double(new - old) / Double(old) * 100).rounded()) : 0
        let sign = percent < 0 ? "−" : "+"
        return "\(formatter.string(fromByteCount: old)) → \(formatter.string(fromByteCount: new)) (\(sign)\(abs(percent))%)"
    }

    /// Tags, download source, the screenshot flag and the dates follow the
    /// image into its optimized file.
    private static func carryMetadata(from source: URL, to destination: URL) {
        for name in ["com.apple.metadata:_kMDItemUserTags", FolderRuleMetadata.whereFromsAttribute,
                     FolderRuleMetadata.screenCaptureAttribute, "com.apple.metadata:kMDItemScreenCaptureType",
                     "com.apple.quarantine"] {
            if let data = FolderRuleMetadata.attribute(name, at: source.path) {
                FolderRuleMetadata.setAttribute(name, data, at: destination.path)
            }
        }
        if let values = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            var attributes: [FileAttributeKey: Any] = [:]
            if let created = values.creationDate { attributes[.creationDate] = created }
            if let modified = values.contentModificationDate { attributes[.modificationDate] = modified }
            if !attributes.isEmpty { try? FileManager.default.setAttributes(attributes, ofItemAtPath: destination.path) }
        }
    }
}
