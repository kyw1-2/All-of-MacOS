import Foundation

/// What the selected text is, so the bar offers only the actions that apply.
/// Built off the main thread from the selection alone; nothing here reads
/// the screen, the clipboard or the network.
struct TextSelectionTraits: Equatable {
    /// The selection without white space at either end.
    var text: String
    /// A web address to open: an http(s) URL, a bare domain ("naver.com"),
    /// localhost or an IPv4 address.
    var link: URL?
    /// `link` came from text without a scheme ("github.com/apple").
    var isDomain = false
    /// One email address ("mailto:" removed).
    var email: String?
    var isNumber = false
    /// Numbers joined by operators ("3 + 4 × 2", "(1+2)/3", "2^10").
    var isMath = false
    /// Worth asking the calculator: a sum, a number with a unit, a function.
    var isCalculatorCandidate = false
    var isJSON = false
    var isMultiline = false
    var hasLetters = false
    /// Letters with an upper and a lower case (Latin, Greek, Cyrillic …).
    var hasCasedLetters = false
    var hasHangul = false
    /// Hangul, Han or Kana.
    var hasCJK = false
    /// "%20"-style escapes that URL decoding would change.
    var hasPercentEscapes = false
    /// The text this Base64 decodes to, when it is Base64 of readable UTF-8.
    var base64Decoded: String?
    /// Characters as people count them (grapheme clusters); a trailing line
    /// break from a triple click is not counted.
    var characters = 0
    var words = 0
    var lines = 0
}

enum TextSelectionClassifier {
    /// Longer selections are counted and copied but never parsed.
    static let parseLimit = 1_000_000
    /// Links and addresses are single tokens of at most this many characters.
    static let tokenLimit = 2_048

    static func classify(_ raw: String) -> TextSelectionTraits {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var traits = TextSelectionTraits(text: text)
        traits.characters = trimmingTrailingLineBreaks(raw).count
        traits.words = wordCount(text)
        traits.lines = lineCount(text)
        traits.isMultiline = traits.lines > 1
        scanScripts(text, into: &traits)
        guard !text.isEmpty, text.utf8.count <= parseLimit else { return traits }

        if !traits.isMultiline {
            if let address = email(in: text) {
                traits.email = address
            } else if let found = link(in: text) {
                traits.link = found.url
                traits.isDomain = found.isDomain
            }
        }
        traits.isNumber = isNumber(text)
        traits.isMath = isMath(text)
        traits.isCalculatorCandidate = isCalculatorCandidate(text, isMath: traits.isMath, isNumber: traits.isNumber)
        traits.isJSON = isJSON(text)
        traits.hasPercentEscapes = hasPercentEscapes(text)
        traits.base64Decoded = base64Text(text)
        return traits
    }

    // MARK: Counting

    static func trimmingTrailingLineBreaks(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isNewline { result.removeLast() }
        return String(result)
    }

    /// Words as the system segments them, so Korean, Chinese and Japanese
    /// text count sensibly. Very long text is split on white space instead.
    static func wordCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        if text.utf16.count > 200_000 {
            return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        text.enumerateLines { _, _ in count += 1 }
        return max(1, count)
    }

