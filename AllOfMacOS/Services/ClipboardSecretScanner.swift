import AppKit
import Foundation

/// The outbound secret check (audit 2026-10-29, PA-03).
///
/// `ClipboardItemClassifier.classify(text:)` answers "what kind of clip is
/// this?" for suggestions and deliberately skips most work on huge clips.
/// This type answers "may this leave the shelf?" — for MCP replies, for
/// copies made on behalf of AI tools and for automatic suggestions — and has
/// none of those shortcuts:
/// - every kind is scanned (text, link, image, file, color), not only text;
/// - every textual representation is decoded: UTF-8 and UTF-16 text, RTF,
///   RTFD, HTML, URLs and file URLs, plus the title and recognised image text;
/// - percent-encoding, HTML character references, zero-width characters and
///   compatibility forms (full-width letters) are undone before matching;
/// - there is no length limit. Multi-megabyte forms are searched whole, in
///   overlapping slices on several cores;
/// - credential names are recognised as quoted keys too (JSON
///   `"password": "…"`, YAML `'token': '…'`) at any length, and JSON up to
///   `structuredScanLimit` is also read key by key, at any depth (re-audit
///   2026-10-30, N333-01).
///
/// Base64 or encrypted blobs are not decoded: only credentials that look like
/// credentials are recognised.
enum ClipboardSecretScanner {
    /// Shown instead of anything withheld from AI tools.
    static let placeholder = "[hidden: looks like a password, token or key]"

