import CoreGraphics
import Foundation

enum CaptureColorProfile: String, CaseIterable, Identifiable {
    case display, sRGB
    var id: String { rawValue }
    var title: String { self == .display ? "Preserve Display Profile" : "Convert to sRGB" }
    /// The packaged WebP encoder writes sRGB pixels without an ICC container.
    func effective(for format: CaptureFormat) -> Self { format == .webp ? .sRGB : self }

    func applying(to image: CGImage) -> CGImage? {
        guard self == .sRGB else { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

extension CaptureSettings {
    static var colorProfile: CaptureColorProfile {
        get { CaptureColorProfile(rawValue: UserDefaults.standard.string(forKey: "AOMCaptureColorProfile") ?? "") ?? .display }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "AOMCaptureColorProfile") }
    }
}
