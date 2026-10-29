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
    /// Freehand points, for `.draw` and `.drawHighlight` (absolute canvas
    /// positions), and the start and end of a `.line` or `.arrow` (3.3.3).
    var points: [CGPoint]
    /// The pixels of an `.image` layer (3.3.3). Absent on every other kind.
    var image: AnnotationImagePayload?
    /// Rotation in radians around the rect's centre, clockwise on screen.
    /// Only image layers rotate (3.3.3); nil means upright.
    var rotation: CGFloat?

    init(id: UUID = UUID(), kind: AnnotationKind, rect: CGRect,
         style: AnnotationStyle = AnnotationStyle(), text: String = "", points: [CGPoint] = [],
         image: AnnotationImagePayload? = nil, rotation: CGFloat? = nil) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.style = style
        self.text = text
        self.points = points
        self.image = image
        self.rotation = rotation
    }

    /// A human-readable summary for the layer list.
    var displayName: String {
        switch kind {
        case .text: return text.isEmpty ? "Text" : String(text.prefix(24))
        case .counter: return "Counter \(text)"
        case .image: return image.map { "Image \($0.pixelWidth) × \($0.pixelHeight)" } ?? "Image"
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
    /// Pixelate, then blur and add noise: an irreversible, opaque redaction.
    case secureBlur
    case redact
    case spotlight
    case counter
    case cursor
    /// The eraser tool (3.3.3). Never stored as an object.
    case eraser
    /// A free-placed image layer (3.3.3).
    case image

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
        case .secureBlur: return "Secure Blur"
        case .redact: return "Redact (Solid)"
        case .spotlight: return "Spotlight"
        case .counter: return "Counter"
        case .cursor: return "Cursor"
        case .eraser: return "Eraser"
        case .image: return "Image"
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
        case .secureBlur: return "lock.rectangle"
        case .redact: return "rectangle.fill"
        case .spotlight: return "flashlight.on.fill"
        case .counter: return "1.circle"
        case .cursor: return "cursorarrow"
        case .eraser: return "eraser"
        case .image: return "photo"
        }
    }

    /// Whether the tool is drawn by dragging a rectangle.
    var isShape: Bool {
        switch self {
        case .arrow, .line, .rectangle, .filledRectangle, .ellipse,
             .pixelate, .blur, .secureBlur, .redact, .spotlight, .draw, .drawHighlight, .highlighter:
            return true
        case .move, .crop, .text, .counter, .cursor, .eraser, .image:
            return false
        }
    }

    /// Freehand tools collect a point path instead of a rect.
    var isFreehand: Bool { self == .draw || self == .drawHighlight }

    /// The tools shown in the toolbar, in order.
    static var toolbarOrder: [AnnotationKind] {
        [.move, .crop, .arrow, .line, .rectangle, .filledRectangle, .ellipse,
         .text, .highlighter, .draw, .drawHighlight, .pixelate, .blur, .secureBlur, .redact, .spotlight,
         .counter, .cursor, .eraser, .image]
    }

    /// Privacy kinds (the Redact tool's styles).
    var isRedaction: Bool { self == .pixelate || self == .blur || self == .secureBlur || self == .redact }

    /// Redactions that sample the pixels under them (Black Out only fills).
    var samplesPixelsBelow: Bool { self == .pixelate || self == .blur || self == .secureBlur }

    /// Kinds whose exported pixels are opaque replacements that cannot be
    /// reversed (Black Out, Secure Blur). Plain Blur / Pixelate are visual only.
    var isSecureRedaction: Bool { self == .secureBlur || self == .redact }
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
    /// 3.3.3: the eraser follows the marker; image layers are inserted from a button.
    case eraser
    case crop, background, imageLayer

    var id: String { rawValue }

    /// The segmented tool group (CleanShot's 12 + AOM marker + eraser).
    static let segments: [AnnotationToolbarItem] = [
        .move, .rectangle, .filledRectangle, .ellipse, .line, .arrow, .text,
        .redact, .spotlight, .counter, .draw, .highlighter, .marker, .eraser,
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
        case .eraser: return "Eraser"
        case .crop: return "Crop"
        case .background: return "Background"
        case .imageLayer: return "Insert Image Layer"
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
        case .eraser: return "x"
        case .crop: return "k"
        case .background: return "b"
        case .imageLayer: return nil
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
        case .eraser: return "eraser"
        case .crop: return "crop"
        case .background: return "photo.artframe"
        case .imageLayer: return "photo.on.rectangle"
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
        case .redact: return [.pixelate, .blur, .secureBlur, .redact]
        case .spotlight: return [.spotlight]
        case .counter: return [.counter]
        case .draw: return [.draw]
        case .highlighter: return [.drawHighlight]
        case .marker: return [.highlighter]
        case .eraser: return [.eraser]
        case .crop: return [.crop]
        case .background: return []
        case .imageLayer: return [.image]
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
    case pixelate, blur, secureBlur, blackOut
    var id: Self { self }

    var title: String {
        switch self {
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .secureBlur: return "Secure Blur"
        case .blackOut: return "Black Out"
        }
    }

    var symbol: String {
        switch self {
        case .pixelate: return "squareshape.split.3x3"
        case .blur: return "drop.halffull"
        case .secureBlur: return "lock.rectangle"
        case .blackOut: return "rectangle.fill"
        }
    }

    /// Tooltip text that is honest about what can be recovered.
    var help: String {
        switch self {
        case .pixelate: return "Pixelate — visual only; large blocks can still hint at the content"
        case .blur: return "Blur — visual only; not safe for passwords or IDs"
        case .secureBlur: return "Secure Blur — pixelated, blurred and noised so the original cannot be recovered"
        case .blackOut: return "Black Out — opaque fill that replaces the pixels"
        }
    }

    var kind: AnnotationKind {
        switch self {
        case .pixelate: return .pixelate
        case .blur: return .blur
        case .secureBlur: return .secureBlur
        case .blackOut: return .redact
        }
    }

    init?(kind: AnnotationKind) {
        switch kind {
        case .pixelate: self = .pixelate
        case .blur: self = .blur
        case .secureBlur: self = .secureBlur
        case .redact: self = .blackOut
        default: return nil
        }
    }
}