    /// Credentials recognisable anywhere inside a longer text. Every pattern
    /// starts with a narrow literal or character set, which keeps a 20 MB log
    /// at about a second of matching instead of several.
    static let patterns: [NSRegularExpression] = [
        // JSON Web Tokens.
        #"eyJ[A-Za-z0-9_-]{7,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
        // Provider API keys: sk-…, GitHub, Slack, AWS, Google.
        #"sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}"#,
        // Inline credentials: password=…, token: …, api_key=…, ?access_token=…,
        // and the same names as quoted keys: "password": "…", 'token': '…'.
        inlineCredentials,
        // Quoted camelCase keys: "accessToken": "…", "clientSecret": "…".
        camelCaseCredentials,
        // Authorization headers.
        #"\bBearer [A-Za-z0-9._~+/=-]{20,}|\bBasic [A-Za-z0-9+/=]{8,}"#,
        // PEM private keys.
        #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED |)PRIVATE KEY-----"#,
        // Passwords inside URLs: scheme://user:password@host.
        #"://[^\s/?#@:]+:[^\s/?#@]+@"#,
        // Signed or authenticated URLs: X-Amz-Signature=…, &sig=…, &session_id=….
        #"(?i)[?&;#](?:[a-z0-9_.-]*(?:signature|credential|session_?id|auth_?key|access_?key|secret_?key)|sig|sid|auth)=[^&#\s]{6,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    // Quoted keys (N333-01). `{"password": "…"}` slipped past the inline
    // pattern, which wanted `:` or `=` right after the name, not a quote.

    /// A quote around a key or a value: straight, typographic, or escaped
    /// (`\"`) as in JSON inside a JSON string.
    private static let quote = #"\\?["'“”‘’]"#

    /// Values that stand in for a credential rather than being one: masked
    /// (`***`, `••••`), a template (`<redacted>`, `<your-token>`), this
    /// scanner's own `placeholder`, `[REDACTED]`, `redacted`, `null`, `none`
    /// and `n/a`. Shared by the patterns and `isPlaceholderValue(_:)`.
    private static let placeholderShape =
        #"(?:\*+|•+|<[^<>"'“”‘’\n]{0,62}>|\[(?:hidden|redacted)\b[^\]"'“”‘’\n]{0,62}\]|redacted|null|none|n/a)"#

    /// What follows a quoted key: the separator and a value that can be a
    /// credential. A quoted value must not be empty or a placeholder. A bare
    /// one must not be a literal (`null`, `true`, `false`…), a number, a
    /// placeholder, or an object or array, whose own keys are checked where
    /// they stand, so a schema's `"password": {"type": "string"}` or a form
    /// error's `"password": ["is too short"]` is not a credential.
    private static let quotedKeyValue = #"\#(quote)\s*[:=]\s*(?:\#(quote)(?!\s*(?:\#(quote)|\#(placeholderShape)\s*\#(quote)))|(?!(?:null|true|false|none|nil|undefined|~|-?\d+(?:\.\d+)?|\*+|•+|<[^<>\n]{0,62}>|redacted)(?:[\s,;)}\]]|$))[^\s"'“”‘’\\,;(){}\[\]])"#

    /// `password=…`, `token: …`, `api_key=…` as before, plus passphrase,
    /// access_key and secret_key; every such name as a quoted key (JSON
    /// `"password": "…"`, YAML `'token': '…'`, TOML `"secret" = "…"`,
    /// `\"api_key\": \"…\"` inside a JSON string); and, only when quoted,
    /// credential(s), authorization, auth and pin, so that
    /// `fetch(url, { credentials: 'include' })` stays readable. The name must
    /// end at the separator (`token_type`, `tokenizer` and `prompt_tokens`
    /// never match) and must not continue a word (`bypass`, `oauth`). The
    /// names are grouped by first letter, which keeps a 20 MB text within
    /// about a quarter of the old inline pattern's cost (0.85 s against
    /// 0.69 s on one core).
    private static let inlineCredentials = #"(?i)(?<![a-z])(?:(?:p(?:ass(?:word|wd|code|phrase)?|wd|rivate[_-]?key)|secret(?:[_-]?key)?|token|a(?:pi|ccess)[_-]?key|client[_-]?secret)(?:\s*[:=]\s*\S|\#(quotedKeyValue))|(?:pin|auth(?:orization)?|credentials?)\#(quotedKeyValue))"#

    /// Quoted camelCase names, which the word boundary above skips:
    /// `"accessToken"`, `"clientSecret"`, `"userPassword"`, `"awsAccessKey"`.
    /// The capital is matched case-sensitively, so matching only starts at a
    /// lower-to-upper case step: 0.09 s for a 20 MB text on one core.
    private static let camelCaseCredentials = #"(?<=[a-z])(?:P(?i:ass(?:word|wd|code|phrase)?|wd|in|rivate[_-]?key)|S(?i:ecret(?:[_-]?key)?)|T(?i:oken)|C(?i:redentials?|lient[_-]?secret)|A(?i:uthorization|uth|pi[_-]?key|ccess[_-]?key))(?i:\#(quotedKeyValue))"#

    private static let placeholderValue = try! NSRegularExpression(pattern: #"(?i)^\#(placeholderShape)$"#)

    /// True for a value that stands in for a credential (`placeholderShape`).
    static func isPlaceholderValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard trimmed.utf16.count <= 80 else { return false }
        return placeholderValue.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    /// A lone password-like value: 12–64 characters without whitespace that
    /// mix letters, digits and symbols. Applied only to a plain-text item's
    /// whole text, where it is a value rather than a link or a path.
    static let passwordShape = try! NSRegularExpression(pattern: #"^(?=.*[A-Za-z])(?=.*\d)(?=.*[^A-Za-z\d\s])\S{12,64}$"#)

    // MARK: Entries

    /// True when anything an item would hand out looks like a credential.
    static func containsSecret(_ entry: ClipboardEntry) -> Bool {
        if entry.kind == .text, let text = entry.text, looksLikePassword(text) { return true }
        return textualForms(of: entry).contains { containsSecret(inText: $0) }
    }

    /// Whole-text password heuristic, shared with the semantic classifier.
    static func looksLikePassword(_ raw: String) -> Bool {
        guard raw.utf8.count <= 4_096 else { return false }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (12...64).contains(text.count), !text.contains(" ") else { return false }
        return passwordShape.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Every distinct text an item carries: its stored text and title, the
    /// text recognised in its image and each textual pasteboard representation.
    static func textualForms(of entry: ClipboardEntry) -> [String] {
        var forms: [String] = []
        func add(_ value: String?) {
            guard let value, !value.isEmpty, !forms.contains(value) else { return }
            forms.append(value)
        }
        add(entry.text)
        add(entry.title)
        add(entry.recognizedText)
        for item in entry.items {
            for type in item.keys.sorted() {
                guard let data = item[type] else { continue }
                for form in decodedRepresentation(type: type, data: data) { add(form) }
            }
        }
        return forms
    }

    /// Representations that hold pixels only. Their recognised text is
    /// scanned instead of their bytes.
    static func isBinaryImageType(_ type: String) -> Bool {
        imageTypes.contains(type)
    }

    private static let imageTypes: Set<String> = [
        NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue,
        "public.jpeg", "public.heic", "public.heif", "org.webmproject.webp", "com.compuserve.gif",
    ]
    static func decodedRepresentation(type: String, data: Data) -> [String] {
        guard !data.isEmpty, !imageTypes.contains(type) else { return [] }
        switch type {
        case NSPasteboard.PasteboardType.color.rawValue:
            return []
        case NSPasteboard.PasteboardType.string.rawValue, NSPasteboard.PasteboardType.URL.rawValue,
             "public.plain-text", "public.url-name":
            return [String(decoding: data, as: UTF8.self)]
        case NSPasteboard.PasteboardType.fileURL.rawValue:
            // The stored form is percent-encoded; the path is not.
            let raw = String(decoding: data, as: UTF8.self)
            return [raw] + (URL(string: raw).map { [$0.path] } ?? [])
        case "public.utf16-external-plain-text", "public.utf16-plain-text":
            return [utf16Text(data)]
        case NSPasteboard.PasteboardType.rtf.rawValue:
            // The rendered text joins words that RTF control codes split.
            return [attributedText(data, .rtf), String(decoding: data, as: UTF8.self)].compactMap { $0 }
        case NSPasteboard.PasteboardType.rtfd.rawValue, "com.apple.rtfd":
            return [attributedText(data, .rtfd)].compactMap { $0 }
        case NSPasteboard.PasteboardType.html.rawValue:
            let raw = String(decoding: data, as: UTF8.self)
            return [raw, withoutMarkup(raw)]
        default:
            // Older archives or other writers: scan whatever reads as text,
            // at any length (an item is at most 20 MB), as UTF-8 and, when
            // the bytes say so (a byte-order mark, or NUL bytes that UTF-16
            // puts between ASCII letters), as UTF-16.
            var forms: [String] = []
            let utf8 = String(data: data, encoding: .utf8)
            if let utf8 { forms.append(utf8) }
            if data.count >= 2, data.count % 2 == 0, utf8 == nil || data.contains(0) {
                forms.append(utf16Text(data))
            }
            return forms
        }
    }

    private static func utf16Text(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF], let text = String(data: data, encoding: .utf16) { return text }
        return String(data: data, encoding: .utf16LittleEndian) ?? String(decoding: data, as: UTF8.self)
    }

    private static func attributedText(_ data: Data, _ type: NSAttributedString.DocumentType) -> String? {
        // RTF and RTFD import is safe off the main thread (HTML import is not,
        // which is why HTML is reduced to text here instead).
        (try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil))?.string
    }

    private static let markup = try! NSRegularExpression(pattern: "<[^<>]{0,4000}>")

    /// Tags removed without spaces, so `sk-<b></b>abc…` reads as one token.
    static func withoutMarkup(_ html: String) -> String {
        markup.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
    }

    // MARK: Text

    /// True when `text`, or one of its decoded forms, contains a credential:
    /// one the patterns recognise, or one found reading JSON key by key.
    static func containsSecret(inText text: String) -> Bool {
        variants(of: text).contains { matchesPattern($0) || containsStructuredSecret($0) }
    }

    /// `text` plus the forms it decodes to, two levels deep (for example a
    /// percent-encoded character reference).
    static func variants(of text: String) -> [String] {
        var results = [text]
        var frontier = [text]
        for _ in 0..<2 where !frontier.isEmpty {
            var next: [String] = []
            for form in frontier {
                for decoded in [percentDecoded(form), referenceDecoded(form), normalized(form)].compactMap({ $0 })
                where !results.contains(decoded) {
                    results.append(decoded)
                    next.append(decoded)
                }
            }
            frontier = next
        }
        return results
    }

    private static let percentEscape = try! NSRegularExpression(pattern: "%[0-9A-Fa-f]{2}")
    private static let characterReference = try! NSRegularExpression(
        pattern: "&(?:#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});")
    private static let hiddenOrCompatibility = try! NSRegularExpression(
        pattern: "[\\u00AD\\u180E\\u200B-\\u200F\\u2060-\\u2064\\uFEFF\\uFF01-\\uFF5E\\u3000]")
    private static let hiddenCharacters = try! NSRegularExpression(
        pattern: "[\\u00AD\\u180E\\u200B-\\u200F\\u2060-\\u2064\\uFEFF]")

    private static func contains(_ expression: NSRegularExpression, in text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Lenient: valid `%XX` escapes are decoded, anything else is kept.
    static func percentDecoded(_ text: String) -> String? {
        guard contains(percentEscape, in: text) else { return nil }
        if let strict = text.removingPercentEncoding, strict != text { return strict }
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count)
        let bytes = Array(text.utf8)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        let decoded = String(decoding: output, as: UTF8.self)
        return decoded == text ? nil : decoded
    }

    /// The named references that matter for spelling a credential, plus all
    /// numeric references.
    private static let namedReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "colon": ":", "equals": "=",
        "lowbar": "_", "hyphen": "-", "dash": "-", "period": ".", "sol": "/", "quest": "?", "commat": "@",
        "percnt": "%", "plus": "+", "num": "#", "lpar": "(", "rpar": ")", "semi": ";", "comma": ",",
        "excl": "!", "dollar": "$", "ast": "*", "Hat": "^", "tilde": "~", "verbar": "|", "bsol": "\\",
    ]

    static func referenceDecoded(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        let matches = characterReference.matches(in: text, range: range)
        guard !matches.isEmpty else { return nil }
        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let found = Range(match.range, in: text) else { continue }
            output += text[cursor..<found.lowerBound]
            let body = text[text.index(after: found.lowerBound)..<text.index(before: found.upperBound)]
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedReferences[String(body)]
            }
            output += replacement ?? String(text[found])
            cursor = found.upperBound
        }
        output += text[cursor...]
        return output == text ? nil : output
    }

    /// Removes invisible characters and folds compatibility forms (NFKC), so
    /// `ｓｋ－…` or `sk-\u{200B}…` read like the plain key.
    static func normalized(_ text: String) -> String? {
        guard contains(hiddenOrCompatibility, in: text) else { return nil }
        let visible = hiddenCharacters.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let folded = visible.precomposedStringWithCompatibilityMapping
        return folded == text ? nil : folded
    }

    // MARK: Matching

    /// Slices this long or longer are searched in parallel. The overlap is
    /// longer than any credential the patterns need to see whole.
    private static let sliceLength = 1 << 20
    private static let sliceOverlap = 16 * 1_024

    static func matchesPattern(_ text: String) -> Bool {
        let length = text.utf16.count
        guard length > 0 else { return false }
        if length <= sliceLength + sliceOverlap {
            let range = NSRange(location: 0, length: length)
            return patterns.contains { $0.firstMatch(in: text, options: [.withTransparentBounds], range: range) != nil }
        }
        let starts = Array(stride(from: 0, to: length, by: sliceLength))
        let found = FoundFlag()
        DispatchQueue.concurrentPerform(iterations: starts.count) { index in
            guard !found.isSet else { return }
            let start = starts[index]
            let range = NSRange(location: start, length: min(length - start, sliceLength + sliceOverlap))
            for pattern in patterns where !found.isSet {
                if pattern.firstMatch(in: text, options: [.withTransparentBounds], range: range) != nil {
                    found.set()
                    return
                }
            }
        }
        return found.isSet
    }

    private final class FoundFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    // MARK: Structured text (JSON)

    /// JSON up to this many UTF-8 bytes is also parsed and read key by key.
    /// Longer JSON is still searched whole by the patterns, which see quoted
    /// keys too; the bound keeps a 20 MB array from being parsed, and held in
    /// memory twice, on every check.
    static let structuredScanLimit = 2 * 1_024 * 1_024

    /// Deeper JSON is left to the patterns, so neither the parser nor the
    /// walk below recurses far on a background thread's small stack.
    private static let structuredDepthLimit = 64

    /// How many times JSON inside a JSON string is read in turn.
    private static let structuredNestingLimit = 3

    /// True when `text` is a JSON object or array holding a credential: a
    /// string under a credential name (`isCredentialKey(_:)`) that is not a
    /// placeholder, at any depth, however the JSON is spaced or escaped
    /// (`"pass\u0077ord"`). Every decoded key and string is searched by the
    /// patterns as well, so what JSON escaping hides from them
    /// (`https:\/\/user:pw@…`, `…\npassword=…`) is read as written, and so
    /// is JSON inside a string.
    static func containsStructuredSecret(_ text: String) -> Bool {
        containsStructuredSecret(text, nesting: 0)
    }

    private static func containsStructuredSecret(_ text: String, nesting: Int) -> Bool {
        guard nesting < structuredNestingLimit, let root = jsonContainer(text) else { return false }
        var strings: [String] = []
        if containsCredential(in: root, key: nil, nesting: nesting, strings: &strings) { return true }
        // U+001F is neither a space nor a separator to the patterns, so no
        // match spans two strings.
        return variants(of: strings.joined(separator: "\u{1F}")).contains(where: matchesPattern)
    }

    /// The parsed value when `text` is a JSON object or array within the
    /// size and depth bounds. Anything else is rejected by its first byte.
    private static func jsonContainer(_ text: String) -> Any? {
        let bytes = text.utf8
        guard let first = bytes.first(where: { !jsonWhitespace.contains($0) }),
              first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
              bytes.count <= structuredScanLimit,
              !nestsDeeper(bytes, than: structuredDepthLimit) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(bytes))
    }

    private static let jsonWhitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

    /// True when brackets outside strings nest deeper than `limit`.
    private static func nestsDeeper(_ bytes: String.UTF8View, than limit: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
                if depth > limit { return true }
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
            }
        }
        return false
    }

    /// Walks a parsed JSON value, collecting every key and string. Only a
    /// string directly under a credential name counts as one: an object
    /// there is judged by its own keys and array elements by their content,
    /// as the patterns do, so a schema's `"password": {"type": "string"}` or
    /// a form error's `"password": ["is too short"]` stays readable.
    private static func containsCredential(in value: Any, key: String?, nesting: Int, strings: inout [String]) -> Bool {
        switch value {
        case let string as String:
            if let key, isCredentialKey(key), !isPlaceholderValue(string) { return true }
            strings.append(string)
            return containsStructuredSecret(string, nesting: nesting + 1)
        case let dictionary as [String: Any]:
            for (name, element) in dictionary {
                strings.append(name)
                if containsCredential(in: element, key: name, nesting: nesting, strings: &strings) { return true }
            }
            return false
        case let array as [Any]:
            for element in array {
                if containsCredential(in: element, key: nil, nesting: nesting, strings: &strings) { return true }
            }
            return false
        default:
            return false
        }
    }

    /// Names whose string value is a credential when JSON is read key by
    /// key. As in the patterns, the last word decides: `accessToken`,
    /// `client_secret`, `X-API-Key`, `db_password` and `basicAuth` are
    /// credentials; `token_type`, `tokenizer`, `prompt_tokens`, `secretName`
    /// and `password_updated_at` are not.
    static func isCredentialKey(_ key: String) -> Bool {
        let folded = key.lowercased()
        guard credentialStems.contains(where: { folded.contains($0) }) else { return false }
        let words = keyWords(key)
        guard let last = words.last else { return false }
        if credentialWords.contains(last) { return true }
        if words.count > 1, credentialWords.contains(words[words.count - 2] + last) { return true }
        // Run-together names: dbpassword, apitoken, xapikey.
        return credentialSuffixes.contains { last.hasSuffix($0) }
    }

    private static let credentialStems = ["pass", "pwd", "secret", "token", "cred", "auth", "key", "pin", "otp"]
    private static let credentialWords: Set<String> = [
        "password", "passwords", "passwd", "passphrase", "passcode", "pass", "pwd", "secret", "secrets", "token",
        "credential", "credentials", "authorization", "auth", "apikey", "privatekey", "accesskey", "secretkey",
        "pin", "pincode", "otp",
    ]
    private static let credentialSuffixes = [
        "password", "passwd", "passphrase", "passcode", "secret", "token", "apikey", "privatekey", "accesskey",
        "secretkey", "authorization",
    ]

    /// The words of a key name: `accessToken`, `access_token`, `Access-Token`
    /// and `ACCESS_TOKEN` all read ["access", "token"]; `APIKey` reads
    /// ["apikey"].
    static func keyWords(_ key: String) -> [String] {
        var words: [String] = []
        var current = ""
        var afterLowercase = false
        for character in key {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                afterLowercase = false
                continue
            }
            if character.isUppercase, afterLowercase, !current.isEmpty { words.append(current); current = "" }
            current += character.lowercased()
            afterLowercase = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: JSON replies (automation tools)

    /// Key names whose string values are credentials whatever they contain.
    static func isSensitiveKey(_ key: String) -> Bool {
        let folded = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["pwd", "auth", "pin", "otp"].contains(folded) { return true }
        return ["password", "passwd", "passcode", "secret", "token", "apikey", "privatekey", "credential", "authorization"]
            .contains { folded.contains($0) }
    }

    /// Replaces credentials inside a JSON-like value (dictionaries, arrays and
    /// strings) with `placeholder`. Returns the redacted value and how many
    /// strings were hidden.
    static func redactingSecrets(in value: Any, key: String? = nil) -> (value: Any, hidden: Int) {
        switch value {
        case let string as String:
            guard !string.isEmpty else { return (string, 0) }
            if key.map(isSensitiveKey) == true || containsSecret(inText: string) { return (placeholder, 1) }
            return (string, 0)
        case let dictionary as [String: Any]:
            var output: [String: Any] = [:]
            var hidden = 0
            for (name, element) in dictionary {
                let result = redactingSecrets(in: element, key: name)
                output[name] = result.value
                hidden += result.hidden
            }
            return (output, hidden)
        case let array as [Any]:
            var hidden = 0
            let output = array.map { element -> Any in
                let result = redactingSecrets(in: element, key: key)
                hidden += result.hidden
                return result.value
            }
            return (output, hidden)
        default:
            return (value, 0)
        }
    }

    /// True when a value still carries `placeholder`, so a client that read a
    /// redacted definition cannot save the placeholder over the real secret.
    static func containsPlaceholder(_ value: Any) -> Bool {
        switch value {
        case let string as String: return string.contains(placeholder)
        case let dictionary as [String: Any]: return dictionary.values.contains(where: containsPlaceholder)
        case let array as [Any]: return array.contains(where: containsPlaceholder)
        default: return false
        }
    }
}
