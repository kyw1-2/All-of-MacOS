import Foundation

// Text Actions (3.4): a PopClip-style bar of actions over the text selected
// in any app. This file holds the saved choices; the engine reads them, the
// page edits them.

/// One action the bar can offer, in the bar's default order. Transforms come
/// last and start switched off.
enum TextActionID: String, CaseIterable, Identifiable, Codable {
    case copy, cut, paste, search, githubSearch, openLink, newEmail, lookUp, translate, calculate
    case count, speak, pinToClipboard, askChatGPT
    case changeCase, formatJSON, urlCoding, base64, markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: return "Copy"
        case .cut: return "Cut"
        case .paste: return "Paste"
        case .search: return "Search"
        case .githubSearch: return "Search GitHub"
        case .openLink: return "Open Link"
        case .newEmail: return "New Email"
        case .lookUp: return "Look Up"
        case .translate: return "Translate"
        case .calculate: return "Calculate"
        case .count: return "Count"
        case .speak: return "Speak"
        case .pinToClipboard: return "Pin to Clipboard"
        case .askChatGPT: return "Ask ChatGPT"
        case .changeCase: return "Change Case"
        case .formatJSON: return "Format JSON"
        case .urlCoding: return "URL Encode or Decode"
        case .base64: return "Base64 Encode or Decode"
        case .markdown: return "Markdown"
        }
    }

    /// SF Symbols available on macOS 14.
    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .cut: return "scissors"
        case .paste: return "doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .githubSearch: return "chevron.left.forwardslash.chevron.right"
        case .openLink: return "safari"
        case .newEmail: return "envelope"
        case .lookUp: return "character.book.closed"
        case .translate: return "translate"
        case .calculate: return "equal.circle"
        case .count: return "number"
        case .speak: return "speaker.wave.2"
        case .pinToClipboard: return "pin"
        case .askChatGPT: return "bubble.left.and.text.bubble.right"
        case .changeCase: return "textformat"
        case .formatJSON: return "curlybraces"
        case .urlCoding: return "percent"
        case .base64: return "arrow.left.arrow.right.square"
        case .markdown: return "bold.italic.underline"
        }
    }

    /// One line for the action list on the Text Actions page.
    var detail: String {
        switch self {
        case .copy: return "Copies the selection"
        case .cut: return "In text you can edit"
        case .paste: return "Replaces the selection with the clipboard, in text you can edit"
        case .search: return "Searches the web with the engine chosen below"
        case .githubSearch: return "Searches GitHub for the selection"
        case .openLink: return "When the selection is a web address"
        case .newEmail: return "When the selection is an email address"
        case .lookUp: return "Opens the word in Dictionary"
        case .translate: return "Opens the translator chosen below"
        case .calculate: return "Shows the result of a sum or a unit conversion"
        case .count: return "Shows how many characters and words are selected"
        case .speak: return "Reads the selection aloud in its language"
        case .pinToClipboard: return "Keeps the selection on a pinboard in Clipboard"
        case .askChatGPT: return "Copies the selection and opens ChatGPT"
        case .changeCase: return "UPPER, lower, Title, camelCase, snake_case, kebab-case"
        case .formatJSON: return "Indents JSON, when the selection is JSON"
        case .urlCoding: return "Percent-encodes the selection, or decodes it"
        case .base64: return "Encodes the selection as Base64, or decodes it"
        case .markdown: return "Wraps the selection as bold, italic, code or a link"
        }
    }

    /// Transforms change the selected text (or copy the result).
    var isTransform: Bool {
        switch self {
        case .changeCase, .formatJSON, .urlCoding, .base64, .markdown: return true
        default: return false
        }
    }

    var isOnByDefault: Bool {
        switch self {
        case .copy, .cut, .paste, .search, .openLink, .newEmail, .lookUp, .translate, .calculate, .pinToClipboard:
            return true
        case .githubSearch, .count, .speak, .askChatGPT, .changeCase, .formatJSON, .urlCoding, .base64, .markdown:
            return false
        }
    }
}