/// Spotlight tool cutout shapes.
enum SpotlightShape: String, CaseIterable, Identifiable, Codable {
    case rectangle, ellipse
    var id: Self { self }
    var displayName: String { rawValue.capitalized }
}

/// Counter sequence formatting styles.
enum CounterStyle: String, CaseIterable, Identifiable, Codable {
    case numbers, upperAlpha, lowerAlpha, roman
    var id: Self { self }
    var displayName: String {
        switch self {
        case .numbers: return "1, 2, 3"
        case .upperAlpha: return "A, B, C"
        case .lowerAlpha: return "a, b, c"
        case .roman: return "I, II, III"
        }
    }
    func format(_ value: Int) -> String {
        switch self {
        case .numbers: return "\(value)"
        case .upperAlpha:
            let clamped = max(1, min(702, value))
            return Self.toAlpha(clamped, uppercase: true)
        case .lowerAlpha:
            let clamped = max(1, min(702, value))
            return Self.toAlpha(clamped, uppercase: false)
        case .roman:
            return Self.toRoman(max(1, min(3999, value)))
        }
    }
    private static func toAlpha(_ num: Int, uppercase: Bool) -> String {
        var n = num
        var s = ""
        while n > 0 {
            n -= 1
            let char = Character(UnicodeScalar((uppercase ? 65 : 97) + (n % 26))!)
            s = String(char) + s
            n /= 26
        }
        return s
    }
    private static func toRoman(_ num: Int) -> String {
        let mapping: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var n = num
        var result = ""
        for (value, numeral) in mapping {
            while n >= value {
                result += numeral
                n -= value
            }
        }
        return result
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
    /// Shape for `.spotlight`.
    var spotlightShape: SpotlightShape?
    /// Outer dimming opacity for `.spotlight`.
    var spotlightOpacity: Double?
    /// Sequence formatting for `.counter`.
    var counterStyle: CounterStyle?

    var customColorHex: String?
    var fontName: String?
    var bold: Bool?
    var italic: Bool?
    var textOutline: Bool?

    // C03 text styles (3.3.3). Defined with their rendering in
    // AnnotationTextStyle.swift; nil keeps the 3.3.2 look.
    /// Explicit weight; nil uses `bold` (semibold or regular), as before.
    var fontWeight: AnnotationFontWeight?
    var textAlignment: AnnotationTextAlignment?
    /// A box behind the text; nil or `.none` means no box.
    var textBackground: AnnotationTextBackground?
    /// Box colour, RRGGBB(AA). nil: the box uses the main colour.
    var textBackgroundHex: String?
    /// Glyph colour, RRGGBB(AA). nil: the main colour, or black/white over a
    /// box drawn in the main colour.
    var textColorHex: String?
    /// Outline colour, RRGGBB(AA). nil: black at 55 %.
    var textOutlineHex: String?
    /// Outline width in percent of the font size. nil: the thin 3.3.2 edge.
    var textOutlineWidth: CGFloat?
    var textShadow: Bool?

    var resolvedColor: NSColor {
        guard let hex = customColorHex, hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return color.nsColor }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    func resolvedFont(size: CGFloat) -> NSFont {
        if let weight = fontWeight {
            // 3.3.3: an explicit weight. `fontName` holds a family name from
            // the font picker; `NSFont(name:)` alone misses most families.
            let wantsItalic = italic == true
            var font = fontName.flatMap { family in
                NSFontManager.shared.font(withFamily: family, traits: wantsItalic ? .italicFontMask : [],
                                          weight: weight.fontManagerWeight, size: size)
                    ?? NSFont(name: family, size: size)
            } ?? NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
            if wantsItalic, !font.fontDescriptor.symbolicTraits.contains(.italic) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            return font
        }
        let base = fontName.flatMap { NSFont(name: $0, size: size) }
            ?? fontName.flatMap { family in
                NSFontManager.shared.font(withFamily: family, traits: [],
                                          weight: (bold ?? true) ? 8 : 5, size: size)
            }
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
        let layout = backgroundLayout(scale: scale)
        return CGSize(width: layout.canvasSize.width / scale, height: layout.canvasSize.height / scale)
    }

    /// Where the (cropped) image's top-left lands on the canvas, in points.
    func imageOrigin(scale: CGFloat) -> CGPoint {
        let layout = backgroundLayout(scale: scale)
        return CGPoint(x: layout.imageRect.minX / scale, y: layout.imageRect.minY / scale)
    }

    /// Pixel layout of the background canvas (padding, inset, ratio, alignment,
    /// auto-balance). Identity layout when the background is off.
    func backgroundLayout(scale: CGFloat) -> AnnotationBackgroundLayout {
        let image = croppedImage
        let size = CGSize(width: image.width, height: image.height)
        let needsAnalysis = background.isExpanded && (background.autoBalance || background.inset > 0)
        let analysis = needsAnalysis ? AnnotationContentBounds.cached(for: image) : nil
        return AnnotationBackgroundLayout.compute(imageSize: size, background: background,
                                                  scale: scale, content: analysis)
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
        combine(image, placement: .bottom, scale: scale)
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

    /// Swaps in same-size pixels (Remove Background) as one undoable step;
    /// annotations stay editable on top.
    mutating func replaceBaseImage(_ image: CGImage) -> Bool {
        guard image.width == baseImage.width, image.height == baseImage.height else { return false }
        beginChange()
        baseImage = image
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
        let layout = backgroundLayout(scale: scale)
        let width = Int(layout.canvasSize.width)
        let height = Int(layout.canvasSize.height)
        guard width > 0, height > 0, width <= 32768, height <= 32768,
              Int64(width) * Int64(height) <= 200_000_000,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }

        context.interpolationQuality = .high
        let expanded = background.isExpanded
        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)

        // Background fill behind an expanded canvas.
        if expanded {
            drawBackgroundFill(in: context, rect: canvasRect, image: image, scale: scale)
        }

        // Layout rects are top-left origin; CoreGraphics is bottom-left.
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
        }
        let imageRect = flipped(layout.imageRect)
        let blockRect = flipped(layout.blockRect)
        context.saveGState()
        if expanded, background.shadow > 0 {
            let amount = min(1, max(0, background.shadow))
            context.setShadow(offset: CGSize(width: 0, height: -20 * amount * scale), blur: 40 * amount * scale,
                              color: NSColor.black.withAlphaComponent(0.7 * amount).cgColor)
        }
        // Composite screenshot + annotations as one rounded floating layer so
        // both the preview and exported image share the same mask and shadow.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        let radius = expanded ? min(background.cornerRadius * scale, min(blockRect.width, blockRect.height) / 2) : 0
        context.addPath(CGPath(roundedRect: blockRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        if expanded, layout.imageRect != layout.blockRect {
            // Inset: the screenshot's own edge colour extends around it.
            let fill = AnnotationContentBounds.cached(for: image).edgeColor
            context.setFillColor(fill)
            context.fill(blockRect)
        }
        context.draw(image, in: imageRect)
        let renderedObjects = objects + (draft.map { [$0] } ?? [])
        drawObjects(renderedObjects, in: context, imageRect: imageRect, scale: scale, base: image)
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
        return context.makeImage()
    }

    /// Draws `list` in z-order. Blur, pixelate and secure blur sample the
    /// screenshot plus the image layers below them (3.3.3), so a redaction
    /// over an inserted image hides that image's pixels.
    private func drawObjects(_ list: [AnnotationObject], in context: CGContext, imageRect: CGRect,
                             scale: CGFloat, base: CGImage) {
        var source = base
        var layerSinceSource = false
        // 3.3.3: several spotlights share one dimmed layer with every cutout,
        // instead of each dimming the others' bright areas.
        let spotlights = list.filter { $0.kind == .spotlight }
        var spotlightsDrawn = false
        for (index, object) in list.enumerated() {
            if object.kind == .image { layerSinceSource = true }
            if layerSinceSource, object.kind.samplesPixelsBelow {
                source = compositeForRedaction(layers: Array(list[..<index]), base: base, scale: scale)
                layerSinceSource = false
            }
            if spotlights.count > 1, object.kind == .spotlight {
                if !spotlightsDrawn {
                    drawMergedSpotlights(spotlights, in: context, imageRect: imageRect, scale: scale)
                    spotlightsDrawn = true
                }
                continue
            }
            draw(object, in: context, imageRect: imageRect, scale: scale, baseImage: source)
        }
    }

    /// Every spotlight cutout punched out of one dim layer, drawn at the lowest
    /// spotlight's place in the z-order with the topmost spotlight's dimming.
    private func drawMergedSpotlights(_ spotlights: [AnnotationObject], in context: CGContext,
                                      imageRect: CGRect, scale: CGFloat) {
        guard let lowest = spotlights.first, let topmost = spotlights.last else { return }
        context.saveGState()
        context.setAlpha(CGFloat(lowest.style.opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(NSColor.black.withAlphaComponent(topmost.style.spotlightOpacity ?? 0.55).cgColor)
        context.fill(imageRect)
        context.setBlendMode(.clear)
        for spotlight in spotlights {
            let rect = CGRect(x: imageRect.minX + spotlight.rect.minX * scale,
                              y: imageRect.maxY - spotlight.rect.maxY * scale,
                              width: spotlight.rect.width * scale, height: spotlight.rect.height * scale)
            if spotlight.style.spotlightShape == .ellipse {
                context.fillEllipse(in: rect)
            } else {
                context.fill(rect)
            }
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// The base image with `subset` drawn on it and no background (flattening).
    /// With `drawsBase == false` only the objects are drawn on transparency
    /// (privacy kinds still sample the base image, so they render correctly).
    func renderFlat(objects subset: [AnnotationObject], scale: CGFloat, drawsBase: Bool = true) -> CGImage? {
        guard scale.isFinite, scale > 0 else { return nil }
        let image = croppedImage
        guard image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.interpolationQuality = .high
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if drawsBase { context.draw(image, in: imageRect) }
        drawObjects(subset, in: context, imageRect: imageRect, scale: scale, base: image)
        return context.makeImage()
    }

    /// A PNG-ready rendering of just these objects, cropped to their bounds
    /// (for "Copy Object" to other apps). Nil when nothing visible remains.
    func renderObjectsImage(ids: Set<UUID>, scale: CGFloat) -> CGImage? {
        let subset = objects.filter { ids.contains($0.id) }
        guard !subset.isEmpty, let full = renderFlat(objects: subset, scale: scale, drawsBase: false) else { return nil }
        let bounds = subset.map { $0.visualBounds }.reduce(CGRect.null) { $0.union($1) }
        let pixels = CGRect(x: bounds.minX * scale, y: bounds.minY * scale,
                            width: bounds.width * scale, height: bounds.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        // CGImage cropping uses a top-left origin, matching object space.
        return full.cropping(to: pixels)
    }

    private func drawBackgroundFill(in context: CGContext, rect: CGRect, image: CGImage, scale: CGFloat) {
        switch background.kind {
        case .solid:
            context.setFillColor(background.resolvedSolidColor.cgColor)
            context.fill(rect)
        case .gradient:
            drawGradient(in: context, rect: rect)
        case .wallpaper:
            if let path = background.wallpaperPath,
               let wallpaper = AnnotationWallpaperLibrary.image(atPath: path,
                                                                maxPixelSize: Int(max(rect.width, rect.height))) {
                drawAspectFill(wallpaper, in: context, rect: rect)
            } else {
                drawGradient(in: context, rect: rect)
            }
        case .blurred:
            let source = CIImage(cgImage: image)
            let blurred = source.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24 * scale])
                .cropped(to: source.extent)
            guard let wallpaper = Self.blurCIContext.createCGImage(blurred, from: source.extent) else {
                context.setFillColor(NSColor.gray.cgColor)
                context.fill(rect)
                return
            }
            drawAspectFill(wallpaper, in: context, rect: rect)
        }
    }

    private func drawAspectFill(_ picture: CGImage, in context: CGContext, rect: CGRect) {
        let fill = max(rect.width / CGFloat(max(1, picture.width)), rect.height / CGFloat(max(1, picture.height)))
        let size = CGSize(width: CGFloat(picture.width) * fill, height: CGFloat(picture.height) * fill)
        context.saveGState()
        context.clip(to: rect)
        context.draw(picture, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                         width: size.width, height: size.height))
        context.restoreGState()
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
            let (start, end) = contextEndpoints(of: object, imageRect: imageRect, scale: scale)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(object.style.thickness * scale)
            context.setLineCap(.round)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        case .arrow:
            let (start, end) = contextEndpoints(of: object, imageRect: imageRect, scale: scale)
            drawArrow(object, in: context, from: start, to: end, color: color, scale: scale)
        case .text:
            AnnotationTextRenderer.draw(object, in: context, rect: rect, scale: scale)
        case .image:
            AnnotationObject.drawImageLayer(object, in: context, rect: rect)
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
            // Integral bounds: an anti-aliased edge would blend original pixels.
            let target = rect.intersection(imageRect).integral.intersection(imageRect)
            guard !target.isNull else { break }
            context.setBlendMode(.copy)
            context.setAlpha(1)
            context.setShouldAntialias(false)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(target)
        case .secureBlur:
            drawSecureBlur(in: context, rect: rect, scale: scale, baseImage: baseImage, imageRect: imageRect,
                           blockSize: object.style.pixelBlockSize, seed: object.id)
        case .blur:
            drawGaussianBlur(in: context, rect: rect, scale: scale,
                             baseImage: baseImage, imageRect: imageRect, radius: object.style.blurRadius)
        case .pixelate:
            drawPixelate(in: context, rect: rect, scale: scale, baseImage: baseImage, imageRect: imageRect,
                         blockSize: object.style.pixelBlockSize)
        case .spotlight:
            // Dim everything except the shape: an even-odd fill of the whole image
            // minus the selection.
            let outer = CGRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: imageRect.height)
            let opacity = object.style.spotlightOpacity ?? 0.55
            context.setFillColor(NSColor.black.withAlphaComponent(opacity).cgColor)
            let path = CGMutablePath()
            path.addRect(outer)
            if object.style.spotlightShape == .ellipse {
                path.addEllipse(in: rect)
            } else {
                path.addRect(rect)
            }
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        case .cursor:
            drawCursor(in: context, rect: rect, color: color, scale: scale)
        case .move, .crop, .eraser:
            break
        }
        context.restoreGState()
    }

    /// A line's or arrow's ends in context space (bottom-left origin, pixels).
    private func contextEndpoints(of object: AnnotationObject, imageRect: CGRect,
                                  scale: CGFloat) -> (CGPoint, CGPoint) {
        let (start, end) = object.lineEndpoints
        func convert(_ point: CGPoint) -> CGPoint {
            CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.maxY - point.y * scale)
        }
        return (convert(start), convert(end))
    }

