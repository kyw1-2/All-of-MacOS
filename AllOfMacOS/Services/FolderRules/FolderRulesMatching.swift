import Foundation

/// Decides whether a rule's conditions match an item. Pure: every input,
/// the clock included, is a value, so the tests run on fixtures.
enum FolderRuleMatcher {
    /// The rule's verdict: its conditions combined with all / any / none.
    /// Items below the top level only count when the rule includes subfolders.
    static func matches(_ rule: FolderRule, _ info: FolderRuleFileInfo, now: Date) -> Bool {
        guard rule.includeSubfolders || info.depth == 0, !rule.conditions.isEmpty else { return false }
        let results = evaluate(rule, info, now: now)
        switch rule.match {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains(true)
        case .none: return !results.contains(true)
        }
    }

    /// One verdict per condition, in order (the inspector's ✓ and ✗).
    static func evaluate(_ rule: FolderRule, _ info: FolderRuleFileInfo, now: Date) -> [Bool] {
        rule.conditions.map { matches($0, info, now: now) }
    }

    static func matches(_ condition: FolderRuleCondition, _ info: FolderRuleFileInfo, now: Date) -> Bool {
        switch condition.attribute {
        case .name:
            return nameMatches(condition, normalized(info.baseName))
        case .fileExtension:
            let values = condition.cleanValues
            guard !values.isEmpty else { return false }
            let hit = values.contains(info.fileExtension.lowercased())
            return condition.comparison.isNegative ? !hit : hit
        case .kind:
            let hit = info.kinds.contains(condition.kind)
            return condition.comparison.isNegative ? !hit : hit
        case .dateAdded, .dateCreated, .dateModified, .dateLastOpened:
            guard let date = date(of: condition.attribute, info), condition.amount.isFinite else { return false }
            let age = now.timeIntervalSince(date)
            let limit = max(0, condition.amount) * condition.timeUnit.seconds
            return condition.comparison == .olderThan ? age > limit : age <= limit
        case .size:
            guard condition.amount.isFinite else { return false }
            let limit = max(0, condition.amount) * condition.sizeUnit.bytes
            return condition.comparison == .greaterThan ? Double(info.size) > limit : Double(info.size) < limit
        case .downloadedFrom:
            let wanted = condition.cleanValues.map(host)
            guard !wanted.isEmpty else { return false }
            let hosts = info.downloadHosts
            let hit = wanted.contains { value in hosts.contains { $0.contains(value) } }
            return condition.comparison.isNegative ? !hit : hit
        case .tags:
            let wanted = condition.cleanValues.map { normalized($0).lowercased() }
            guard !wanted.isEmpty else { return false }
            let tags = Set(info.tags.map { normalized($0).lowercased() })
            let hit = wanted.contains { tags.contains($0) }
            return condition.comparison.isNegative ? !hit : hit
        }
    }

    /// The date a condition reads. A file that was never opened counts as
    /// last opened when it arrived, so "last opened more than 30 days ago"
    /// also finds downloads nobody opened.
    static func date(of attribute: FolderRuleAttribute, _ info: FolderRuleFileInfo) -> Date? {
        switch attribute {
        case .dateAdded: return info.dateAdded ?? info.dateCreated
        case .dateCreated: return info.dateCreated
        case .dateModified: return info.dateModified
        case .dateLastOpened: return info.dateLastOpened ?? info.dateAdded ?? info.dateCreated
        default: return nil
        }
    }

    /// Names compare case-insensitively in Unicode NFC: macOS file names
    /// often arrive decomposed, so "영수증" typed in the editor must still
    /// match a decomposed "영수증" from a browser download.
    static func normalized(_ string: String) -> String { string.precomposedStringWithCanonicalMapping }

