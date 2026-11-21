import AppKit

/// Text that goes with one question (7.4): the clipboard (@clip), the
/// window the launcher opened over (@window) or the display under the
/// pointer (@screen). Screen text is read with on-device OCR; only the text
/// goes to the model, and text that looks like a password or key is held
/// back as the clipboard's is.
struct AOMAIAttachment: Equatable {
    /// "Clipboard", "Safari window", "Screen".
    let label: String
    /// How the text is introduced to the model.
    let heading: String
    let text: String

    static let limit = 20_000

    var sent: String { "\n\n\(heading):\n```\n\(text)\n```" }

    static func clipboard(_ text: String) -> AOMAIAttachment {
        AOMAIAttachment(label: "Clipboard", heading: "Clipboard text the user attached", text: text)
    }

    /// Pure: OCR text to an attachment, or why it isn't attached.
    static func screenText(_ text: String, label: String, heading: String) -> Result<AOMAIAttachment, AOMAIError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(AOMAIError(message: "No text found in the \(label.lowercased()), so nothing was attached.")) }
        if ClipboardSecretScanner.containsSecret(inText: trimmed) {
            return .failure(AOMAIError(message: "The \(label.lowercased()) shows what looks like a password or key, so it wasn't attached."))
        }
        return .success(AOMAIAttachment(label: label, heading: heading, text: String(trimmed.prefix(limit))))
    }

    /// Reads @screen or @window now.
    @MainActor
    static func capture(_ source: AOMAIRecordSource, frontApp: NSRunningApplication?) async -> Result<AOMAIAttachment, AOMAIError> {
        guard ScreenCaptureService.hasPermission else {
            return .failure(AOMAIError(message: "\(source.mention) needs Screen Recording for AOM (System Settings › Privacy & Security)."))
        }
        let service = ScreenCaptureService.shared
        do {
            switch source {
            case .window:
                guard let app = frontApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    return .failure(AOMAIError(message: "@window reads the app the launcher opened over; open the launcher from that app."))
                }
                let window = try await service.frontWindow(of: app.processIdentifier)
                let result = try await service.captureWindow(window)
                let name = app.localizedName ?? "App"
                let title = (window.title ?? "").isEmpty ? name : "\(name) — \(window.title ?? "")"
                let text = await ClipboardImageText.recognize(result.image, maximumLength: limit)?.text ?? ""
                return screenText(text, label: "\(name) window", heading: "Text read from the user's \(title) window (OCR)")
            case .screen:
                let result = try await service.captureDisplayUnderPointerWithoutAOM()
                let text = await ClipboardImageText.recognize(result.image, maximumLength: limit)?.text ?? ""
                return screenText(text, label: "Screen", heading: "Text read from the user's screen (OCR)")
            default:
                return .failure(AOMAIError(message: "\(source.mention) isn't read from the screen."))
            }
        } catch {
            return .failure(AOMAIError(message: "\(source.mention) couldn't be read: \(error.localizedDescription)"))
        }
    }
}
