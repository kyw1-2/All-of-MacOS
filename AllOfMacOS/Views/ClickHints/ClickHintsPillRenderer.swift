import AppKit

/// How pills look: an opaque keycap-like capsule (design-340 b.17: 22 pt,
/// Callout semibold) that reads over any content, with the accent fill on
/// the typed prefix. Light and dark follow the appearance; Increase
/// Contrast swaps the halo for a full-strength 1.5 pt border.
struct ClickHintsPillStyle {
    var fill: CGColor
    var text: CGColor
    var border: CGColor
    var borderWidth: CGFloat
    var accent: CGColor
    var onAccent: CGColor
    /// The halo behind the pill; nil with Increase Contrast (borders replace shadows, b.11).
    var halo: CGColor?
    var font: NSFont
    var height: CGFloat
    var padding: CGFloat

    static func resolve(dark: Bool, increasedContrast: Bool, size: ClickHintsSize,
                        accent: NSColor = .controlAccentColor) -> ClickHintsPillStyle {
        // The system text style for the size, semibold (no fixed point size).
        let pointSize = NSFont.preferredFont(forTextStyle: size.textStyle).pointSize
        let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var accentColor = accent.cgColor
        appearance?.performAsCurrentDrawingAppearance {
            accentColor = (accent.usingColorSpace(.sRGB) ?? accent).cgColor
        }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        if increasedContrast {
            return ClickHintsPillStyle(fill: dark ? black : white, text: dark ? white : black, border: dark ? white : black,
                                       borderWidth: 1.5, accent: accentColor, onAccent: white, halo: nil,
                                       font: font, height: size.height, padding: (size.height * 0.3).rounded())
        }
        return ClickHintsPillStyle(
            fill: dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.98) : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.98),
            text: dark ? CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1) : CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
            border: dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.38) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32),
            borderWidth: 1, accent: accentColor, onAccent: white,
            halo: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: dark ? 0.6 : 0.35),
            font: font, height: size.height, padding: (size.height * 0.3).rounded())
    }

    /// The style for the current system appearance and contrast setting.
    @MainActor
    static func current(size: ClickHintsSize) -> ClickHintsPillStyle {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return resolve(dark: dark, increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast, size: size)
    }
}

/// Draws one pill into an image (a layer's contents), so the overlay is a
/// handful of small layers and never a full-screen backing store.
enum ClickHintsPillRenderer {
    static let kern: CGFloat = 0.4

    private static func attributes(_ style: ClickHintsPillStyle, color: CGColor) -> [NSAttributedString.Key: Any] {
        [.font: style.font, .kern: kern, .foregroundColor: NSColor(cgColor: color) ?? .labelColor]
    }

    /// Labels read in capitals, like key caps; typing ignores case.
    static func displayText(_ label: String) -> String { label.uppercased() }

    static func textWidth(_ text: String, style: ClickHintsPillStyle) -> CGFloat {
        NSAttributedString(string: text, attributes: attributes(style, color: style.text)).size().width
    }

    /// The pill's size in points, whole pixels wide at `scale`.
    static func size(for label: String, style: ClickHintsPillStyle, scale: CGFloat = 2) -> CGSize {
        let raw = max(style.height, textWidth(displayText(label), style: style) + style.padding * 2)
        return CGSize(width: (raw * scale).rounded(.up) / scale, height: style.height)
    }

    /// The pill image at `scale`. `typed` letters get the accent fill;
    /// `highlighted` fills the whole pill (the search match Return acts on).
    static func image(label: String, typed: Int, highlighted: Bool, style: ClickHintsPillStyle, scale: CGFloat) -> CGImage? {
        let text = displayText(label)
        let size = size(for: label, style: style, scale: scale)
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(origin: .zero, size: size)
        let inset = style.borderWidth / 2
        let capsuleRect = bounds.insetBy(dx: inset, dy: inset)
        let radius = capsuleRect.height / 2
        let capsule = CGPath(roundedRect: capsuleRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.addPath(capsule)
        context.setFillColor(highlighted ? style.accent : style.fill)
        context.fillPath()

        let typedCount = highlighted ? 0 : min(max(0, typed), text.count)
        let prefix = String(text.prefix(typedCount))
        // Capitals centred on the cap height.
        let string = NSMutableAttributedString(string: prefix, attributes: attributes(style, color: style.onAccent))
        string.append(NSAttributedString(string: String(text.dropFirst(typedCount)),
                                         attributes: attributes(style, color: highlighted ? style.onAccent : style.text)))
        let fullWidth = string.size().width
        let baseline = (size.height - style.font.capHeight) / 2
        let origin = CGPoint(x: max(style.padding, (size.width - fullWidth) / 2), y: baseline + style.font.descender)

        if typedCount > 0 {
            // The accent covers the typed letters, cut to the capsule's left end.
            let end = origin.x + textWidth(prefix, style: style) + style.padding * 0.4
            context.saveGState()
            context.addPath(capsule)
            context.clip()
            context.setFillColor(style.accent)
            context.fill(CGRect(x: 0, y: 0, width: min(size.width, end), height: size.height))
            context.restoreGState()
        }

        context.addPath(capsule)
        context.setStrokeColor(highlighted ? style.onAccent : style.border)
        context.setLineWidth(style.borderWidth)
        context.strokePath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
