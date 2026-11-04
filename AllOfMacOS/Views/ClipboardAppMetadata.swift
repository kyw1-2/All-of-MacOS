import AppKit
import ImageIO
import SwiftUI

// MARK: - App Metadata & Banner Color Cache

@MainActor
final class AppMetadataCache {
    static let shared = AppMetadataCache()
    private var iconCache = BoundedLRUCache<String, NSImage>(countLimit: 128)
    /// Uninstalled source apps: LaunchServices lookups are not free, so a
    /// miss is remembered instead of repeated for every card render.
    private var missingIcons = BoundedLRUCache<String, Bool>(countLimit: 128)
    private var fileIconCache = BoundedLRUCache<String, NSImage>(countLimit: 300)

    func fileIcon(for url: URL) -> NSImage {
        if let cached = fileIconCache[url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        fileIconCache[url.path] = icon
        return icon
    }

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        if missingIcons[bundleID] != nil { return nil }

        var image: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            image = app.icon
        }

        if let image {
            iconCache[bundleID] = image
            return image
        }
        missingIcons[bundleID] = true
        return nil
    }

    private var colorCache = BoundedLRUCache<String, Color>(countLimit: 512)

    /// Paste paints the card header with the source app's icon colour.
    /// The dominant saturated hue of the real icon is used, darkened enough
    /// for white header text; a small curated map remains the fallback.
    func bannerColor(for bundleID: String?, name: String?) -> Color {
        let key = (bundleID ?? name ?? "").lowercased()
        if let cached = colorCache[key] { return cached }
        let color = icon(for: bundleID).flatMap(Self.dominantColor(of:)) ?? fallbackBanner(key)
        colorCache[key] = color
        return color
    }

    private var darkTextCache = BoundedLRUCache<String, Bool>(countLimit: 512)

    /// Whether a banner is light enough that white text would drop under
    /// 3:1 (WCAG relative luminance), so the header uses dark text.
    func bannerUsesDarkText(for bundleID: String?, name: String?) -> Bool {
        let key = (bundleID ?? name ?? "").lowercased()
        if let cached = darkTextCache[key] { return cached }
        var dark = false
        if let color = NSColor(bannerColor(for: bundleID, name: name)).usingColorSpace(.sRGB) {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
            dark = 1.05 / (luminance + 0.05) < 3
        }
        darkTextCache[key] = dark
        return dark
    }

    static func dominantColor(of image: NSImage) -> Color? {
        // Raw RGBA bytes from one 24×24 draw; NSBitmapImageRep.colorAt plus a
        // colour-space conversion per pixel made the first shelf open stall.
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: rect)
        var bins = [(weight: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        var gray: (weight: CGFloat, value: CGFloat) = (0, 0)
        for i in 0..<(side * side) {
            let alpha = CGFloat(pixels[i * 4 + 3]) / 255
            guard alpha > 0.6 else { continue }
            let r = CGFloat(pixels[i * 4]) / 255 / alpha, g = CGFloat(pixels[i * 4 + 1]) / 255 / alpha
            let bl = CGFloat(pixels[i * 4 + 2]) / 255 / alpha
            let maxC = max(r, g, bl), minC = min(r, g, bl)
            let v = maxC, sat = maxC > 0 ? (maxC - minC) / maxC : 0
            if sat < 0.22 || v < 0.12 {
                gray.weight += 1; gray.value += v
                continue
            }
            var h: CGFloat
            let d = maxC - minC
            if maxC == r { h = (g - bl) / d } else if maxC == g { h = 2 + (bl - r) / d } else { h = 4 + (r - g) / d }
            h /= 6; if h < 0 { h += 1 }
            let weight = sat * v
            let index = min(11, Int(h * 12))
            bins[index].weight += weight
            bins[index].r += r * weight; bins[index].g += g * weight; bins[index].b += bl * weight
        }
        let best = bins.max { $0.weight < $1.weight }!
        let colorful = best.weight > 0 && best.weight * 2.2 > gray.weight * 0.35
        let base: NSColor
        if colorful {
            base = NSColor(deviceRed: best.r / best.weight, green: best.g / best.weight, blue: best.b / best.weight, alpha: 1)
        } else if gray.weight > 0 {
            let v = gray.value / gray.weight
            let w = min(0.42, max(0.18, v * 0.55))
            base = NSColor(deviceRed: w, green: w, blue: w, alpha: 1)
        } else { return nil }
        // Keep white title text legible (Paste's headers are mid-tone).
        let hue = base.hueComponent, sat = base.saturationComponent
        let brightness = min(base.brightnessComponent, colorful ? 0.82 : 0.42)
        let adjusted = NSColor(deviceHue: hue, saturation: colorful ? max(sat, 0.45) : sat,
                               brightness: max(brightness, 0.2), alpha: 1)
        return Color(nsColor: adjusted)
    }

    private func fallbackBanner(_ key: String) -> Color {
        if key.contains("terminal") || key.contains("iterm") {
            return Color(red: 0.16, green: 0.18, blue: 0.22)
        } else if key.contains("chrome") {
            return Color(red: 0.25, green: 0.52, blue: 0.96)
        } else if key.contains("safari") {
            return Color(red: 0.00, green: 0.48, blue: 0.98)
        } else if key.contains("zen") {
            return Color(red: 0.48, green: 0.18, blue: 0.72)
        } else if key.contains("textedit") {
            return Color(red: 0.86, green: 0.46, blue: 0.32)
        } else if key.contains("xcode") {
            return Color(red: 0.08, green: 0.46, blue: 0.94)
        } else if key.contains("finder") {
            return Color(red: 0.00, green: 0.50, blue: 0.95)
        } else if key.contains("slack") {
            return Color(red: 0.32, green: 0.10, blue: 0.32)
        } else if key.contains("discord") {
            return Color(red: 0.35, green: 0.40, blue: 0.92)
        } else if key.contains("notes") {
            return Color(red: 0.97, green: 0.81, blue: 0.02)
        } else if key.contains("paste") {
            return Color(red: 0.92, green: 0.30, blue: 0.42)
        } else if key.contains("code") || key.contains("cursor") {
            return Color(red: 0.12, green: 0.40, blue: 0.76)
        }

        return Color(red: 0.51, green: 0.51, blue: 0.51)
    }
}

/// Bounded first-line extraction for card headers. Finding the newline before
/// taking a prefix walks an entire multi-megabyte single-line clip on each draw.
enum ClipboardCardText {
    static func automaticTitle(_ text: String) -> String {
        // A clip consisting mostly of whitespace must be bounded too. If
        // its real title is farther away, the card uses the stored title
        // already derived by background capture instead of rescanning it.
        guard let start = text.prefix(4_096).firstIndex(where: { !$0.isWhitespace }) else { return "Text" }
        let rest = text[start...]
        let prefix = rest.prefix(101)
        let end = prefix.firstIndex(where: \.isNewline) ?? prefix.endIndex
        var line = prefix[..<end]
        if end == text.endIndex {
            while let last = line.last, last.isWhitespace { line = line.dropLast() }
        }
        return String(line.prefix(100))
    }
}
