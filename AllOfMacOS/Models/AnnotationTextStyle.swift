import AppKit
import CoreText

// C03 text styles (3.3.3): font family, size and weight, text colour, a box
// behind the text (including a speech bubble), outline, shadow and alignment.
//
// Every field is an optional on `AnnotationStyle`, so a 3.3.2 project decodes
// unchanged, and a style that uses none of them is drawn by the 3.3.2 code
// path, pixel for pixel.
//
// This file is compiled into the Quick Look extensions too
// (scripts/bundle-annotation-preview.sh globs Models/Annotation*.swift), so it
// must only depend on other annotation model files and system frameworks.

/// Font weights offered by the Text tool.
enum AnnotationFontWeight: String, CaseIterable, Identifiable, Codable {
    case light, regular, medium, semibold, bold, heavy, black

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var nsWeight: NSFont.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    /// `NSFontManager`'s 0–15 weight scale (5 regular, 9 bold), for family fonts.
    var fontManagerWeight: Int {
        switch self {
        case .light: return 3
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 11
        case .black: return 12
        }
    }

    var isBold: Bool { fontManagerWeight >= 8 }
}

/// Horizontal text alignment inside the text box.
enum AnnotationTextAlignment: String, CaseIterable, Identifiable, Codable {
    case left, center, right

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var symbol: String { "text.align\(rawValue)" }

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

/// The shape drawn behind text.
enum AnnotationTextBackground: String, CaseIterable, Identifiable, Codable {
    case none, rectangle, rounded, pill, bubble

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "No Background"
        case .rectangle: return "Box"
        case .rounded: return "Rounded Box"
        case .pill: return "Pill"
        case .bubble: return "Speech Bubble"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "textformat"
        case .rectangle: return "square"
        case .rounded: return "app"
        case .pill: return "capsule"
        case .bubble: return "bubble.left"
        }
    }
}

/// Built-in text looks, in the spirit of CleanShot's predefined text styles.
///
/// A preset sets only the look (weight, outline, shadow, box). It keeps the
/// colour, size, font family, italic and alignment, and it uses the main
/// colour as its accent: the glyphs, or the box for the label styles.
enum AnnotationTextStylePreset: String, CaseIterable, Identifiable {
    case classic, plain, outline, shadow, label, lightLabel, pill, bubble

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .plain: return "Plain"
        case .outline: return "Outline"
        case .shadow: return "Shadow"
        case .label: return "Label"
        case .lightLabel: return "Light Label"
        case .pill: return "Pill"
        case .bubble: return "Speech Bubble"
        }
    }

    var help: String {
        switch self {
        case .classic: return "Semibold text with a thin dark edge (the AOM 3.3.2 look)"
        case .plain: return "Text in the chosen colour, nothing else"
        case .outline: return "Bold text with a thick white outline"
        case .shadow: return "Bold text with a soft drop shadow"
        case .label: return "Contrasting text on a rounded box in the chosen colour"
        case .lightLabel: return "Text in the chosen colour on a white rounded box"
        case .pill: return "Contrasting text on a capsule in the chosen colour"
        case .bubble: return "Contrasting text in a speech bubble in the chosen colour"
        }
    }

    func applied(to style: AnnotationStyle) -> AnnotationStyle {
        var result = style
        result.clearTextLook()
        switch self {
        case .classic:
            break
        case .plain:
            result.fontWeight = .semibold
            result.textOutline = false
        case .outline:
            result.fontWeight = .bold
            result.textOutline = true
            result.textOutlineHex = "FFFFFFFF"
            result.textOutlineWidth = 24
        case .shadow:
            result.fontWeight = .bold
            result.textOutline = false
            result.textShadow = true
        case .label:
            result.fontWeight = .semibold
            result.textOutline = false
            result.textBackground = .rounded
        case .lightLabel:
            result.fontWeight = .semibold
            result.textOutline = false
            result.textBackground = .rounded
            result.textBackgroundHex = "FFFFFFFF"
            result.textShadow = true
        case .pill:
            result.fontWeight = .bold
            result.textOutline = false
            result.textBackground = .pill
        case .bubble:
            result.fontWeight = .semibold
            result.textOutline = false
            result.textBackground = .bubble
        }
        return result
    }

    /// The preset whose look `style` has, if any.
    static func matching(_ style: AnnotationStyle) -> AnnotationTextStylePreset? {
        allCases.first { $0.applied(to: style).textLook == style.textLook }
    }
}

extension AnnotationStyle {
    /// The fields a text preset controls, normalised so nil and its default compare equal.
    struct TextLook: Equatable {
        var weight: AnnotationFontWeight
        var outline: Bool
        var outlineHex: String?
        var outlineWidth: CGFloat?
        var shadow: Bool
        var background: AnnotationTextBackground
        var backgroundHex: String?
        var colorHex: String?
    }

    var textLook: TextLook {
        TextLook(weight: resolvedFontWeight, outline: textOutline ?? true, outlineHex: textOutlineHex,
                 outlineWidth: textOutlineWidth, shadow: textShadow ?? false, background: resolvedTextBackground,
                 backgroundHex: textBackgroundHex, colorHex: textColorHex)
    }

