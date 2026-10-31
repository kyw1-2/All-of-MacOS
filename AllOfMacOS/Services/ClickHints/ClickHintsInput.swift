import AppKit
import Carbon

/// A key as hint mode reads it. Letters come from the keyboard layout by
/// key position, so hints work the same with the Korean input source on.
enum ClickHintsKey: Equatable {
    /// A printable key, lowercased.
    case character(Character)
    case space, returnKey, backspace, escape, tab, backtab, up, down
    case other
}

/// The typed-filter state machine of hint mode (pure; the overlay feeds it
/// keys and draws what it says).
///
/// Labels: typing narrows the labels; a complete label acts at once
/// (labels are prefix-free). Space or Return act when one hint is left.
/// ⌫ removes a letter, Esc cancels, / switches to search.
///
/// Search: typing filters by name (spaces are ignored, as in Homerow; Korean
/// names also match the keys that type them on the 2-Set layout, "wjwkd" for
/// 저장). ↑ ↓ Tab move the highlight, Return acts on it, Space acts when one
/// match is left, ⌫ on an empty query or / go back to labels.
///
/// Modifiers held with the key that acts choose the click: ⇧ or ⌃ right-click,
/// ⌘ ⌘-click, ⌥ moves the pointer.
struct ClickHintsInputState {
    enum Mode: Equatable { case labels, search }

    enum Outcome: Equatable {
        /// Nothing to redraw.
        case unchanged
        /// The visible hints or the highlight changed.
        case updated
        /// The key matches nothing (the overlay beeps; state is kept).
        case rejected
        case cancel
        case act(target: Int, kind: ClickHintsClickKind)
    }

    /// Labels by target index.
    let labels: [String]
    private let searchForms: [[String]]
    private let alphabet: Set<Character>

    private(set) var mode: Mode
    /// The label prefix typed so far.
    private(set) var typed = ""
    /// The search text typed so far (normalized).
    private(set) var query = ""
    /// Targets still shown, in rank order.
    private(set) var matches: [Int]
    /// Position of the highlighted match in search mode.
    private(set) var highlight = 0

    init(labels: [String], searchTexts: [String], startsInSearch: Bool = false) {
        self.labels = labels.map { $0.lowercased() }
        searchForms = searchTexts.map(ClickHintsSearch.forms(of:))
        alphabet = Set(self.labels.joined())
        mode = startsInSearch ? .search : .labels
        matches = Array(labels.indices)
    }

    /// The highlighted target in search mode.
    var highlightedTarget: Int? {
        guard mode == .search, matches.indices.contains(highlight) else { return nil }
        return matches[highlight]
    }

    mutating func handle(_ key: ClickHintsKey, modifiers: ClickHintsModifiers) -> Outcome {
        if key == .escape { return .cancel }
        switch mode {
        case .labels: return handleLabel(key, modifiers: modifiers)
        case .search: return handleSearch(key, modifiers: modifiers)
        }
    }

    // MARK: Labels

    private mutating func handleLabel(_ key: ClickHintsKey, modifiers: ClickHintsModifiers) -> Outcome {
        switch key {
        case .character("/"):
            mode = .search
            typed = ""
            refreshSearch()
            return .updated
        case .character(let character):
            guard alphabet.contains(character) else { return .rejected }
            let next = typed + String(character)
            let found = labels.indices.filter { labels[$0].hasPrefix(next) }
            guard !found.isEmpty else { return .rejected }
            if found.count == 1, labels[found[0]] == next {
                return .act(target: found[0], kind: ClickHintsClickKind(modifiers: modifiers))
            }
            typed = next
            matches = found
            return .updated
        case .space, .returnKey:
            guard matches.count == 1 else { return .rejected }
            return .act(target: matches[0], kind: ClickHintsClickKind(modifiers: modifiers))
        case .backspace:
            guard !typed.isEmpty else { return .unchanged }
            typed.removeLast()
            matches = labels.indices.filter { labels[$0].hasPrefix(typed) }
            return .updated
        case .escape:
            return .cancel
        case .tab, .backtab, .up, .down, .other:
            return .unchanged
        }
    }

    // MARK: Search

    private mutating func handleSearch(_ key: ClickHintsKey, modifiers: ClickHintsModifiers) -> Outcome {
        switch key {
        case .character("/"):
            mode = .labels
            query = ""
            typed = ""
            matches = Array(labels.indices)
            highlight = 0
            return .updated
        case .character(let character):
            let addition = ClickHintsSearch.normalize(String(character))
            guard !addition.isEmpty else { return .unchanged }
            query += addition
            refreshSearch()
            return .updated
        case .space:
            // Spaces are ignored in queries; with one match left, Space acts.
            guard matches.count == 1 else { return .unchanged }
            return .act(target: matches[0], kind: ClickHintsClickKind(modifiers: modifiers))
        case .returnKey:
            guard let target = highlightedTarget else { return .rejected }
            return .act(target: target, kind: ClickHintsClickKind(modifiers: modifiers))
        case .backspace:
            if query.isEmpty {
                mode = .labels
                matches = Array(labels.indices)
                highlight = 0
                return .updated
            }
            query.removeLast()
            refreshSearch()
            return .updated
        case .tab, .down:
            return moveHighlight(by: 1)
        case .backtab, .up:
            return moveHighlight(by: -1)
        case .escape:
            return .cancel
        case .other:
            return .unchanged
        }
    }

