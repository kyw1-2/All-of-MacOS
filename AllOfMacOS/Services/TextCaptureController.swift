import Foundation
import AppKit
import UniformTypeIdentifiers

/// What happens after pixels for Capture Text exist: recognition, barcode
/// reading, clipboard (replace or append), sound, result HUD and speech.
///
/// The selection and the pixel grab stay in `CaptureCoordinator`; every text
/// entry point (menu, All-In-One "Capture Text", shortcuts, clipboard image)
/// funnels into `deliver` so they all behave identically.
@MainActor
final class TextCaptureController {
    static let shared = TextCaptureController()

    var settings: TextCaptureSettings = .shared
    var pasteboard: NSPasteboard = .general

    struct Outcome: Equatable {
        var copiedText: String
        var appended: Bool
        var links: [URL]
        var barcodes: [String]
    }

    // MARK: - Pure helpers

    /// The recognised text plus barcode payloads that are not already part
    /// of it (a QR code next to its own printed URL is not duplicated).
    nonisolated static func composeOutput(text: String, barcodes: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = barcodes.filter { !$0.isEmpty && !trimmed.contains($0) }
        if trimmed.isEmpty { return extra.joined(separator: "\n") }
        return extra.isEmpty ? trimmed : trimmed + "\n" + extra.joined(separator: "\n")
    }

    /// Additive clipboard: append to the clipboard's current text on a new line.
    nonisolated static func clipboardText(for output: String, existing: String?, additive: Bool) -> (text: String, appended: Bool) {
        guard additive, let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (output, false)
        }
        let separator = existing.hasSuffix("\n") ? "" : "\n"
        return (existing + separator + output, true)
    }

    // MARK: - Delivery

    /// Recognises `image` and delivers the result. Returns nil when nothing
    /// was found (after telling the user).
    @discardableResult
    func deliver(image: CGImage, keepsLineBreaks: Bool? = nil, anchor: CGRect? = nil,
                 allowsAdditive: Bool = true) async throws -> Outcome? {
        let options = TextRecognitionOptions.fromSettings(settings, keepsLineBreaks: keepsLineBreaks)
        async let recognition = TextRecognitionService.recognize(image, options: options)
        let barcodes: [String] = settings.readsBarcodes
            ? ((try? await TextRecognitionService.detectBarcodes(image)) ?? []).map(\.payload) : []
        let result = try await recognition
        let output = Self.composeOutput(text: result.text, barcodes: barcodes)
        guard !output.isEmpty else {
            if settings.playsSound { NSSound(named: "Funk")?.play() }
            GestureHUD.shared.show(title: "No Text Detected", detail: "The selection contained no recognizable text.")
            return nil
        }
        let existing = pasteboard.string(forType: .string)
        let clip = Self.clipboardText(for: output, existing: existing,
                                      additive: allowsAdditive && settings.additiveClipboard)
        pasteboard.clearContents()
        pasteboard.setString(clip.text, forType: .string)

        let links = settings.detectsLinks ? TextPostProcessor.links(in: output) : []
        if settings.playsSound { NSSound(named: "Pop")?.play() }
        let outcome = Outcome(copiedText: output, appended: clip.appended, links: links, barcodes: barcodes)
        present(outcome, result: result, anchor: anchor)
        if settings.speaksResult { TextCaptureSpeech.shared.speak(output, languageCode: result.detectedLanguage) }
        return outcome
    }

    private func present(_ outcome: Outcome, result: TextRecognitionResult, anchor: CGRect?) {
        let characters = outcome.copiedText.count
        let title = outcome.appended ? "Added to Clipboard" : "Text Copied"
        guard settings.showsResultHUD else {
            GestureHUD.shared.show(title: title, detail: "\(characters) characters")
            return
        }
        var details = ["\(characters) characters"]
        if let code = result.detectedLanguage {
            details.append(Locale.current.localizedString(forLanguageCode: code) ?? code)
        }
        if result.usedLiveText { details.append("Live Text") }
        let model = TextCaptureHUDModel(title: title, subtitle: details.joined(separator: " · "),
                                        text: outcome.copiedText, links: outcome.links,
                                        barcodes: outcome.barcodes, languageCode: result.detectedLanguage,
                                        symbol: outcome.appended ? "text.badge.plus" : "checkmark.circle.fill")
        TextCaptureHUDController.shared.show(model, anchor: anchor, duration: settings.hudDuration)
    }

    // MARK: - QR / barcodes

    /// "Read QR / Barcode": copies every payload, one per line.
    @discardableResult
    func deliverBarcodes(image: CGImage, anchor: CGRect? = nil) async -> [String] {
        let codes = ((try? await TextRecognitionService.detectBarcodes(image)) ?? []).map(\.payload)
        guard !codes.isEmpty else {
            if settings.playsSound { NSSound(named: "Funk")?.play() }
            GestureHUD.shared.show(title: "No QR/Bar Code Detected", detail: "Try a larger selection.")
            return []
        }
        let text = codes.joined(separator: "\n")
        let clip = Self.clipboardText(for: text, existing: pasteboard.string(forType: .string),
                                      additive: settings.additiveClipboard)
        pasteboard.clearContents()
        pasteboard.setString(clip.text, forType: .string)
        if settings.playsSound { NSSound(named: "Pop")?.play() }
        let links = settings.detectsLinks ? TextPostProcessor.links(in: text) : []
        if settings.showsResultHUD {
            let model = TextCaptureHUDModel(title: codes.count == 1 ? "Code Copied" : "\(codes.count) Codes Copied",
                                            subtitle: "QR / barcode", text: text, links: links, barcodes: [],
                                            languageCode: nil, symbol: "qrcode")
            TextCaptureHUDController.shared.show(model, anchor: anchor, duration: settings.hudDuration)
        } else {
            GestureHUD.shared.show(title: "Code Copied", detail: String(text.prefix(80)))
        }
        return codes
    }

    // MARK: - Clipboard image

    /// The first image on `pasteboard`: image data, or an image file URL.
    static func clipboardImage(from pasteboard: NSPasteboard) -> CGImage? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                return image
            }
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            var rect = CGRect(origin: .zero, size: image.size)
            if let best = image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }),
               let cg = best.cgImage {
                return cg
            }
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }

    /// "Capture Text from Clipboard Image".
    func captureFromClipboardImage() {
        guard let image = Self.clipboardImage(from: pasteboard) else {
            GestureHUD.shared.show(title: "No Image on Clipboard", detail: "Copy an image or an image file first.")
            return
        }
        Task { @MainActor in
            do {
                // The clipboard held the image itself, so there is no text to append to.
                try await deliver(image: image, allowsAdditive: false)
            } catch {
                GestureHUD.shared.show(title: "Text Recognition Failed", detail: error.localizedDescription)
            }
        }
    }
}
