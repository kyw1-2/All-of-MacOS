import Foundation
import AppKit
import CoreGraphics
import CoreImage

/// One drawn object on the annotate canvas.
///
/// Objects are value types held in an ordered array rather than a node tree: the
/// editor only ever adds, moves, restyles and deletes, and z-order is exactly the
/// array order, so a tree would buy nothing.
struct AnnotationObject: Identifiable, Equatable, Codable {
    let id: UUID
    var kind: AnnotationKind
    /// The object's geometry, in canvas coordinates (top-left origin, points).
    var rect: CGRect
    var style: AnnotationStyle
    /// Text content, for `.text` and `.counter`.
    var text: String
    /// Freehand points, for `.draw` and `.drawHighlight`, relative to `rect`.
    var points: [CGPoint]

    init(id: UUID = UUID(), kind: AnnotationKind, rect: CGRect,
         style: AnnotationStyle = AnnotationStyle(), text: String = "", points: [CGPoint] = []) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.style = style
        self.text = text
        self.points = points
    }

    /// A human-readable summary for the layer list.
    var displayName: String {
        switch kind {
        case .text: return text.isEmpty ? "Text" : String(text.prefix(24))
        case .counter: return "Counter \(text)"
        default: return kind.displayName
        }
    }
}

/// The annotate tools, matching CleanShot's toolbar.
///
/// The set is the same because these are the tools a screenshot annotation
/// actually needs; nothing here is present only to mirror a competitor.
enum AnnotationKind: String, CaseIterable, Identifiable, Codable {
    case move
    case crop
    case arrow
    case line
    case rectangle
    case filledRectangle
    case ellipse
    case text
    case highlighter
    case draw
    case drawHighlight
    case pixelate
    case blur
    case redact
    case spotlight
    case counter
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .move: return "Move"
        case .crop: return "Crop & Resize"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        case .highlighter: return "Highlighter"
        case .draw: return "Draw"
        case .drawHighlight: return "Highlight Draw"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .redact: return "Redact (Solid)"
        case .spotlight: return "Spotlight"
        case .counter: return "Counter"
        case .cursor: return "Cursor"
        }
    }

    var iconName: String {
        switch self {
        case .move: return "hand.point.up.left"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .draw: return "scribble"
        case .drawHighlight: return "scribble.variable"
        case .pixelate: return "squareshape.dotted.split.2x2"
        case .blur: return "drop.halffull"
        case .redact: return "rectangle.fill"
        case .spotlight: return "flashlight.on.fill"
        case .counter: return "1.circle"
        case .cursor: return "cursorarrow"
        }
    }

    /// Whether the tool is drawn by dragging a rectangle.
    var isShape: Bool {
        switch self {
        case .arrow, .line, .rectangle, .filledRectangle, .ellipse,
             .pixelate, .blur, .redact, .spotlight, .draw, .drawHighlight, .highlighter:
            return true
        case .move, .crop, .text, .counter, .cursor:
            return false
        }
    }

    /// Freehand tools collect a point path instead of a rect.
    var isFreehand: Bool { self == .draw || self == .drawHighlight }

    /// The tools shown in the toolbar, in order.
    static var toolbarOrder: [AnnotationKind] {
        [.move, .crop, .arrow, .line, .rectangle, .filledRectangle, .ellipse,
         .text, .highlighter, .draw, .drawHighlight, .pixelate, .blur, .redact, .spotlight, .counter, .cursor]
    }
}

/// The annotate toolbar, in CleanShot X order with its single-letter keys
/// (V R F E L A T P H C D M, plus K crop and B background).
///
/// "Redact" covers AOM's three privacy kinds (pixelate / blur / black out),
/// chosen from the properties bar as CleanShot's "Redaction style".
/// "Marker" is AOM's rectangular highlighter, kept as an extra after the
/// CleanShot segments.
enum AnnotationToolbarItem: String, CaseIterable, Identifiable {
    case move, rectangle, filledRectangle, ellipse, line, arrow, text, redact,
         spotlight, counter, draw, highlighter
    case marker
    case crop, background

    var id: String { rawValue }

    /// The segmented tool group (CleanShot's 12 + AOM marker).
    static let segments: [AnnotationToolbarItem] = [
        .move, .rectangle, .filledRectangle, .ellipse, .line, .arrow, .text,
        .redact, .spotlight, .counter, .draw, .highlighter, .marker,
    ]

