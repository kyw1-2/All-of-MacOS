import AppKit
import Vision

/// Kept separate from FoundationModels because SDK 27's optional
/// Vision/FoundationModels cross-import overlay is not shipped by every SDK.
enum ClipboardScreenContextOCR {
    static func recognize(_ image: CGImage) async -> String {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
            catch { return "" }
            return String((request.results ?? []).prefix(80).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(4_000))
        }.value
    }
}
