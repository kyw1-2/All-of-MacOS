import Foundation

/// One control on the bar.
struct TextActionBarItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Runs the action.
        case action
        /// The calculator's answer: a click copies it, ⌥-click replaces the selection.
        case result
        /// Information only (Count).
        case chip
        /// A transform with several rewrites: the bar shows them in its place.
        case menu([TextTransformVariant])
        /// A transform with one rewrite: runs it.
        case transform(TextTransformVariant)
    }

    let id: TextActionID
    var kind: Kind
    var title: String
    var symbol: String
    var help: String
    var accessibilityLabel: String
}

extension TextTransformVariant {
    /// The label when the rewrite stands alone on the bar.
    var fullTitle: String {
        switch self {
        case .urlEncode: return "URL Encode"
        case .urlDecode: return "URL Decode"
        case .base64Encode: return "Base64 Encode"
        case .base64Decode: return "Base64 Decode"
        default: return title
        }
    }
}

/// Builds the bar's items from the actions that apply.
enum TextActionBarItems {
    static func make(_ actions: [TextActionID], traits: TextSelectionTraits, context: TextActionContext,
                     speaking: Bool) -> [TextActionBarItem] {
        let replaces = context.editability != .readOnly
        return actions.compactMap { id -> TextActionBarItem? in
            switch id {
            case .calculate:
                guard let result = TextActionApplicability.calculation(context.calculation, for: traits) else { return nil }
                return TextActionBarItem(id: id, kind: .result, title: "= " + result.display, symbol: id.symbol,
                                         help: replaces ? "Click to copy the result, ⌥-click to replace the selection with it"
                                                        : "Click to copy the result",
                                         accessibilityLabel: "Result: \(result.display)")
            case .count:
                let spoken = TextActionCountFormat.spoken(characters: traits.characters, words: traits.words, lines: traits.lines)
                return TextActionBarItem(id: id, kind: .chip,
                                         title: TextActionCountFormat.chip(characters: traits.characters, words: traits.words),
                                         symbol: id.symbol, help: spoken, accessibilityLabel: spoken)
            case .speak:
                return TextActionBarItem(id: id, kind: .action, title: speaking ? "Stop" : "Speak",
                                         symbol: speaking ? "stop.fill" : id.symbol,
                                         help: speaking ? "Stop speaking" : "Read the selection aloud",
                                         accessibilityLabel: speaking ? "Stop speaking" : "Speak")
            default:
                guard id.isTransform else {
                    return TextActionBarItem(id: id, kind: .action, title: id.title, symbol: id.symbol,
                                             help: help(for: id, traits: traits), accessibilityLabel: id.title)
                }
                let variants = TextActionApplicability.variants(for: id, traits: traits)
                guard let first = variants.first else { return nil }
                if variants.count == 1 {
                    let how = replaces ? "\(first.help) (⌥-click copies the result instead)" : "\(first.help) and copy the result"
                    return TextActionBarItem(id: id, kind: .transform(first), title: first.fullTitle, symbol: id.symbol,
                                             help: how, accessibilityLabel: first.fullTitle)
                }
                return TextActionBarItem(id: id, kind: .menu(variants), title: id.title, symbol: id.symbol,
                                         help: id.title, accessibilityLabel: id.title)
            }
        }
    }

    private static func help(for id: TextActionID, traits: TextSelectionTraits) -> String {
        switch id {
        case .copy: return "Copy"
        case .cut: return "Cut"
        case .paste: return "Paste over the selection"
        case .search: return "Search the web"
        case .githubSearch: return "Search GitHub"
        case .openLink: return traits.link.map { "Open \($0.host ?? $0.absoluteString)" } ?? "Open the link"
        case .newEmail: return traits.email.map { "Write to \($0)" } ?? "New email"
        case .lookUp: return "Look up in Dictionary"
        case .translate: return "Translate"
        case .pinToClipboard: return "Pin to a Clipboard pinboard"
        case .askChatGPT: return "Copy and open ChatGPT"
        default: return id.title
        }
    }
}