    var title: String {
        switch self {
        case .move: return "Move"
        case .rectangle: return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .redact: return "Redact"
        case .spotlight: return "Spotlight"
        case .counter: return "Counter"
        case .draw: return "Draw"
        case .highlighter: return "Highlighter"
        case .marker: return "Marker"
        case .crop: return "Crop"
        case .background: return "Background"
        }
    }

    var shortcut: Character? {
        switch self {
        case .move: return "v"
        case .rectangle: return "r"
        case .filledRectangle: return "f"
        case .ellipse: return "e"
        case .line: return "l"
        case .arrow: return "a"
        case .text: return "t"
        case .redact: return "p"
        case .spotlight: return "h"
        case .counter: return "c"
        case .draw: return "d"
        case .highlighter: return "m"
        case .marker: return nil
        case .crop: return "k"
        case .background: return "b"
        }
    }

    var help: String {
        guard let shortcut else { return title }
        return "\(title) (\(String(shortcut).uppercased()))"
    }

    var symbol: String {
        switch self {
        case .move: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .redact: return "eye.slash"
        case .spotlight: return "flashlight.on.fill"
        case .counter: return "1.circle.fill"
        case .draw: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .marker: return "rectangle.inset.filled"
        case .crop: return "crop"
        case .background: return "photo.artframe"
        }
    }

    /// Document kinds this item draws; the first is its default.
    var kinds: [AnnotationKind] {
        switch self {
        case .move: return [.move]
        case .rectangle: return [.rectangle]
        case .filledRectangle: return [.filledRectangle]
        case .ellipse: return [.ellipse]
        case .line: return [.line]
        case .arrow: return [.arrow]
        case .text: return [.text]
        case .redact: return [.pixelate, .blur, .redact]
        case .spotlight: return [.spotlight]
        case .counter: return [.counter]
        case .draw: return [.draw]
        case .highlighter: return [.drawHighlight]
        case .marker: return [.highlighter]
        case .crop: return [.crop]
        case .background: return []
        }
    }

    static func forShortcut(_ character: Character) -> AnnotationToolbarItem? {
        let lowered = Character(character.lowercased())
        return allCases.first { $0.shortcut == lowered }
    }

    static func item(for kind: AnnotationKind) -> AnnotationToolbarItem? {
        allCases.first { $0.kinds.contains(kind) }
    }
}

/// CleanShot "Redaction style" names for AOM's privacy kinds.
enum AnnotationRedactionStyle: CaseIterable, Identifiable {
    case pixelate, blur, blackOut
    var id: Self { self }

    var title: String {
        switch self {
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .blackOut: return "Black Out"
        }
    }

    var kind: AnnotationKind {
        switch self {
        case .pixelate: return .pixelate
        case .blur: return .blur
        case .blackOut: return .redact
        }
    }

    init?(kind: AnnotationKind) {
        switch kind {
        case .pixelate: self = .pixelate
        case .blur: self = .blur
        case .redact: self = .blackOut
        default: return nil
        }
    }
}

/// How an object is painted.
struct AnnotationStyle: Equatable, Codable {
    var color: AnnotationColor = .red
    var thickness: CGFloat = 3
    var fontSize: CGFloat = 24
    var opacity: Double = 1
    /// Arrow head shape, for `.arrow`.
    var arrowStyle: ArrowStyle = .standard
    /// Pixel block size for `.pixelate`, in output pixels.
    var pixelBlockSize: CGFloat = 16
    /// Gaussian radius in output pixels.
    var blurRadius: CGFloat = 8
    /// Corner radius for the rounded-rectangle tools.
    var cornerRadius: CGFloat = 0

    var customColorHex: String?
    var fontName: String?
    var bold: Bool?
    var italic: Bool?
    var textOutline: Bool?

    var resolvedColor: NSColor {
        guard let hex = customColorHex, hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return color.nsColor }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    func resolvedFont(size: CGFloat) -> NSFont {
        let base = fontName.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: (bold ?? true) ? .semibold : .regular)
        var traits: NSFontTraitMask = []
        if bold == true { traits.insert(.boldFontMask) }
        if italic == true { traits.insert(.italicFontMask) }
        return traits.isEmpty ? base : NSFontManager.shared.convert(base, toHaveTrait: traits)
    }

    init() {}
}