/// The web search behind the Search action.
enum TextSearchEngine: String, CaseIterable, Identifiable, Codable {
    case google, naver, bing, duckDuckGo, perplexity, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .naver: return "Naver"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        case .perplexity: return "Perplexity"
        case .custom: return "Custom"
        }
    }

    /// The URL with `{query}` where the text goes; nil for a custom engine.
    var template: String? {
        switch self {
        case .google: return "https://www.google.com/search?q={query}"
        case .naver: return "https://search.naver.com/search.naver?query={query}"
        case .bing: return "https://www.bing.com/search?q={query}"
        case .duckDuckGo: return "https://duckduckgo.com/?q={query}"
        case .perplexity: return "https://www.perplexity.ai/search?q={query}"
        case .custom: return nil
        }
    }
}

/// The translator behind the Translate action.
enum TextTranslator: String, CaseIterable, Identifiable, Codable {
    case google, papago

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google Translate"
        case .papago: return "Papago"
        }
    }
}

/// A language both translators accept, with the code they share.
struct TextTranslateLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    /// "auto" lets the translator detect the language (source only).
    static let automatic = TextTranslateLanguage(code: "auto", name: "Detect Language")

    /// Papago's languages, which Google Translate also has.
    static let all: [TextTranslateLanguage] = [
        .init(code: "ko", name: "Korean"), .init(code: "en", name: "English"),
        .init(code: "ja", name: "Japanese"), .init(code: "zh-CN", name: "Chinese (Simplified)"),
        .init(code: "zh-TW", name: "Chinese (Traditional)"), .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"), .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"), .init(code: "pt", name: "Portuguese"),
        .init(code: "ru", name: "Russian"), .init(code: "vi", name: "Vietnamese"),
        .init(code: "th", name: "Thai"), .init(code: "id", name: "Indonesian"),
        .init(code: "hi", name: "Hindi"), .init(code: "ar", name: "Arabic")
    ]

    static func isSupported(_ code: String) -> Bool { all.contains { $0.code == code } }

    /// The supported code for a BCP-47 language ("ko-KR" → "ko",
    /// "zh-Hant-TW" → "zh-TW"), or nil.
    static func code(forPreferredLanguage identifier: String) -> String? {
        let parts = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let base = parts.first?.lowercased(), !base.isEmpty else { return nil }
        if base == "zh" {
            let traditional = parts.contains { ["Hant", "TW", "HK", "MO"].contains($0) }
            return traditional ? "zh-TW" : "zh-CN"
        }
        return isSupported(base) ? base : nil
    }
}

/// Where the bar sits relative to the selection; it flips when there is no room.
enum TextActionBarPosition: String, CaseIterable, Identifiable, Codable {
    case above, below

    var id: String { rawValue }

    var title: String {
        switch self {
        case .above: return "Above the Selection"
        case .below: return "Below the Selection"
        }
    }
}

/// Everything the user chooses for Text Actions, saved as one JSON value.
/// Every field decodes with its default when it is missing, so settings saved
/// by an earlier version never reset as a whole.
struct TextActionsSettings: Codable, Equatable {
    /// One row of the action list: an action and its switch.
    struct Action: Codable, Equatable, Identifiable {
        var id: TextActionID
        var isOn: Bool
    }

    /// The master switch: show the bar on its own when text is selected.
    var isOn = false
    /// Every action exactly once, in the bar's order.
    var actions: [Action] = Self.defaultActions
    var searchEngine: TextSearchEngine = .google
    /// Used when `searchEngine` is `.custom`; holds `{query}`.
    var customSearchURL = ""
    /// Optional instruction for Ask ChatGPT. {text} is replaced when clicked,
    /// never sent automatically; the user reviews and pastes the clipboard.
    var customChatGPTPrompt = ""
    var translator: TextTranslator = Self.defaultTranslator()
    /// "auto" or a `TextTranslateLanguage` code.
    var translateFrom = "auto"
    var translateTo = Self.defaultTargetLanguage()
    /// Bundle identifiers of apps where the bar never appears.
    var excludedApps: [String] = Self.defaultExcludedApps
    /// Triggers: a mouse drag, a double or triple click, ⇧ with the arrow keys.
    var showsOnDrag = true
    var showsOnDoubleClick = true
    var showsOnKeyboardSelection = false
    /// Presses ⌘C (and puts the clipboard back) when an app does not share
    /// its selection with Accessibility.
    var readsWithCopy = false
    /// Seconds between the end of a selection and the bar.
    var showDelay: Double = 0.2
    var position: TextActionBarPosition = .above
    /// Seconds the bar stays once the pointer is away from it.
    var hideDelay: Double = 4
    /// Action names next to their icons.
    var showsNames = false
    /// The pinboard Pin to Clipboard uses; nil makes (or finds) "Text Actions".
    var pinboardID: UUID?

