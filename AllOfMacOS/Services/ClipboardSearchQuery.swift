import Foundation

/// Literal and quoted terms can be combined with local metadata filters:
/// type:image from:"Google Chrome" board:Work after:2026-01-01 -draft
struct ClipboardSearchQuery {
    private struct Term {
        var field: String?
        var value: String
        var excluded: Bool
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
            terms.append(Term(field: field, value: field == nil ? text : split[1], excluded: excluded))
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
                if let date = Self.dayFormatter.date(from: term.value) {
                    matched = term.field == "before" ? entry.lastCopiedAt < date : entry.lastCopiedAt >= date
                } else { matched = false }
            default: matched = Self.contains(entry, term.value)
            }
            return term.excluded ? !matched : matched
        }
    }
}
