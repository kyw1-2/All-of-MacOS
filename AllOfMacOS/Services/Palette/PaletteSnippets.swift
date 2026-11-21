import Foundation

// AOM 7.2 (Oracle report 05 §3-F, checked against the code): AOM already
// expands typed abbreviations — Automation's "Typed String" trigger with a
// replacement (espanso-style, KeyboardMonitor + TypedStringEngine). What was
// missing is Raycast's Snippets in the launcher: find one by its keyword or
// text, paste it into the app in front, and make a new one from the
// clipboard without opening the editor. A launcher snippet is that same
// trigger, so it also expands as you type.

enum PaletteSnippets {
    struct Snippet: Identifiable, Hashable {
        let id: UUID
        let abbreviation: String
        let text: String
        let name: String
        let isEnabled: Bool
        /// 7.3: placeholders on (TypedStringSpec.syntax).
        var syntax: Int? = nil

        var usesPlaceholders: Bool { syntax == SnippetTemplate.currentSyntax }

        /// The {arg:…} fields it asks for, in order.
        var argumentNames: [String] {
            guard usesPlaceholders, case .success(let tokens) = SnippetTemplate.parse(text) else { return [] }
            return SnippetTemplate.argumentNames(tokens)
        }
    }

    static let namePrefix = "Snippet: "

    /// Pure: the preset's typed strings that type text.
    static func snippets(in triggers: [Trigger]) -> [Snippet] {
        triggers.compactMap { trigger in
            guard case .typedString(let spec) = trigger.input, !spec.replacement.isEmpty else { return nil }
            return Snippet(id: trigger.id, abbreviation: spec.abbreviation, text: spec.replacement,
                           name: trigger.name.hasPrefix(namePrefix) ? String(trigger.name.dropFirst(namePrefix.count)) : trigger.name,
                           isEnabled: trigger.isEnabled, syntax: spec.syntax)
        }
        .sorted { $0.abbreviation.localizedStandardCompare($1.abbreviation) == .orderedAscending }
    }

    /// Pure: why `abbreviation` can't be used, or nil. Two to 32 characters
    /// without spaces, not taken by another typed string.
    static func problem(with abbreviation: String, existing triggers: [Trigger]) -> String? {
        let text = abbreviation.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return "Type a keyword of at least two characters, such as ;sig" }
        guard text.count <= 32 else { return "Keep the keyword to 32 characters" }
        guard !text.contains(where: \.isWhitespace) else { return "A keyword has no spaces" }
        // The matcher ignores case, so ";Ab" and ";ab" are one keyword (7.3, Codex probe).
        let taken = triggers.contains { trigger in
            if case .typedString(let spec) = trigger.input { return spec.abbreviation.caseInsensitiveCompare(text) == .orderedSame }
            return false
        }
        return taken ? "“\(text)” is already a typed string" : nil
    }

    /// A typed-string trigger that types `text` after `abbreviation`.
    static func trigger(abbreviation: String, text: String, placeholders: Bool = false) -> Trigger {
        let keyword = abbreviation.trimmingCharacters(in: .whitespaces)
        let firstLine = text.split(separator: "\n").first.map { String($0.prefix(40)) } ?? keyword
        return Trigger(name: namePrefix + firstLine, input: .typedString(TypedStringSpec(abbreviation: keyword, replacement: text,
                                                                                         syntax: placeholders ? SnippetTemplate.currentSyntax : nil)))
    }

    /// 7.3: the snippet test — what it would insert now, or what is wrong
    /// with the template and where.
    static func preview(_ snippet: Snippet, arguments: [String: String] = [:]) -> String {
        preview(text: snippet.text, syntax: snippet.syntax, arguments: arguments)
    }

    /// Missing fields show as ‹name›, the clipboard as [clipboard], the cursor as ▏.
    static func preview(text: String, syntax: Int?, arguments: [String: String] = [:], now: Date = Date()) -> String {
        var filled = arguments
        if syntax == SnippetTemplate.currentSyntax, case .success(let tokens) = SnippetTemplate.parse(text) {
            for name in SnippetTemplate.argumentNames(tokens) where (filled[name] ?? "").isEmpty { filled[name] = "‹\(name)›" }
        }
        switch SnippetTemplate.render(text: text, syntax: syntax,
                                      context: .init(now: now, clipboard: { "[clipboard]" }, arguments: filled)) {
        case .success(let render):
            var shown = render.text
            if let after = render.charactersAfterCursor { shown.insert("▏", at: shown.index(shown.endIndex, offsetBy: -after)) }
            return shown
        case .failure(let error):
            return "⚠︎ \(error.message) (at character \(error.offset + 1))"
        }
    }
}
