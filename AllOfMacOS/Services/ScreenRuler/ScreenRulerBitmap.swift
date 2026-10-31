import CoreGraphics
import Foundation

/// A run of similar pixels along one axis, as pixel boundaries: the run
/// covers pixels `lower ..< upper`.
struct ScreenRulerSpan: Equatable, Hashable {
    let lower: Int
    let upper: Int
    /// The run reached the image's first (left or top) pixel without an edge.
    let reachesLowerBorder: Bool
    /// The run reached the image's last (right or bottom) pixel without an edge.
    let reachesUpperBorder: Bool

    var length: Int { upper - lower }
}

/// One display's captured pixels, held in memory for the whole measuring
/// session so every pointer move is answered from RAM (never a new capture).
///
/// Storage is 8-bit RGBA, rows packed top row first, in the capture's own
/// colour space: edges are found on the values the display showed, and only
/// the single pixel shown as hex is converted to sRGB.
struct ScreenRulerBitmap: @unchecked Sendable {
    // @unchecked: `CGColorSpace` is immutable and thread-safe; the pixels are a value.
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let colorSpace: CGColorSpace

    enum Axis { case horizontal, vertical }

    /// Wraps existing RGBA bytes (`width * height * 4`, top row first).
    init?(width: Int, height: Int, rgba: [UInt8], colorSpace: CGColorSpace? = nil) {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        self.width = width
        self.height = height
        self.pixels = rgba
        self.colorSpace = space
    }

    /// Copies a capture into RGBA bytes. The capture's colour space is kept
    /// (no colour matching), so this is a plain copy and a format swizzle.
    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 32_768, height <= 32_768 else { return nil }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let source = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? srgb
        guard let space = source else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            func draw(in space: CGColorSpace) -> Bool {
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.interpolationQuality = .none
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            // A colour space a bitmap context cannot use falls back to sRGB.
            return draw(in: space) || (srgb.map(draw(in:)) ?? false)
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = bytes
        self.colorSpace = space
    }

    func contains(_ pixel: ScreenRulerPixel) -> Bool {
        pixel.x >= 0 && pixel.y >= 0 && pixel.x < width && pixel.y < height
    }

    /// The RGBA bytes of one pixel.
    func rgba(at pixel: ScreenRulerPixel) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
        guard contains(pixel) else { return nil }
        let index = (pixel.y * width + pixel.x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }

    /// The tolerance as the largest per-channel difference still counted as
    /// the same colour (0...255).
    static func threshold(for tolerance: Double) -> Int {
        guard tolerance.isFinite else { return 0 }
        return Int((min(1, max(0, tolerance)) * 255).rounded())
    }

    // MARK: - Edges

    /// From `start`, walks both ways along `axis` to the first pixel whose
    /// colour differs from the start pixel by more than `tolerance` (the
    /// largest per-channel difference, as a fraction of full scale), and
    /// returns the run between those edges. Comparing with the start pixel,
    /// not the neighbour, keeps a slow gradient from hiding a real edge.
    func span(from start: ScreenRulerPixel, axis: Axis, tolerance: Double) -> ScreenRulerSpan? {
        guard contains(start) else { return nil }
        let limit = Self.threshold(for: tolerance)
        return pixels.withUnsafeBufferPointer { buffer -> ScreenRulerSpan in
            let base = buffer.baseAddress!
            let origin = (start.y * width + start.x) * 4
            let r = Int(base[origin]), g = Int(base[origin + 1]), b = Int(base[origin + 2]), a = Int(base[origin + 3])
            @inline(__always) func same(_ index: Int) -> Bool {
                let offset = index * 4
                return abs(Int(base[offset]) - r) <= limit && abs(Int(base[offset + 1]) - g) <= limit
                    && abs(Int(base[offset + 2]) - b) <= limit && abs(Int(base[offset + 3]) - a) <= limit
            }
            switch axis {
            case .horizontal:
                let row = start.y * width
                var low = start.x
                while low > 0, same(row + low - 1) { low -= 1 }
                var high = start.x
                while high < width - 1, same(row + high + 1) { high += 1 }
                return ScreenRulerSpan(lower: low, upper: high + 1, reachesLowerBorder: low == 0,
                                       reachesUpperBorder: high == width - 1)
            case .vertical:
                var low = start.y
                while low > 0, same((low - 1) * width + start.x) { low -= 1 }
                var high = start.y
                while high < height - 1, same((high + 1) * width + start.x) { high += 1 }
                return ScreenRulerSpan(lower: low, upper: high + 1, reachesLowerBorder: low == 0,
                                       reachesUpperBorder: high == height - 1)
            }
        }
    }

