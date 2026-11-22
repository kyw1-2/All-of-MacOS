import AppKit
import Combine

// 7.8 (Codex spec MB-01, MB-02): menu bar items as the person sees them.
//
// On macOS 27 `com.apple.MenuBarAgent` publishes six direct children under
// its extras menu bar: two pressable live activities and four nameless
// `AXHostingView` containers with no actions. Battery, Sound, Control Center
// and the clock sit one level down, as `AXMenuBarItem/AXMenuExtra` with a
// description, an identifier and `AXShowMenu`/`AXPress`. AOM listed the four
// containers, so Settings showed four identical "MenuBarAgent" rows and
// "Open" pressed nothing. Containers are now walked (to a small depth), the
// system items get their names and symbols, and a person can give any item
// a name, a symbol and a group of their own.

/// One accessibility element as the probe read it — pure, for tests.
struct AOMMenuExtraNode: Equatable {
    var role = ""
    var subrole = ""
    var title = ""
    var description = ""
    var identifier = ""
    var actions: [String] = []
    var children: [AOMMenuExtraNode] = []

    var isActionable: Bool { actions.contains("AXPress") || actions.contains("AXShowMenu") }
    var isNamed: Bool { !title.isEmpty || !description.isEmpty || !identifier.isEmpty }
    /// Pictures and plain groups inside an item are never items themselves.
    var isDecoration: Bool { (role == "AXImage" || role == "AXGroup" || role == "AXStaticText") && !isActionable }
}

enum AOMMenuExtraFlatten {
    struct Result: Equatable {
        /// Index paths from the extras bar (the first index is the direct child).
        var paths: [[Int]] = []
        /// A container went deeper than the walk reads ("read in part").
        var truncated = false
    }

    /// Pure: which elements are the items. A direct child that can be pressed,
    /// or that names itself, is kept as it is (its pictures are not walked).
    /// A container with neither is walked down to `maxDepth`, keeping the
    /// first pressable or menu-extra element on each branch — so an item and
    /// a child doing the same thing count once. A container with nothing in
    /// it stays a row of its own (it may still answer a press).
    static func items(_ roots: [AOMMenuExtraNode], maxDepth: Int = 3) -> Result {
        var result = Result()
        for (index, root) in roots.enumerated() {
            if root.isActionable || root.isNamed || root.children.isEmpty {
                result.paths.append([index])
                continue
            }
            let before = result.paths.count
            walk(root.children, path: [index], depth: 1, maxDepth: maxDepth, into: &result)
            if result.paths.count == before { result.paths.append([index]) }
        }
        return result
    }

    private static func walk(_ nodes: [AOMMenuExtraNode], path: [Int], depth: Int, maxDepth: Int, into result: inout Result) {
        for (index, node) in nodes.enumerated() where !node.isDecoration || !node.children.isEmpty {
            let here = path + [index]
            if node.isActionable || node.subrole == "AXMenuExtra" {
                result.paths.append(here)
                continue
            }
            guard depth < maxDepth else {
                if !node.children.isEmpty { result.truncated = true }
                continue
            }
            walk(node.children, path: here, depth: depth + 1, maxDepth: maxDepth, into: &result)
        }
    }

    static func node(at path: [Int], in roots: [AOMMenuExtraNode]) -> AOMMenuExtraNode? {
        guard let first = path.first, roots.indices.contains(first) else { return nil }
        var node = roots[first]
        for index in path.dropFirst() {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }
}

/// What a system item is called and drawn as (macOS's own names).
struct AOMMenuBarIdentity: Equatable {
    let name: String
    let symbol: String

