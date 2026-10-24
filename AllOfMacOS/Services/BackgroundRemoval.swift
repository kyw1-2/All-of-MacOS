import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Paste 7's "Remove Background": lifts the foreground subjects out of an
/// image with Vision's on-device subject mask and returns a new image with a
/// transparent background. The source image is never modified; callers add
/// the result as a new clipboard item or capture.
enum BackgroundRemoval {
    enum Failure: LocalizedError {
        case noSubject
        var errorDescription: String? { "No subject was found in the image." }
    }

    private static let queue = DispatchQueue(label: "com.kyw.allofmacos.background-removal", qos: .userInitiated)

    /// Runs off the main thread.
    static func removingBackground(_ image: CGImage) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try removingBackgroundSync(image) }) }
        }
    }

    static func removingBackgroundSync(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.noSubject }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: false)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = context.createCGImage(ciImage, from: ciImage.extent,
                                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw Failure.noSubject
        }
        return output
    }
}