    private func drawArrow(_ object: AnnotationObject, in context: CGContext,
                           from start: CGPoint, to end: CGPoint, color: NSColor, scale: CGFloat) {
        let thickness = object.style.thickness * scale
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

    /// Irreversible redaction: the region is reduced to a coarse mosaic (the
    /// only data that survives), blurred, mixed with deterministic noise and
    /// written back as fully opaque pixels. Any output pixel that still equals
    /// its original value is nudged, so no source pixel survives verbatim.
    private func drawSecureBlur(in context: CGContext, rect: CGRect, scale: CGFloat, baseImage: CGImage,
                                imageRect: CGRect, blockSize: CGFloat, seed: UUID) {
        let clipped = rect.intersection(imageRect).integral.intersection(imageRect)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        let sourceRect = CGRect(x: clipped.minX - imageRect.minX, y: imageRect.maxY - clipped.maxY,
                                width: clipped.width, height: clipped.height)
        guard let region = baseImage.cropping(to: sourceRect),
              let output = AnnotationSecureRedaction.secureBlur(region: region,
                                                                blockSize: max(12 * scale, blockSize),
                                                                seed: seed) else {
            // Fail closed: if the secure pipeline cannot run, black the region out.
            context.saveGState()
            context.setAlpha(1)
            context.setBlendMode(.copy)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(clipped)
            context.restoreGState()
            return
        }
        context.saveGState()
        context.setAlpha(1)
        context.setBlendMode(.copy)
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        context.clip(to: clipped)
        context.draw(output, in: clipped)
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

/// The background behind an expanded canvas (CleanShot Background Tool).
///
/// Decoding tolerates every key being absent so projects written before a
/// field existed keep opening.
struct AnnotationBackground: Equatable, Codable {
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case solid, gradient, blurred, wallpaper
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .solid: return "Plain Color"
            case .gradient: return "Gradient"
            case .blurred: return "Blurred"
            case .wallpaper: return "Wallpaper"
            }
        }
    }

