import Foundation
import SwiftUI

/// Literal and quoted terms can be combined with local metadata filters:
/// type:image from:"Google Chrome" board:Work after:2026-01-01 -draft
struct ClipboardSearchQuery {
    private struct Term {
        var field: String?
        var value: String
        var excluded: Bool
        var date: Date?
    }
    private var terms: [Term] = []

    private static let tokenExpression = try? NSRegularExpression(pattern: #"(?:[^\s"]|"[^"]*")+"#)

    init(_ query: String) {
        guard !query.isEmpty else { return }
        let expression = Self.tokenExpression
        let range = NSRange(query.startIndex..., in: query)
        for match in expression?.matches(in: query, range: range) ?? [] {
            guard let range = Range(match.range, in: query) else { continue }
            var text = String(query[range]).replacingOccurrences(of: "\"", with: "")
            let excluded = text.hasPrefix("-") && text.count > 1
            if excluded { text.removeFirst() }
            let split = text.split(separator: ":", maxSplits: 1).map(String.init)
            let field = split.count == 2 && ["type", "from", "app", "board", "before", "after"].contains(split[0].lowercased())
                ? split[0].lowercased() : nil
            let value = field == nil ? text : split[1]
            let date = (field == "before" || field == "after") ? Self.dayFormatter.date(from: value) : nil
            terms.append(Term(field: field, value: value, excluded: excluded, date: date))
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    var isEmpty: Bool { terms.isEmpty }

    /// Cheap fields first; the full text and file paths are only searched
    /// when nothing shorter matched (typing searches every clip per key).
    private static func contains(_ entry: ClipboardEntry, _ value: String) -> Bool {
        if entry.title.localizedStandardContains(value) { return true }
        // App names only: bundle IDs like com.apple.* would make "apple"
        // match every clip from an Apple app.
        if let name = entry.sourceName, name.localizedStandardContains(value) { return true }
        if let text = entry.text, text.localizedStandardContains(value) { return true }
        if let text = entry.recognizedText, text.localizedStandardContains(value) { return true }
        if entry.kind == .file, entry.fileURLs.contains(where: { $0.path.localizedStandardContains(value) }) { return true }
        return false
    }

    func matches(_ entry: ClipboardEntry, boards: [ClipboardPinboard]) -> Bool {
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { term in
            let matched: Bool
            switch term.field {
            case "type": matched = entry.kind.rawValue.caseInsensitiveCompare(term.value) == .orderedSame
            case "from", "app":
                matched = [entry.sourceName ?? "", entry.sourceBundleID ?? ""].contains { $0.localizedStandardContains(term.value) }
            case "board":
                matched = boards.contains { entry.pinboardIDs.contains($0.id) && $0.name.localizedStandardContains(term.value) }
            case "before", "after":
                if let date = term.date {
                    matched = term.field == "before" ? entry.lastCopiedAt < date : entry.lastCopiedAt >= date
                } else { matched = false }
            default: matched = Self.contains(entry, term.value)
            }
            return term.excluded ? !matched : matched
        }
    }
}

extension ClipboardSearchQuery {
    static func tokens(in query: String) -> [String] {
        let range = NSRange(query.startIndex..., in: query)
        return (tokenExpression?.matches(in: query, range: range) ?? []).compactMap { match in
            Range(match.range, in: query).map { String(query[$0]) }
        }
    }
    static func filterTokens(in query: String) -> [String] {
        var seen = Set<String>()
        return tokens(in: query).filter { token in
            let candidate = token.hasPrefix("-") ? String(token.dropFirst()) : token
            let pieces = candidate.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, !pieces[1].isEmpty else { return false }
            let field = pieces[0].lowercased(), value = pieces[1].replacingOccurrences(of: "\"", with: "")
            let complete: Bool
            switch field {
            case "type": complete = ClipboardEntry.Kind(rawValue: value.lowercased()) != nil
            case "before", "after": complete = dayFormatter.date(from: value) != nil
            case "from", "app", "board": complete = pieces[1].contains("\"") ? (pieces[1].filter { $0 == "\"" }.count >= 2 && pieces[1].hasSuffix("\"")) : (query.last?.isWhitespace == true || token != tokens(in: query).last)
            default: complete = false
            }
            return complete && seen.insert(token).inserted
        }
    }
    static func editableText(in query: String) -> String {
        let filters = Set(filterTokens(in: query))
        return tokens(in: query).filter { !filters.contains($0) }.joined(separator: " ") + (query.last?.isWhitespace == true ? " " : "")
    }
    static func updatingEditableText(_ text: String, in query: String) -> String {
        let filters = filterTokens(in: query)
        return filters.isEmpty ? text : filters.joined(separator: " ") + " " + text
    }
    static func replacing(token: String, with replacement: String, in query: String) -> String {
        var replaced = false
        return tokens(in: query).map { candidate in
            guard candidate == token, !replaced else { return candidate }
            replaced = true
            return replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: " ")
    }
    /// Complete, positive `type:`, `from:`/`app:` and `board:` tokens that the
    /// filter chips can represent. The panel moves them out of the query into
    /// the chips (typing `type:image` lights the Image chip); everything else
    /// — excluded terms, dates, partial tokens — stays as typed.
    static func chipFilters(in query: String) -> [(token: String, field: String, value: String)] {
        filterTokens(in: query).compactMap { token in
            guard !token.hasPrefix("-") else { return nil }
            let pieces = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            let field = pieces[0].lowercased() == "app" ? "from" : pieces[0].lowercased()
            guard ["type", "from", "board"].contains(field) else { return nil }
            return (token, field, pieces[1].replacingOccurrences(of: "\"", with: ""))
        }
    }

    static func removing(token: String, from query: String) -> String { tokens(in: query).filter { $0 != token }.joined(separator: " ") }
    static func inserting(token: String, into query: String) -> String {
        var existing = tokens(in: query)
        if let last = existing.last, last.contains(":"), token.lowercased().hasPrefix(last.lowercased()) { existing.removeLast() }
        if !existing.contains(token) { existing.append(token) }
        return existing.joined(separator: " ") + " "
    }
    var highlightValues: [String] { terms.filter { $0.field == nil && !$0.excluded && !$0.value.isEmpty }.map(\.value) }
    func highlighted(_ text: String, limit: Int) -> AttributedString {
        // Include the first matching OCR excerpt instead of always truncating
        // the beginning, where a distant match would be invisible.
        var snippet = String(text.prefix(limit))
        if let match = highlightValues.compactMap({ text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let start = text.index(match.lowerBound, offsetBy: -min(40, text.distance(from: text.startIndex, to: match.lowerBound)))
            snippet = (start > text.startIndex ? "…" : "") + String(text[start...].prefix(limit))
        }
        var attributed = AttributedString(snippet)
        for term in highlightValues {
            var cursor = snippet.startIndex
            while cursor < snippet.endIndex, let range = snippet.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<snippet.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: attributed), let upper = AttributedString.Index(range.upperBound, within: attributed) {
                    attributed[lower..<upper].backgroundColor = .yellow.opacity(0.65)
                    attributed[lower..<upper].foregroundColor = .black
                }
                cursor = range.upperBound
            }
        }
        return attributed
    }
}