/// The preset colours, matching the swatch row CleanShot shows.
///
/// Stored as a fixed enum rather than a free colour so a preset saved on one
/// machine reads back identically on another, and so the palette stays a
/// deliberate set rather than drifting into arbitrary values.
enum AnnotationColor: String, CaseIterable, Identifiable, Codable {
    // Declaration order is the swatch order: CleanShot's palette, then gray.
    // Raw values are what is persisted, so reordering is format-compatible.
    case black, red, orange, yellow, green, turquoise, blue, purple, pink, white, gray

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    /// CleanShot X's default palette, in its order.
    static let palette: [AnnotationColor] = [.black, .red, .orange, .yellow, .green,
                                             .turquoise, .blue, .purple, .pink, .white]

    var nsColor: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)
        case .orange: return NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1)
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1)
        case .green: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .turquoise: return NSColor(srgbRed: 0.19, green: 0.78, blue: 0.80, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)
        case .pink: return NSColor(srgbRed: 1.00, green: 0.18, blue: 0.33, alpha: 1)
        case .black: return NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1)
        case .white: return NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
        case .gray: return NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
        }
    }
}

/// The four arrow head shapes CleanShot offers.
enum ArrowStyle: String, CaseIterable, Identifiable, Codable {
    case standard, curved, double, fancy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .curved: return "Curved"
        case .double: return "Double"
        case .fancy: return "Fancy"
        }
    }
}

/// The annotate document: the base image, the objects on it, and the crop.
///
/// Undo is a snapshot stack rather than per-object inverse operations. The
/// documents are small (a screenshot, not a video) and the operations are
/// structural, so snapshots are both simpler and impossible to get wrong.
struct AnnotationDocument {
    /// The unmodified capture. Every render starts from this.
    var baseImage: CGImage
    /// Crop applied to the base, in image pixel coordinates. Nil means uncropped.
    var cropRect: CGRect?
    var objects: [AnnotationObject] = []
    /// Background settings, applied behind the image when the canvas is expanded.
    var background: AnnotationBackground = AnnotationBackground()

    private var undoStack: [[AnnotationObject]] = []
    private var redoStack: [[AnnotationObject]] = []
    private var undoCrops: [CGRect?] = []
    private var redoCrops: [CGRect?] = []
    private var undoImages: [CGImage] = []
    private var redoImages: [CGImage] = []
    private var undoBackgrounds: [AnnotationBackground] = []
    private var redoBackgrounds: [AnnotationBackground] = []
    private let undoLimit = 50

    init(baseImage: CGImage) {
        self.baseImage = baseImage
    }

    /// The image after cropping but before annotation.
    var croppedImage: CGImage {
        guard let cropRect else { return baseImage }
        let bounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let clamped = cropRect.intersection(bounds).integral
        guard clamped.width >= 1, clamped.height >= 1 else { return baseImage }
        return baseImage.cropping(to: clamped) ?? baseImage
    }

    /// The canvas size in points, which is the cropped image's size unless the
    /// background has been expanded.
    func canvasSize(scale: CGFloat) -> CGSize {
        let base = CGSize(width: CGFloat(croppedImage.width) / scale,
                          height: CGFloat(croppedImage.height) / scale)
        guard background.isExpanded else { return base }
        return CGSize(width: base.width + background.padding * 2,
                      height: base.height + background.padding * 2)
    }

    // MARK: - Mutation

    mutating func beginChange() {
        undoStack.append(objects)
        undoCrops.append(cropRect)
        undoImages.append(baseImage)
        undoBackgrounds.append(background)
        if undoStack.count > undoLimit {
            undoStack.removeFirst()
            undoCrops.removeFirst()
            undoImages.removeFirst()
            undoBackgrounds.removeFirst()
        }
        // A new edit invalidates the redo branch, which is what every editor does.
        redoStack.removeAll()
        redoCrops.removeAll()
        redoImages.removeAll()
        redoBackgrounds.removeAll()
    }

    mutating func add(_ object: AnnotationObject) {
        beginChange()
        objects.append(object)
    }

    /// One undoable operation for multiple OCR-matched text highlight boxes.
    mutating func addObjects(_ additions: [AnnotationObject]) {
        guard !additions.isEmpty else { return }
        beginChange()
        objects.append(contentsOf: additions)
    }

    mutating func update(_ object: AnnotationObject) {
        guard let index = objects.firstIndex(where: { $0.id == object.id }) else { return }
        objects[index] = object
    }

    mutating func remove(_ id: UUID) {
        beginChange()
        objects.removeAll { $0.id == id }
    }

    mutating func removeAllObjects() {
        beginChange()
        objects.removeAll()
    }

    mutating func setCrop(_ rect: CGRect?) {
        beginChange()
        cropRect = rect
    }

