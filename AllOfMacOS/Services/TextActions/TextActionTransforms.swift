import Foundation

/// The six case styles of Change Case.
enum TextCaseStyle: String, CaseIterable, Identifiable {
    case upper, lower, title, camel, snake, kebab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upper: return "UPPER"
        case .lower: return "lower"
        case .title: return "Title"
        case .camel: return "camelCase"
        case .snake: return "snake_case"
        case .kebab: return "kebab-case"
        }
    }

    /// The rewrite the Transform Selected Text action already uses, so both
    /// give the same result.
    var transform: TextTransform {
        switch self {
        case .upper: return .uppercase
        case .lower: return .lowercase
        case .title: return .titleCase
        case .camel: return .camelCase
        case .snake: return .snakeCase
        case .kebab: return .kebabCase
        }
    }
}

/// The four Markdown wraps.
enum TextMarkdownStyle: String, CaseIterable, Identifiable {
    case bold, italic, code, link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .code: return "Code"
        case .link: return "Link"
        }
    }
}

/// One concrete rewrite offered under a transform action.
enum TextTransformVariant: Hashable, Identifiable {
    case changeCase(TextCaseStyle)
    case formatJSON
    case urlEncode, urlDecode
    case base64Encode, base64Decode
    case markdown(TextMarkdownStyle)

    var id: String {
        switch self {
        case .changeCase(let style): return "case." + style.rawValue
        case .formatJSON: return "json"
        case .urlEncode: return "url.encode"
        case .urlDecode: return "url.decode"
        case .base64Encode: return "base64.encode"
        case .base64Decode: return "base64.decode"
        case .markdown(let style): return "markdown." + style.rawValue
        }
    }

    /// The label on the bar.
    var title: String {
        switch self {
        case .changeCase(let style): return style.title
        case .formatJSON: return "Format JSON"
        case .urlEncode, .base64Encode: return "Encode"
        case .urlDecode, .base64Decode: return "Decode"
        case .markdown(let style): return style.title
        }
    }

    /// The tooltip and VoiceOver label.
    var help: String {
        switch self {
        case .changeCase(let style): return "Change to \(style.title)"
        case .formatJSON: return "Indent the JSON"
        case .urlEncode: return "Percent-encode for a URL"
        case .urlDecode: return "Decode percent escapes"
        case .base64Encode: return "Encode as Base64"
        case .base64Decode: return "Decode Base64"
        case .markdown(let style):
            switch style {
            case .bold: return "Wrap in ** for bold"
            case .italic: return "Wrap in * for italic"
            case .code: return "Wrap in backticks as code"
            case .link: return "Make a Markdown link"
            }
        }
    }
}

enum TextActionTransforms {
    /// The rewritten text, or nil when the variant does not apply (invalid
    /// JSON or Base64). `clipboardURL` gives Link its address.
    static func apply(_ variant: TextTransformVariant, to text: String, clipboardURL: URL? = nil) -> String? {
        switch variant {
        case .changeCase(let style): return style.transform.apply(text)
        case .formatJSON: return prettyJSON(text)
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: TextActionURLs.unreserved)
        case .urlDecode: return text.removingPercentEncoding
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode: return TextSelectionClassifier.base64Text(text)
        case .markdown(let style): return markdown(style, text, clipboardURL: clipboardURL)
        }
    }

    /// Re-indents valid JSON with two spaces. Keys stay in their order and
    /// numbers and escapes stay exactly as written (JSONSerialization would
    /// sort keys and rewrite both).
    static func prettyJSON(_ text: String, indent: String = "  ") -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TextSelectionClassifier.isJSON(trimmed) else { return nil }
        let characters = Array(trimmed)
        var output = ""
        output.reserveCapacity(trimmed.utf8.count + trimmed.utf8.count / 2)
        var level = 0
        var inString = false
        var escaped = false
        var index = 0
        func breakLine() {
            output.append("\n")
            output.append(String(repeating: indent, count: max(0, level)))
        }
        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                index += 1
                continue
            }
            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                // An empty object or array stays "{}" / "[]".
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, (character == "{" && characters[next] == "}") || (character == "[" && characters[next] == "]") {
                    output.append(character)
                    output.append(characters[next])
                    index = next + 1
                    continue
                }
                output.append(character)
                level += 1
                breakLine()
            case "}", "]":
                level -= 1
                breakLine()
                output.append(character)
            case ",":
                output.append(character)
                breakLine()
            case ":":
                output.append(": ")
            default:
                if !character.isWhitespace { output.append(character) }
            }
            index += 1
        }
        return output
    }

    /// Wraps the text, keeping white space at either end outside the
    /// markers, where Markdown needs it ("**word** ", not "**word **").
    static func markdown(_ style: TextMarkdownStyle, _ text: String, clipboardURL: URL?) -> String {
        let leading = String(text.prefix(while: { $0.isWhitespace || $0.isNewline }))
        let rest = text.dropFirst(leading.count)
        let trailingCount = rest.reversed().prefix(while: { $0.isWhitespace || $0.isNewline }).count
        let core = String(rest.dropLast(trailingCount))
        let trailing = String(rest.suffix(trailingCount))
        guard !core.isEmpty else { return text }
        switch style {
        case .bold:
            return leading + "**" + core + "**" + trailing
        case .italic:
            return leading + "*" + core + "*" + trailing
        case .code:
            if core.contains(where: \.isNewline) {
                let fence = core.contains("```") ? "````" : "```"
                return leading + fence + "\n" + core + "\n" + fence + trailing
            }
            // A backtick inside needs a longer fence; one at either end needs a space.
            let fence = core.contains("`") ? "``" : "`"
            let pad = core.hasPrefix("`") || core.hasSuffix("`") ? " " : ""
            return leading + fence + pad + core + pad + fence + trailing
        case .link:
            let address: String
            if let own = TextSelectionClassifier.link(in: core)?.url {
                address = own.absoluteString
            } else {
                address = clipboardURL?.absoluteString ?? ""
            }
            let label = core.replacingOccurrences(of: "]", with: "\\]")
            return leading + "[" + label + "](" + address + ")" + trailing
        }
    }
}
