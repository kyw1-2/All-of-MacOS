import Foundation
import Combine

/// Which recogniser Capture Text uses.
enum TextRecognitionEngineMode: String, CaseIterable, Identifiable {
    /// Vision multi-pass per script group, cross-checked by Live Text.
    case automatic
    /// VisionKit Live Text transcript first (TextSniper's CJK path).
    case liveText
    /// Vision only (no VisionKit).
    case vision

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic (Vision + Live Text)"
        case .liveText: return "Live Text"
        case .vision: return "Vision"
        }
    }
}

/// Capture Text (OCR) preferences.
///
/// Values are read when a capture runs, so changes apply to the next capture.
/// Tests and the isolated UI preview get a throwaway suite so they can never
/// rewrite the installed app's preferences.
final class TextCaptureSettings: ObservableObject {
    static let shared = TextCaptureSettings()

    enum Key {
        static let automaticLanguages = "AOMTextCaptureAutomaticLanguages"
        static let languages = "AOMTextCaptureLanguages"
        /// Shared with `CaptureSettings.ocrKeepsLineBreaks` (pre-existing key).
        static let keepsLineBreaks = "AOMOCRKeepsLineBreaks"
        static let additiveClipboard = "AOMTextCaptureAdditiveClipboard"
        static let joinsHyphenatedWords = "AOMTextCaptureJoinHyphens"
        static let detectsLinks = "AOMTextCaptureDetectLinks"
        static let readsBarcodes = "AOMTextCaptureReadBarcodes"
        static let playsSound = "AOMTextCapturePlaySound"
        static let showsResultHUD = "AOMTextCaptureShowHUD"
        static let hudDuration = "AOMTextCaptureHUDDuration"
        static let speaksResult = "AOMTextCaptureSpeak"
        static let usesLanguageCorrection = "AOMTextCaptureLanguageCorrection"
        static let customWords = "AOMTextCaptureCustomWords"
        static let engine = "AOMTextCaptureEngine"
        static let fastRecognition = "AOMTextCaptureFastRecognition"
    }

    let defaults: UserDefaults
    private static let isolatedDefaults = UserDefaults(suiteName: "AOMTextCapture-Isolated-\(UUID().uuidString)")!

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ((PresetManager.isRunningTests || PresetManager.isUIPreview)
            ? Self.isolatedDefaults : .standard)
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func set(_ value: Any?, _ key: String) {
        objectWillChange.send()
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// "Automatic" follows the system language order.
    var usesAutomaticLanguages: Bool {
        get { bool(Key.automaticLanguages, true) }
        set { set(newValue, Key.automaticLanguages) }
    }

    /// The user's ordered language choice (Vision codes), used when Automatic is off.
    var selectedLanguages: [String] {
        get {
            let stored = defaults.stringArray(forKey: Key.languages) ?? []
            var unique: [String] = []
            for code in stored where !unique.contains(code) { unique.append(code) }
            return unique
        }
        set {
            var unique: [String] = []
            for code in newValue where !unique.contains(code) { unique.append(code) }
            set(unique, Key.languages)
        }
    }

    var keepsLineBreaks: Bool {
        get { bool(Key.keepsLineBreaks, true) }
        set { set(newValue, Key.keepsLineBreaks) }
    }

    /// Append each result to the text already on the clipboard.
    var additiveClipboard: Bool {
        get { bool(Key.additiveClipboard, false) }
        set { set(newValue, Key.additiveClipboard) }
    }

    var joinsHyphenatedWords: Bool {
        get { bool(Key.joinsHyphenatedWords, true) }
        set { set(newValue, Key.joinsHyphenatedWords) }
    }

    var detectsLinks: Bool {
        get { bool(Key.detectsLinks, true) }
        set { set(newValue, Key.detectsLinks) }
    }

    /// Also read QR codes and barcodes inside a text capture.
    var readsBarcodes: Bool {
        get { bool(Key.readsBarcodes, true) }
        set { set(newValue, Key.readsBarcodes) }
    }

    var playsSound: Bool {
        get { bool(Key.playsSound, true) }
        set { set(newValue, Key.playsSound) }
    }

    var showsResultHUD: Bool {
        get { bool(Key.showsResultHUD, true) }
        set { set(newValue, Key.showsResultHUD) }
    }

    /// Seconds before the result HUD fades (hovering pauses it).
    var hudDuration: Double {
        get {
            let value = defaults.object(forKey: Key.hudDuration) as? Double ?? 6
            return min(30, max(2, value))
        }
        set { set(min(30, max(2, newValue)), Key.hudDuration) }
    }

    var speaksResult: Bool {
        get { bool(Key.speaksResult, false) }
        set { set(newValue, Key.speaksResult) }
    }

    /// TextSniper always enables Vision's language correction; so does AOM by default.
    var usesLanguageCorrection: Bool {
        get { bool(Key.usesLanguageCorrection, true) }
        set { set(newValue, Key.usesLanguageCorrection) }
    }

    /// Comma- or newline-separated vocabulary for language correction.
    var customWordsText: String {
        get { defaults.string(forKey: Key.customWords) ?? "" }
        set { set(newValue, Key.customWords) }
    }

    var customWords: [String] {
        customWordsText.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var engine: TextRecognitionEngineMode {
        get { TextRecognitionEngineMode(rawValue: defaults.string(forKey: Key.engine) ?? "") ?? .automatic }
        set { set(newValue.rawValue, Key.engine) }
    }

    /// Instant recognition: a single pass unless the text needs the
    /// multi-script voting pipeline (on by default, like TextSniper).
    var prefersFastRecognition: Bool {
        get { bool(Key.fastRecognition, true) }
        set { set(newValue, Key.fastRecognition) }
    }

    /// The full ordered language list for the recogniser.
    var recognitionLanguages: [String] {
        TextCaptureLanguages.priorityList(selected: selectedLanguages, automatic: usesAutomaticLanguages)
    }

    // MARK: Ordered multi-select editing

    func addLanguage(_ code: String) {
        var list = selectedLanguages.isEmpty && usesAutomaticLanguages
            ? TextCaptureLanguages.automaticPriority() : selectedLanguages
        if !list.contains(code) { list.append(code) }
        selectedLanguages = list
    }

    func removeLanguage(_ code: String) {
        selectedLanguages = selectedLanguages.filter { $0 != code }
    }

    func moveLanguage(_ code: String, by offset: Int) {
        var list = selectedLanguages
        guard let index = list.firstIndex(of: code) else { return }
        let target = min(list.count - 1, max(0, index + offset))
        guard target != index else { return }
        list.remove(at: index)
        list.insert(code, at: target)
        selectedLanguages = list
    }

    /// Switching Automatic off seeds the editable list from the system order.
    func setAutomaticLanguages(_ automatic: Bool) {
        if !automatic, selectedLanguages.isEmpty {
            selectedLanguages = TextCaptureLanguages.automaticPriority()
        }
        usesAutomaticLanguages = automatic
    }
}
