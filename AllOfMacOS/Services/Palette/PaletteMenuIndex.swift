import AppKit
import ApplicationServices

/// One node of an app's menu bar as Accessibility reports it (or as a test
/// fixture builds it): a top-level menu, a submenu or an item.
struct PaletteMenuNode {
    var title: String
    var isEnabled = true
    var commandCharacter: String?
    /// kAXMenuItemModifier bits: Shift 1, Option 2, Control 4, no Command 8.
    var commandModifiers: Int?
    /// A Carbon menu glyph (kMenuDeleteLeftGlyph …), for keys with no character.
    var commandGlyph: Int?
    var commandVirtualKey: Int?
    /// "✓" or "•" when the item is checked.
    var markCharacter: String?
    var children: [PaletteMenuNode] = []
    var element: AXUIElement?

    init(title: String, isEnabled: Bool = true, commandCharacter: String? = nil, commandModifiers: Int? = nil,
         commandGlyph: Int? = nil, commandVirtualKey: Int? = nil, markCharacter: String? = nil,
         children: [PaletteMenuNode] = [], element: AXUIElement? = nil) {
        self.title = title
        self.isEnabled = isEnabled
        self.commandCharacter = commandCharacter
        self.commandModifiers = commandModifiers
        self.commandGlyph = commandGlyph
        self.commandVirtualKey = commandVirtualKey
        self.markCharacter = markCharacter
        self.children = children
        self.element = element
    }
}

/// A menu item that can be chosen, flattened out of its menus.
struct PaletteMenuItem: Identifiable, Equatable {
    /// Unique within one app's menus: the path, plus "#2" for repeats.
    let id: String
    let title: String
    /// The menus above the item: ["File", "Export"].
    let path: [String]
    /// "⇧⌘S", in the HIG order ⌃⌥⇧⌘; nil when the item has none.
    let shortcut: String?
    let isEnabled: Bool
    let isChecked: Bool

    /// "File › Export › PDF".
    var fullPath: String { (path + [title]).joined(separator: " › ") }
    /// The top-level menu ("File").
    var menu: String { path.first ?? "" }
}