    enum GradientPreset: String, CaseIterable, Identifiable, Codable {
        case custom, sunset, ocean, sequoia, aurora, peach, mint, lavender, midnight, ember, citrus, slate
        var id: String { rawValue }
        var displayName: String { rawValue == "custom" ? "Custom" : rawValue.capitalized }

        /// The swatches shown in the Gradients section (Custom is edited separately).
        static let gallery: [GradientPreset] = allCases.filter { $0 != .custom }

        /// Original AOM colour stops (sRGB), top-left → bottom-right.
        var stops: [(CGFloat, CGFloat, CGFloat)] {
            switch self {
            case .custom: return []
            case .sunset: return [(0.28, 0.12, 0.54), (0.76, 0.23, 0.54), (1, 0.48, 0.32), (1, 0.78, 0.48)]
            case .ocean: return [(0.05, 0.12, 0.38), (0.08, 0.39, 0.75), (0.08, 0.70, 0.80), (0.55, 0.90, 0.85)]
            case .sequoia: return [(0.12, 0.23, 0.20), (0.26, 0.42, 0.31), (0.64, 0.63, 0.38), (0.91, 0.71, 0.45)]
            case .aurora: return [(0.10, 0.85, 0.65), (0.20, 0.45, 0.95), (0.55, 0.25, 0.85)]
            case .peach: return [(1.00, 0.85, 0.72), (0.98, 0.62, 0.60), (0.90, 0.45, 0.62)]
            case .mint: return [(0.80, 0.98, 0.88), (0.45, 0.88, 0.78), (0.20, 0.66, 0.70)]
            case .lavender: return [(0.93, 0.88, 1.00), (0.74, 0.66, 0.96), (0.52, 0.47, 0.88)]
            case .midnight: return [(0.04, 0.05, 0.14), (0.14, 0.12, 0.32), (0.30, 0.20, 0.48)]
            case .ember: return [(0.98, 0.78, 0.22), (0.96, 0.43, 0.20), (0.75, 0.13, 0.25)]
            case .citrus: return [(0.98, 0.98, 0.55), (0.70, 0.92, 0.35), (0.25, 0.75, 0.40)]
            case .slate: return [(0.82, 0.85, 0.89), (0.55, 0.60, 0.68), (0.28, 0.32, 0.40)]
            }
        }
    }