    private static func nameMatches(_ condition: FolderRuleCondition, _ name: String) -> Bool {
        if condition.comparison == .matchesRegex {
            guard !condition.pattern.isEmpty,
                  let regex = try? NSRegularExpression(pattern: normalized(condition.pattern), options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        let values = condition.cleanValues.map(normalized)
        guard !values.isEmpty else { return false }
        func test(_ value: String) -> Bool {
            switch condition.comparison {
            case .contains, .doesNotContain: return name.range(of: value, options: [.caseInsensitive]) != nil
            case .is, .isNot: return name.compare(value, options: [.caseInsensitive]) == .orderedSame
            case .startsWith: return name.range(of: value, options: [.caseInsensitive, .anchored]) != nil
            case .endsWith: return name.range(of: value, options: [.caseInsensitive, .anchored, .backwards]) != nil
            default: return false
            }
        }
        let hit = values.contains(where: test)
        return condition.comparison.isNegative ? !hit : hit
    }

    /// "https://github.com/x" in a Downloaded From value means its host.
    private static func host(_ value: String) -> String {
        if value.contains("://"), let host = URLComponents(string: value)?.host { return host.lowercased() }
        return value.lowercased()
    }
}

// MARK: - Patterns and names

/// Expands `{…}` tokens in folder and name patterns, and keeps the results
/// safe as path components.
enum FolderRulePatterns {
    /// Tokens for subfolder patterns ("{year}-{month}", "{kind}").
    static let folderTokens: Set<String> = ["year", "month", "day", "kind", "ext"]
    /// Tokens for Rename and Show Notification.
    static let nameTokens: Set<String> = ["name", "ext", "date", "counter", "year", "month", "day", "kind"]

    struct Context {
        var info: FolderRuleFileInfo
        var now: Date
        var counter = 1
        var calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar
        }()

        /// When the item arrived (or was created); `now` if macOS doesn't know.
        var date: Date { info.referenceDate ?? now }
    }

    struct Token: Equatable {
        let name: String
        let argument: String?
        let range: Range<String.Index>
    }

    private static let tokenExpression = try! NSRegularExpression(pattern: #"\{([A-Za-z]+)(?::([^{}]*))?\}"#)

    static func tokens(in pattern: String) -> [Token] {
        let range = NSRange(pattern.startIndex..., in: pattern)
        return tokenExpression.matches(in: pattern, range: range).compactMap { match in
            guard let whole = Range(match.range, in: pattern), let name = Range(match.range(at: 1), in: pattern) else { return nil }
            let argument = Range(match.range(at: 2), in: pattern).map { String(pattern[$0]) }
            return Token(name: pattern[name].lowercased(), argument: argument, range: whole)
        }
    }

    static func unknownTokens(in pattern: String, allowed: Set<String>) -> [String] {
        tokens(in: pattern).map(\.name).filter { !allowed.contains($0) }
    }

    static func usesCounter(_ pattern: String) -> Bool { tokens(in: pattern).contains { $0.name == "counter" } }

    /// Replaces every known token; unknown ones stay as written.
    static func expand(_ pattern: String, _ context: Context) -> String {
        var result = ""
        var cursor = pattern.startIndex
        for token in tokens(in: pattern) {
            result += pattern[cursor..<token.range.lowerBound]
            result += value(of: token, context) ?? String(pattern[token.range])
            cursor = token.range.upperBound
        }
        result += pattern[cursor...]
        return result
    }

    private static func value(of token: Token, _ context: Context) -> String? {
        let parts = context.calendar.dateComponents([.year, .month, .day], from: context.date)
        switch token.name {
        case "name": return context.info.baseName
        case "ext": return context.info.fileExtension
        case "year": return String(format: "%04d", parts.year ?? 0)
        case "month": return String(format: "%02d", parts.month ?? 0)
        case "day": return String(format: "%02d", parts.day ?? 0)
        case "kind": return context.info.primaryKind?.folderName ?? "Other"
        case "date":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = context.calendar
            formatter.timeZone = context.calendar.timeZone
            let format = token.argument?.trimmingCharacters(in: .whitespaces) ?? ""
            formatter.dateFormat = format.isEmpty ? "yyyy-MM-dd" : format
            return formatter.string(from: context.date)
        case "counter":
            let width = token.argument.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { min(9, max(1, $0)) } ?? 1
            let digits = String(max(0, context.counter))
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        default: return nil
        }
    }

    /// The subfolders a Move or Copy pattern sorts into, as safe components:
    /// "/" separates levels, "." and ".." and empty levels are dropped, so a
    /// pattern can never climb out of the destination folder.
    static func subfolderComponents(_ pattern: String, _ context: Context) -> [String] {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: "/", omittingEmptySubsequences: true).compactMap { level in
            let component = sanitized(expand(String(level), context))
            return component.isEmpty || component == "." || component == ".." ? nil : component
        }
    }

    /// The new name for Rename. Without `{ext}` in the pattern the original
    /// extension is kept, so "{name} {date:yyyy-MM-dd}" never drops ".pdf".
    /// Nil when the pattern leaves no usable name.
    static func fileName(_ pattern: String, _ context: Context) -> String? {
        var name = sanitized(expand(pattern, context))
        let keepsExtension = !tokens(in: pattern).contains { $0.name == "ext" }
        let ext = context.info.fileExtension
        if keepsExtension, !ext.isEmpty {
            guard !name.isEmpty else { return nil }
            name += "." + ext
        }
        while name.hasSuffix(".") { name.removeLast() }
        name = sanitized(name)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return name
    }

    /// One path component: no "/" or ":" (Finder shows ":" as "/"), no NUL,
    /// no leading dot (which would hide the item), no surrounding spaces,
    /// at most 255 UTF-8 bytes.
    static func sanitized(_ component: String) -> String {
        var text = component.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        while text.hasPrefix(".") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        while text.utf8.count > 255 { text.removeLast() }
        return text
    }

    /// Finder-style conflict names: "Report.pdf" → "Report 2.pdf", "Report 3.pdf".
    static func uniqueURL(_ desired: URL, isTaken: (URL) -> Bool) -> URL {
        guard isTaken(desired) else { return desired }
        let directory = desired.deletingLastPathComponent()
        let name = desired.lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for number in 2...9_999 {
            let candidateName = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: desired.hasDirectoryPath)
            if !isTaken(candidate) { return candidate }
        }
        let fallback = ext.isEmpty ? "\(base) \(UUID().uuidString.prefix(8))" : "\(base) \(UUID().uuidString.prefix(8)).\(ext)"
        return directory.appendingPathComponent(fallback)
    }
}