    // MARK: - Shrink-wrap

    /// The most common colour on the rect's border: what the user dragged
    /// across to enclose something, so it is the background around it.
    func backgroundColor(around rect: ScreenRulerPixelRect) -> UInt32? {
        let area = rect.clamped(width: width, height: height)
        guard !area.isEmpty else { return nil }
        return pixels.withUnsafeBufferPointer { buffer -> UInt32? in
            let base = buffer.baseAddress!
            var counts: [UInt32: Int] = [:]
            @inline(__always) func add(_ x: Int, _ y: Int) {
                let offset = (y * width + x) * 4
                let key = UInt32(base[offset]) << 24 | UInt32(base[offset + 1]) << 16
                    | UInt32(base[offset + 2]) << 8 | UInt32(base[offset + 3])
                counts[key, default: 0] += 1
            }
            for x in area.minX..<area.maxX {
                add(x, area.minY)
                if area.height > 1 { add(x, area.maxY - 1) }
            }
            if area.height > 2 {
                for y in (area.minY + 1)..<(area.maxY - 1) {
                    add(area.minX, y)
                    if area.width > 1 { add(area.maxX - 1, y) }
                }
            }
            // Ties go to the smaller value so the answer never depends on hashing.
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
    }

    /// PixelSnap's shrink: the tightest rect inside `rect` holding every pixel
    /// that differs from the background by more than `tolerance`. The
    /// background is the most common colour on the rect's border. Nil when
    /// the rect holds nothing but background.
    func contentBounds(in rect: ScreenRulerPixelRect, tolerance: Double) -> ScreenRulerPixelRect? {
        let area = rect.clamped(width: width, height: height)
        guard !area.isEmpty, let background = backgroundColor(around: area) else { return nil }
        let limit = Self.threshold(for: tolerance)
        let r = Int(background >> 24 & 0xFF), g = Int(background >> 16 & 0xFF)
        let b = Int(background >> 8 & 0xFF), a = Int(background & 0xFF)
        return pixels.withUnsafeBufferPointer { buffer -> ScreenRulerPixelRect? in
            let base = buffer.baseAddress!
            @inline(__always) func isBackground(_ x: Int, _ y: Int) -> Bool {
                let offset = (y * width + x) * 4
                return abs(Int(base[offset]) - r) <= limit && abs(Int(base[offset + 1]) - g) <= limit
                    && abs(Int(base[offset + 2]) - b) <= limit && abs(Int(base[offset + 3]) - a) <= limit
            }
            func rowIsBackground(_ y: Int, _ left: Int, _ right: Int) -> Bool {
                for x in left..<right where !isBackground(x, y) { return false }
                return true
            }
            func columnIsBackground(_ x: Int, _ top: Int, _ bottom: Int) -> Bool {
                for y in top..<bottom where !isBackground(x, y) { return false }
                return true
            }
            var top = area.minY, bottom = area.maxY
            var left = area.minX, right = area.maxX
            while top < bottom, rowIsBackground(top, left, right) { top += 1 }
            guard top < bottom else { return nil }
            while bottom > top, rowIsBackground(bottom - 1, left, right) { bottom -= 1 }
            while left < right, columnIsBackground(left, top, bottom) { left += 1 }
            while right > left, columnIsBackground(right - 1, top, bottom) { right -= 1 }
            return ScreenRulerPixelRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    // MARK: - Colour

    /// The pixel as `#RRGGBB` in sRGB (converted from the capture's colour space).
    func srgbHex(at pixel: ScreenRulerPixel) -> String? {
        guard let value = rgba(at: pixel) else { return nil }
        let alpha = CGFloat(value.alpha) / 255
        // Premultiplied storage: undo it before converting (screens are opaque).
        func unit(_ channel: UInt8) -> CGFloat { alpha > 0 ? min(1, CGFloat(channel) / 255 / alpha) : 0 }
        let components = [unit(value.red), unit(value.green), unit(value.blue), 1]
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let color = CGColor(colorSpace: colorSpace, components: components),
              let converted = colorSpace.name == CGColorSpace.sRGB ? color
                : color.converted(to: srgb, intent: .relativeColorimetric, options: nil),
              let parts = converted.components, parts.count >= 3 else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(parts[0]), byte(parts[1]), byte(parts[2]))
    }
}
