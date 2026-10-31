import Foundation
import NaturalLanguage

/// The web addresses the bar's actions open. Pure functions: nothing is
/// opened here, so every engine's encoding (Korean included) is tested.
enum TextActionURLs {
    /// RFC 3986 unreserved characters; everything else is percent-encoded
    /// (a space becomes %20, "한" becomes %ED%95%9C).
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// Characters of the selection a search sends; longer text is cut at a word.
    static let searchLimit = 500
    /// Characters a translation link carries, and the most its encoded text
    /// may take, so the address stays short enough for the translator's
    /// server (Korean takes nine encoded characters per syllable).
    static let translateLimit = 2_000
    static let translateEncodedLimit = 7_000
    static let gitHubTemplate = "https://github.com/search?q={query}"

    static func encoded(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// A custom engine is any URL with `{query}` and no spaces. Its scheme
    /// may be an app's ("dash://{query}"): the user typed it, not a web page.
    static func isValidTemplate(_ template: String) -> Bool {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("{query}"), !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed.replacingOccurrences(of: "{query}", with: "x")),
              let scheme = url.scheme, !scheme.isEmpty else { return false }
        return true
    }

    /// White space folded to single spaces and cut at a word boundary.
    static func query(_ text: String, limit: Int) -> String {
        let folded = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard folded.count > limit else { return folded }
        let cut = folded.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space])
        }
        return String(cut)
    }

    static func fill(_ template: String, with text: String) -> URL? {
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidTemplate(template), !text.isEmpty, let value = encoded(text) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{query}", with: value))
    }

    static func search(_ text: String, engine: TextSearchEngine, customTemplate: String) -> URL? {
        guard let template = engine.template ?? (customTemplate.isEmpty ? nil : customTemplate) else { return nil }
        return fill(template, with: query(text, limit: searchLimit))
    }

    static func gitHubSearch(_ text: String) -> URL? {
        fill(gitHubTemplate, with: query(text, limit: 256))
    }

    // MARK: Translation

    /// The text a translation link carries: line breaks kept, at most
    /// `translateLimit` characters and `translateEncodedLimit` encoded
    /// characters, cut at a sentence or a word when possible.
    static func translationText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedCount = encoded(trimmed)?.count ?? trimmed.utf8.count * 3
        guard trimmed.count > translateLimit || encodedCount > translateEncodedLimit else { return trimmed }
        // As many characters as fit both limits, estimated from the average encoded width.
        let perCharacter = max(1, Double(encodedCount) / Double(max(1, trimmed.count)))
        var limit = min(translateLimit, Int(Double(translateEncodedLimit) / perCharacter))
        var cut = String(trimmed.prefix(limit))
        while limit > 1, (encoded(cut)?.count ?? 0) > translateEncodedLimit {
            limit = limit * 9 / 10
            cut = String(trimmed.prefix(limit))
        }
        let breaks: [Character] = [".", "!", "?", "。", "\n", " "]
        if let end = cut.lastIndex(where: { breaks.contains($0) }), cut.distance(from: cut.startIndex, to: end) > limit / 2 {
            return String(cut[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cut
    }

    static func translate(_ text: String, translator: TextTranslator, from: String, to: String) -> URL? {
        let source = translationText(text)
        guard !source.isEmpty, let value = encoded(source),
              from == "auto" || TextTranslateLanguage.isSupported(from), TextTranslateLanguage.isSupported(to) else { return nil }
        switch translator {
        case .google:
            return URL(string: "https://translate.google.com/?sl=\(from)&tl=\(to)&text=\(value)&op=translate")
        case .papago:
            return URL(string: "https://papago.naver.com/?sk=\(from)&tk=\(to)&st=\(value)")
        }
    }

    /// Translating text that is already in the target language does nothing,
    /// so with "Detect Language" such text goes to English instead (or from
    /// English to the person's other language, when they have one).
    static func targetLanguage(for text: String, from: String, to: String,
                               preferred: [String] = Locale.preferredLanguages) -> String {
        guard from == "auto", let detected = dominantLanguage(of: text), detected == to else { return to }
        if to != "en" { return "en" }
        return preferred.lazy.compactMap(TextTranslateLanguage.code(forPreferredLanguage:)).first { $0 != "en" } ?? to
    }

    /// The language of the text as a translator code, when it is clear.
    /// Hangul settles Korean on its own, even in short text.
    static func dominantLanguage(of text: String) -> String? {
        let sample = String(text.prefix(1_000))
        var hangul = 0, otherLetters = 0
        for scalar in sample.unicodeScalars where scalar.properties.isAlphabetic {
            if TextSelectionClassifier.isHangul(scalar.value) { hangul += 1 } else { otherLetters += 1 }
        }
        if hangul > 0, hangul >= otherLetters / 2 { return "ko" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.8 else { return nil }
        switch language {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        default:
            let code = language.rawValue.split(separator: "-").first.map(String.init) ?? language.rawValue
            return TextTranslateLanguage.isSupported(code) ? code : nil
        }
    }

    // MARK: Other actions

    /// Dictionary's own scheme: dict://word.
    static func lookUp(_ text: String) -> URL? {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let value = encoded(term) else { return nil }
        return URL(string: "dict://" + value)
    }

    static func mail(to address: String) -> URL? {
        guard TextSelectionClassifier.email(in: address) == address else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        return components.url
    }
}

/// The Count chip's words.
enum TextActionCountFormat {
    static func chip(characters: Int, words: Int) -> String {
        "\(characters.formatted()) \(characters == 1 ? "char" : "chars") · \(words.formatted()) \(words == 1 ? "word" : "words")"
    }

    static func spoken(characters: Int, words: Int, lines: Int) -> String {
        var parts = ["\(characters.formatted()) \(characters == 1 ? "character" : "characters")",
                     "\(words.formatted()) \(words == 1 ? "word" : "words")"]
        if lines > 1 { parts.append("\(lines.formatted()) lines") }
        return parts.joined(separator: ", ")
    }
}
