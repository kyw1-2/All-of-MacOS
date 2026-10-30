import Foundation
import CryptoKit

/// The pure parts of the Text & Developer tools (DevUtils / Boop style). They
/// take and return plain strings so they are unit tested without touching the
/// clipboard; the page reads and writes the clipboard around them.
enum DevTextTools {
    enum Failure: LocalizedError, Equatable {
        case notJSON(String)
        case notBase64
        case notUTF8

        var errorDescription: String? {
            switch self {
            case .notJSON(let reason): return "The clipboard text isn't valid JSON (\(reason))."
            case .notBase64: return "The clipboard text isn't valid Base64."
            case .notUTF8: return "The decoded Base64 isn't text (UTF-8), so it was not copied."
            }
        }
    }

    // MARK: JSON

    /// Pretty-printed with two-space indentation and sorted keys, so the same
    /// input always formats the same way. Top-level fragments ("1", "\"a\"")
    /// are accepted.
    static func prettyJSON(_ text: String) throws -> String {
        try reencodeJSON(text, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    /// One line, no whitespace between tokens.
    static func minifiedJSON(_ text: String) throws -> String {
        try reencodeJSON(text, options: [.withoutEscapingSlashes, .fragmentsAllowed])
    }

    private static func reencodeJSON(_ text: String, options: JSONSerialization.WritingOptions) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "parse error"
            throw Failure.notJSON(reason)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Base64

    static func base64Encode(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    /// Accepts standard and URL-safe alphabets, missing padding and embedded
    /// line breaks (as e-mail and PEM text wrap it).
    static func base64Decode(_ text: String) throws -> String {
        var cleaned = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !cleaned.isEmpty else { throw Failure.notBase64 }
        let remainder = cleaned.count % 4
        if remainder == 1 { throw Failure.notBase64 }
        if remainder > 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: cleaned) else { throw Failure.notBase64 }
        guard let decoded = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
        return decoded
    }

    // MARK: Statistics

    struct TextStats: Equatable {
        let characters: Int
        let words: Int
        let lines: Int
        let bytes: Int

        var summary: String {
            "\(characters) character\(characters == 1 ? "" : "s"), \(words) word\(words == 1 ? "" : "s"), "
                + "\(lines) line\(lines == 1 ? "" : "s"), \(bytes) byte\(bytes == 1 ? "" : "s") (UTF-8)"
        }
    }

    /// Characters are user-perceived (grapheme clusters); words follow the
    /// system word boundaries, so Korean, Japanese and English all count.
    static func stats(_ text: String) -> TextStats {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let lines = text.isEmpty ? 0 : TextTransform.lines(text).count - (text.hasSuffix("\n") ? 1 : 0)
        return TextStats(characters: text.count, words: words, lines: lines, bytes: text.utf8.count)
    }

    // MARK: Hashes and identifiers

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }

    /// Streams the file in 1 MB chunks so a multi-gigabyte file never sits in
    /// memory. `isCancelled` is polled between chunks.
    static func sha256Hex(fileAt url: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if isCancelled() { throw CancellationError() }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A 64-character hex SHA-256 found in the text, for "matches the
    /// clipboard" checks after hashing a download.
    static func expectedHash(in text: String?) -> String? {
        guard let candidate = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              candidate.count == 64, candidate.allSatisfy(\.isHexDigit) else { return nil }
        return candidate
    }

    // MARK: Unix time

    struct Timestamp: Equatable {
        let date: Date
        /// The input was in milliseconds (13 digits) rather than seconds.
        let wasMilliseconds: Bool
    }

    /// A clipboard number read as a Unix time: 9–11 digits are seconds,
    /// 12–14 digits milliseconds. Anything else is not a timestamp.
    static func timestamp(from text: String) -> Timestamp? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let value = Double(trimmed) else { return nil }
        switch digits.count {
        case 9...11: return Timestamp(date: Date(timeIntervalSince1970: value), wasMilliseconds: false)
        case 12...14: return Timestamp(date: Date(timeIntervalSince1970: value / 1000), wasMilliseconds: true)
        default: return nil
        }
    }

    /// ISO 8601 in UTC, the form other tools paste back in.
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func unixSeconds(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970.rounded(.down))) }
}
