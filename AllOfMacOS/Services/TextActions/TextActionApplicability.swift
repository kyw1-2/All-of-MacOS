import Foundation

/// Whether the selected text can be changed where it is.
enum TextEditability: Equatable {
    /// Accessibility can set the selected text (a text field, an editor).
    case editable
    /// Accessibility reads the text but cannot change it (a web page, a label).
    case readOnly
    /// The text came from ⌘C, so AOM cannot tell; a replacement is pasted.
    case unknown
}

/// What the bar knows besides the text itself.
struct TextActionContext: Equatable {
    var editability: TextEditability = .readOnly
    /// The calculator's answer for the text, when it has one.
    var calculation: AOMCalculator.Result?
    var chatGPTInstalled = false
    /// The clipboard holds something Paste could put in.
    var clipboardHasContent = true
}

/// Which actions apply to a selection. Contextual actions (Open Link, New
/// Email, Calculate, Format JSON …) appear only when they apply.
enum TextActionApplicability {
    /// Longer text is not searched: a search engine cannot use it.
    static let searchLimit = 1_000
    /// Dictionary looks up words and short phrases.
    static let lookUpLimit = 40
    /// AVSpeechSynthesizer is given at most this much.
    static let speakLimit = 20_000

    static func applies(_ id: TextActionID, traits: TextSelectionTraits, context: TextActionContext) -> Bool {
        guard !traits.text.isEmpty else { return false }
        switch id {
        case .copy, .pinToClipboard, .count, .urlCoding, .base64, .markdown:
            return true
        case .cut:
            return context.editability == .editable
        case .paste:
            return context.editability == .editable && context.clipboardHasContent
        case .search, .githubSearch:
            return traits.text.count <= searchLimit
        case .openLink:
            return traits.link != nil
        case .newEmail:
            return traits.email != nil
        case .lookUp:
            return !traits.isMultiline && traits.text.count <= lookUpLimit && traits.hasLetters
                && traits.link == nil && traits.email == nil && !traits.isJSON
        case .translate:
            return traits.hasLetters && traits.link == nil && traits.email == nil && !traits.isJSON
        case .calculate:
            return calculation(context.calculation, for: traits) != nil
        case .speak:
            return traits.text.count <= speakLimit && (traits.hasLetters || traits.text.contains(where: \.isNumber))
        case .askChatGPT:
            return context.chatGPTInstalled
        case .changeCase:
            return traits.hasCasedLetters
        case .formatJSON:
            return traits.isJSON
        }
    }

    /// The calculator's result worth showing: none for text that is not a
    /// sum, and none when the result just repeats the text ("42" → "42").
    static func calculation(_ result: AOMCalculator.Result?, for traits: TextSelectionTraits) -> AOMCalculator.Result? {
        guard traits.isCalculatorCandidate, let result else { return nil }
        let display = result.display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return nil }
        let squeeze = { (text: String) in text.filter { !$0.isWhitespace }.lowercased() }
        return squeeze(display) == squeeze(traits.text) ? nil : result
    }

    /// The rewrites a transform action offers for this text.
    static func variants(for id: TextActionID, traits: TextSelectionTraits) -> [TextTransformVariant] {
        switch id {
        case .changeCase: return TextCaseStyle.allCases.map { .changeCase($0) }
        case .formatJSON: return traits.isJSON ? [.formatJSON] : []
        case .urlCoding: return traits.hasPercentEscapes ? [.urlDecode, .urlEncode] : [.urlEncode]
        case .base64: return traits.base64Decoded != nil ? [.base64Decode, .base64Encode] : [.base64Encode]
        case .markdown: return TextMarkdownStyle.allCases.map { .markdown($0) }
        default: return []
        }
    }

    /// The switched-on actions that apply, in the user's order.
    static func actions(settings: TextActionsSettings, traits: TextSelectionTraits, context: TextActionContext) -> [TextActionID] {
        settings.enabledActions.filter { applies($0, traits: traits, context: context) }
    }
}