    private static func scanScripts(_ text: String, into traits: inout TextSelectionTraits) {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let properties = scalar.properties
            if properties.isAlphabetic { traits.hasLetters = true }
            if properties.changesWhenCaseMapped { traits.hasCasedLetters = true }
            if isHangul(value) {
                traits.hasHangul = true
                traits.hasCJK = true
            } else if isHanOrKana(value) {
                traits.hasCJK = true
            }
        }
    }

    static func isHangul(_ value: UInt32) -> Bool {
        (0xAC00...0xD7A3).contains(value) || (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value)
            || (0xA960...0xA97F).contains(value) || (0xD7B0...0xD7FF).contains(value)
    }

    static func isHanOrKana(_ value: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) || (0x20000...0x2A6DF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x3040...0x309F).contains(value) || (0x30A0...0x30FF).contains(value)
            || (0x31F0...0x31FF).contains(value)
    }

    // MARK: Links and addresses

    /// One token with quotes, brackets and sentence punctuation around it removed.
    static func cleanedToken(_ text: String) -> String {
        var token = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let pairs: [(Character, Character)] = [("<", ">"), ("(", ")"), ("[", "]"), ("\"", "\""), ("'", "'"),
                                               ("“", "”"), ("‘", "’"), ("「", "」"), ("『", "』")]
        var changed = true
        while changed {
            changed = false
            for (open, close) in pairs where token.count >= 2 && token.first == open && token.last == close {
                token = token.dropFirst().dropLast()
                changed = true
            }
            while let last = token.last, ".,;:!?。、，".contains(last) {
                token = token.dropLast()
                changed = true
            }
        }
        return String(token)
    }

    private static let emailPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*\.[A-Za-z]{2,63}$"#)

    /// One address, alone in the selection.
    static func email(in text: String) -> String? {
        var token = cleanedToken(text)
        if token.lowercased().hasPrefix("mailto:") { token = String(token.dropFirst("mailto:".count)) }
        guard !token.isEmpty, token.count <= 254, matches(emailPattern, token) else { return nil }
        return token
    }

    /// Top-level domains that are also common file extensions: "README.md"
    /// or "Safari.app" alone is a file name, not a website.
    static let fileLikeTopLevelDomains: Set<String> = ["app", "md", "py", "sh", "rs", "pl", "pm", "zip", "mov", "cc", "ps"]

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let localAddress = try! NSRegularExpression(
        pattern: #"^(?:localhost|(?:\d{1,3}\.){3}\d{1,3})(?::\d{1,5})?(?:[/?#]\S*)?$"#, options: [.caseInsensitive])
    private static let hostPattern = try! NSRegularExpression(
        pattern: #"^(?:[\p{L}\p{N}](?:[\p{L}\p{N}\-]{0,61}[\p{L}\p{N}])?\.)+(?:\p{L}{2,63}|xn--[a-z0-9\-]{1,59})$"#,
        options: [.caseInsensitive])

    /// A web address alone in the selection. Only http and https are opened:
    /// a page could show "shortcuts://…" or "file://…" text, and Open Link
    /// must never run an app's URL scheme from it.
    static func link(in text: String) -> (url: URL, isDomain: Bool)? {
        let token = cleanedToken(text)
        guard !token.isEmpty, token.count <= tokenLimit, !token.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = token.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: token), let host = url.host, !host.isEmpty else { return nil }
            return (url, false)
        }
        if lower.contains("://") || lower.hasPrefix("mailto:") { return nil }
        if matches(localAddress, token) {
            guard let url = URL(string: "http://" + token), url.host != nil else { return nil }
            if let host = url.host, host.contains("."), !host.split(separator: ".").allSatisfy({ (Int($0) ?? 256) <= 255 }) { return nil }
            return (url, false)
        }
        // A bare domain, maybe with a port and a path.
        let hostEnd = token.firstIndex(where: { "/?#:".contains($0) }) ?? token.endIndex
        let host = String(token[..<hostEnd])
        guard matches(hostPattern, host), let tld = host.split(separator: ".").last?.lowercased() else { return nil }
        let hasPath = hostEnd != token.endIndex
        if fileLikeTopLevelDomains.contains(tld), !hasPath, !lower.hasPrefix("www.") { return nil }
        // The system's link detector knows which top-level domains exist.
        guard let detector = linkDetector else { return nil }
        let range = NSRange(token.startIndex..., in: token)
        guard let match = detector.firstMatch(in: token, options: [], range: range), match.range == range,
              let detected = match.url, ["http", "https"].contains(detected.scheme?.lowercased() ?? "") else { return nil }
        guard let url = URL(string: "https://" + token), url.host != nil else { return nil }
        return (url, true)
    }

    // MARK: Numbers and sums

    private static let numberPattern = try! NSRegularExpression(
        pattern: #"^[+\-−]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:[eE][+\-]?\d+)?%?$"#)
    private static let mathCharacters = try! NSRegularExpression(pattern: #"^[\d\s.,+\-−*/×÷^%()]+$"#)
    private static let binaryOperator = try! NSRegularExpression(pattern: #"[\d)%]\s*[+\-−*/×÷^]\s*[\d(.]"#)
    /// "2024-10-31", "010-1234-5678", "10/31/2024", "978-3-16-148410-0", "10-20".
    private static let datesAndPhones = try! NSRegularExpression(pattern: #"^\d+(?:([\-/])\d+)(?:\1\d+)+$|^\d+-\d+$"#)
    private static let numberWithUnit = try! NSRegularExpression(
        pattern: #"^[+\-−]?\d[\d,.]*\s*[\p{L}°$€£¥₩%][\p{L}°$€£¥₩%/²³]*(?:\s*(?:to|in|as|→|->|=)\s*[\p{L}°$€£¥₩][\p{L}°$€£¥₩/²³]*)?$"#,
        options: [.caseInsensitive])
    private static let currencyFirst = try! NSRegularExpression(
        pattern: #"^[$€£¥₩]\s?\d[\d,.]*(?:\s*(?:to|in|as|→|->)\s*[\p{L}$€£¥₩]+)?$"#, options: [.caseInsensitive])
    private static let functionCall = try! NSRegularExpression(pattern: #"^[a-z]{2,6}\s*\(.*\d.*\)$"#, options: [.caseInsensitive])
    private static let percentOf = try! NSRegularExpression(pattern: #"^\d[\d,.]*\s*%\s*of\s*\d[\d,.]*$"#, options: [.caseInsensitive])

    static func isNumber(_ text: String) -> Bool { matches(numberPattern, text) }

    static func isMath(_ text: String) -> Bool {
        guard text.count <= 200, !text.contains(where: \.isNewline), text.contains(where: \.isNumber),
              matches(mathCharacters, text), contains(binaryOperator, text) else { return false }
        return !matches(datesAndPhones, text)
    }

    /// Asks the calculator only about short, single-line text with a digit
    /// that looks like a sum, a number with a unit or a function call.
    static func isCalculatorCandidate(_ text: String, isMath: Bool, isNumber: Bool) -> Bool {
        guard !text.isEmpty, text.count <= 160, !text.contains(where: \.isNewline), text.contains(where: \.isNumber) else { return false }
        if isMath { return true }
        if isNumber || matches(datesAndPhones, text) { return false }
        return matches(numberWithUnit, text) || matches(currencyFirst, text) || matches(functionCall, text) || matches(percentOf, text)
    }

    // MARK: Structured text

    static func isJSON(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last, (first == "{" && last == "}") || (first == "[" && last == "]"),
              text.utf8.count <= parseLimit else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    private static let percentEscape = try! NSRegularExpression(pattern: "%[0-9A-Fa-f]{2}")

    static func hasPercentEscapes(_ text: String) -> Bool {
        guard contains(percentEscape, text), let decoded = text.removingPercentEncoding else { return false }
        return decoded != text
    }

    private static let base64Characters = try! NSRegularExpression(pattern: #"^[A-Za-z0-9+/_\-]+={0,2}$"#)

    /// The UTF-8 text a Base64 selection holds, or nil. Plain words are
    /// valid Base64 too, so short text without digits, symbols or padding is
    /// not treated as Base64, and the result must be readable text.
    static func base64Text(_ text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace && !$0.isNewline }
        guard compact.count >= 8, compact.utf8.count <= parseLimit, matches(base64Characters, compact) else { return nil }
        let looksEncoded = compact.count >= 16 || compact.contains(where: { $0.isNumber || "+/=-_".contains($0) })
        guard looksEncoded else { return nil }
        var normalized = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let unpadded = normalized.filter { $0 != "=" }.count
        if unpadded % 4 == 1 { return nil }
        if normalized.count % 4 != 0 { normalized += String(repeating: "=", count: 4 - normalized.count % 4) }
        guard let data = Data(base64Encoded: normalized), !data.isEmpty,
              let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty else { return nil }
        let readable = decoded.unicodeScalars.allSatisfy { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t" || !(scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .unassigned || scalar.properties.generalCategory == .privateUse)
        }
        guard readable, decoded.unicodeScalars.contains(where: { $0.properties.isAlphabetic || ("0"..."9").contains($0) }) else { return nil }
        return decoded
    }

    // MARK: Helpers

    static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range) else { return false }
        return match.range == range
    }

    static func contains(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }
}