    /// Resets the look a preset controls; colour, size, family, italic and alignment stay.
    mutating func clearTextLook() {
        fontWeight = nil
        bold = nil
        textOutline = nil
        textOutlineHex = nil
        textOutlineWidth = nil
        textShadow = nil
        textBackground = nil
        textBackgroundHex = nil
        textColorHex = nil
    }

    var resolvedFontWeight: AnnotationFontWeight {
        fontWeight ?? ((bold ?? true) ? .semibold : .regular)
    }

    var resolvedTextBackground: AnnotationTextBackground { textBackground ?? .none }

    var resolvedTextAlignment: AnnotationTextAlignment { textAlignment ?? .left }

    /// The box fill, or nil when the text has no box. Without its own colour
    /// the box uses the main colour.
    var resolvedTextBoxColor: NSColor? {
        guard resolvedTextBackground != .none else { return nil }
        return textBackgroundHex.flatMap(AnnotationColorLibrary.color(fromHex:)) ?? resolvedColor
    }

    /// The glyph colour: its own colour when set; black or white over a box
    /// drawn in the main colour; otherwise the main colour.
    var resolvedTextColor: NSColor {
        if let hex = textColorHex, let color = AnnotationColorLibrary.color(fromHex: hex) { return color }
        if resolvedTextBackground != .none, textBackgroundHex == nil {
            return AnnotationTextRenderer.contrastingColor(for: resolvedColor)
        }
        return resolvedColor
    }

    /// Outline colour; the 3.3.2 outline was black at 55 %.
    var resolvedTextOutlineColor: NSColor {
        textOutlineHex.flatMap(AnnotationColorLibrary.color(fromHex:)) ?? NSColor.black.withAlphaComponent(0.55)
    }

    /// True when the style uses nothing the 3.3.2 renderer did not know, so
    /// that renderer draws it and older documents look exactly as before.
    var usesClassicTextRendering: Bool {
        resolvedTextBackground == .none && textShadow != true && resolvedTextAlignment == .left
            && textColorHex == nil && textOutlineHex == nil && textOutlineWidth == nil
    }

    /// Range checks for the text-style fields (project loading).
    var hasValidTextStyle: Bool {
        let hexes = [customColorHex, textBackgroundHex, textColorHex, textOutlineHex]
        return hexes.allSatisfy { ($0?.utf8.count ?? 0) <= 9 }
            && (fontName?.utf8.count ?? 0) <= 512
            && (textOutlineWidth.map { $0.isFinite && (0...100).contains($0) } ?? true)
    }
}

/// Lays out and draws text objects.
enum AnnotationTextRenderer {
    /// Box padding and speech-bubble tail, in the same units as `fontSize`.
    struct Metrics: Equatable {
        var padding: CGSize
        var tail: CGFloat
    }

    static func metrics(for style: AnnotationStyle, fontSize: CGFloat) -> Metrics {
        let background = style.resolvedTextBackground
        guard background != .none else { return Metrics(padding: .zero, tail: 0) }
        let horizontal = fontSize * (background == .pill ? 0.6 : 0.4)
        return Metrics(padding: CGSize(width: horizontal, height: fontSize * 0.2),
                       tail: background == .bubble ? fontSize * 0.5 : 0)
    }

    /// Black or white, whichever reads better on `color`.
    static func contrastingColor(for color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }

