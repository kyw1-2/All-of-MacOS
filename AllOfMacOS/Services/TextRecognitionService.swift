import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Optical character recognition over a captured image, on device.
///
/// This is the single entry point every OCR consumer in AOM uses (Capture
/// Text, All-In-One "Capture Text", Quick Access and Pin "Extract Text",
/// Copy Text From Last Capture, Smart Highlighter, the clipboard image
/// index). The pipeline itself lives in `TextRecognitionEngine`
/// (TextCaptureEngine.swift): Vision multi-pass per script group fused with
/// VisionKit Live Text, adaptive upscaling, dark-capture inversion, and
/// layout-aware post-processing. Nothing leaves the Mac and no model is
/// bundled — both frameworks ship with macOS.
enum TextRecognitionService {
    enum OCRError: LocalizedError {
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let reason): return "Text recognition failed: \(reason)"
            }
        }
    }

    /// Recognizes text in `image` using the user's Text Recognition settings.
    ///
    /// - Parameters:
    ///   - keepsLineBreaks: true keeps the visual lines; false re-flows them
    ///     into paragraphs (script-aware: no spaces inserted between
    ///     Chinese/Japanese lines).
    ///   - languages: optional explicit language priority (Vision codes),
    ///     overriding the settings.
    static func recognize(_ image: CGImage, keepsLineBreaks: Bool = true,
                          languages: [String] = []) async throws -> String {
        var options = TextRecognitionOptions.fromSettings(keepsLineBreaks: keepsLineBreaks)
        if !languages.isEmpty { options.languages = languages }
        return try await recognize(image, options: options).text
    }

    /// Full result (text, fused line geometry, detected language, engine info).
    static func recognize(_ image: CGImage, options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        do {
            return try await TextRecognitionEngine.recognize(image, options: options)
        } catch let error as TextRecognitionEngine.EngineError {
            throw OCRError.requestFailed(error.errorDescription ?? "unknown error")
        }
    }

    /// Recognizes QR-code payloads without network access, using Vision.
    static func detectQRCodes(_ image: CGImage) async throws -> [String] {
        do {
            return try await TextRecognitionEngine.detectBarcodes(image, symbologies: [.qr]).map(\.payload)
        } catch {
            throw OCRError.requestFailed(error.localizedDescription)
        }
    }

    /// Every barcode symbology Vision reads (QR, Aztec, Data Matrix, PDF417,
    /// EAN/UPC, Code 39/93/128, ITF…), de-duplicated in detection order.
    static func detectBarcodes(_ image: CGImage) async throws -> [TextCaptureBarcode] {
        do {
            return try await TextRecognitionEngine.detectBarcodes(image)
        } catch {
            throw OCRError.requestFailed(error.localizedDescription)
        }
    }

    /// Recognizes text and returns per-line boxes, for callers that need to
    /// know where the text was as well as what it said. Boxes use Vision's
    /// normalised, bottom-left-origin convention, as before.
    static func recognizeWithLayout(_ image: CGImage) async throws -> [(text: String, box: CGRect)] {
        let result = try await recognize(image, options: .fromSettings())
        let width = max(1, result.imageSize.width), height = max(1, result.imageSize.height)
        return result.lines.map { line in
            (line.text, CGRect(x: line.box.minX / width, y: 1 - line.box.maxY / height,
                               width: line.box.width / width, height: line.box.height / height))
        }
    }

    /// Normalised (bottom-left origin) boxes of recognised lines containing
    /// `query`, case-insensitively — the Smart Highlighter's search.
    static func boxes(matching query: String, in image: CGImage, limit: Int = 100) async throws -> [CGRect] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let compactNeedle = needle.filter { !$0.isWhitespace }
        return try await recognizeWithLayout(image).filter { item in
            item.text.localizedCaseInsensitiveContains(needle)
                || item.text.filter { !$0.isWhitespace }.localizedCaseInsensitiveContains(compactNeedle)
        }.prefix(limit).map(\.box)
    }

    /// Background-friendly text for search indexing (clipboard images).
    /// Uses line breaks, no Live Text (it is UI-oriented and slower), and
    /// never throws: an unreadable image simply indexes as nil.
    static func recognizeForIndexing(_ image: CGImage, maximumLength: Int = 100_000) async -> String? {
        var options = TextRecognitionOptions.fromSettings(keepsLineBreaks: true)
        options.engine = .vision
        options.maximumScriptPasses = 3
        guard let text = try? await recognize(image, options: options).text else { return nil }
        return String(text.prefix(maximumLength))
    }

    /// Image-data convenience for `recognizeForIndexing(_:)`.
    static func recognizeForIndexing(imageData: Data, maximumLength: Int = 100_000) async -> String? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return await recognizeForIndexing(image, maximumLength: maximumLength)
    }

    /// The languages Vision can currently recognize, for a settings picker.
    static func supportedLanguages() -> [String] {
        TextCaptureLanguages.supported
    }
}