    /// Appends a screenshot below the cropped image without shifting annotations.
    /// Undo restores both the previous base image and crop.
    @discardableResult
    mutating func appendScreenshot(_ image: CGImage, scale: CGFloat) -> Bool {
        guard scale.isFinite && scale > 0 else { return false }
        let old = croppedImage
        let width = max(old.width, image.width)
        let height = old.height + image.height
        guard width > 0, height > 0, width <= 16000, height <= 16000,
              Int64(width) * Int64(height) <= 100_000_000,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return false
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(old, in: CGRect(x: 0, y: image.height,
                                    width: old.width, height: old.height))
        context.draw(image, in: CGRect(x: 0, y: 0,
                                      width: image.width, height: image.height))
        guard let combined = context.makeImage() else { return false }
        beginChange()
        baseImage = combined
        cropRect = nil
        return true
    }

    /// Changes the image's physical pixel dimensions. Unlike a crop, resize
    /// resamples the bitmap, preserving editable annotations unless flattening
    /// is explicitly requested. All source validation happens before beginChange,
    /// so an invalid or failed resize leaves the document and undo history intact.
    @discardableResult
    mutating func resize(toPixelWidth width: Int, height: Int,
                         scale: CGFloat, flattenAnnotations: Bool = false) -> Bool {
        guard scale.isFinite, scale > 0,
              width > 0, height > 0, width <= 16384, height <= 16384,
              Int64(width) * Int64(height) <= 100_000_000 else { return false }

        let source: CGImage
        if flattenAnnotations {
            guard let rendered = render(scale: scale) else { return false }
            source = rendered
        } else {
            source = croppedImage
        }
        guard source.width > 0, source.height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return false
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resampled = context.makeImage() else { return false }

        let horizontal = CGFloat(width) / CGFloat(source.width)
        let vertical = CGFloat(height) / CGFloat(source.height)
        beginChange()
        baseImage = resampled
        cropRect = nil
        if flattenAnnotations {
            objects.removeAll()
            background = AnnotationBackground()
        } else {
            objects = objects.map { original in
                var updated = original
                updated.rect = CGRect(x: original.rect.minX * horizontal,
                                      y: original.rect.minY * vertical,
                                      width: original.rect.width * horizontal,
                                      height: original.rect.height * vertical)
                // Freehand points are absolute canvas positions, not local
                // offsets. The bounding rect and stroke path must both move.
                updated.points = original.points.map {
                    CGPoint(x: $0.x * horizontal, y: $0.y * vertical)
                }
                let thicknessFactor = min(horizontal, vertical)
                updated.style.thickness *= thicknessFactor
                updated.style.fontSize *= thicknessFactor
                updated.style.pixelBlockSize *= thicknessFactor
                updated.style.blurRadius *= thicknessFactor
                updated.style.cornerRadius *= thicknessFactor
                return updated
            }
        }
        return true
    }

    enum ImageTransform: CaseIterable {
        case rotateClockwise
        case rotateCounterclockwise
        case flipHorizontal
        case flipVertical
    }

    /// Pixel-accurate rotation and flipping. Rendering the editable layers
    /// first preserves existing arrows, glyphs and freehand geometry without
    /// silently rotating their selection handles incorrectly. Undo/redo saves
    /// the original *editable* layers and the background.
    @discardableResult
    mutating func transformImage(_ operation: ImageTransform, scale: CGFloat) -> Bool {
        guard scale.isFinite, scale > 0 else { return false }
        let needsFlattening = !objects.isEmpty || background.isExpanded
        guard let source = needsFlattening ? render(scale: scale) : Optional(croppedImage) else {
            return false
        }
        let sourceWidth = source.width
        let sourceHeight = source.height
        guard sourceWidth > 0, sourceHeight > 0 else { return false }
        let rotating = operation == .rotateClockwise || operation == .rotateCounterclockwise
        let width = rotating ? sourceHeight : sourceWidth
        let height = rotating ? sourceWidth : sourceHeight
        guard width <= 16384, height <= 16384,
              Int64(width) * Int64(height) <= 100_000_000,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return false
        }

