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

    init(_ query: String) {
        let expression = try? NSRegularExpression(pattern: #"(?:[^\s"]|"[^"]*")+"#)
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

    func matches(_ entry: ClipboardEntry, boards: [ClipboardPinboard]) -> Bool {
        let searchable = [entry.title, entry.text ?? "", entry.recognizedText ?? "",
                          // App names only: bundle IDs like com.apple.* would make
                          // "apple" match every clip from an Apple app.
                          entry.sourceName ?? "",
                          entry.fileURLs.map(\.path).joined(separator: " ")]
        return terms.allSatisfy { term in
            let matched: Bool
            switch term.field {
            case "type": matched = entry.kind.rawValue.caseInsensitiveCompare(term.value) == .orderedSame
            case "from", "app":
                matched = [entry.sourceName ?? "", entry.sourceBundleID ?? ""].contains { $0.localizedStandardContains(term.value) }
            case "board":
                matched = boards.contains { entry.pinboardIDs.contains($0.id) && $0.name.localizedStandardContains(term.value) }
            case "before", "after":
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.isLenient = false
                if let date = formatter.date(from: term.value) {
                    matched = term.field == "before" ? entry.lastCopiedAt < date : entry.lastCopiedAt >= date
                } else { matched = false }
            default: matched = searchable.contains { $0.localizedStandardContains(term.value) }
            }
            return term.excluded ? !matched : matched
        }
    }
}
