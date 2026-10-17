import Foundation
import CoreGraphics

/// Pixel pipeline behind the "Secure Blur" redaction style.
///
/// Plain blur is a linear filter and can be partially inverted; pixelation of
/// small blocks leaks shapes. Secure Blur therefore keeps only one average
/// colour per coarse block (information is destroyed here), smooths those
/// blocks, adds seeded noise and finally guarantees that no output pixel is
/// bit-identical to the source pixel at the same position. Everything is
/// integer arithmetic on an RGBA8 buffer, so it is deterministic for a given
/// region + seed (stable preview, stable tests).
enum AnnotationSecureRedaction {
    /// RGBA8 (premultiplied-last, alpha forced opaque on output) buffer.
    struct Buffer {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()

    static func rgba(_ image: CGImage) -> Buffer? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, Int64(width) * Int64(height) <= 100_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Buffer(width: width, height: height, pixels: pixels) : nil
    }

    static func image(from buffer: Buffer) -> CGImage? {
        let data = Data(buffer.pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: buffer.width, height: buffer.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: buffer.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The secure replacement for `region` (same pixel size, fully opaque).
    static func secureBlur(region: CGImage, blockSize: CGFloat, seed: UUID) -> CGImage? {
        let block = max(4, Int(blockSize.isFinite ? blockSize.rounded() : 16))
        guard let source = rgba(region) else { return nil }
        let key = "\(seed.uuidString)-\(region.width)x\(region.height)-\(block)-\(fingerprint(source))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var output = mosaic(source, block: block)
        // Two box passes approximate a Gaussian over the block grid.
        let radius = max(1, block / 2)
        boxBlur(&output, radius: radius)
        boxBlur(&output, radius: radius)
        addNoise(&output, seed: seed, amplitude: 10)
        breakIdentity(&output, original: source)
        guard let image = image(from: output) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// One average colour per `block × block` cell; alpha becomes opaque.
    static func mosaic(_ source: Buffer, block: Int) -> Buffer {
        var out = source
        let w = source.width, h = source.height
        var by = 0
        while by < h {
            var bx = 0
            let bh = min(block, h - by)
            while bx < w {
                let bw = min(block, w - bx)
                var sum = (0, 0, 0)
                for y in by..<(by + bh) {
                    var i = (y * w + bx) * 4
                    for _ in 0..<bw {
                        sum.0 += Int(source.pixels[i]); sum.1 += Int(source.pixels[i + 1]); sum.2 += Int(source.pixels[i + 2])
                        i += 4
                    }
                }
                let count = bw * bh
                let avg = (UInt8(sum.0 / count), UInt8(sum.1 / count), UInt8(sum.2 / count))
                for y in by..<(by + bh) {
                    var i = (y * w + bx) * 4
                    for _ in 0..<bw {
                        out.pixels[i] = avg.0; out.pixels[i + 1] = avg.1; out.pixels[i + 2] = avg.2; out.pixels[i + 3] = 255
                        i += 4
                    }
                }
                bx += block
            }
            by += block
        }
        return out
    }

    /// Separable running-sum box blur on RGB with clamped edges.
    static func boxBlur(_ buffer: inout Buffer, radius: Int) {
        let w = buffer.width, h = buffer.height
        guard w > 1 || h > 1 else { return }
        var temp = buffer.pixels
        let span = 2 * radius + 1
        // Horizontal.
        for y in 0..<h {
            let row = y * w
            for c in 0..<3 {
                var sum = 0
                for k in -radius...radius { sum += Int(buffer.pixels[(row + min(max(k, 0), w - 1)) * 4 + c]) }
                for x in 0..<w {
                    temp[(row + x) * 4 + c] = UInt8(sum / span)
                    let outIndex = min(max(x - radius, 0), w - 1)
                    let inIndex = min(max(x + radius + 1, 0), w - 1)
                    sum += Int(buffer.pixels[(row + inIndex) * 4 + c]) - Int(buffer.pixels[(row + outIndex) * 4 + c])
                }
            }
        }
        // Vertical.
        for x in 0..<w {
            for c in 0..<3 {
                var sum = 0
                for k in -radius...radius { sum += Int(temp[(min(max(k, 0), h - 1) * w + x) * 4 + c]) }
                for y in 0..<h {
                    buffer.pixels[(y * w + x) * 4 + c] = UInt8(sum / span)
                    let outIndex = min(max(y - radius, 0), h - 1)
                    let inIndex = min(max(y + radius + 1, 0), h - 1)
                    sum += Int(temp[(inIndex * w + x) * 4 + c]) - Int(temp[(outIndex * w + x) * 4 + c])
                }
            }
        }
        for i in stride(from: 3, to: buffer.pixels.count, by: 4) { buffer.pixels[i] = 255 }
    }

    /// Deterministic ±`amplitude` noise (xorshift64*, seeded from the object id).
    static func addNoise(_ buffer: inout Buffer, seed: UUID, amplitude: Int) {
        var state: UInt64 = withUnsafeBytes(of: seed.uuid) { raw in
            raw.load(fromByteOffset: 0, as: UInt64.self) ^ raw.load(fromByteOffset: 8, as: UInt64.self)
        }
        if state == 0 { state = 0x9E37_79B9_7F4A_7C15 }
        let range = UInt64(2 * amplitude + 1)
        for i in stride(from: 0, to: buffer.pixels.count, by: 4) {
            for c in 0..<3 {
                state ^= state >> 12; state ^= state << 25; state ^= state >> 27
                let random = Int((state &* 2_685_821_657_736_338_717) % range) - amplitude
                buffer.pixels[i + c] = UInt8(min(255, max(0, Int(buffer.pixels[i + c]) + random)))
            }
            buffer.pixels[i + 3] = 255
        }
    }

    /// Guarantees no output pixel equals the original pixel at that position.
    static func breakIdentity(_ buffer: inout Buffer, original: Buffer) {
        guard buffer.pixels.count == original.pixels.count else { return }
        for i in stride(from: 0, to: buffer.pixels.count, by: 4)
        where buffer.pixels[i] == original.pixels[i] && buffer.pixels[i + 1] == original.pixels[i + 1]
            && buffer.pixels[i + 2] == original.pixels[i + 2] {
            let value = buffer.pixels[i]
            buffer.pixels[i] = value >= 128 ? value - 3 : value + 3
        }
    }

    /// FNV-1a over every pixel, so the cache never serves another region's output.
    private static func fingerprint(_ buffer: Buffer) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in buffer.pixels { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }
}
