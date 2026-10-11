import Foundation
import CoreGraphics
import Vision

/// Optical character recognition over a captured image, using the on-device
/// Vision framework.
///
/// Vision is used rather than a bundled OCR engine because it ships with macOS,
/// runs entirely on-device, and needs no model download — which matters for a
/// tool that may be used on a machine with no network.
enum TextRecognitionService {
    enum OCRError: LocalizedError {
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let reason): return "Text recognition failed: \(reason)"
            }
        }
    }

    /// Recognizes text in `image`.
    ///
    /// - Parameter keepsLineBreaks: when true, the result preserves the visual
    ///   line structure by joining observations per line. When false, lines are
    ///   joined with single spaces, which is what a paste into a search field or
    ///   a spreadsheet wants. CleanShot offers both as separate menu commands.
    static func recognize(_ image: CGImage, keepsLineBreaks: Bool = true,
                          languages: [String] = []) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.requestFailed(error.localizedDescription))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let text = assemble(observations, keepsLineBreaks: keepsLineBreaks)
                continuation.resume(returning: text)
            }
            // `.accurate` costs a little time but is materially better on screen
            // text, which is the only thing this is ever pointed at.
            request.recognitionLevel = .accurate
            // Language correction helps prose and hurts code, so it stays off:
            // a screenshot of source or a terminal is a common case here.
            request.usesLanguageCorrection = false
            if !languages.isEmpty { request.recognitionLanguages = languages }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRError.requestFailed(error.localizedDescription))
            }
        }
    }

    /// Recognizes QR-code payloads without network access, using Vision.
    /// CleanShot X exposes this separately from text OCR.
    static func detectQRCodes(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.requestFailed(error.localizedDescription))
                    return
                }
                let items = ((request.results as? [VNBarcodeObservation]) ?? [])
                    .filter { $0.symbology == .qr }
                    .compactMap(\.payloadStringValue)
                // Avoid repeated payloads on a page with overlapping detections.
                continuation.resume(returning: Array(NSOrderedSet(array: items)) as? [String] ?? items)
            }
            request.symbologies = [.qr]
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: OCRError.requestFailed(error.localizedDescription))
            }
        }
    }

    /// Recognizes text and returns per-observation boxes, for callers that need
    /// to know where the text was as well as what it said.
    static func recognizeWithLayout(_ image: CGImage) async throws -> [(text: String, box: CGRect)] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.requestFailed(error.localizedDescription))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let items = observations.compactMap { observation -> (String, CGRect)? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return (candidate.string, observation.boundingBox)
                }
                continuation.resume(returning: items)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) }
            catch { continuation.resume(throwing: OCRError.requestFailed(error.localizedDescription)) }
        }
    }

    /// Orders observations into reading order and joins them.
    ///
    /// Vision returns observations in no guaranteed order, so they are grouped
    /// into lines by vertical overlap and each line sorted left to right. Without
    /// this, a two-column layout comes back interleaved.
    private static func assemble(_ observations: [VNRecognizedTextObservation], keepsLineBreaks: Bool) -> String {
        let items: [(text: String, box: CGRect)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox)
        }
        guard !items.isEmpty else { return "" }

        // Vision's bounding box is bottom-left origin with 0…1 extents, so a
        // larger y means higher on the page.
        let sorted = items.sorted { $0.box.midY > $1.box.midY }
        var lines: [[(text: String, box: CGRect)]] = []
        for item in sorted {
            // Same line when the vertical centres overlap by more than half the
            // shorter box's height.
            if let last = lines.last, let reference = last.first,
               abs(reference.box.midY - item.box.midY) < min(reference.box.height, item.box.height) * 0.5 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }
        let rendered = lines.map { line in
            line.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }
        return rendered.joined(separator: keepsLineBreaks ? "\n" : " ")
    }

    /// The languages Vision can currently recognize, for a settings picker.
    static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }
}