        switch operation {
        case .rotateClockwise:
            context.translateBy(x: 0, y: CGFloat(sourceWidth))
            context.rotate(by: -.pi / 2)
        case .rotateCounterclockwise:
            context.translateBy(x: CGFloat(sourceHeight), y: 0)
            context.rotate(by: .pi / 2)
        case .flipHorizontal:
            context.translateBy(x: CGFloat(sourceWidth), y: 0)
            context.scaleBy(x: -1, y: 1)
        case .flipVertical:
            context.translateBy(x: 0, y: CGFloat(sourceHeight))
            context.scaleBy(x: 1, y: -1)
        }
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: 0, y: 0,
                                        width: sourceWidth, height: sourceHeight))
        guard let transformed = context.makeImage() else { return false }
        beginChange()
        baseImage = transformed
        cropRect = nil
        if needsFlattening {
            objects.removeAll()
            background = AnnotationBackground()
        }
        return true
    }

    /// Moves an object up or down the z-order.
    mutating func reorder(_ id: UUID, offset: Int) {
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard objects.indices.contains(destination) else { return }
        beginChange()
        objects.swapAt(index, destination)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func undo() {
        guard let previous = undoStack.last, let previousCrop = undoCrops.last,
              let previousImage = undoImages.last,
              let previousBackground = undoBackgrounds.last else { return }
        undoStack.removeLast()
        undoCrops.removeLast()
        undoImages.removeLast()
        undoBackgrounds.removeLast()
        redoStack.append(objects)
        redoCrops.append(cropRect)
        redoImages.append(baseImage)
        redoBackgrounds.append(background)
        objects = previous
        cropRect = previousCrop
        baseImage = previousImage
        background = previousBackground
    }

    mutating func redo() {
        guard let next = redoStack.last, let nextCrop = redoCrops.last,
              let nextImage = redoImages.last,
              let nextBackground = redoBackgrounds.last else { return }
        redoStack.removeLast()
        redoCrops.removeLast()
        redoImages.removeLast()
        redoBackgrounds.removeLast()
        undoStack.append(objects)
        undoCrops.append(cropRect)
        undoImages.append(baseImage)
        undoBackgrounds.append(background)
        objects = next
        cropRect = nextCrop
        baseImage = nextImage
        background = nextBackground
    }

    // MARK: - Rendering

    /// Renders the document to a `CGImage` at `scale` (the capture's backing scale).
    ///
    /// Rendering is done in one pass into a bitmap context rather than by
    /// compositing `NSImage`s, so the output is exactly the pixel grid the editor
    /// previewed and no resampling creeps in at export time.
    func render(scale: CGFloat, draft: AnnotationObject? = nil) -> CGImage? {
        guard scale.isFinite, scale > 0 else { return nil }
        let image = croppedImage
        let padding = background.isExpanded ? background.padding * scale : 0
        let width = Int(CGFloat(image.width) + padding * 2)
        let height = Int(CGFloat(image.height) + padding * 2)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }

        context.interpolationQuality = .high

        // Background fill behind an expanded canvas.
        if background.isExpanded {
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            switch background.kind {
            case .solid:
                context.setFillColor(background.color.nsColor.cgColor)
                context.fill(rect)
            case .gradient:
                drawGradient(in: context, rect: rect)
            case .blurred:
                let source = CIImage(cgImage: image)
                let blurred = source.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24 * scale])
                    .cropped(to: source.extent)
                guard let wallpaper = Self.blurCIContext.createCGImage(blurred, from: source.extent) else { return nil }
                let fill = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * fill, height: CGFloat(image.height) * fill)
                context.saveGState()
                context.clip(to: rect)
                context.draw(wallpaper, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                                  width: size.width, height: size.height))
                context.restoreGState()
            }
        }

        // The capture itself. CoreGraphics is bottom-left origin, so the image
        // sits at the bottom of the canvas and object coordinates are flipped below.
        let imageRect = CGRect(x: padding, y: padding, width: CGFloat(image.width), height: CGFloat(image.height))
        context.saveGState()
        if background.isExpanded {
            context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
                              color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }
        // Composite screenshot + annotations as one rounded floating layer so
        // both the preview and exported image share the same mask and shadow.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        let radius = background.isExpanded ? background.cornerRadius * scale : 0
        context.addPath(CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(image, in: imageRect)
        let renderedObjects = objects + (draft.map { [$0] } ?? [])
        for object in renderedObjects {
            draw(object, in: context, imageRect: imageRect, scale: scale, baseImage: image)
        }
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
        return context.makeImage()
    }

    private func drawGradient(in context: CGContext, rect: CGRect) {
        let stops = background.gradientColors
        let colors = stops.map(\.cgColor) as CFArray
        let locations = stops.indices.map { CGFloat($0) / CGFloat(max(1, stops.count - 1)) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                                   end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }

    /// Draws one object.
    ///
    /// `imageRect` is where the base image landed in the context, so an object's
    /// canvas-space rect converts to context space by adding that origin and
    /// flipping Y — object space is top-left origin because that is what SwiftUI
    /// gestures produce.
    private func draw(_ object: AnnotationObject, in context: CGContext,
                      imageRect: CGRect, scale: CGFloat, baseImage: CGImage) {
        let color = object.style.resolvedColor
        context.saveGState()
        context.setAlpha(CGFloat(object.style.opacity))

        let rect = CGRect(x: imageRect.minX + object.rect.minX * scale,
                          y: imageRect.maxY - (object.rect.maxY * scale),
                          width: object.rect.width * scale,
                          height: object.rect.height * scale)

        switch object.kind {
        case .rectangle:
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(object.style.thickness * scale)
            context.stroke(rect)
        case .filledRectangle:
            context.setFillColor(color.cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: object.style.cornerRadius * scale,
                              cornerHeight: object.style.cornerRadius * scale, transform: nil)
            context.addPath(path); context.fillPath()
        case .ellipse:
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(object.style.thickness * scale)
            context.strokeEllipse(in: rect)
        case .line:
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(object.style.thickness * scale)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.strokePath()
        case .arrow:
            drawArrow(object, in: context, rect: rect, color: color, scale: scale)
        case .text:
            drawText(object, in: context, rect: rect, color: color, scale: scale)
        case .counter:
            drawCounter(object, in: context, rect: rect, scale: scale)
        case .highlighter:
            context.setBlendMode(.multiply)
            context.setFillColor(color.withAlphaComponent(0.35).cgColor)
            context.fill(rect)
        case .draw, .drawHighlight:
            drawFreehand(object, in: context, imageRect: imageRect, color: color, scale: scale)
        case .redact:
            // Flattened opaque replacement. Never depend on the annotation's
            // alpha or editable layer color for privacy-sensitive redaction.
            context.setBlendMode(.normal)
            context.setAlpha(1)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(rect.intersection(imageRect))
        case .blur:
            drawGaussianBlur(in: context, rect: rect, scale: scale,
                             baseImage: baseImage, imageRect: imageRect, radius: object.style.blurRadius)
        case .pixelate:
            drawPixelate(in: context, rect: rect, scale: scale, baseImage: baseImage, imageRect: imageRect,
                         blockSize: object.style.pixelBlockSize)
        case .spotlight:
            // Dim everything except the rect: an even-odd fill of the whole image
            // minus the selection.
            let outer = CGRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: imageRect.height)
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            let path = CGMutablePath()
            path.addRect(outer)
            path.addRect(rect)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        case .cursor:
            drawCursor(in: context, rect: rect, color: color, scale: scale)
        case .move, .crop:
            break
        }
        context.restoreGState()
    }

    private func drawArrow(_ object: AnnotationObject, in context: CGContext,
                           rect: CGRect, color: NSColor, scale: CGFloat) {
        let thickness = object.style.thickness * scale
        let start = CGPoint(x: rect.minX, y: rect.maxY)
        let end = CGPoint(x: rect.maxX, y: rect.minY)
        let headLength = max(thickness * 3.2, 10 * scale)
        let angle = atan2(end.y - start.y, end.x - start.x)

        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(thickness)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch object.style.arrowStyle {
        case .standard:
            // Shaft stops short of the tip so the head is not doubled up.
            let shaftEnd = CGPoint(x: end.x - cos(angle) * headLength * 0.8,
                                   y: end.y - sin(angle) * headLength * 0.8)
            context.move(to: start); context.addLine(to: shaftEnd); context.strokePath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 7) * headLength,
                                        y: end.y - sin(angle - .pi / 7) * headLength))
            context.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 7) * headLength,
                                        y: end.y - sin(angle + .pi / 7) * headLength))
            context.closePath(); context.fillPath()
        case .double:
            context.move(to: start); context.addLine(to: end); context.strokePath()
            for (point, direction) in [(end, angle), (start, angle + .pi)] {
                context.move(to: point)
                context.addLine(to: CGPoint(x: point.x - cos(direction - .pi / 7) * headLength,
                                            y: point.y - sin(direction - .pi / 7) * headLength))
                context.addLine(to: CGPoint(x: point.x - cos(direction + .pi / 7) * headLength,
                                            y: point.y - sin(direction + .pi / 7) * headLength))
                context.closePath(); context.fillPath()
            }
        case .curved:
            // A quadratic bow, so the arrow arcs instead of cutting straight across.
            let control = CGPoint(x: (start.x + end.x) / 2 - (end.y - start.y) * 0.28,
                                  y: (start.y + end.y) / 2 + (end.x - start.x) * 0.28)
            let tangent = atan2(end.y - control.y, end.x - control.x)
            context.move(to: start)
            context.addQuadCurve(to: CGPoint(x: end.x - cos(tangent) * headLength * 0.7,
                                             y: end.y - sin(tangent) * headLength * 0.7),
                                 control: control)
            context.strokePath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - cos(tangent - .pi / 7) * headLength,
                                        y: end.y - sin(tangent - .pi / 7) * headLength))
            context.addLine(to: CGPoint(x: end.x - cos(tangent + .pi / 7) * headLength,
                                        y: end.y - sin(tangent + .pi / 7) * headLength))
            context.closePath(); context.fillPath()
        case .fancy:
            // A tapered tail: two edges that meet at the tip, giving a brush look.
            let perpendicular = angle + .pi / 2
            let halfWidth = max(thickness * 1.6, 4 * scale)
            context.move(to: end)
            context.addLine(to: CGPoint(x: start.x + cos(perpendicular) * halfWidth,
                                        y: start.y + sin(perpendicular) * halfWidth))
            context.addLine(to: CGPoint(x: start.x - cos(perpendicular) * halfWidth,
                                        y: start.y - sin(perpendicular) * halfWidth))
            context.closePath(); context.fillPath()
        }
    }

    private func drawText(_ object: AnnotationObject, in context: CGContext,
                          rect: CGRect, color: NSColor, scale: CGFloat) {
        guard !object.text.isEmpty else { return }
        let size = object.style.fontSize * scale
        let font = object.style.resolvedFont(size: size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            // A matching outline keeps the text readable over a light or a dark
            // screenshot without needing a background box.
            .strokeColor: NSColor.black.withAlphaComponent(0.55),
            .strokeWidth: (object.style.textOutline ?? true) ? -3.0 : 0.0
        ]
        let attributed = NSAttributedString(string: object.text, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }

    private func drawCounter(_ object: AnnotationObject, in context: CGContext, rect: CGRect, scale: CGFloat) {
        let diameter = max(rect.width, 24 * scale)
        let circle = CGRect(x: rect.minX, y: rect.minY, width: diameter, height: diameter)
        context.setFillColor(object.style.resolvedColor.cgColor)
        context.fillEllipse(in: circle)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(max(1.5, 2 * scale))
        context.strokeEllipse(in: circle)

        let size = min(diameter * 0.6, diameter * 0.75 / max(1, CGFloat(object.text.count) * 0.6))
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let attributed = NSAttributedString(string: object.text, attributes: [
            .font: font, .foregroundColor: NSColor.white
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: circle.midX - bounds.width / 2 - bounds.minX,
                                       y: circle.midY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }

    private func drawFreehand(_ object: AnnotationObject, in context: CGContext,
                              imageRect: CGRect, color: NSColor, scale: CGFloat) {
        guard object.points.count > 1 else { return }
        // Highlight draws translucent and under the content, like a marker.
        if object.kind == .drawHighlight {
            context.setBlendMode(.multiply)
            context.setAlpha(CGFloat(object.style.opacity) * 0.4)
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(object.style.thickness * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: imageRect.minX + object.points[0].x * scale,
                                 y: imageRect.maxY - object.points[0].y * scale))
        for point in object.points.dropFirst() {
            context.addLine(to: CGPoint(x: imageRect.minX + point.x * scale,
                                        y: imageRect.maxY - point.y * scale))
        }
        context.strokePath()
    }

    /// Non-destructive soft blur. Render a bounded slice of the underlying
    /// capture and composite it only inside the selected rectangle. Unlike
    /// .redact this is visual obfuscation, NOT irreversible privacy removal.
    private func drawGaussianBlur(in context: CGContext, rect: CGRect,
                                  scale: CGFloat, baseImage: CGImage,
                                  imageRect: CGRect, radius: CGFloat) {
        guard scale.isFinite, scale > 0, rect.width > 1, rect.height > 1 else { return }
        let clipped = rect.intersection(imageRect)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return }

        // Editor coordinates are top-left; CIImage uses a bottom-left extent.
        let inputX = clipped.minX - imageRect.minX
        let inputY = clipped.minY - imageRect.minY
        let inputRect = CGRect(x: inputX, y: inputY,
                               width: clipped.width,
                               height: clipped.height)
        let source = CIImage(cgImage: baseImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(1, radius), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return }
        let within = inputRect.intersection(source.extent)
        guard !within.isNull, within.width > 0, within.height > 0,
              let blurred = Self.blurCIContext.createCGImage(output, from: within) else { return }
        context.saveGState()
        context.setAlpha(1)
        context.setBlendMode(.normal)
        context.clip(to: clipped)
        context.draw(blurred, in: clipped)
        context.restoreGState()
    }

    private static let blurCIContext = CIContext(options: [.cacheIntermediates: false])

    /// Pixelates by drawing the source region scaled down and back up with no
    /// interpolation, which is both faster and blockier than a real mosaic filter.
    private func drawPixelate(in context: CGContext, rect: CGRect, scale: CGFloat,
                              baseImage: CGImage, imageRect: CGRect, blockSize: CGFloat) {
        let clipped = rect.intersection(imageRect).integral.intersection(imageRect)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return }
        let block = max(2, blockSize)
        // imageRect and clipped are already in output pixels. CGImage cropping
        // uses a top-left origin; dividing by Retina scale would sample elsewhere.
        let sourceRect = CGRect(x: clipped.minX - imageRect.minX,
                                y: imageRect.maxY - clipped.maxY,
                                width: clipped.width, height: clipped.height)
        guard let region = baseImage.cropping(to: sourceRect) else { return }
        let smallWidth = max(1, Int(ceil(clipped.width / block)))
        let smallHeight = max(1, Int(ceil(clipped.height / block)))
        guard let small = CGContext(data: nil, width: smallWidth, height: smallHeight,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(region, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let mosaic = small.makeImage() else { return }
        context.saveGState()
        context.setAlpha(1)
        context.setBlendMode(.normal)
        context.clip(to: clipped)
        context.interpolationQuality = .none
        context.draw(mosaic, in: clipped)
        context.restoreGState()
    }

    /// Draws the system arrow cursor, so a screenshot can show where the click was.
    private func drawCursor(in context: CGContext, rect: CGRect, color: NSColor, scale: CGFloat) {
        let size = max(rect.width, 20 * scale)
        let origin = CGPoint(x: rect.minX, y: rect.minY)
        let path = CGMutablePath()
        // A classic pointer outline, drawn as a filled polygon rather than an
        // SF Symbol so it renders identically at any size.
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -0.72), CGPoint(x: 0.18, y: -0.56),
            CGPoint(x: 0.30, y: -0.86), CGPoint(x: 0.44, y: -0.80), CGPoint(x: 0.32, y: -0.50),
            CGPoint(x: 0.55, y: -0.48), CGPoint(x: 0, y: 0)
        ]
        path.move(to: origin)
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: origin.x + point.x * size, y: origin.y + point.y * size))
        }
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(max(1, 1.5 * scale))
        context.strokePath()
    }
}