enum PaletteMenuFlattener {
    /// Every choosable item under `menus` (the menu bar's top-level menus,
    /// the Apple menu already left out). Separators, untitled custom views
    /// and the submenu items themselves are skipped; items inside submenus
    /// carry the submenu in their path. At most `limit` items.
    static func flatten(_ menus: [PaletteMenuNode], limit: Int = 2000) -> [(item: PaletteMenuItem, element: AXUIElement?)] {
        var result: [(item: PaletteMenuItem, element: AXUIElement?)] = []
        var seen: [String: Int] = [:]
        func visit(_ node: PaletteMenuNode, path: [String], depth: Int) {
            guard result.count < limit, depth <= 6 else { return }
            let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            if !node.children.isEmpty {
                for child in node.children { visit(child, path: path + [title], depth: depth + 1) }
                return
            }
            let key = (path + [title]).joined(separator: "\u{1F}")
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            let item = PaletteMenuItem(
                id: count == 1 ? key : "\(key)#\(count)", title: title, path: path,
                shortcut: shortcut(character: node.commandCharacter, modifiers: node.commandModifiers,
                                   glyph: node.commandGlyph, virtualKey: node.commandVirtualKey),
                isEnabled: node.isEnabled,
                isChecked: !(node.markCharacter ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            result.append((item, node.element))
        }
        for menu in menus {
            let title = menu.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            for child in menu.children { visit(child, path: [title], depth: 1) }
        }
        return result
    }

    // MARK: Shortcuts

    /// The key equivalent as macOS menus draw it: modifiers in ⌃⌥⇧⌘ order,
    /// then the key ("⇧⌘S", "⌥⌘←", "⌃F2"). Nil when the item has no key.
    static func shortcut(character: String?, modifiers: Int?, glyph: Int?, virtualKey: Int?) -> String? {
        let key: String
        if let glyph, glyph != 0, let name = glyphNames[glyph] {
            key = name
        } else if let character, !character.isEmpty {
            key = displayKey(character)
        } else if let virtualKey, let name = virtualKeyNames[virtualKey] {
            key = name
        } else {
            return nil
        }
        let bits = modifiers ?? 0
        var text = ""
        if bits & 4 != 0 { text += "⌃" }
        if bits & 2 != 0 { text += "⌥" }
        if bits & 1 != 0 { text += "⇧" }
        if bits & 8 == 0 { text += "⌘" }
        return text + key
    }

    static func displayKey(_ character: String) -> String {
        guard let scalar = character.unicodeScalars.first else { return character }
        switch scalar.value {
        case 0x08, 0x7F: return "⌫"
        case 0x0D: return "↩"
        case 0x03: return "⌤"
        case 0x09: return "⇥"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF70F: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        default: return character.uppercased()
        }
    }

    /// Carbon's menu glyphs (HIToolbox Menus.h) for keys without a character.
    static let glyphNames: [Int: String] = {
        var names: [Int: String] = [0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x0D: "↩",
                                    0x17: "⌫", 0x1B: "⎋", 0x1C: "⌧", 0x62: "⇞", 0x63: "⇪", 0x64: "←", 0x65: "→",
                                    0x66: "↖", 0x68: "↑", 0x69: "↘", 0x6A: "↓", 0x6B: "⇟", 0x8C: "⏏",
                                    0x87: "F13", 0x88: "F14", 0x89: "F15", 0x8F: "F16", 0x90: "F17", 0x91: "F18", 0x92: "F19"]
        for index in 0..<12 { names[0x6F + index] = "F\(index + 1)" }
        return names
    }()

    static let virtualKeyNames: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

enum PaletteMenuSearch {
    /// Items matching `query`, best first: the title counts more than the
    /// path, unavailable items sink, ties keep menu order.
    static func results(_ items: [PaletteMenuItem], query: String, limit: Int = 30) -> [PaletteMenuItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let scored: [(item: PaletteMenuItem, score: Int, order: Int)] = items.enumerated().compactMap { order, item in
            guard var score = PaletteFuzzy.bestScore(trimmed, fields: [(item.title, 0), (item.fullPath, 60)]) else { return nil }
            if !item.isEnabled { score -= 400 }
            return (item, score, order)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(limit).map(\.item)
    }

    /// The items that have a key equivalent, grouped by top-level menu in
    /// menu-bar order (the hold-⌘ shortcut sheet).
    static func shortcutGroups(_ items: [PaletteMenuItem]) -> [(menu: String, items: [PaletteMenuItem])] {
        var order: [String] = []
        var groups: [String: [PaletteMenuItem]] = [:]
        for item in items where item.shortcut != nil {
            if groups[item.menu] == nil { order.append(item.menu) }
            groups[item.menu, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

/// Reads an app's menu bar through Accessibility. Every call is bounded by
/// `AXDeadline` (per request and in all) and must run off the main thread.
enum PaletteMenuReader {
    private static let attributes: [String] = [
        kAXTitleAttribute, kAXEnabledAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers",
        "AXMenuItemCmdGlyph", "AXMenuItemCmdVirtualKey", "AXMenuItemMarkChar", kAXChildrenAttribute,
    ]

    /// The top-level menus of `pid` without the Apple menu, or nil when the
    /// app has no readable menu bar.
    static func read(pid: pid_t, budget: TimeInterval = 1.5, maximumItems: Int = 2000) -> [PaletteMenuNode]? {
        let application = AXUIElementCreateApplication(pid)
        let limit = AXDeadline(perRequest: 0.3, budget: budget)
        guard limit.allow(application), let menuBar = element(application, kAXMenuBarAttribute),
              limit.allow(menuBar), let barItems = children(menuBar) else { return nil }
        var count = 0
        var menus: [PaletteMenuNode] = []
        // The first menu-bar item is the Apple menu (About This Mac, Shut Down…).
        for barItem in barItems.dropFirst() {
            guard !limit.isSpent, var node = readItem(barItem, limit: limit, depth: 0, count: &count, maximum: maximumItems) else { continue }
            node.element = barItem
            menus.append(node)
        }
        return menus
    }

    private static func readItem(_ item: AXUIElement, limit: AXDeadline, depth: Int, count: inout Int,
                                 maximum: Int) -> PaletteMenuNode? {
        guard depth <= 6, count < maximum, limit.allow(item) else { return nil }
        count += 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(item, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let list = values as? [AnyObject], list.count == attributes.count else { return nil }
        func value(_ index: Int) -> AnyObject? {
            let raw = list[index]
            if CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .axError { return nil }
            return raw
        }
        var node = PaletteMenuNode(title: value(0) as? String ?? "",
                                   isEnabled: value(1) as? Bool ?? true,
                                   commandCharacter: value(2) as? String,
                                   commandModifiers: (value(3) as? NSNumber)?.intValue,
                                   commandGlyph: (value(4) as? NSNumber)?.intValue,
                                   commandVirtualKey: (value(5) as? NSNumber)?.intValue,
                                   markCharacter: value(6) as? String,
                                   element: item)
        // A submenu: the item's one child is an AXMenu holding the items.
        if let children = value(7) as? [AXUIElement], let submenu = children.first, limit.allow(submenu),
           let entries = PaletteMenuReader.children(submenu) {
            node.children = entries.compactMap { readItem($0, limit: limit, depth: depth + 1, count: &count, maximum: maximum) }
        }
        return node
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ parent: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    /// Presses a menu item (the same as choosing it).
    static func press(_ element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, 0.6)
        return AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
}

/// One app's flattened menus, as read at `readAt`.
struct PaletteMenuSnapshot {
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let version: String?
    let items: [PaletteMenuItem]
    let elements: [String: AXUIElement]
    let readAt: Date
}

/// Menus of recently searched apps, read once and kept for a short time:
/// the palette reuses them for 60 s, the shortcut sheet (keys rarely change)
/// for 10 minutes. At most four apps are kept.
final class PaletteMenuIndex: @unchecked Sendable {
    static let shared = PaletteMenuIndex()

    enum Failure: Error, Equatable {
        /// AOM may not use Accessibility.
        case notTrusted
        /// The app has no menu bar AOM can read (or it didn't answer in time).
        case unreadable
    }

    static let paletteLifetime: TimeInterval = 60
    static let sheetLifetime: TimeInterval = 600
    static let capacity = 4

    private let lock = NSLock()
    private var cache: [pid_t: PaletteMenuSnapshot] = [:]
    private var recency: [pid_t] = []
    var now: () -> Date = Date.init
    /// Test seam: the reader (the real one asks Accessibility).
    var reader: (pid_t) -> [PaletteMenuNode]? = { PaletteMenuReader.read(pid: $0) }
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }

    func cached(pid: pid_t, maxAge: TimeInterval) -> PaletteMenuSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot = cache[pid], now().timeIntervalSince(snapshot.readAt) < maxAge else { return nil }
        return snapshot
    }

    /// The app's menus, from the cache when fresh enough, else read now.
    /// Call off the main thread.
    func snapshot(pid: pid_t, appName: String, bundleID: String?, version: String?,
                  maxAge: TimeInterval = PaletteMenuIndex.paletteLifetime) -> Result<PaletteMenuSnapshot, Failure> {
        if let cached = cached(pid: pid, maxAge: maxAge), cached.version == version { return .success(cached) }
        guard isTrusted() else { return .failure(.notTrusted) }
        guard let menus = reader(pid) else { return .failure(.unreadable) }
        let flat = PaletteMenuFlattener.flatten(menus)
        var elements: [String: AXUIElement] = [:]
        for entry in flat { if let element = entry.element { elements[entry.item.id] = element } }
        let snapshot = PaletteMenuSnapshot(pid: pid, appName: appName, bundleID: bundleID, version: version,
                                           items: flat.map(\.item), elements: elements, readAt: now())
        store(snapshot)
        return .success(snapshot)
    }

    func invalidate(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        cache[pid] = nil
        recency.removeAll { $0 == pid }
    }

    private func store(_ snapshot: PaletteMenuSnapshot) {
        lock.lock(); defer { lock.unlock() }
        cache[snapshot.pid] = snapshot
        recency.removeAll { $0 == snapshot.pid }
        recency.insert(snapshot.pid, at: 0)
        while recency.count > Self.capacity, let oldest = recency.popLast() { cache[oldest] = nil }
    }

    /// Chooses `item`: presses the element read with the snapshot, and when
    /// the app rebuilt its menus since (the element is gone), reads them
    /// again and presses the item at the same path. Call off the main thread.
    func press(_ item: PaletteMenuItem, in snapshot: PaletteMenuSnapshot) -> AXError {
        if let element = snapshot.elements[item.id] {
            let result = PaletteMenuReader.press(element)
            if result != .invalidUIElement && result != .cannotComplete { return result }
        }
        invalidate(pid: snapshot.pid)
        guard let menus = reader(snapshot.pid) else { return .cannotComplete }
        guard let fresh = PaletteMenuFlattener.flatten(menus).first(where: { $0.item.id == item.id }),
              let element = fresh.element else { return .invalidUIElement }
        return PaletteMenuReader.press(element)
    }

    static func failureReason(_ error: AXError) -> String {
        switch error {
        case .apiDisabled: return "All of MacOS isn't allowed to use Accessibility"
        case .invalidUIElement: return "the menu item is no longer there"
        case .cannotComplete: return "the app didn't respond"
        case .actionUnsupported: return "the item can't be chosen this way"
        default: return "the app refused it (error \(error.rawValue))"
        }
    }
}
