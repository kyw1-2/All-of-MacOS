import Foundation
import SwiftUI

/// Literal and quoted terms can be combined with local metadata filters:
/// type:image from:"Google Chrome" board:Work after:2026-01-01 -draft
///
/// 3.3.3 adds `pinboard:` (same as `board:`), `is:pinned` / `is:unpinned`,
/// `on:` for a single day, relative dates (`today`, `yesterday`, `7d`, `2w`,
/// `3m`, `1y` — the start of that day) for `before:`, `after:` and `on:`, and
/// plural or common names for types (`images`, `links`, `url`, `files`…).
struct ClipboardSearchQuery {
    private struct Term {
        var field: String?
        var value: String
        var excluded: Bool
        var date: Date?
        var dayEnd: Date?
        var boardIDs: Set<UUID>?
        var kind: ClipboardEntry.Kind?
    }
    private var terms: [Term] = []

    private static let tokenExpression = try? NSRegularExpression(pattern: #"(?:[^\s"]|"[^"]*")+"#)
    static let fields: Set<String> = ["type", "from", "app", "board", "pinboard", "before", "after", "on", "is"]

    init(_ query: String, boards: [ClipboardPinboard]? = nil, now: Date = Date(), calendar: Calendar = .current) {
        guard !query.isEmpty else { return }
        let expression = Self.tokenExpression
        let range = NSRange(query.startIndex..., in: query)
        for match in expression?.matches(in: query, range: range) ?? [] {
            guard let range = Range(match.range, in: query) else { continue }
            var text = String(query[range]).replacingOccurrences(of: "\"", with: "")
            let excluded = text.hasPrefix("-") && text.count > 1
            if excluded { text.removeFirst() }
            let split = text.split(separator: ":", maxSplits: 1).map(String.init)
            let named = split.first?.lowercased() ?? ""
            let field = split.count == 2 && Self.fields.contains(named) ? (named == "pinboard" ? "board" : named) : nil
            let value = field == nil ? text : split[1]
            let isDate = field == "before" || field == "after" || field == "on"
            let date = isDate ? Self.date(from: value, now: now, calendar: calendar) : nil
            let dayEnd = field == "on" ? date.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } : nil
            let boardIDs = field == "board" ? boards.map { boards in
                Set(boards.filter { $0.name.localizedStandardContains(value) }.map(\.id))
            } : nil
            terms.append(Term(field: field, value: value, excluded: excluded, date: date, dayEnd: dayEnd,
                              boardIDs: boardIDs, kind: field == "type" ? Self.kind(named: value) : nil))
        }
        // Reject metadata mismatches before scanning potentially large bodies.
        terms = terms.filter { $0.field != nil } + terms.filter { $0.field == nil }
    }

    /// `type:` values, including plurals and everyday names.
    static func kind(named raw: String) -> ClipboardEntry.Kind? {
        let value = raw.lowercased()
        if let kind = ClipboardEntry.Kind(rawValue: value) { return kind }
        switch value {
        case "texts", "txt", "string", "snippet", "snippets": return .text
        case "links", "url", "urls", "web": return .link
        case "images", "img", "picture", "pictures", "photo", "photos", "screenshot", "screenshots": return .image
        case "files", "document", "documents", "doc", "docs": return .file
        case "colors", "colour", "colours": return .color
        default: return nil
        }
    }

    /// yyyy-MM-dd, `today`, `yesterday`, or an amount of days, weeks, months
    /// or years ago (`7d`, `2w`, `3m`, `1y`), as the start of that day in
    /// `calendar` (the user's calendar and time zone by default).
    static func date(from value: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let lower = value.lowercased()
        let parts = lower.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            // Strict: 2026-02-30 is not quietly read as 2 March. Always the
            // Gregorian calendar, in the given time zone, as before.
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = gregorian.date(from: components),
                  gregorian.dateComponents([.year, .month, .day], from: date) == components else { return nil }
            return date
        }
        let today = calendar.startOfDay(for: now)
        switch lower {
        case "today": return today
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        default: break
        }
        guard lower.count >= 2, let unit = lower.last, let amount = Int(lower.dropLast()), (0...3_650).contains(amount) else { return nil }
        switch unit {
        case "d": return calendar.date(byAdding: .day, value: -amount, to: today)
        case "w": return calendar.date(byAdding: .day, value: -7 * amount, to: today)
        case "m": return calendar.date(byAdding: .month, value: -amount, to: today)
        case "y": return calendar.date(byAdding: .year, value: -amount, to: today)
        default: return nil
        }
    }

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
            case "type":
                matched = term.kind.map { entry.kind == $0 }
                    ?? (entry.kind.rawValue.caseInsensitiveCompare(term.value) == .orderedSame)
            case "from", "app":
                matched = [entry.sourceName ?? "", entry.sourceBundleID ?? ""].contains { $0.localizedStandardContains(term.value) }
            case "board":
                if let ids = term.boardIDs {
                    matched = entry.pinboardIDs.contains { ids.contains($0) }
                } else {
                    matched = boards.contains { entry.pinboardIDs.contains($0.id) && $0.name.localizedStandardContains(term.value) }
                }
            case "is":
                switch term.value.lowercased() {
                case "pinned": matched = !entry.pinboardIDs.isEmpty
                case "unpinned": matched = entry.pinboardIDs.isEmpty
                default: matched = false
                }
            case "before", "after", "on":
                if let date = term.date {
                    switch term.field {
                    case "before": matched = entry.lastCopiedAt < date
                    case "after": matched = entry.lastCopiedAt >= date
                    default: matched = entry.lastCopiedAt >= date && entry.lastCopiedAt < (term.dayEnd ?? date)
                    }
                } else { matched = false }
            default: matched = Self.contains(entry, term.value)
            }
            return term.excluded ? !matched : matched
        }
    }

    /// True when the query matches on content (free or excluded words), not
    /// only on metadata such as type, app, pinboard or date.
    var hasContentTerms: Bool { terms.contains { $0.field == nil } }
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
        let parsed = tokens(in: query)
        return parsed.enumerated().filter { index, token in
            let candidate = token.hasPrefix("-") ? String(token.dropFirst()) : token
            let pieces = candidate.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, !pieces[1].isEmpty else { return false }
            let field = pieces[0].lowercased(), value = pieces[1].replacingOccurrences(of: "\"", with: "")
            let complete: Bool
            switch field {
            case "type": complete = kind(named: value) != nil
            case "before", "after", "on": complete = date(from: value) != nil
            case "is": complete = ["pinned", "unpinned"].contains(value.lowercased())
            case "from", "app", "board", "pinboard": complete = pieces[1].contains("\"") ? (pieces[1].filter { $0 == "\"" }.count >= 2 && pieces[1].hasSuffix("\"")) : (query.last?.isWhitespace == true || index < parsed.count - 1)
            default: complete = false
            }
            return complete && seen.insert(token).inserted
        }.map(\.element)
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
            let named = pieces[0].lowercased()
            let field = named == "app" ? "from" : named == "pinboard" ? "board" : named
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
