import Foundation
import NaturalLanguage
import SwiftUI

// 7.22 (DeepSeek 7.21 report §4.1.3–4): code clips are coloured, and the
// clipboard can be searched by meaning, both on this Mac.

// MARK: - Code highlighting

/// A small tokenizer for code previews: comments, strings, numbers and the
/// keywords most languages share. It colours at most the first 4,000
/// characters (the rest plain) and never parses.
enum ClipboardCodeHighlighter {
    static let limit = 4_000
    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "struct", "class", "enum", "import", "guard", "switch",
        "case", "default", "break", "continue", "in", "do", "try", "catch", "throw", "throws", "async", "await", "static",
        "private", "public", "protocol", "extension", "self", "nil", "true", "false", "def", "lambda", "None", "True", "False",
        "const", "function", "new", "this", "null", "undefined", "export", "from", "interface", "type", "package", "fn",
        "impl", "pub", "use", "mut", "match", "select", "where", "and", "or", "not", "elif", "with", "as", "yield",
    ]

    enum Kind: Equatable { case plain, keyword, string, comment, number }

    /// Pure: the text split into runs of one kind.
    static func tokens(_ text: String) -> [(Kind, Substring)] {
        var out: [(Kind, Substring)] = []
        var index = text.startIndex
        func push(_ kind: Kind, _ end: String.Index) {
            guard end > index else { return }
            if let last = out.last, last.0 == kind, last.1.endIndex == index {
                out[out.count - 1].1 = text[last.1.startIndex..<end]
            } else { out.append((kind, text[index..<end])) }
            index = end
        }
        while index < text.endIndex {
            let rest = text[index...]
            let c = text[index]
            if rest.hasPrefix("//") || c == "#" && (index == text.startIndex || text[text.index(before: index)].isNewline) {
                push(.comment, rest.firstIndex(where: \.isNewline) ?? text.endIndex)
            } else if rest.hasPrefix("/*") {
                push(.comment, rest.range(of: "*/").map { $0.upperBound } ?? text.endIndex)
            } else if c == "\"" || c == "'" || c == "`" {
                var end = text.index(after: index)
                while end < text.endIndex, text[end] != c, !text[end].isNewline {
                    if text[end] == "\\" { end = text.index(after: end); if end == text.endIndex { break } }
                    end = text.index(after: end)
                }
                push(.string, end < text.endIndex && text[end] == c ? text.index(after: end) : end)
            } else if c.isNumber {
                push(.number, rest.firstIndex { !($0.isNumber || $0 == "." || $0 == "x" || $0.isHexDigit || $0 == "_") } ?? text.endIndex)
            } else if c.isLetter || c == "_" {
                let end = rest.firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? text.endIndex
                push(keywords.contains(String(text[index..<end])) ? .keyword : .plain, end)
            } else {
                push(.plain, text.index(after: index))
            }
        }
        return out
    }

    static func attributed(_ text: String) -> AttributedString {
        let head = String(text.prefix(limit))
        var result = AttributedString()
        for (kind, run) in tokens(head) {
            var piece = AttributedString(String(run))
            switch kind {
            case .keyword: piece.foregroundColor = Color(nsColor: .systemPink)
            case .string: piece.foregroundColor = Color(nsColor: .systemOrange)
            case .comment: piece.foregroundColor = Color(nsColor: .secondaryLabelColor)
            case .number: piece.foregroundColor = Color(nsColor: .systemPurple)
            case .plain: break
            }
            result += piece
        }
        if text.count > limit { result += AttributedString(String(text.dropFirst(limit).prefix(2_000))) }
        return result
    }
}

// MARK: - Meaning search

/// Clipboard search by meaning: each text item's sentence embedding
/// (Apple's NaturalLanguage model, Korean or English by the item's dominant
/// language) is computed once and kept in memory; a query ranks items by
/// cosine similarity blended with the plain text match. Items that look
/// like a credential are never embedded. Nothing is stored or sent.
@MainActor
final class ClipboardMeaningIndex {
    static let shared = ClipboardMeaningIndex()

    private var vectors: [UUID: (revision: UUID, language: NLLanguage, vector: [Double])] = [:]
    private var embeddings: [NLLanguage: NLEmbedding] = [:]

    static let threshold = 0.35

    func embedding(for language: NLLanguage) -> NLEmbedding? {
        if let cached = embeddings[language] { return cached }
        let made = NLEmbedding.sentenceEmbedding(for: language)
        embeddings[language] = made
        return made
    }

    nonisolated static func language(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.korean, .english]
        recognizer.processString(String(text.prefix(500)))
        return recognizer.dominantLanguage ?? .english
    }

    private func vector(for entry: ClipboardEntry) -> (NLLanguage, [Double])? {
        if let cached = vectors[entry.id], cached.revision == entry.contentVersion { return (cached.language, cached.vector) }
        guard let text = (entry.text ?? entry.recognizedText)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2,
              ClipboardIntelligence.shared.itemClass(entry) != .secret else { return nil }
        let language = Self.language(of: text)
        guard let model = embedding(for: language), let vector = model.vector(for: String(text.prefix(1_000))) else { return nil }
        vectors[entry.id] = (entry.contentVersion, language, vector)
        return (language, vector)
    }

    nonisolated static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Pure: 0.6 × meaning + 0.4 × text match.
    nonisolated static func blended(cosine: Double, lexical: Bool) -> Double { 0.6 * cosine + (lexical ? 0.4 : 0) }

    /// `entries` ranked by meaning for `query`, best first, above the threshold.
    /// The newest 5,000 text items are compared (embedding is cached per item).
    func rank(_ query: String, in entries: [ClipboardEntry]) -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return entries }
        let language = Self.language(of: trimmed)
        guard let model = embedding(for: language), let wanted = model.vector(for: trimmed) else { return [] }
        var scored: [(ClipboardEntry, Double)] = []
        for entry in entries.prefix(5_000) {
            guard let (itemLanguage, vector) = vector(for: entry), itemLanguage == language else {
                if entry.text?.localizedCaseInsensitiveContains(trimmed) == true { scored.append((entry, 0.4)) }
                continue
            }
            let lexical = entry.text?.localizedCaseInsensitiveContains(trimmed) == true
            let score = Self.blended(cosine: Self.cosine(wanted, vector), lexical: lexical)
            if score >= Self.threshold { scored.append((entry, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    func forget() { vectors.removeAll() }
}
