import AppKit

// Click Hints settings (Text Actions › Click Hints). Every key starts with
// AOMClickHints, so Settings › Data › Reset Preferences resets them, and
// `backedUpKeys` puts them in the settings backup.

/// The characters labels are made of, best keys first.
enum ClickHintsAlphabet: String, CaseIterable, Identifiable {
    /// The nine home-row keys; more letters join only when a window has more
    /// than 81 targets, so labels stay at two letters.
    case homeRow
    /// All 26 letters from the start: more one-letter labels.
    case letters
    /// The digits 1–9 and 0.
    case numbers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .homeRow: return "Home Row"
        case .letters: return "Letters"
        case .numbers: return "Numbers"
        }
    }

    /// Every letter in the order labels use them on a QWERTY keyboard: the
    /// home row by finger strength (index, middle, ring, little, then the
    /// index stretch), then the top row, then the bottom row.
    static let comfortOrder: [Character] = Array("fjdkslaghrueiwoqptyvmcnxbz")
    static let homeRowCount = 9

    /// The characters this alphabet starts with.
    var baseCharacters: [Character] {
        switch self {
        case .homeRow: return Array(Self.comfortOrder.prefix(Self.homeRowCount))
        case .letters: return Self.comfortOrder
        case .numbers: return Array("1234567890")
        }
    }

    /// The characters labels for `count` targets use. The home row grows
    /// one letter at a time until two letters can label every target.
    func characters(forCount count: Int) -> [Character] {
        guard self == .homeRow, count > Self.homeRowCount * Self.homeRowCount else { return baseCharacters }
        let needed = Int(Double(count).squareRoot().rounded(.up))
        return Array(Self.comfortOrder.prefix(min(Self.comfortOrder.count, max(Self.homeRowCount, needed))))
    }

    /// A short sample for the settings row ("F J D K S L A G H").
    var sample: String {
        baseCharacters.prefix(9).map { String($0).uppercased() }.joined(separator: " ")
    }
}

/// How large the pills are. Each size follows a macOS text style, never a
/// fixed point size, so the system text size applies.
enum ClickHintsSize: String, CaseIterable, Identifiable {
    case small, regular, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .regular: return "Regular"
        case .large: return "Large"
        }
    }

    var textStyle: NSFont.TextStyle {
        switch self {
        case .small: return .subheadline
        case .regular: return .callout
        case .large: return .title3
        }
    }

    /// The capsule height in points (design-340 b.17: 22 pt capsules).
    var height: CGFloat {
        switch self {
        case .small: return 18
        case .regular: return 22
        case .large: return 26
        }
    }
}

/// The stored options, read when hints are shown (nothing is cached).
struct ClickHintsSettings {
    static let alphabetKey = "AOMClickHintsAlphabet"
    static let sizeKey = "AOMClickHintsSize"
    static let menuBarKey = "AOMClickHintsMenuBar"
    static let dockKey = "AOMClickHintsDock"
    static let startInSearchKey = "AOMClickHintsStartInSearch"
    static let enhancedAppsKey = "AOMClickHintsEnhancedApps"
    static let excludedAppsKey = "AOMClickHintsExcludedApps"

    /// Every key, for the settings backup and Reset Preferences.
    static let backedUpKeys = [alphabetKey, sizeKey, menuBarKey, dockKey, startInSearchKey,
                               enhancedAppsKey, excludedAppsKey]

    /// Password managers start excluded (the same five Text Actions uses,
    /// checked on this Mac): 1Password 8 and 7, Bitwarden, Keychain Access
    /// and Passwords.
    static let defaultExcludedApps = ["com.1password.1password", "com.agilebits.onepassword7",
                                      "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"]

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var alphabet: ClickHintsAlphabet {
        get { defaults.string(forKey: Self.alphabetKey).flatMap(ClickHintsAlphabet.init(rawValue:)) ?? .homeRow }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.alphabetKey) }
    }

    var size: ClickHintsSize {
        get { defaults.string(forKey: Self.sizeKey).flatMap(ClickHintsSize.init(rawValue:)) ?? .regular }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.sizeKey) }
    }

    /// Off by default: hints cover the front window only.
    var includesMenuBar: Bool {
        get { defaults.bool(forKey: Self.menuBarKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.menuBarKey) }
    }

    var includesDock: Bool {
        get { defaults.bool(forKey: Self.dockKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.dockKey) }
    }

    /// Start by typing part of a name instead of a label.
    var startsInSearch: Bool {
        get { defaults.bool(forKey: Self.startInSearchKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.startInSearchKey) }
    }

    /// Apps (bundle identifiers) asked to build their accessibility tree
    /// before hints are read: Chromium and Electron apps. Empty by default.
    var enhancedApps: [String] {
        get { Self.cleaned(defaults.stringArray(forKey: Self.enhancedAppsKey) ?? []) }
        nonmutating set { defaults.set(Self.cleaned(newValue), forKey: Self.enhancedAppsKey) }
    }

    /// Apps where hints never appear. Never set means the password managers;
    /// an empty list is kept as the person's choice.
    var excludedApps: [String] {
        get {
            guard let stored = defaults.stringArray(forKey: Self.excludedAppsKey) else { return Self.defaultExcludedApps }
            return Self.cleaned(stored)
        }
        nonmutating set { defaults.set(Self.cleaned(newValue), forKey: Self.excludedAppsKey) }
    }

    /// Trimmed, non-empty and unique, in the order given.
    static func cleaned(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }
}
