import Foundation
import Vision

/// Groups of recognition languages that share a script. Vision's accurate
/// recogniser effectively reads one script family per pass (the first
/// language of `recognitionLanguages` decides), so the engine runs one pass
/// per group that is present and lets the passes vote.
enum TextScriptGroup: String, CaseIterable {
    case latin, hangul, japanese, chineseSimplified, chineseTraditional, cyrillic, thai, arabic, devanagari

    /// The Vision language placed first for this group's pass.
    var leadLanguage: String {
        switch self {
        case .latin: return "en-US"
        case .hangul: return "ko-KR"
        case .japanese: return "ja-JP"
        case .chineseSimplified: return "zh-Hans"
        case .chineseTraditional: return "zh-Hant"
        case .cyrillic: return "ru-RU"
        case .thai: return "th-TH"
        case .arabic: return "ar-SA"
        case .devanagari: return "hi-IN"
        }
    }

    /// Scripts this group reads natively.
    var nativeScripts: Set<TextScript> {
        switch self {
        case .latin: return [.latin]
        case .hangul: return [.hangul]
        case .japanese: return [.han, .kana, .cjkPunctuation]
        case .chineseSimplified, .chineseTraditional: return [.han, .cjkPunctuation]
        case .cyrillic: return [.cyrillic]
        case .thai: return [.thai]
        case .arabic: return [.arabic]
        case .devanagari: return [.devanagari]
        }
    }

    static func group(forLanguage code: String) -> TextScriptGroup {
        let lower = code.lowercased()
        if lower.hasPrefix("ko") { return .hangul }
        if lower.hasPrefix("ja") { return .japanese }
        if lower.hasPrefix("zh-hant") || lower.hasPrefix("yue-hant") { return .chineseTraditional }
        if lower.hasPrefix("zh") || lower.hasPrefix("yue") { return .chineseSimplified }
        if lower.hasPrefix("ru") || lower.hasPrefix("uk") || lower.hasPrefix("bg") { return .cyrillic }
        if lower.hasPrefix("th") { return .thai }
        if lower.hasPrefix("ar") || lower.hasPrefix("ars") || lower.hasPrefix("fa") { return .arabic }
        if lower.hasPrefix("hi") || lower.hasPrefix("mr") { return .devanagari }
        return .latin
    }

    /// Groups implied by the scripts seen in a recognition result. Han
    /// without Kana is ambiguous between Chinese and Japanese, so the caller's
    /// language priority decides (defaulting to Simplified Chinese).
    static func groups(forScripts scripts: [TextScript: Int], priority: [String]) -> [TextScriptGroup] {
        var result: [TextScriptGroup] = []
        func add(_ g: TextScriptGroup) { if !result.contains(g) { result.append(g) } }
        if scripts[.hangul, default: 0] > 0 { add(.hangul) }
        if scripts[.kana, default: 0] > 0 { add(.japanese) }
        if scripts[.han, default: 0] > 0 {
            let cjkGroups: Set<TextScriptGroup> = [.japanese, .chineseSimplified, .chineseTraditional]
            var han: TextScriptGroup?
            for code in priority {
                let candidate = group(forLanguage: code)
                if cjkGroups.contains(candidate) { han = candidate; break }
            }
            add(han ?? .chineseSimplified)
        }
        if scripts[.cyrillic, default: 0] > 0 { add(.cyrillic) }
        if scripts[.thai, default: 0] > 0 { add(.thai) }
        if scripts[.arabic, default: 0] > 0 { add(.arabic) }
        if scripts[.devanagari, default: 0] > 0 { add(.devanagari) }
        if scripts[.latin, default: 0] > 0 { add(.latin) }
        return result
    }
}

