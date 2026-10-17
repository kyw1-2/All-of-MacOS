import Foundation
import AVFoundation
import NaturalLanguage

/// Reads recognised text aloud in the language it was written in.
///
/// TextSniper uses NSSpeechSynthesizer with the system voice; AOM picks an
/// AVSpeechSynthesizer voice matching the detected language, so a Korean
/// capture is not read by an English voice.
@MainActor
final class TextCaptureSpeech: NSObject, ObservableObject {
    static let shared = TextCaptureSpeech()

    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Best installed voice language for a BCP-47 code ("ko" → "ko-KR").
    nonisolated static func voiceLanguage(for code: String?,
                                          available: [String] = AVSpeechSynthesisVoice.speechVoices().map(\.language),
                                          preferred: [String] = Locale.preferredLanguages) -> String? {
        guard let code, !code.isEmpty else { return nil }
        if available.contains(code) { return code }
        let base = code.split(separator: "-").first.map(String.init)?.lowercased() ?? code.lowercased()
        // Chinese: keep the script/region family (zh-Hant → zh-TW/zh-HK voices).
        if base == "zh" {
            let traditional = code.contains("Hant") || code.hasSuffix("TW") || code.hasSuffix("HK")
            let wanted = traditional ? ["zh-TW", "zh-HK"] : ["zh-CN"]
            if let match = wanted.first(where: available.contains) { return match }
        }
        // Prefer the user's own regional variant of the language.
        if let regional = preferred.first(where: { $0.lowercased().hasPrefix(base + "-") }),
           available.contains(regional) { return regional }
        return available.first { $0.lowercased().hasPrefix(base + "-") || $0.lowercased() == base }
    }

    func speak(_ text: String, languageCode: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: String(trimmed.prefix(20_000)))
        let code = languageCode ?? TextRecognitionEngine.dominantLanguage(trimmed)
        if let language = Self.voiceLanguage(for: code), let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    func toggle(_ text: String, languageCode: String? = nil) {
        if isSpeaking { stop() } else { speak(text, languageCode: languageCode) }
    }
}

extension TextCaptureSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = synthesizer.isSpeaking }
    }
}