    static let defaultsKey = "AOMTextActionsSettings.v1"
    static let showDelayRange: ClosedRange<Double> = 0...1.5
    static let hideDelayRange: ClosedRange<Double> = 1.5...30

    /// Password managers and the system's password apps.
    static let defaultExcludedApps = ["com.1password.1password", "com.agilebits.onepassword7",
                                      "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"]

    static var defaultActions: [Action] {
        TextActionID.allCases.map { Action(id: $0, isOn: $0.isOnByDefault) }
    }

    /// Papago for people who read Korean, Google Translate otherwise.
    static func defaultTranslator(preferred: [String] = Locale.preferredLanguages) -> TextTranslator {
        preferred.contains { TextTranslateLanguage.code(forPreferredLanguage: $0) == "ko" } ? .papago : .google
    }

    /// The language people read besides English: the first preferred one
    /// that is not English ("en-KR, ko-KR" → Korean), else English.
    static func defaultTargetLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        let codes = preferred.compactMap(TextTranslateLanguage.code(forPreferredLanguage:))
        return codes.first { $0 != "en" } ?? codes.first ?? "en"
    }

    init() {}

    // MARK: Queries

    func isOn(_ id: TextActionID) -> Bool { actions.first { $0.id == id }?.isOn ?? false }

    /// The switched-on actions in the bar's order.
    var enabledActions: [TextActionID] { actions.filter(\.isOn).map(\.id) }

    /// The excluded list as the gate compares it: trimmed and case-insensitive.
    var excludedBundleIDs: Set<String> {
        Set(excludedApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    func excludes(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else { return false }
        return excludedBundleIDs.contains(id)
    }

    // MARK: Editing

    mutating func setAction(_ id: TextActionID, isOn: Bool) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].isOn = isOn
    }

    /// Moves `id` to sit just before `target` (or to the end for nil).
    mutating func moveAction(_ id: TextActionID, before target: TextActionID?) {
        guard id != target, let from = actions.firstIndex(where: { $0.id == id }) else { return }
        let moving = actions.remove(at: from)
        if let target, let to = actions.firstIndex(where: { $0.id == target }) {
            actions.insert(moving, at: to)
        } else {
            actions.append(moving)
        }
    }

    /// Moves `id` `offset` places: -1 is one place up, +1 one place down.
    mutating func moveAction(_ id: TextActionID, by offset: Int) {
        guard let from = actions.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), actions.count - 1)
        guard to != from else { return }
        let moving = actions.remove(at: from)
        actions.insert(moving, at: to)
    }

    /// Values kept in range, every action exactly once, a clean app list.
    var bounded: TextActionsSettings {
        var result = self
        result.actions = Self.normalized(actions)
        result.showDelay = min(max(showDelay.isFinite ? showDelay : 0.2, Self.showDelayRange.lowerBound), Self.showDelayRange.upperBound)
        result.hideDelay = min(max(hideDelay.isFinite ? hideDelay : 4, Self.hideDelayRange.lowerBound), Self.hideDelayRange.upperBound)
        var seen = Set<String>()
        result.excludedApps = excludedApps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        if translateFrom != "auto", !TextTranslateLanguage.isSupported(translateFrom) { result.translateFrom = "auto" }
        if !TextTranslateLanguage.isSupported(translateTo) { result.translateTo = "en" }
        result.customSearchURL = customSearchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.customChatGPTPrompt = String(customChatGPTPrompt.prefix(1000))
        return result
    }

    /// Keeps the saved order, drops repeats, and appends actions added by a
    /// newer version with their default switch.
    static func normalized(_ actions: [Action]) -> [Action] {
        var seen = Set<TextActionID>()
        var result = actions.filter { seen.insert($0.id).inserted }
        for id in TextActionID.allCases where !seen.contains(id) {
            result.append(Action(id: id, isOn: id.isOnByDefault))
        }
        return result
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case isOn, actions, searchEngine, customSearchURL, customChatGPTPrompt, translator, translateFrom, translateTo, excludedApps
        case showsOnDrag, showsOnDoubleClick, showsOnKeyboardSelection, readsWithCopy
        case showDelay, position, hideDelay, showsNames, pinboardID
    }

    /// An action row from any version: an id this version does not know is dropped.
    private struct StoredAction: Decodable {
        let action: Action?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let raw = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            let isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn)
            action = TextActionID(rawValue: raw).map { Action(id: $0, isOn: isOn ?? $0.isOnByDefault) }
        }
        private enum Keys: String, CodingKey { case id, isOn }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TextActionsSettings()
        // A field of the wrong type falls back on its own; it never fails the whole value.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            let decoded: T? = try? c.decodeIfPresent(T.self, forKey: key)
            return decoded ?? fallback
        }
        isOn = value(.isOn, defaults.isOn)
        let stored: [StoredAction]? = try? c.decodeIfPresent([StoredAction].self, forKey: .actions)
        actions = Self.normalized(stored?.compactMap(\.action) ?? defaults.actions)
        searchEngine = value(.searchEngine, defaults.searchEngine)
        customSearchURL = value(.customSearchURL, defaults.customSearchURL)
        customChatGPTPrompt = value(.customChatGPTPrompt, defaults.customChatGPTPrompt)
        translator = value(.translator, defaults.translator)
        translateFrom = value(.translateFrom, defaults.translateFrom)
        translateTo = value(.translateTo, defaults.translateTo)
        excludedApps = value(.excludedApps, defaults.excludedApps)
        showsOnDrag = value(.showsOnDrag, defaults.showsOnDrag)
        showsOnDoubleClick = value(.showsOnDoubleClick, defaults.showsOnDoubleClick)
        showsOnKeyboardSelection = value(.showsOnKeyboardSelection, defaults.showsOnKeyboardSelection)
        readsWithCopy = value(.readsWithCopy, defaults.readsWithCopy)
        showDelay = value(.showDelay, defaults.showDelay)
        position = value(.position, defaults.position)
        hideDelay = value(.hideDelay, defaults.hideDelay)
        showsNames = value(.showsNames, defaults.showsNames)
        pinboardID = value(.pinboardID, defaults.pinboardID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isOn, forKey: .isOn)
        try c.encode(actions, forKey: .actions)
        try c.encode(searchEngine, forKey: .searchEngine)
        try c.encode(customSearchURL, forKey: .customSearchURL)
        try c.encode(customChatGPTPrompt, forKey: .customChatGPTPrompt)
        try c.encode(translator, forKey: .translator)
        try c.encode(translateFrom, forKey: .translateFrom)
        try c.encode(translateTo, forKey: .translateTo)
        try c.encode(excludedApps, forKey: .excludedApps)
        try c.encode(showsOnDrag, forKey: .showsOnDrag)
        try c.encode(showsOnDoubleClick, forKey: .showsOnDoubleClick)
        try c.encode(showsOnKeyboardSelection, forKey: .showsOnKeyboardSelection)
        try c.encode(readsWithCopy, forKey: .readsWithCopy)
        try c.encode(showDelay, forKey: .showDelay)
        try c.encode(position, forKey: .position)
        try c.encode(hideDelay, forKey: .hideDelay)
        try c.encode(showsNames, forKey: .showsNames)
        try c.encodeIfPresent(pinboardID, forKey: .pinboardID)
    }

    // MARK: Storage

    static func load(from defaults: UserDefaults) -> TextActionsSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(TextActionsSettings.self, from: data) else { return TextActionsSettings() }
        return decoded.bounded
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