enum TextCaptureLanguages {
    /// Vision's languages for the accurate recogniser at the latest revision,
    /// in Vision's own order. Cached: the list only changes with the OS.
    static let supported: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequest.currentRevision
        let list = (try? request.supportedRecognitionLanguages()) ?? []
        return list.isEmpty ? ["en-US"] : list
    }()

    /// A localised name for a Vision language code ("ko-KR" → "한국어 (대한민국)"
    /// under a Korean UI). Vision uses a few non-standard codes; those are
    /// mapped to their BCP-47 equivalents for naming only.
    static func displayName(for code: String, locale: Locale = .current) -> String {
        let aliases = ["vi-VT": "vi-VN", "ars-SA": "ar-SA", "yue-Hans": "yue-Hans-CN", "yue-Hant": "yue-Hant-HK"]
        let identifier = aliases[code] ?? code
        var name = locale.localizedString(forIdentifier: identifier) ?? code
        if code == "ars-SA" { name += " (Najdi)" }
        return name
    }

    /// Picker order: alphabetical by localised name.
    static func pickerOrder(_ codes: [String] = supported, locale: Locale = .current) -> [String] {
        codes.sorted {
            displayName(for: $0, locale: locale)
                .localizedStandardCompare(displayName(for: $1, locale: locale)) == .orderedAscending
        }
    }

    /// The supported code that best matches an arbitrary BCP-47 identifier
    /// ("zh-Hant-TW" → "zh-Hant", "en-GB" → "en-US", "ko" → "ko-KR").
    static func bestMatch(for identifier: String, in supported: [String] = supported) -> String? {
        if supported.contains(identifier) { return identifier }
        let parts = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased() else { return nil }
        let candidates = supported.filter { $0.split(separator: "-").first?.lowercased() == language }
        guard !candidates.isEmpty else {
            if language == "nb" || language == "nn" { return supported.first { $0.hasPrefix("no") } }
            return nil
        }
        if language == "zh" || language == "yue" {
            let traditionalRegions: Set<String> = ["TW", "HK", "MO"]
            let traditional = parts.contains("Hant") || parts.contains { traditionalRegions.contains($0.uppercased()) }
            let script = traditional ? "Hant" : "Hans"
            return candidates.first { $0.contains(script) } ?? candidates.first
        }
        if parts.count > 1, let exactRegion = candidates.first(where: { $0.hasSuffix("-" + parts[parts.count - 1].uppercased()) }) {
            return exactRegion
        }
        return candidates.first
    }

    /// The user's system languages mapped onto Vision codes, most preferred first.
    static func automaticPriority(preferred: [String] = Locale.preferredLanguages,
                                  supported: [String] = supported) -> [String] {
        var result: [String] = []
        for identifier in preferred {
            if let match = bestMatch(for: identifier, in: supported), !result.contains(match) {
                result.append(match)
            }
        }
        return result
    }

    /// The full ordered list handed to the recogniser: the user's languages in
    /// their order (or the system's under Automatic), English as a fallback
    /// for Latin text, then every other supported language — TextSniper's
    /// approach of giving Vision the whole list with the primary first.
    static func priorityList(selected: [String], automatic: Bool,
                             preferred: [String] = Locale.preferredLanguages,
                             supported: [String] = supported) -> [String] {
        var head = automatic ? automaticPriority(preferred: preferred, supported: supported)
                             : selected.compactMap { bestMatch(for: $0, in: supported) }
        if head.isEmpty { head = automaticPriority(preferred: preferred, supported: supported) }
        var result: [String] = []
        for code in head where !result.contains(code) { result.append(code) }
        if supported.contains("en-US"), !result.contains("en-US") { result.append("en-US") }
        for code in supported where !result.contains(code) { result.append(code) }
        return result
    }

    /// The language list for one script-group pass: the group's best language
    /// first (the user's own choice within the group wins over the default),
    /// then the rest of the priority list.
    static func passLanguages(for group: TextScriptGroup, priority: [String]) -> [String] {
        let lead = priority.first { TextScriptGroup.group(forLanguage: $0) == group } ?? group.leadLanguage
        return [lead] + priority.filter { $0 != lead }
    }
}
