import AppKit
import Darwin

/// Uses the packaged libwebp codec, independently of Homebrew on the recipient's Mac.
enum WebPEncoder {
    static func encode(image: CGImage, quality: Double) -> Data? {
        guard image.width > 0, image.height > 0, image.width <= 16383, image.height <= 16383,
              Int64(image.width) * Int64(image.height) <= 100_000_000,
              let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let libraryURL = frameworks.appendingPathComponent("libwebp.7.dylib")
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        defer { dlclose(library) }
        typealias Encode = @convention(c) (UnsafePointer<UInt8>?, Int32, Int32, Int32, Float, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?) -> Int
        typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
        guard let encodeSymbol = dlsym(library, "WebPEncodeRGBA"), let freeSymbol = dlsym(library, "WebPFree") else { return nil }
        let encode = unsafeBitCast(encodeSymbol, to: Encode.self)
        let free = unsafeBitCast(freeSymbol, to: Free.self)
        let stride = image.width * 4
        var rgba = [UInt8](repeating: 0, count: stride * image.height)
        return rgba.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(data: pixels.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: stride,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = pixels.bindMemory(to: UInt8.self)
            // libwebp accepts straight alpha; undo CGContext's premultiplication.
            for i in Swift.stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Int(bytes[i + 3])
                if alpha > 0 && alpha < 255 {
                    for channel in 0..<3 { bytes[i + channel] = UInt8(min(255, (Int(bytes[i + channel]) * 255 + alpha / 2) / alpha)) }
                }
            }
            var output: UnsafeMutablePointer<UInt8>?
            let size = encode(bytes.baseAddress, Int32(image.width), Int32(image.height), Int32(stride),
                              Float(min(1, max(0.1, quality)) * 100), &output)
            guard size > 0, let output else { return nil }
            defer { free(UnsafeMutableRawPointer(output)) }
            return Data(bytes: output, count: size)
        }
    }
}