    /// Identifier fragments → name and symbol, most specific first.
    private static let known: [(keys: [String], name: String, symbol: String)] = [
        (["liveactivity", "live activity"], "Live Activity", "circle.dotted.circle"),
        (["timemachine", "time machine"], "Time Machine", "clock.arrow.circlepath"),
        (["keyboardbrightness"], "Keyboard Brightness", "light.max"),
        (["battery"], "Battery", "battery.75percent"),
        (["sound", "volume", "audio"], "Sound", "speaker.wave.2.fill"),
        (["controlcenter", "control center", "control-center"], "Control Center", "switch.2"),
        (["clock"], "Clock", "clock"),
        (["wifi", "wi-fi", "airport"], "Wi‑Fi", "wifi"),
        (["bluetooth"], "Bluetooth", "wave.3.right"),
        (["focus", "donotdisturb", "do not disturb"], "Focus", "moon.fill"),
        (["nowplaying", "now playing"], "Now Playing", "play.circle"),
        (["spotlight"], "Spotlight", "magnifyingglass"),
        (["siri"], "Siri", "mic.circle"),
        (["screenmirroring", "airplay", "screen mirroring"], "Screen Mirroring", "rectangle.on.rectangle"),
        (["display"], "Display", "sun.max"),
        (["textinput", "inputmenu", "input menu", "keyboard"], "Input Source", "keyboard"),
        (["user", "fastuserswitching"], "User", "person.crop.circle"),
        (["vpn"], "VPN", "network.badge.shield.half.filled"),
        (["accessibility"], "Accessibility", "accessibility"),
        (["hearing"], "Hearing", "ear"),
        (["stagemanager", "stage manager"], "Stage Manager", "rectangle.3.group"),
        (["weather"], "Weather", "cloud.sun"),
    ]

    /// Pure: the item's name and symbol from what macOS says about it. The
    /// identifier decides for Apple's own processes; otherwise a description
    /// that is exactly a known name ("Battery") does. nil: not recognised.
    static func identify(ownerBundleID: String, identifier: String, description: String) -> AOMMenuBarIdentity? {
        let apple = ownerBundleID.hasPrefix("com.apple.")
        let id = identifier.lowercased()
        if apple, !id.isEmpty {
            for entry in known where entry.keys.contains(where: { id.contains($0.replacingOccurrences(of: " ", with: "")) }) {
                return AOMMenuBarIdentity(name: entry.name, symbol: entry.symbol)
            }
        }
        let words = description.trimmingCharacters(in: .whitespaces).lowercased()
        guard apple, !words.isEmpty else { return nil }
        for entry in known where entry.keys.contains(where: { words == $0 || words.hasPrefix($0 + ",") || words.hasPrefix($0 + " ") }) {
            return AOMMenuBarIdentity(name: entry.name, symbol: entry.symbol)
        }
        return nil
    }

    /// Pure: text that changes (18°C, 80 %, 3:41) — kept as a detail line,
    /// never as the item's name or in its saved key.
    static func isChanging(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .decimalDigits) != nil
    }
}

/// A person's own name, symbol and group for an item (MB-02), keyed by the
/// item's stable identity — never by its place or its changing title.
struct AOMMenuBarAlias: Codable, Equatable {
    var name: String?
    var symbol: String?
    var group: String?

    var isEmpty: Bool {
        (name ?? "").isEmpty && (symbol ?? "").isEmpty && (group ?? "").isEmpty
    }
}

@MainActor
final class AOMMenuBarAliasStore: ObservableObject {
    static let shared = AOMMenuBarAliasStore()
    nonisolated static let key = "AOMMenuBarItemAliases"

    @Published private(set) var aliases: [String: AOMMenuBarAlias]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: AOMMenuBarAlias].self, from: data) {
            aliases = decoded
        } else {
            aliases = [:]
        }
    }

    func alias(for key: String?) -> AOMMenuBarAlias? {
        guard let key else { return nil }
        return aliases[key]
    }

    func set(_ alias: AOMMenuBarAlias?, for key: String) {
        if let alias, !alias.isEmpty { aliases[key] = alias } else { aliases.removeValue(forKey: key) }
        if let data = try? JSONEncoder().encode(aliases) { defaults.set(data, forKey: Self.key) }
    }

    /// The groups people have used, for the editor's suggestions.
    var groups: [String] {
        Array(Set(aliases.values.compactMap(\.group).filter { !$0.isEmpty })).sorted()
    }
}

/// Symbols offered when renaming an item (MB-02).
enum AOMMenuBarSymbolChoices {
    static let all: [String] = [
        "speaker.wave.2.fill", "speaker.slash.fill", "mic.fill", "headphones", "hifispeaker.2",
        "battery.75percent", "bolt.fill", "wifi", "wave.3.right", "network",
        "clock", "calendar", "timer", "alarm", "moon.fill",
        "sun.max", "cloud.sun", "switch.2", "slider.horizontal.3", "gearshape",
        "display", "rectangle.on.rectangle", "keyboard", "magnifyingglass", "doc.on.clipboard",
        "folder", "tray.full", "bell", "lock.shield", "person.crop.circle",
        "star.fill", "heart.fill", "bookmark.fill", "flag.fill", "tag.fill",
        "video.fill", "camera.fill", "music.note", "play.circle", "app.badge",
    ]
}