/// The background behind an expanded canvas.
struct AnnotationBackground: Equatable, Codable {
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case solid, gradient, blurred
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .solid: return "Solid"
            case .gradient: return "Gradient"
            case .blurred: return "Blurred"
            }
        }
    }

    enum GradientPreset: String, CaseIterable, Identifiable, Codable {
        case custom, sunset, ocean, sequoia
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .custom: return "Custom"
            case .sunset: return "Sunset"
            case .ocean: return "Ocean"
            case .sequoia: return "Sequoia"
            }
        }
    }

    var kind: Kind = .gradient
    var gradientPreset: GradientPreset = .custom
    var cornerRadius: CGFloat = 16
    var color: AnnotationColor = .gray
    var gradientStart: AnnotationColor = .purple
    var gradientEnd: AnnotationColor = .blue
    /// Padding around the image, in points. Zero means no expansion.
    var padding: CGFloat = 0

    var isExpanded: Bool { padding > 0 }

    var gradientColors: [NSColor] {
        let rgb: [(CGFloat, CGFloat, CGFloat)]
        switch gradientPreset {
        case .custom: return [gradientStart.nsColor, gradientEnd.nsColor]
        case .sunset: rgb = [(0.28, 0.12, 0.54), (0.76, 0.23, 0.54), (1, 0.48, 0.32), (1, 0.78, 0.48)]
        case .ocean: rgb = [(0.05, 0.12, 0.38), (0.08, 0.39, 0.75), (0.08, 0.70, 0.80), (0.55, 0.90, 0.85)]
        case .sequoia: rgb = [(0.12, 0.23, 0.20), (0.26, 0.42, 0.31), (0.64, 0.63, 0.38), (0.91, 0.71, 0.45)]
        }
        return rgb.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    }
}
