import AppKit
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Page lists typed by people: "1-3, 5, 8-" (8 to the end), "-4" (1 to
/// 4), "5-1" (backwards). Pages are 1-based as every PDF viewer shows them.
enum PageRanges {
    enum ParseError: LocalizedError, Equatable {
        case empty
        case notAPage(String)
        case outOfRange(Int, count: Int)

        var errorDescription: String? {
            switch self {
            case .empty: return "Type the pages, for example 1-3, 5."
            case .notAPage(let token): return "“\(token)” isn't a page or a range like 2-5."
            case .outOfRange(let page, let count):
                return "Page \(page) doesn't exist; the PDF has \(count) page\(count == 1 ? "" : "s")."
            }
        }
    }

    /// Each comma-separated part as its own list of pages, in the order
    /// written (one file per part when splitting by ranges).
    static func groups(_ text: String, pageCount: Int) throws -> [[Int]] {
        let parts = text.replacingOccurrences(of: ";", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ParseError.empty }
        return try parts.map { try pages(inPart: $0, pageCount: pageCount) }
    }

    /// Every page written, in order, repeats kept.
    static func pages(_ text: String, pageCount: Int) throws -> [Int] {
        try groups(text, pageCount: pageCount).flatMap { $0 }
    }

    /// Every page written, once each, ascending (remove and rotate).
    static func set(_ text: String, pageCount: Int) throws -> [Int] {
        Array(Set(try pages(text, pageCount: pageCount))).sorted()
    }

    private static func pages(inPart raw: String, pageCount: Int) throws -> [Int] {
        let part = raw.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " ", with: "")
        func number(_ text: Substring) throws -> Int {
            let lowered = text.lowercased()
            if lowered == "end" || lowered == "last" { return pageCount }
            guard let value = Int(text), value >= 1 else { throw ParseError.notAPage(raw) }
            guard value <= pageCount else { throw ParseError.outOfRange(value, count: pageCount) }
            return value
        }
        guard part.contains("-") else { return [try number(Substring(part))] }
        let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard ends.count == 2, !(ends[0].isEmpty && ends[1].isEmpty), !ends[1].contains("-") else {
            throw ParseError.notAPage(raw)
        }
        let first = ends[0].isEmpty ? 1 : try number(ends[0])
        let last = ends[1].isEmpty ? pageCount : try number(ends[1])
        return first <= last ? Array(first...last) : Array((last...first).reversed())
    }

    /// The new page order for Reorder Pages: the pages written first, in
    /// that order, then every page not written, in its original order. A
    /// page written twice is a mistake, not a copy.
    static func reorder(_ text: String, pageCount: Int) throws -> [Int] {
        let written = try pages(text, pageCount: pageCount)
        var seen = Set<Int>()
        for page in written where !seen.insert(page).inserted {
            throw ParseError.notAPage("page \(page) twice")
        }
        return written + (1...max(1, pageCount)).filter { !seen.contains($0) && $0 <= pageCount }
    }

    /// "1-3", "5", "7-9, 12" for file names and messages.
    static func describe(_ pages: [Int]) -> String {
        guard !pages.isEmpty else { return "" }
        var parts: [String] = []
        var start = pages[0], previous = pages[0]
        for page in pages.dropFirst() {
            if page == previous + 1 { previous = page; continue }
            parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
            start = page; previous = page
        }
        parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
        return parts.joined(separator: ", ")
    }
}