    static func attributedText(_ text: String, style: AnnotationStyle, font: NSFont,
                               color: NSColor, extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.resolvedTextAlignment.nsAlignment
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        attributes.merge(extra) { _, new in new }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// The height (points) a text object `width` points wide needs so every
    /// line, the box padding and the bubble tail show. Never below the
    /// editor's initial one-line height.
    static func fittedHeight(text: String, style: AnnotationStyle, width: CGFloat) -> CGFloat {
        let size = style.fontSize
        guard size.isFinite, size > 0 else { return 1 }
        let minimum = size * 1.4
        guard !text.isEmpty, width.isFinite, width > 1 else { return minimum }
        let metrics = metrics(for: style, fontSize: size)
        let frameWidth = max(1, width - 2 * metrics.padding.width)
        let attributed = attributedText(text, style: style, font: style.resolvedFont(size: size), color: .black)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let used = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: frameWidth, height: CGFloat.greatestFiniteMagnitude), nil)
        return max(minimum, ceil(used.height) + 2 + 2 * metrics.padding.height + metrics.tail)
    }

    /// Draws a text object. `rect` is the object's rect in context space
    /// (bottom-left origin, pixels).
    static func draw(_ object: AnnotationObject, in context: CGContext, rect: CGRect, scale: CGFloat) {
        guard !object.text.isEmpty else { return }
        let style = object.style
        let size = style.fontSize * scale
        guard size.isFinite, size > 0, rect.width > 0, rect.height > 0 else { return }
        let font = style.resolvedFont(size: size)
        if style.usesClassicTextRendering {
            drawClassic(object.text, style: style, font: font, in: context, rect: rect)
            return
        }
        let metrics = metrics(for: style, fontSize: size)
        // Glyphs sit inside the box padding; a bubble keeps its tail below the box.
        var frameRect = rect.insetBy(dx: metrics.padding.width, dy: metrics.padding.height)
        frameRect.origin.y += metrics.tail
        frameRect.size.height -= metrics.tail
        guard frameRect.width >= 1, frameRect.height >= 1 else { return }
        let path = CGPath(rect: frameRect, transform: nil)
        let fill = attributedText(object.text, style: style, font: font, color: style.resolvedTextColor)
        let fillSetter = CTFramesetterCreateWithAttributedString(fill)
        let fillFrame = CTFramesetterCreateFrame(fillSetter, CFRange(location: 0, length: 0), path, nil)

        var strokeFrame: CTFrame?
        if style.textOutline ?? true {
            let outline = style.resolvedTextOutlineColor
            // A positive width strokes without filling; the fill pass on top
            // leaves only the outer half visible, so the glyphs keep their shape.
            let stroked = attributedText(object.text, style: style, font: font, color: outline, extra: [
                .strokeColor: outline, .strokeWidth: style.textOutlineWidth ?? 6,
            ])
            let strokeSetter = CTFramesetterCreateWithAttributedString(stroked)
            strokeFrame = CTFramesetterCreateFrame(strokeSetter, CFRange(location: 0, length: 0), path, nil)
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.setLineJoin(.round)
        let shadow = style.textShadow == true
        func applyShadow() {
            context.setShadow(offset: CGSize(width: 0, height: -size * 0.06), blur: size * 0.25,
                              color: NSColor.black.withAlphaComponent(0.45).cgColor)
        }
        if let boxColor = style.resolvedTextBoxColor {
            let used = CTFramesetterSuggestFrameSizeWithConstraints(
                fillSetter, CFRange(location: 0, length: 0), nil, frameRect.size, nil)
            let box = boxRect(usedSize: used, frame: frameRect, padding: metrics.padding,
                              alignment: style.resolvedTextAlignment)
            context.saveGState()
            if shadow { applyShadow() }
            context.setFillColor(boxColor.cgColor)
            context.addPath(boxPath(style.resolvedTextBackground, box: box, fontSize: size, tail: metrics.tail))
            context.fillPath()
            context.restoreGState()
            if let strokeFrame { CTFrameDraw(strokeFrame, context) }
            CTFrameDraw(fillFrame, context)
        } else {
            if shadow {
                // One shadow for outline + fill together, not one per pass.
                applyShadow()
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            if let strokeFrame { CTFrameDraw(strokeFrame, context) }
            CTFrameDraw(fillFrame, context)
            if shadow { context.endTransparencyLayer() }
        }
    }

    /// The 3.3.2 text renderer, unchanged.
    private static func drawClassic(_ text: String, style: AnnotationStyle, font: NSFont,
                                    in context: CGContext, rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.resolvedColor,
            // A matching outline keeps the text readable over a light or a dark
            // screenshot without needing a background box.
            .strokeColor: NSColor.black.withAlphaComponent(0.55),
            .strokeWidth: (style.textOutline ?? true) ? -3.0 : 0.0
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }

    /// The box around the laid-out lines (context space): the lines start at
    /// the top of `frame` and are aligned inside its width.
    static func boxRect(usedSize: CGSize, frame: CGRect, padding: CGSize,
                        alignment: AnnotationTextAlignment) -> CGRect {
        let width = min(frame.width, ceil(usedSize.width))
        let height = min(frame.height, ceil(usedSize.height))
        let x: CGFloat
        switch alignment {
        case .left: x = frame.minX
        case .center: x = frame.midX - width / 2
        case .right: x = frame.maxX - width
        }
        return CGRect(x: x - padding.width, y: frame.maxY - height - padding.height,
                      width: width + 2 * padding.width, height: height + 2 * padding.height)
    }

    /// The background shape (context space, bottom-left origin).
    static func boxPath(_ background: AnnotationTextBackground, box: CGRect, fontSize: CGFloat, tail: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch background {
        case .none:
            break
        case .rectangle:
            path.addRect(box)
        case .rounded, .bubble:
            let radius = min(fontSize * 0.3, box.height / 2, box.width / 2)
            path.addRoundedRect(in: box, cornerWidth: radius, cornerHeight: radius)
            if background == .bubble, tail > 0 {
                // A tail under the lower-left corner, pointing down and left.
                let baseStart = min(box.maxX - 1, box.minX + fontSize * 0.45)
                let baseEnd = min(box.maxX, baseStart + fontSize * 0.6)
                path.move(to: CGPoint(x: baseStart, y: box.minY + 1))
                path.addLine(to: CGPoint(x: max(box.minX, baseStart - fontSize * 0.25), y: box.minY - tail))
                path.addLine(to: CGPoint(x: baseEnd, y: box.minY + 1))
                path.closeSubpath()
            }
        case .pill:
            let radius = min(box.height / 2, box.width / 2)
            path.addRoundedRect(in: box, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }
}