    private mutating func moveHighlight(by step: Int) -> Outcome {
        guard matches.count > 1 else { return .unchanged }
        highlight = (highlight + step + matches.count) % matches.count
        return .updated
    }

    private mutating func refreshSearch() {
        matches = query.isEmpty ? Array(labels.indices)
            : labels.indices.filter { index in searchForms[index].contains { $0.contains(query) } }
        highlight = 0
    }
}

// MARK: - Search text

/// Matching for search mode: case, accents, widths and spaces are ignored,
/// and Hangul names also match the 2-Set keys that type them.
enum ClickHintsSearch {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    /// The normalized name, and its 2-Set key spelling when it has Hangul.
    static func forms(of text: String) -> [String] {
        let plain = normalize(text)
        guard text.unicodeScalars.contains(where: isHangul) else { return plain.isEmpty ? [] : [plain] }
        return [plain, normalize(twoSetKeys(text))].filter { !$0.isEmpty }
    }

    static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value) || (0x3131...0x3163).contains(scalar.value)
    }

    // The keys of the Korean 2-Set (Dubeolsik) layout, lowercased: a doubled
    // consonant (ㄲ ⇧R) reads as its plain key, as typing without ⇧ would.
    private static let initials = ["r", "r", "s", "e", "e", "f", "a", "q", "q", "t", "t", "d", "w", "w", "c", "z", "x", "v", "g"]
    private static let medials = ["k", "o", "i", "o", "j", "p", "u", "p", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl",
                                  "b", "m", "ml", "l"]
    private static let finals = ["", "r", "r", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg",
                                 "a", "q", "qt", "t", "t", "d", "w", "c", "z", "x", "v", "g"]
    /// U+3131 ㄱ … U+3163 ㅣ (compatibility jamo).
    private static let compatibility = ["r", "r", "rt", "s", "sw", "sg", "e", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv",
                                        "fg", "a", "q", "q", "qt", "t", "t", "d", "w", "w", "c", "z", "x", "v", "g",
                                        "k", "o", "i", "o", "j", "p", "u", "p", "h", "hk", "ho", "hl", "y", "n", "nj",
                                        "np", "nl", "b", "m", "ml", "l"]

    /// "저장" → "wjwkd"; other characters stay as they are.
    static func twoSetKeys(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let value = Int(scalar.value)
            if (0xAC00...0xD7A3).contains(value) {
                let code = value - 0xAC00
                result += initials[code / 588] + medials[(code % 588) / 28] + finals[code % 28]
            } else if (0x3131...0x3163).contains(value) {
                result += compatibility[value - 0x3131]
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

// MARK: - Keys

/// Reads key events by key position through the current keyboard layout (the
/// ASCII-capable one behind an input method), so a Korean, Japanese or
/// Chinese input source types the same hint letters as ABC.
enum ClickHintsKeyboard {
    static let escape: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let tab: UInt16 = 48
    static let down: UInt16 = 125
    static let up: UInt16 = 126

    /// The key for a key code; `translate` gives the layout's character for
    /// a printable key.
    static func key(keyCode: UInt16, shift: Bool, translate: (UInt16) -> Character?) -> ClickHintsKey {
        switch keyCode {
        case escape: return .escape
        case returnKey, enter: return .returnKey
        case space: return .space
        case delete, forwardDelete: return .backspace
        case tab: return shift ? .backtab : .tab
        case down: return .down
        case up: return .up
        default:
            guard let character = translate(keyCode), !character.isWhitespace,
                  character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return .other }
            return .character(Character(character.lowercased()))
        }
    }
}

/// UCKeyTranslate over the current keyboard layout. Made once per hint
/// session on the main thread (Text Input Sources are used there only).
final class ClickHintsLayoutTranslator {
    private let layout: Data?
    private let keyboardType = UInt32(LMGetKbdType())

    init() {
        layout = Self.layoutData(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
            ?? Self.layoutData(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    private static func layoutData(_ source: TISInputSource?) -> Data? {
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.isEmpty ? nil : data
    }

    /// The unshifted character of `keyCode`, or nil (dead keys, no layout).
    func character(for keyCode: UInt16) -> Character? {
        guard let layout else { return nil }
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(base, keyCode, UInt16(kUCKeyActionDown), 0, keyboardType,
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).first
    }
}
