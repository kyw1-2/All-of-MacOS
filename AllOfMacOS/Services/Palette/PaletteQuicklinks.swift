import AppKit
import Foundation

/// A Raycast-style quicklink: a keyword, a space and a query open a URL
/// template ("g cats" → Google). `{query}` (or `%s`) marks where the query
/// goes; it is percent-encoded so it can never change the URL around it.
struct PaletteQuicklink: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var keyword: String
    var name: String
    var template: String
    var isEnabled: Bool

    init(id: UUID = UUID(), keyword: String, name: String, template: String, isEnabled: Bool = true) {
        self.id = id
        self.keyword = keyword
        self.name = name
        self.template = template
        self.isEnabled = isEnabled
    }
}

enum PaletteQuicklinks {
    /// The user's list as JSON (Settings › Data › Reset Preferences brings
    /// back the defaults).
    static let storageKey = "AOMPaletteQuicklinks"
    static let placeholder = "{query}"
    /// Chrome and Firefox search engines use `%s`; both work.
    static let alternatePlaceholder = "%s"

    /// The defaults from the user's routine (Raycast, Naver, Papago, Homebrew).
    static let defaults: [PaletteQuicklink] = [
        PaletteQuicklink(keyword: "g", name: "Google", template: "https://www.google.com/search?q={query}"),
        PaletteQuicklink(keyword: "n", name: "Naver", template: "https://search.naver.com/search.naver?query={query}"),
        PaletteQuicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}"),
        PaletteQuicklink(keyword: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query={query}"),
        PaletteQuicklink(keyword: "r", name: "Reddit", template: "https://www.reddit.com/search/?q={query}"),
        PaletteQuicklink(keyword: "w", name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search={query}"),
        PaletteQuicklink(keyword: "p", name: "Papago", template: "https://papago.naver.com/?sk=auto&tk=ko&st={query}"),
        PaletteQuicklink(keyword: "maps", name: "Apple Maps", template: "https://maps.apple.com/?q={query}"),
        PaletteQuicklink(keyword: "so", name: "Stack Overflow", template: "https://stackoverflow.com/search?q={query}"),
        // formulae.brew.sh has no search URL (its search box runs in the
        // page), so the keyword opens the formula's own page.
        PaletteQuicklink(keyword: "brew", name: "Homebrew Formula", template: "https://formulae.brew.sh/formula/{query}"),
    ]

    /// Schemes a template may not use: local files and script URLs.
    static let refusedSchemes: Set<String> = ["file", "javascript", "data", "vbscript", "about"]

    // MARK: Storage

    static func load(from defaults: UserDefaults = .standard) -> [PaletteQuicklink] {
        guard let data = defaults.data(forKey: storageKey),
              let links = try? JSONDecoder().decode([PaletteQuicklink].self, from: data) else { return Self.defaults }
        return links
    }

    static func save(_ links: [PaletteQuicklink], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults.set(data, forKey: storageKey)
    }

    // MARK: URLs

    /// Percent-encodes everything except RFC 3986's unreserved characters
    /// (letters, digits, - . _ ~), so the query is safe in a path or a query
    /// string alike: "a b&c" → "a%20b%26c", "고양이" → "%EA%B3%A0%EC%96%91%EC%9D%B4".
    static func encode(_ query: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// The URL for `query`, or nil when the template is not a usable URL.
    /// A template without a placeholder opens as is (a plain bookmark).
    static func url(for link: PaletteQuicklink, query: String) -> URL? {
        guard validationProblem(link) == nil else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = encode(trimmed)
        let filled = link.template
            .replacingOccurrences(of: placeholder, with: encoded)
            .replacingOccurrences(of: alternatePlaceholder, with: encoded)
        guard let url = URL(string: filled), let scheme = url.scheme?.lowercased(),
              !refusedSchemes.contains(scheme) else { return nil }
        return url
    }

    static func hasPlaceholder(_ link: PaletteQuicklink) -> Bool {
        link.template.contains(placeholder) || link.template.contains(alternatePlaceholder)
    }

    // MARK: Matching

    struct Match: Equatable {
        let link: PaletteQuicklink
        /// The text after the keyword (may be empty while typing "g ").
        let query: String
    }

    /// "g cats" → Google with "cats"; the keyword is matched without case
    /// and must be followed by a space. Disabled links never match.
    static func match(_ text: String, in links: [PaletteQuicklink]) -> Match? {
        let trimmedLeading = String(text.drop { $0.isWhitespace })
        guard let space = trimmedLeading.firstIndex(where: { $0 == " " }) else { return nil }
        let keyword = trimmedLeading[trimmedLeading.startIndex..<space].lowercased()
        guard !keyword.isEmpty,
              let link = links.first(where: { $0.isEnabled && $0.keyword.lowercased() == keyword }) else { return nil }
        let query = trimmedLeading[trimmedLeading.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return Match(link: link, query: query)
    }

    /// Links whose keyword or name starts with `text` (typing "gh" or
    /// "Git" offers GitHub before the space).
    static func suggestions(_ text: String, in links: [PaletteQuicklink]) -> [PaletteQuicklink] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, !needle.contains(" ") else { return [] }
        return links.filter { link in
            link.isEnabled && (link.keyword.lowercased() == needle
                               || (needle.count >= 2 && link.name.lowercased().hasPrefix(needle)))
        }
    }

    // MARK: Validation

    enum Problem: Equatable {
        case emptyKeyword, keywordHasSpace, duplicateKeyword, emptyName, notAURL, refusedScheme
    }

    /// What is wrong with `link`, if anything; `others` are the rest of the
    /// list (for duplicate keywords).
    static func validationProblem(_ link: PaletteQuicklink, among others: [PaletteQuicklink] = []) -> Problem? {
        let keyword = link.keyword.trimmingCharacters(in: .whitespaces)
        if keyword.isEmpty { return .emptyKeyword }
        if keyword.contains(where: \.isWhitespace) { return .keywordHasSpace }
        if others.contains(where: { $0.id != link.id && $0.keyword.lowercased() == keyword.lowercased() }) {
            return .duplicateKeyword
        }
        if link.name.trimmingCharacters(in: .whitespaces).isEmpty { return .emptyName }
        let probe = link.template.replacingOccurrences(of: placeholder, with: "x")
            .replacingOccurrences(of: alternatePlaceholder, with: "x")
        guard let url = URL(string: probe), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .notAURL }
        if refusedSchemes.contains(scheme) { return .refusedScheme }
        if (scheme == "http" || scheme == "https") && (url.host ?? "").isEmpty { return .notAURL }
        return nil
    }

    static func message(for problem: Problem) -> String {
        switch problem {
        case .emptyKeyword: return "Type a keyword."
        case .keywordHasSpace: return "A keyword can't contain spaces."
        case .duplicateKeyword: return "Another quicklink uses this keyword."
        case .emptyName: return "Type a name."
        case .notAURL: return "Type a full URL, for example https://example.com/search?q={query}."
        case .refusedScheme: return "Quicklinks open web and app links, not files or scripts."
        }
    }
}

/// The quicklinks the palette and its editor share.
@MainActor
final class PaletteQuicklinkStore: ObservableObject {
    static let shared = PaletteQuicklinkStore()

    @Published private(set) var links: [PaletteQuicklink]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.links = PaletteQuicklinks.load(from: defaults)
    }

    func replace(with links: [PaletteQuicklink]) {
        self.links = links
        PaletteQuicklinks.save(links, to: defaults)
    }

    func reload() {
        links = PaletteQuicklinks.load(from: defaults)
    }
}