    /// CleanShot "Ratio": Auto + fixed canvas ratios.
    enum Ratio: String, CaseIterable, Identifiable, Codable {
        case auto
        case square = "1:1", r3x4 = "3:4", r4x3 = "4:3", r3x2 = "3:2", r16x9 = "16:9", r4x5 = "4:5", r9x16 = "9:16"
        var id: String { rawValue }
        var title: String { self == .auto ? "Auto" : rawValue }
        /// Width ÷ height, nil for Auto.
        var value: CGFloat? {
            switch self {
            case .auto: return nil
            case .square: return 1
            case .r3x4: return 3.0 / 4
            case .r4x3: return 4.0 / 3
            case .r3x2: return 3.0 / 2
            case .r16x9: return 16.0 / 9
            case .r4x5: return 4.0 / 5
            case .r9x16: return 9.0 / 16
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
    /// Extra margin inside the rounded frame, filled with the screenshot's edge colour (points).
    var inset: CGFloat = 0
    /// Drop shadow strength, 0…1 (0.5 matches the original fixed shadow).
    var shadow: CGFloat = 0.5
    /// 3 × 3 alignment cell, row-major: 0 = top-left, 4 = centre, 8 = bottom-right.
    var alignment: Int = 4
    var ratio: Ratio = .auto
    /// Shift the screenshot so its visual content (not its uniform border) is centred.
    var autoBalance: Bool = false
    /// Plain colour as RRGGBB (overrides `color` when set).
    var solidHex: String?
    /// A system desktop picture, for `.wallpaper`.
    var wallpaperPath: String?

    var isExpanded: Bool { padding > 0 || inset > 0 || ratio != .auto }

    var resolvedSolidColor: NSColor {
        solidHex.flatMap(AnnotationColorLibrary.color(fromHex:)) ?? color.nsColor
    }

    var gradientColors: [NSColor] {
        guard gradientPreset != .custom else { return [gradientStart.nsColor, gradientEnd.nsColor] }
        return gradientPreset.stops.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case kind, gradientPreset, cornerRadius, color, gradientStart, gradientEnd, padding
        case inset, shadow, alignment, ratio, autoBalance, solidHex, wallpaperPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AnnotationBackground()
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? defaults.kind
        gradientPreset = (try? c.decodeIfPresent(GradientPreset.self, forKey: .gradientPreset)) ?? defaults.gradientPreset
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? defaults.cornerRadius
        color = (try? c.decodeIfPresent(AnnotationColor.self, forKey: .color)) ?? defaults.color
        gradientStart = (try? c.decodeIfPresent(AnnotationColor.self, forKey: .gradientStart)) ?? defaults.gradientStart
        gradientEnd = (try? c.decodeIfPresent(AnnotationColor.self, forKey: .gradientEnd)) ?? defaults.gradientEnd
        padding = try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? defaults.padding
        inset = try c.decodeIfPresent(CGFloat.self, forKey: .inset) ?? defaults.inset
        shadow = try c.decodeIfPresent(CGFloat.self, forKey: .shadow) ?? defaults.shadow
        alignment = try c.decodeIfPresent(Int.self, forKey: .alignment) ?? defaults.alignment
        ratio = (try? c.decodeIfPresent(Ratio.self, forKey: .ratio)) ?? defaults.ratio
        autoBalance = try c.decodeIfPresent(Bool.self, forKey: .autoBalance) ?? defaults.autoBalance
        solidHex = try c.decodeIfPresent(String.self, forKey: .solidHex)
        wallpaperPath = try c.decodeIfPresent(String.self, forKey: .wallpaperPath)
    }

    /// Range checks shared by project and preset loading.
    var isValid: Bool {
        [padding, cornerRadius, inset].allSatisfy { $0.isFinite && (0...2000).contains($0) }
            && shadow.isFinite && (0...1).contains(shadow) && (0...8).contains(alignment)
            && (solidHex.map { $0.count <= 8 } ?? true) && (wallpaperPath.map { $0.utf8.count <= 4096 } ?? true)
    }
}

extension AnnotationObject {
    /// The painted extent (stroke, arrow heads, counter disc), in canvas points.
    var visualBounds: CGRect {
        if kind == .image {
            return AnnotationTransformGeometry.boundingBox(of: rect, rotation: resolvedRotation).insetBy(dx: -1, dy: -1)
        }
        var bounds = rect
        if kind == .counter { bounds.size = CGSize(width: max(rect.width, 24), height: max(rect.width, 24)) }
        let outset: CGFloat
        switch kind {
        case .arrow: outset = max(style.thickness * 3.5, 12)
        case .rectangle, .ellipse, .line, .draw, .drawHighlight: outset = style.thickness + 2
        case .text:
            // Shadows and thick outlines (3.3.3) paint past the text box.
            let shadow = style.textShadow == true ? style.fontSize * 0.35 : 0
            let outline = (style.textOutlineWidth ?? 0) * style.fontSize / 200
            outset = max(4, shadow, outline + 2)
        default: outset = 1
        }
        return bounds.insetBy(dx: -outset, dy: -outset)
    }

    /// The same object moved by (dx, dy), freehand points included.
    func offsetBy(dx: CGFloat, dy: CGFloat) -> AnnotationObject {
        var moved = self
        moved.rect = rect.offsetBy(dx: dx, dy: dy)
        moved.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return moved
    }

    /// A copy with a fresh identity (paste / duplicate).
    func duplicated(offsetBy delta: CGFloat) -> AnnotationObject {
        let moved = offsetBy(dx: delta, dy: delta)
        return AnnotationObject(kind: moved.kind, rect: moved.rect, style: moved.style,
                                text: moved.text, points: moved.points, image: moved.image, rotation: moved.rotation)
    }
}

/// Where an added image goes relative to the current canvas
/// (CleanShot "Place on the right / left / top / bottom").
enum AnnotationCombinePlacement: String, CaseIterable, Identifiable {
    case top, bottom, left, right
    var id: String { rawValue }

    var title: String { "Place on the \(rawValue)" }

    var symbol: String {
        switch self {
        case .top: return "arrow.up"
        case .bottom: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    /// The drop zone for a pointer at `point` over a canvas of `size`: the
    /// nearest edge, measured relative to the canvas dimensions.
    static func zone(for point: CGPoint, in size: CGSize) -> AnnotationCombinePlacement {
        guard size.width > 0, size.height > 0 else { return .bottom }
        let nx = min(max(point.x / size.width, 0), 1)
        let ny = min(max(point.y / size.height, 0), 1)
        let distances: [(AnnotationCombinePlacement, CGFloat)] = [
            (.top, ny), (.bottom, 1 - ny), (.left, nx), (.right, 1 - nx),
        ]
        // The centre of the canvas means "append below" (the classic behaviour).
        if abs(nx - 0.5) < 0.2 && abs(ny - 0.5) < 0.2 { return .bottom }
        return distances.min { $0.1 < $1.1 }!.0
    }
}

extension AnnotationDocument {
    static let maximumCombinedSide = 16000

    /// Places `image` next to the current (cropped) image on `placement`,
    /// growing the canvas. Annotations keep their on-screen position over the
    /// original pixels. `imageScale` (the added image's own backing scale)
    /// resamples it to this document's point size when the two differ.
    @discardableResult
    mutating func combine(_ image: CGImage, placement: AnnotationCombinePlacement, scale: CGFloat,
                          imageScale: CGFloat? = nil) -> Bool {
        guard scale.isFinite, scale > 0, image.width > 0, image.height > 0 else { return false }
        var added = image
        if let imageScale, imageScale.isFinite, imageScale > 0, abs(imageScale - scale) > 0.01 {
            let factor = scale / imageScale
            let w = max(1, Int((CGFloat(image.width) * factor).rounded()))
            let h = max(1, Int((CGFloat(image.height) * factor).rounded()))
            guard w <= Self.maximumCombinedSide, h <= Self.maximumCombinedSide,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let resampled = ctx.makeImage() else { return false }
            added = resampled
        }
        let old = croppedImage
        let vertical = placement == .top || placement == .bottom
        let width = vertical ? max(old.width, added.width) : old.width + added.width
        let height = vertical ? old.height + added.height : max(old.height, added.height)
        guard width > 0, height > 0, width <= Self.maximumCombinedSide, height <= Self.maximumCombinedSide,
              Int64(width) * Int64(height) <= 100_000_000,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return false
        }
        // Top-left placement of each image, converted to CG's bottom-left below.
        let oldOrigin: CGPoint, newOrigin: CGPoint
        switch placement {
        case .bottom: oldOrigin = .zero; newOrigin = CGPoint(x: 0, y: old.height)
        case .top: newOrigin = .zero; oldOrigin = CGPoint(x: 0, y: added.height)
        case .right: oldOrigin = .zero; newOrigin = CGPoint(x: old.width, y: 0)
        case .left: newOrigin = .zero; oldOrigin = CGPoint(x: added.width, y: 0)
        }
        func cgRect(_ origin: CGPoint, _ picture: CGImage) -> CGRect {
            CGRect(x: origin.x, y: CGFloat(height) - origin.y - CGFloat(picture.height),
                   width: CGFloat(picture.width), height: CGFloat(picture.height))
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(old, in: cgRect(oldOrigin, old))
        context.draw(added, in: cgRect(newOrigin, added))
        guard let combined = context.makeImage() else { return false }
        beginChange()
        baseImage = combined
        cropRect = nil
        let dx = oldOrigin.x / scale, dy = oldOrigin.y / scale
        if dx != 0 || dy != 0 {
            objects = objects.map { $0.offsetBy(dx: dx, dy: dy) }
        }
        return true
    }

    /// Burns every redaction (and everything beneath the top-most one, so the
    /// stacking order is unchanged) into the base image. Afterwards neither the
    /// editor nor a saved project contains the original pixels under them.
    @discardableResult
    mutating func flattenRedactions(scale: CGFloat) -> Bool {
        guard let last = objects.lastIndex(where: { $0.kind.isRedaction }) else { return false }
        let flattened = Array(objects[...last])
        guard let image = renderFlat(objects: flattened, scale: scale) else { return false }
        beginChange()
        baseImage = image
        cropRect = nil
        objects = Array(objects[(last + 1)...])
        return true
    }

    /// Inserts copies of `pasted` (fresh ids) and returns their ids, as one undo step.
    @discardableResult
    mutating func insertCopies(of pasted: [AnnotationObject], offset: CGFloat) -> [UUID] {
        guard !pasted.isEmpty else { return [] }
        let copies = pasted.map { $0.duplicated(offsetBy: offset) }
        addObjects(copies)
        return copies.map(\.id)
    }

    /// Removes several objects as one undo step.
    mutating func removeObjects(_ ids: Set<UUID>) {
        guard objects.contains(where: { ids.contains($0.id) }) else { return }
        beginChange()
        objects.removeAll { ids.contains($0.id) }
    }
}