/// PDFgear-style page tools on PDFKit. Every tool writes a new file and
/// never changes the original; each returns what it wrote so the caller can
/// show it in Finder.
enum PDFTools {
    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case locked(String)
        case wrongPassword
        case notEncrypted(String)
        case empty
        case notWritten(String)
        case noImages
        case passwordsDiffer

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "“\(name)” isn't a PDF AOM can read."
            case .locked(let name): return "“\(name)” is password-protected. Remove its password first."
            case .wrongPassword: return "That password doesn't open the PDF."
            case .notEncrypted(let name): return "“\(name)” has no password."
            case .empty: return "The result would have no pages."
            case .notWritten(let name): return "“\(name)” couldn't be saved there."
            case .noImages: return "None of the chosen files is an image AOM can read."
            case .passwordsDiffer: return "The two passwords don't match."
            }
        }
    }

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable(url.lastPathComponent) }
        guard !document.isLocked else { throw Failure.locked(url.lastPathComponent) }
        return document
    }

    /// A document holding copies of `pages` (1-based) of `source`, in order.
    static func document(with pages: [Int], from source: PDFDocument) throws -> PDFDocument {
        let result = PDFDocument()
        for page in pages {
            guard let original = source.page(at: page - 1), let copy = original.copy() as? PDFPage else { continue }
            result.insert(copy, at: result.pageCount)
        }
        guard result.pageCount > 0 else { throw Failure.empty }
        return result
    }

    static func write(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        let written = options.isEmpty ? document.write(to: url) : document.write(to: url, withOptions: options)
        guard written else { throw Failure.notWritten(url.lastPathComponent) }
    }

    /// A name next to `url` that isn't taken: "Report (pages 1-3).pdf",
    /// "Report (pages 1-3) 2.pdf".
    static func freeURL(in folder: URL, base: String, ext: String = "pdf",
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = folder.appendingPathComponent(clean).appendingPathExtension(ext)
        var number = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(clean) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }

    // MARK: Split, extract, remove, rotate, reorder

    /// One file per page ("Report - Page 3.pdf") into `folder`.
    static func splitIntoPages(_ url: URL, into folder: URL) throws -> [URL] {
        let source = try open(url)
        let base = url.deletingPathExtension().lastPathComponent
        return try (1...max(1, source.pageCount)).map { page in
            let output = freeURL(in: folder, base: "\(base) - Page \(page)")
            try write(try document(with: [page], from: source), to: output)
            return output
        }
    }

    /// One file per part of `ranges` ("1-3, 4-6, 7-") into `folder`.
    static func split(_ url: URL, ranges: String, into folder: URL) throws -> [URL] {
        let source = try open(url)
        let groups = try PageRanges.groups(ranges, pageCount: source.pageCount)
        let base = url.deletingPathExtension().lastPathComponent
        return try groups.map { pages in
            let output = freeURL(in: folder, base: "\(base) (pages \(PageRanges.describe(pages)))")
            try write(try document(with: pages, from: source), to: output)
            return output
        }
    }

    /// The pages written, in that order, as a new PDF.
    static func extract(_ url: URL, pages text: String, to output: URL) throws -> Int {
        let source = try open(url)
        let pages = try PageRanges.pages(text, pageCount: source.pageCount)
        let result = try document(with: pages, from: source)
        try write(result, to: output)
        return result.pageCount
    }

    /// Every page except those written.
    static func remove(_ url: URL, pages text: String, to output: URL) throws -> Int {
        let source = try open(url)
        let removed = Set(try PageRanges.set(text, pageCount: source.pageCount))
        let kept = (1...max(1, source.pageCount)).filter { !removed.contains($0) }
        let result = try document(with: kept, from: source)
        try write(result, to: output)
        return result.pageCount
    }

    /// Rotates the pages written (empty: every page) by `degrees`
    /// (90, -90 or 180) on top of their current rotation.
    static func rotate(_ url: URL, pages text: String, degrees: Int, to output: URL) throws -> Int {
        let source = try open(url)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let chosen = trimmed.isEmpty ? Array(1...max(1, source.pageCount)) : try PageRanges.set(trimmed, pageCount: source.pageCount)
        let result = try document(with: Array(1...max(1, source.pageCount)), from: source)
        for page in chosen {
            guard let target = result.page(at: page - 1) else { continue }
            target.rotation = normalizedRotation(target.rotation + degrees)
        }
        try write(result, to: output)
        return chosen.count
    }

    static func normalizedRotation(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    /// Pages in the order written, then the rest in their original order.
    static func reorder(_ url: URL, order text: String, to output: URL) throws -> [Int] {
        let source = try open(url)
        let order = try PageRanges.reorder(text, pageCount: source.pageCount)
        try write(try document(with: order, from: source), to: output)
        return order
    }

    // MARK: Images ↔ PDF

    enum PageSize: String, CaseIterable, Sendable {
        case image, a4, letter
        var title: String {
            switch self {
            case .image: return "Page Size of Each Image"
            case .a4: return "A4 Pages"
            case .letter: return "US Letter Pages"
            }
        }
        /// Portrait size in points (1/72 in).
        var portrait: CGSize? {
            switch self {
            case .image: return nil
            case .a4: return CGSize(width: 595.28, height: 841.89)
            case .letter: return CGSize(width: 612, height: 792)
            }
        }
    }

    /// One page per image, in the order given. JPEGs are embedded as they
    /// are (no recompression); other images are drawn losslessly. A4 and
    /// Letter pages turn landscape for wide images and keep a 36 pt margin.
    static func imagesToPDF(_ images: [URL], pageSize: PageSize, to output: URL) throws -> Int {
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw Failure.notWritten(output.lastPathComponent)
        }
        var pages = 0
        for url in images {
            guard let image = loadImage(url) else { continue }
            let pixel = CGSize(width: image.cgImage.width, height: image.cgImage.height)
            let upright = image.orientation.swapsSides ? CGSize(width: pixel.height, height: pixel.width) : pixel
            // Points at the image's own resolution (72 dpi when it has none).
            let natural = CGSize(width: upright.width * 72 / image.dpi, height: upright.height * 72 / image.dpi)
            var box: CGRect
            var target: CGRect
            if let portrait = pageSize.portrait {
                let landscape = natural.width > natural.height
                let page = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
                box = CGRect(origin: .zero, size: page)
                let area = box.insetBy(dx: 36, dy: 36)
                let scale = min(area.width / natural.width, area.height / natural.height, 1)
                let size = CGSize(width: natural.width * scale, height: natural.height * scale)
                target = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
            } else {
                box = CGRect(origin: .zero, size: natural)
                target = box
            }
            context.beginPage(mediaBox: &box)
            draw(image, in: target, context: context)
            context.endPage()
            pages += 1
        }
        context.closePDF()
        guard pages > 0 else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.noImages
        }
        return pages
    }

    struct LoadedImage {
        let cgImage: CGImage
        let orientation: CGImagePropertyOrientation
        let dpi: CGFloat
    }

    static func loadImage(_ url: URL) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let dpiValue = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let dpi = CGFloat(dpiValue > 1 ? dpiValue : 72)
        let type = CGImageSourceGetType(source) as String?
        var image: CGImage?
        if type == UTType.jpeg.identifier, let provider = CGDataProvider(url: url as CFURL) {
            // Quartz writes a JPEG-backed image into the PDF unchanged.
            image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        if image == nil { image = CGImageSourceCreateImageAtIndex(source, 0, nil) }
        guard let image else { return nil }
        return LoadedImage(cgImage: image, orientation: orientation, dpi: dpi)
    }

    /// Draws the image upright (EXIF orientation applied) filling `rect`.
    private static func draw(_ image: LoadedImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        let w = rect.width, h = rect.height
        switch image.orientation {
        case .up: break
        case .upMirrored: context.translateBy(x: w, y: 0); context.scaleBy(x: -1, y: 1)
        case .down: context.translateBy(x: w, y: h); context.rotate(by: .pi)
        case .downMirrored: context.translateBy(x: 0, y: h); context.scaleBy(x: 1, y: -1)
        case .left: context.translateBy(x: w, y: 0); context.rotate(by: .pi / 2)
        case .leftMirrored: context.translateBy(x: w, y: h); context.scaleBy(x: 1, y: -1); context.rotate(by: .pi / 2)
        case .right: context.translateBy(x: 0, y: h); context.rotate(by: -.pi / 2)
        case .rightMirrored: context.rotate(by: -.pi / 2); context.scaleBy(x: -1, y: 1)
        }
        let drawSize = image.orientation.swapsSides ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        context.interpolationQuality = .high
        context.draw(image.cgImage, in: CGRect(origin: .zero, size: drawSize))
        context.restoreGState()
    }

    enum ImageFormat: String, CaseIterable, Sendable {
        case png, jpeg
        var title: String { self == .png ? "PNG" : "JPEG" }
        var type: UTType { self == .png ? .png : .jpeg }
        var ext: String { self == .png ? "png" : "jpg" }
    }

    static let dpiChoices: [Int] = [72, 150, 300]

    /// Every page as an image at `dpi` into `folder` ("Report - Page 1.png").
    /// Pages keep their rotation; transparent areas become white.
    static func pdfToImages(_ url: URL, format: ImageFormat, dpi: Int, into folder: URL,
                            isCancelled: () -> Bool = { false }) throws -> [URL] {
        let source = try open(url)
        let base = url.deletingPathExtension().lastPathComponent
        var outputs: [URL] = []
        for index in 0..<source.pageCount {
            if isCancelled() { break }
            guard let page = source.page(at: index), let image = render(page, dpi: dpi) else { continue }
            let output = freeURL(in: folder, base: "\(base) - Page \(index + 1)", ext: format.ext)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else {
                throw Failure.notWritten(output.lastPathComponent)
            }
            let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                               kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.notWritten(output.lastPathComponent) }
            outputs.append(output)
        }
        return outputs
    }

    /// The page's visible (crop) box at `dpi`, upright.
    static func render(_ page: PDFPage, dpi: Int) -> CGImage? {
        guard let ref = page.pageRef, dpi > 0 else { return nil }
        let box = ref.getBoxRect(.cropBox)
        let rotation = normalizedRotation(Int(ref.rotationAngle))
        let upright = rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
        let scale = CGFloat(dpi) / 72
        let width = max(1, Int((upright.width * scale).rounded())), height = max(1, Int((upright.height * scale).rounded()))
        guard width * height <= 400_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        let target = CGRect(origin: .zero, size: upright)
        context.concatenate(ref.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(ref)
        return context.makeImage()
    }

    // MARK: Passwords

    /// A copy that asks for `password` to open (the same password also
    /// guards printing and editing changes).
    static func protect(_ url: URL, password: String, to output: URL) throws {
        let document = try open(url)
        try write(document, to: output, options: [.userPasswordOption: password, .ownerPasswordOption: password])
        guard let check = PDFDocument(url: output), check.isEncrypted, check.isLocked, check.unlock(withPassword: password) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.notWritten(output.lastPathComponent)
        }
    }

    /// A copy without the password, once `password` opens it.
    static func unprotect(_ url: URL, password: String, to output: URL) throws {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable(url.lastPathComponent) }
        guard document.isEncrypted else { throw Failure.notEncrypted(url.lastPathComponent) }
        guard document.unlock(withPassword: password) else { throw Failure.wrongPassword }
        // Copying the pages into a new document drops the encryption
        // dictionary; writing the unlocked original could keep it.
        let plain = try self.document(with: Array(1...max(1, document.pageCount)), from: document)
        try write(plain, to: output)
        guard let check = PDFDocument(url: output), !check.isEncrypted else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.notWritten(output.lastPathComponent)
        }
    }

    // MARK: Page numbers

    enum NumberPosition: String, CaseIterable, Sendable {
        case bottomCenter, bottomRight, topRight
        var title: String {
            switch self {
            case .bottomCenter: return "Bottom Center"
            case .bottomRight: return "Bottom Right"
            case .topRight: return "Top Right"
            }
        }
    }

    enum NumberStyle: String, CaseIterable, Sendable {
        case plain, ofTotal
        func text(page: Int, total: Int) -> String {
            self == .plain ? "\(page)" : "Page \(page) of \(total)"
        }
    }

    /// Adds a page number to every page as a free-text annotation, so the
    /// page content itself, its links and its form fields stay untouched;
    /// viewers show and print it like page text. On a rotated page the
    /// annotation is marked NoRotate so it stays upright; a viewer that
    /// ignores that flag draws it sideways in the same place.
    static func addPageNumbers(_ url: URL, position: NumberPosition, style: NumberStyle, to output: URL) throws -> Int {
        let document = try open(url)
        let total = document.pageCount
        guard total > 0 else { throw Failure.empty }
        let font = NSFont.systemFont(ofSize: 10)
        for index in 0..<total {
            guard let page = document.page(at: index) else { continue }
            let text = style.text(page: index + 1, total: total)
            let size = (text as NSString).size(withAttributes: [.font: font])
            let width = ceil(size.width) + 8, height = ceil(size.height) + 4
            let bounds = numberRect(page: page, size: CGSize(width: width, height: height), position: position)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = font
            annotation.fontColor = .black
            annotation.color = .clear
            annotation.alignment = position == .bottomCenter ? .center : .right
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            annotation.shouldPrint = true
            if normalizedRotation(page.rotation) != 0 {
                // Print (4) + NoRotate (16), PDF 32000 table 165.
                annotation.setValue(NSNumber(value: 20), forAnnotationKey: .flags)
            }
            annotation.setValue("AOM page number", forAnnotationKey: .name)
            page.addAnnotation(annotation)
        }
        try write(document, to: output)
        return total
    }

    /// Where the number goes, 24 pt from the edges of the page as it is
    /// shown. On a rotated page the rectangle is anchored at the shown
    /// rectangle's upper-left corner (what NoRotate keeps fixed).
    static func numberRect(page: PDFPage, size: CGSize, position: NumberPosition) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        let margin: CGFloat = 24
        let rotation = normalizedRotation(page.rotation)
        let upright = rotation == 90 || rotation == 270 ? CGSize(width: crop.height, height: crop.width) : crop.size
        let origin: CGPoint
        switch position {
        case .bottomCenter: origin = CGPoint(x: (upright.width - size.width) / 2, y: margin)
        case .bottomRight: origin = CGPoint(x: upright.width - margin - size.width, y: margin)
        case .topRight: origin = CGPoint(x: upright.width - margin - size.width, y: upright.height - margin - size.height)
        }
        guard rotation != 0 else { return CGRect(origin: origin, size: size).offsetBy(dx: crop.minX, dy: crop.minY) }
        // The shown upper-left corner, back in page space (the page turns
        // clockwise by `rotation` when shown).
        let shown = CGPoint(x: origin.x, y: origin.y + size.height)
        let anchor: CGPoint
        switch rotation {
        case 90: anchor = CGPoint(x: crop.width - shown.y, y: shown.x)
        case 180: anchor = CGPoint(x: crop.width - shown.x, y: crop.height - shown.y)
        default: anchor = CGPoint(x: shown.y, y: crop.height - shown.x)
        }
        return CGRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
            .offsetBy(dx: crop.minX, dy: crop.minY)
    }
}

extension CGImagePropertyOrientation {
    /// Left and right orientations store the picture on its side.
    var swapsSides: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: return true
        default: return false
        }
    }
}
