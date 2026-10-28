import AppKit
import AVFoundation
import Carbon
import CoreMIDI
import CoreWLAN
import IOBluetooth
import Network

// 3.1.0 parity actions: the remaining BetterTouchTool, Paste and CleanShot X
// features that run locally (no cloud, Magic Mouse or Stream Deck). Pure logic
// sits in small enums so it is unit tested; the system calls stay in
// `ParityActions`, which `ActionExecutor` reaches only without a test hook.

// MARK: - Text transforms

/// Rewrites shared by Transform Selected Text and Transform Clipboard Text.
enum TextTransform: String, CaseIterable, Identifiable {
    case uppercase, lowercase, titleCase, sentenceCase
    case trimWhitespace, collapseSpaces, removeLineBreaks
    case camelCase, snakeCase, kebabCase
    case urlEncode, urlDecode
    case sortLines, reverseLines, removeDuplicateLines
    case plainText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uppercase: return "UPPER CASE"
        case .lowercase: return "lower case"
        case .titleCase: return "Title Case"
        case .sentenceCase: return "Sentence case"
        case .trimWhitespace: return "Trim Whitespace"
        case .collapseSpaces: return "Collapse Repeated Spaces"
        case .removeLineBreaks: return "Join Lines"
        case .camelCase: return "camelCase"
        case .snakeCase: return "snake_case"
        case .kebabCase: return "kebab-case"
        case .urlEncode: return "URL Encode"
        case .urlDecode: return "URL Decode"
        case .sortLines: return "Sort Lines"
        case .reverseLines: return "Reverse Lines"
        case .removeDuplicateLines: return "Remove Duplicate Lines"
        case .plainText: return "Plain Text (remove formatting)"
        }
    }

    /// RFC 3986 unreserved characters; everything else is percent-encoded.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    func apply(_ text: String, locale: Locale = .current) -> String {
        switch self {
        case .uppercase: return text.uppercased(with: locale)
        case .lowercase: return text.lowercased(with: locale)
        case .titleCase: return text.capitalized(with: locale)
        case .sentenceCase: return Self.sentenceCased(text, locale: locale)
        case .trimWhitespace: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .collapseSpaces: return Self.collapsingSpaces(text)
        case .removeLineBreaks: return Self.joiningLines(text)
        case .camelCase:
            let words = Self.words(text)
            guard let first = words.first else { return text }
            return first.lowercased(with: locale)
                + words.dropFirst().map { $0.lowercased(with: locale).capitalized(with: locale) }.joined()
        case .snakeCase, .kebabCase:
            let words = Self.words(text)
            guard !words.isEmpty else { return text }
            return words.map { $0.lowercased(with: locale) }.joined(separator: self == .snakeCase ? "_" : "-")
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? text
        case .urlDecode: return text.removingPercentEncoding ?? text
        case .sortLines:
            return Self.mapLines(text) { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        case .reverseLines: return Self.mapLines(text) { $0.reversed() }
        case .removeDuplicateLines:
            return Self.mapLines(text) { lines in
                var seen = Set<String>()
                return lines.filter { seen.insert($0).inserted }
            }
        case .plainText: return text
        }
    }

    /// Words for the naming styles: split on anything that is not a letter or
    /// digit, and on a lower-to-upper case change ("fileName" → file, Name).
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isLetter || character.isNumber {
                if let previous, !current.isEmpty, previous.isLowercase || previous.isNumber, character.isUppercase {
                    words.append(current); current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                words.append(current); current = ""
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func sentenceCased(_ text: String, locale: Locale) -> String {
        var result = ""
        var capitalizeNext = true
        for character in text.lowercased(with: locale) {
            if capitalizeNext, character.isLetter {
                result += String(character).uppercased(with: locale)
                capitalizeNext = false
                continue
            }
            result.append(character)
            if ".!?".contains(character) || character.isNewline { capitalizeNext = true }
            else if character.isNumber { capitalizeNext = false }
        }
        return result
    }

    static func collapsingSpaces(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            let isSpace = character == " " || character == "\t"
            if isSpace && lastWasSpace { continue }
            result.append(isSpace ? " " : character)
            lastWasSpace = isSpace
        }
        return result
    }

    static func joiningLines(_ text: String) -> String {
        lines(text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Applies a line operation while keeping one trailing line break in place,
    /// so sorting "b\na\n" gives "a\nb\n" rather than a leading empty line.
    static func mapLines(_ text: String, _ transform: ([String]) -> [String]) -> String {
        var all = lines(text)
        let trailingBreak = all.count > 1 && all.last == ""
        if trailingBreak { all.removeLast() }
        return transform(all).joined(separator: "\n") + (trailingBreak ? "\n" : "")
    }
}

// MARK: - Selected text

enum TextActionSupport {
    static let defaultSearchURL = "https://www.google.com/search?q={query}"
    static let searchPresets: [(name: String, url: String)] = [
        ("Google", defaultSearchURL),
        ("DuckDuckGo", "https://duckduckgo.com/?q={query}"),
        ("Naver", "https://search.naver.com/search.naver?query={query}"),
        ("Wikipedia", "https://en.wikipedia.org/w/index.php?search={query}"),
        ("Apple Developer", "https://developer.apple.com/search/?q={query}"),
        ("GitHub", "https://github.com/search?q={query}")
    ]

    /// Any URL scheme works (custom app schemes too); `{query}` is required.
    static func isValidSearchTemplate(_ template: String) -> Bool {
        guard template.contains("{query}"), !template.contains(where: \.isWhitespace) else { return false }
        return URL(string: template.replacingOccurrences(of: "{query}", with: "x"))?.scheme?.isEmpty == false
    }

    static func searchURL(template: String, query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isValidSearchTemplate(template),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: TextTransform.unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }

    /// Workflow variables hold at most 512 characters.
    static func variableValue(_ text: String) -> String { String(text.prefix(512)) }
}

@MainActor
enum SelectedTextReader {
    /// Accessibility first, which has no clipboard side effects; ⌘C otherwise.
    static func read(_ completion: @escaping (String?) -> Void) {
        if let text = accessibilitySelection(), !text.isEmpty { completion(text); return }
        copySelection(completion)
    }

    static func accessibilitySelection() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// For apps that do not expose AXSelectedText (many Electron apps and web
    /// views): press ⌘C, read the string, then put the user's clipboard back.
    /// AOM's own history is paused around the probe so neither write is kept.
    static func copySelection(_ completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let before = pasteboard.changeCount
        let store = ClipboardStore.shared
        let wasPaused = store.paused
        if !wasPaused { store.paused = true }
        func finish(_ text: String?) {
            if pasteboard.changeCount != before { snapshot.restore(to: pasteboard) }
            if !wasPaused { store.paused = false }
            completion(text)
        }
        guard SyntheticInput.key(8, flags: .maskCommand) else { finish(nil); return }
        var attempts = 0
        func poll() {
            if pasteboard.changeCount != before { finish(pasteboard.string(forType: .string)); return }
            attempts += 1
            guard attempts < 15 else { finish(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { poll() }
    }
}

// MARK: - Menus

enum MenuPath {
    static let separators: Set<Character> = [">", "›", "→", "▸"]

    /// "File > Export > PDF…" → ["File", "Export", "PDF…"].
    static func components(_ path: String) -> [String] {
        path.split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Case- and accent-insensitive, ignoring a trailing ellipsis ("…" or "...").
    static func normalized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("…") || text.hasSuffix(".") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Exact title, or a whole-title `*` / `?` wildcard pattern.
    static func matches(_ title: String, _ wanted: String) -> Bool {
        let pattern = normalized(wanted)
        guard !pattern.isEmpty else { return false }
        if pattern.contains("*") || pattern.contains("?") {
            return WorkflowBranchCondition.wildcardMatches(pattern, normalized(title))
        }
        return normalized(title) == pattern
    }

    /// Chooses the item; nil means success, otherwise the reason it failed.
    static func choose(_ path: String, pid: pid_t) -> String? {
        let parts = components(path)
        guard !parts.isEmpty else { return "The menu path is empty." }
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return "The app has no accessible menu bar." }
        var level = AX.children(bar as! AXUIElement)
        for (index, part) in parts.enumerated() {
            guard let item = level.first(where: { matches(AX.string($0, kAXTitleAttribute) ?? "", part) }) else {
                return "No menu item named “\(part)”."
            }
            if index == parts.count - 1 {
                if AX.bool(item, kAXEnabledAttribute) == false { return "“\(part)” is disabled right now." }
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? nil : "“\(part)” could not be chosen."
            }
            // A menu bar item or submenu item holds one AXMenu with the items.
            level = AX.children(item).flatMap { AX.children($0) }
        }
        return nil
    }
}

/// Small Accessibility readers shared by the parity actions.
enum AX {
    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
    static func windows(pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
    static func isStandardWindow(_ window: AXUIElement) -> Bool {
        string(window, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String)
    }
}

// MARK: - Apps and windows

/// Most-recent-first list without duplicates, used for Activate Previous App.
struct RecentRing<ID: Equatable> {
    private(set) var items: [ID] = []
    let capacity: Int
    init(capacity: Int = 16) { self.capacity = max(1, capacity) }
    mutating func note(_ id: ID) {
        items.removeAll { $0 == id }
        items.insert(id, at: 0)
        if items.count > capacity { items.removeLast(items.count - capacity) }
    }
    mutating func remove(_ id: ID) { items.removeAll { $0 == id } }
    /// The most recent item that is not `current` and still passes `isAlive`.
    func previous(excluding current: ID?, isAlive: (ID) -> Bool = { _ in true }) -> ID? {
        items.first { $0 != current && isAlive($0) }
    }
}

@MainActor
final class AppActivationHistory {
    static let shared = AppActivationHistory()
    private var ring = RecentRing<pid_t>()
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        if let front = NSWorkspace.shared.frontmostApplication { note(front) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { AppActivationHistory.shared.note(app) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { AppActivationHistory.shared.ring.remove(pid) }
        })
    }

    private func note(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.processIdentifier != getpid() else { return }
        ring.note(app.processIdentifier)
    }

    /// The apps activated most recently first, still running. Read-only, for
    /// the menu bar's tap-and-hold app switch (`AppCycle`).
    func recentPIDs() -> [pid_t] {
        ring.items.filter { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false }
    }

    func previousApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return ring.previous(excluding: front) { pid in
            NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
        }.flatMap { NSRunningApplication(processIdentifier: $0) }
    }
}

/// One entry of the on-screen window list, front to back.
struct OnScreenWindow: Equatable {
    var pid: pid_t
    var layer: Int
    var bounds: CGRect
    var alpha: Double

    static func current() -> [OnScreenWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return OnScreenWindow(pid: pid, layer: layer, bounds: bounds, alpha: window[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// The app whose normal window is topmost at `point` (global, top-left
    /// origin). Over the Dock, the menu bar or a panel the answer is nil, so a
    /// quit never reaches through to a window underneath.
    static func owner(at point: CGPoint, in windows: [OnScreenWindow], excluding own: pid_t) -> pid_t? {
        for window in windows where window.pid != own && window.alpha > 0 && window.bounds.contains(point) {
            return window.layer == 0 ? window.pid : nil
        }
        return nil
    }
}

extension WindowGeometry {
    /// Keeps a window's place when it moves to another display: the same share
    /// of free space on each side, shrunk only when it does not fit.
    static func carried(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let size = CGSize(width: min(window.width, target.width), height: min(window.height, target.height))
        func share(_ offset: CGFloat, _ free: CGFloat) -> CGFloat { free > 0 ? min(1, max(0, offset / free)) : 0.5 }
        let x = share(window.minX - source.minX, source.width - window.width)
        let y = share(window.minY - source.minY, source.height - window.height)
        return CGRect(x: (target.minX + x * (target.width - size.width)).rounded(),
                      y: (target.minY + y * (target.height - size.height)).rounded(),
                      width: size.width, height: size.height)
    }

    /// Left and right halves of a visible area; the right half takes any odd point.
    static func sideBySide(in visible: CGRect) -> (left: CGRect, right: CGRect) {
        let leftWidth = (visible.width / 2).rounded(.down)
        let left = CGRect(x: visible.minX, y: visible.minY, width: leftWidth, height: visible.height)
        return (left, CGRect(x: left.maxX, y: visible.minY, width: visible.width - leftWidth, height: visible.height))
    }

    static func titleMatches(_ title: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, !title.isEmpty else { return false }
        if needle.contains("*") || needle.contains("?") {
            return WorkflowBranchCondition.wildcardMatches(needle.lowercased(), title.lowercased())
        }
        return title.localizedCaseInsensitiveContains(needle)
    }
}

// MARK: - Input sources and displays

enum InputSources {
    struct Source: Identifiable, Equatable {
        let id: String
        let name: String
    }

    static func enabled() -> [Source] { list().map(\.source) }

    private static func list() -> [(source: Source, ref: TISInputSource)] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as [String: Any]
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return sources.compactMap { ref in
            guard let id = property(ref, kTISPropertyInputSourceID) else { return nil }
            return (Source(id: id, name: property(ref, kTISPropertyLocalizedName) ?? id), ref)
        }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(source, kTISPropertyInputSourceID)
    }

    /// An empty request cycles to the next enabled source; otherwise an exact
    /// identifier wins over a case-insensitive name.
    static func target(for wanted: String?, in sources: [Source], current: String?) -> Source? {
        let request = (wanted ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sources.isEmpty else { return nil }
        if request.isEmpty {
            let index = sources.firstIndex { $0.id == current } ?? -1
            return sources[(index + 1) % sources.count]
        }
        return sources.first { $0.id == request } ?? sources.first { $0.name.caseInsensitiveCompare(request) == .orderedSame }
    }

    static func select(_ wanted: String?) -> Source? {
        let all = list()
        guard let chosen = target(for: wanted, in: all.map(\.source), current: currentID()),
              let ref = all.first(where: { $0.source == chosen })?.ref,
              TISSelectInputSource(ref) == noErr else { return nil }
        return chosen
    }
}

enum DisplayMirroring {
    /// The master each display should get: unmirror all when any display is in
    /// a mirror set, otherwise mirror every other display to the main one.
    static func plan(displays: [CGDirectDisplayID], main: CGDirectDisplayID, anyMirrored: Bool) -> [(CGDirectDisplayID, CGDirectDisplayID)] {
        displays.filter { $0 != main }.map { ($0, anyMirrored ? kCGNullDirectDisplay : main) }
    }

    static func toggle() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 1 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        let mirrored = displays.contains { CGDisplayIsInMirrorSet($0) != 0 }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for (display, master) in plan(displays: displays, main: CGMainDisplayID(), anyMirrored: mirrored) {
            guard CGConfigureDisplayMirrorOfDisplay(config, display, master) == .success else {
                CGCancelDisplayConfiguration(config); return false
            }
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}

// MARK: - OCR

enum ScreenTextSearch {
    /// Approximate box of `query` inside the first line that contains it, in
    /// the lines' pixel space. Glyphs are taken as evenly wide inside a line,
    /// which is close enough to click a word or a short phrase.
    static func locate(_ query: String, in lines: [TextLayoutLine]) -> CGRect? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        for line in lines {
            guard let range = line.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let total = CGFloat(max(1, line.text.count))
            let start = CGFloat(line.text.distance(from: line.text.startIndex, to: range.lowerBound))
            let length = CGFloat(line.text.distance(from: range.lowerBound, to: range.upperBound))
            return CGRect(x: line.box.minX + line.box.width * start / total, y: line.box.minY,
                          width: max(1, line.box.width * length / total), height: line.box.height)
        }
        return nil
    }

    /// Image pixels to global points (top-left origin) for a capture.
    static func globalPoint(_ pixel: CGPoint, imageSize: CGSize, globalRect: CGRect) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return globalRect.origin }
        return CGPoint(x: globalRect.minX + pixel.x * globalRect.width / imageSize.width,
                       y: globalRect.minY + pixel.y * globalRect.height / imageSize.height)
    }
}

// MARK: - MIDI and OSC

enum MIDIMessage {
    enum Kind: String, CaseIterable, Identifiable {
        case noteOn, noteOff, controlChange, programChange
        var id: String { rawValue }
        var title: String {
            switch self {
            case .noteOn: return "Note On"
            case .noteOff: return "Note Off"
            case .controlChange: return "Control Change"
            case .programChange: return "Program Change"
            }
        }
    }

    /// MIDI 1.0 bytes. Channel is 1…16; numbers are clamped to 0…127.
    static func bytes(_ kind: Kind, channel: Int, number: Int, value: Int) -> [UInt8] {
        let channel = UInt8(min(16, max(1, channel)) - 1)
        let number = UInt8(min(127, max(0, number)))
        let value = UInt8(min(127, max(0, value)))
        switch kind {
        case .noteOn: return [0x90 | channel, number, value]
        case .noteOff: return [0x80 | channel, number, value]
        case .controlChange: return [0xB0 | channel, number, value]
        case .programChange: return [0xC0 | channel, number]
        }
    }

    /// A MIDI 1.0 channel-voice message as one Universal MIDI Packet word
    /// (message type 2, group 0), the form CoreMIDI's event lists carry.
    static func universalPacket(_ bytes: [UInt8]) -> UInt32 {
        let status = UInt32(bytes.first ?? 0)
        let data1 = UInt32(bytes.count > 1 ? bytes[1] : 0)
        let data2 = UInt32(bytes.count > 2 ? bytes[2] : 0)
        return 0x2000_0000 | (status << 16) | (data1 << 8) | data2
    }
}

/// AOM's virtual MIDI source, created on first use. Other apps see it as
/// "All of MacOS" in their MIDI input lists.
final class MIDIOutput {
    static let shared = MIDIOutput()
    private let lock = NSLock()
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    func send(_ bytes: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if client == 0, MIDIClientCreateWithBlock("All of MacOS" as CFString, &client, nil) != noErr { client = 0; return false }
        if source == 0, MIDISourceCreateWithProtocol(client, "All of MacOS" as CFString, ._1_0, &source) != noErr { source = 0; return false }
        var list = MIDIEventList()
        var word = MIDIMessage.universalPacket(bytes)
        let packet = MIDIEventListInit(&list, ._1_0)
        // One word always fits an empty list, so the returned packet is not needed.
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        return MIDIReceivedEventList(source, &list) == noErr
    }
}

enum OSCMessage {
    enum Argument: Equatable {
        case int(Int32), float(Float), string(String), bool(Bool)
        var tag: Character {
            switch self {
            case .int: return "i"
            case .float: return "f"
            case .string: return "s"
            case .bool(let value): return value ? "T" : "F"
            }
        }
    }

    static func isValidAddress(_ address: String) -> Bool {
        address.hasPrefix("/") && address.utf8.count <= 512
            && address.allSatisfy { $0.isASCII && !$0.isWhitespace && $0 != "#" && $0 != "," }
    }

    /// Whitespace-separated arguments. "Quoted text" is always a string;
    /// true/false become T/F; integers and decimals become i and f.
    static func arguments(from text: String) -> [Argument] {
        tokens(text).map { token, quoted in
            if quoted { return .string(token) }
            switch token.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: break
            }
            if let integer = Int32(token) { return .int(integer) }
            if token.contains(where: { ".eE".contains($0) }), let number = Float(token), number.isFinite { return .float(number) }
            return .string(token)
        }
    }

    static func tokens(_ text: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var quoted = false
        var wasQuoted = false
        var escaping = false
        for character in text {
            if escaping { current.append(character); escaping = false; continue }
            if quoted {
                if character == "\\" { escaping = true }
                else if character == "\"" { quoted = false }
                else { current.append(character) }
                continue
            }
            if character == "\"" { quoted = true; wasQuoted = true; continue }
            if character.isWhitespace {
                if !current.isEmpty || wasQuoted { result.append((current, wasQuoted)) }
                current = ""; wasQuoted = false
                continue
            }
            current.append(character)
        }
        if !current.isEmpty || wasQuoted { result.append((current, wasQuoted)) }
        return result
    }

    /// OSC 1.0 packet: padded address, type tags, then big-endian arguments.
    static func encode(address: String, arguments: [Argument]) -> Data? {
        guard isValidAddress(address) else { return nil }
        var data = Data()
        func append(_ string: String) {
            var bytes = Array(string.utf8.filter { $0 != 0 })
            bytes.append(0)
            while bytes.count % 4 != 0 { bytes.append(0) }
            data.append(contentsOf: bytes)
        }
        append(address)
        append("," + String(arguments.map(\.tag)))
        for argument in arguments {
            switch argument {
            case .int(let value): withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
            case .float(let value): withUnsafeBytes(of: value.bitPattern.bigEndian) { data.append(contentsOf: $0) }
            case .string(let value): append(value)
            case .bool: break
            }
        }
        return data
    }

    static func send(_ data: Data, host: String, port: Int, completion: @escaping (Bool) -> Void) {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0, !host.isEmpty else {
            completion(false); return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        let queue = DispatchQueue(label: "com.kyw.allofmacos.osc")
        var finished = false
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            DispatchQueue.main.async { completion(ok) }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: connection.send(content: data, completion: .contentProcessed { error in finish(error == nil) })
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { finish(false) }
    }
}

enum ColorHex {
    static func string(_ color: NSColor) -> String {
        // Pattern and catalog colors without an sRGB form would raise on component access.
        guard let srgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
    }
}

// MARK: - Dispatcher

enum ParityActions {
    static let handled: Set<ActionType> = [
        .saveSelectedText, .transformSelectedText, .searchSelectedText, .speakSelectedText,
        .pasteClipboardItem, .transformClipboardText, .saveClipboard, .restoreClipboard, .clearClipboard,
        .chooseMenuItem, .showContextMenu, .activatePreviousApp, .quitAppUnderCursor, .hideAppUnderCursor,
        .activateWindowByTitle, .minimizeAppWindows, .gatherWindowsToPointerDisplay, .tileFrontWindowsSideBySide,
        .switchInputSource, .setSoundInput, .toggleDisplayMirroring, .ejectAllDisks, .toggleDockAutoHide,
        .bluetoothDevice, .setWiFiPower, .showEmojiPicker,
        .recognizeScreenText, .sendMIDI, .sendOSC, .pickScreenColor, .hapticFeedback, .postDistributedNotification,
        .restartRecording]

    static func handles(_ type: ActionType) -> Bool { handled.contains(type) }

    @MainActor private static var savedClipboard: PasteboardSnapshot?
    @MainActor private static let synthesizer = AVSpeechSynthesizer()
    @MainActor private static var sampler: NSColorSampler?

    static func perform(_ action: TriggerAction, isCancelled: @escaping () -> Bool = { false }, completion: @escaping (Bool) -> Void) {
        let work = { MainActor.assumeIsolated { dispatch(action, isCancelled: isCancelled, completion: completion) } }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private static func log(_ message: String, error: Bool = true) {
        GestureLog.shared.logFromAnyThread(message, level: error ? .error : .action)
    }

    private static func needsAccessibility(_ completion: (Bool) -> Void) -> Bool {
        guard AXIsProcessTrusted() else {
            log("This step needs Accessibility permission for AOM.")
            completion(false); return true
        }
        return false
    }

    @MainActor
    private static func dispatch(_ action: TriggerAction, isCancelled: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard !isCancelled() else { completion(false); return }
        let p = action.parameters
        switch action.actionType {
        // Selected text
        case .saveSelectedText:
            let name = nonEmpty(p.variableName) ?? "selection"
            SelectedTextReader.read { text in
                guard let text, !text.isEmpty else { log("No selected text"); completion(false); return }
                if text.count > 512 { log("Selected text was shortened to 512 characters for the variable", error: false) }
                completion(WorkflowVariables.set(name, value: TextActionSupport.variableValue(text)))
            }
        case .transformSelectedText:
            guard let transform = TextTransform(rawValue: p.textTransform ?? "") else { log("Choose a text transform"); completion(false); return }
            SelectedTextReader.read { text in
                guard let text, !text.isEmpty, !isCancelled() else { log("No selected text"); completion(false); return }
                let result = transform.apply(text)
                guard result != text else { completion(true); return }
                ExtendedActions.pasteString(result, completion)
            }
        case .searchSelectedText:
            let template = nonEmpty(p.url) ?? TextActionSupport.defaultSearchURL
            SelectedTextReader.read { text in
                guard let text, let url = TextActionSupport.searchURL(template: template, query: text) else {
                    log("No selected text to search for"); completion(false); return
                }
                completion(NSWorkspace.shared.open(url))
            }
        case .speakSelectedText:
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate); completion(true); return }
            SelectedTextReader.read { text in
                guard let text, !text.isEmpty else { log("No selected text to speak"); completion(false); return }
                synthesizer.speak(AVSpeechUtterance(string: String(text.prefix(20_000))))
                completion(true)
            }

        // Clipboard
        case .pasteClipboardItem: pasteHistoryItem(p, completion)
        case .transformClipboardText:
            let pasteboard = NSPasteboard.general
            guard let transform = TextTransform(rawValue: p.textTransform ?? ""),
                  let text = pasteboard.string(forType: .string) else { log("The clipboard holds no text"); completion(false); return }
            pasteboard.clearContents()
            completion(pasteboard.setString(transform.apply(text), forType: .string))
        case .saveClipboard:
            savedClipboard = PasteboardSnapshot.capture(.general)
            completion(true)
        case .restoreClipboard:
            guard let saved = savedClipboard else { log("Nothing was saved with Save Clipboard Contents"); completion(false); return }
            completion(saved.restore(to: .general))
        case .clearClipboard:
            NSPasteboard.general.clearContents()
            completion(true)

        // Menus and apps
        case .chooseMenuItem:
            if needsAccessibility(completion) { return }
            guard let path = nonEmpty(p.menuPath) else { log("Enter a menu path such as File > Save"); completion(false); return }
            guard let app = application(bundleID: p.targetApplicationBundleID) else { log("The app is not running"); completion(false); return }
            if let problem = MenuPath.choose(path, pid: app.processIdentifier) { log(problem); completion(false) }
            else { completion(true) }
        case .showContextMenu:
            if needsAccessibility(completion) { return }
            completion(showContextMenu())
        case .activatePreviousApp:
            guard let app = AppActivationHistory.shared.previousApp() else { log("No previous app"); completion(false); return }
            if app.isHidden { app.unhide() }
            completion(app.activate())
        case .quitAppUnderCursor, .hideAppUnderCursor:
            let point = CGEvent(source: nil)?.location ?? .zero
            guard let pid = OnScreenWindow.owner(at: point, in: OnScreenWindow.current(), excluding: getpid()),
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  app.bundleIdentifier != "com.apple.finder" || action.actionType == .hideAppUnderCursor else {
                log("No app window under the pointer"); completion(false); return
            }
            completion(action.actionType == .quitAppUnderCursor ? app.terminate() : app.hide())

        // Windows
        case .activateWindowByTitle:
            if needsAccessibility(completion) { return }
            guard let query = nonEmpty(p.windowTitleQuery) else { log("Enter part of the window title"); completion(false); return }
            completion(activateWindow(titleMatching: query, bundleID: nonEmpty(p.targetApplicationBundleID)))
        case .minimizeAppWindows:
            if needsAccessibility(completion) { return }
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { completion(false); return }
            let windows = AX.windows(pid: app.processIdentifier).filter { AX.isStandardWindow($0) && AX.bool($0, kAXMinimizedAttribute) != true }
            let failed = windows.filter {
                AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanTrue) != .success
            }.count
            if failed > 0 { log("\(failed) of \(windows.count) windows could not be minimized") }
            completion(ActionOutcome.batch(attempted: windows.count, failed: failed))
        case .gatherWindowsToPointerDisplay:
            if needsAccessibility(completion) { return }
            gatherWindows(completion)
        case .tileFrontWindowsSideBySide:
            if needsAccessibility(completion) { return }
            tileFrontWindows(completion)

        // System
        case .switchInputSource:
            guard let source = InputSources.select(p.inputSourceID) else { log("Input source not found or not enabled"); completion(false); return }
            GestureHUD.shared.show(title: source.name, icon: "globe")
            completion(true)
        case .setSoundInput:
            let uid = p.audioInputUID ?? ""
            guard AudioOutputService.inputDevices().contains(where: { $0.uid == uid }) else { log("Choose a connected input device"); completion(false); return }
            guard AudioOutputService.selectInput(uid: uid) else { log("macOS did not switch the input device"); completion(false); return }
            completion(true)
        case .toggleDisplayMirroring:
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = DisplayMirroring.toggle()
                DispatchQueue.main.async {
                    if !ok { log("Mirroring needs two or more displays") }
                    completion(ok)
                }
            }
        case .ejectAllDisks: ejectAll(completion)
        case .toggleDockAutoHide:
            let value: String
            switch p.switchMode ?? "toggle" {
            case "on": value = "true"
            case "off": value = "false"
            default: value = "not autohide"
            }
            let script = "tell application \"System Events\" to tell dock preferences to set autohide to \(value)"
            ScriptRunnerClient.shared.run(kind: "applescript", source: script, timeout: 10) { code, output, _ in
                if code != 0 { log("Dock: allow AOM to control System Events in Privacy & Security › Automation. \(output.prefix(160))") }
                completion(code == 0)
            }
        case .bluetoothDevice: bluetooth(p, completion)
        case .setWiFiPower:
            guard let interface = CWWiFiClient.shared().interface() else { log("No Wi-Fi interface"); completion(false); return }
            let on: Bool
            switch p.switchMode ?? "toggle" {
            case "on": on = true
            case "off": on = false
            default: on = !interface.powerOn()
            }
            do {
                try interface.setPower(on)
                GestureHUD.shared.show(title: on ? "Wi-Fi On" : "Wi-Fi Off", icon: on ? "wifi" : "wifi.slash")
                completion(true)
            } catch { log("Wi-Fi: \(error.localizedDescription)"); completion(false) }
        case .showEmojiPicker:
            if MenuBarExtras.pressEditMenuItem(prefix: "Emoji") || MenuBarExtras.pressEditMenuItem(prefix: "이모티콘") { completion(true); return }
            completion(SyntheticInput.key(49, flags: [.maskControl, .maskCommand]))

        // Utility
        case .recognizeScreenText: recognizeScreenText(p, isCancelled: isCancelled, completion)
        case .sendMIDI:
            let kind = MIDIMessage.Kind(rawValue: p.midiMessage ?? "") ?? .noteOn
            let bytes = MIDIMessage.bytes(kind, channel: p.midiChannel ?? 1, number: p.midiNumber ?? 60, value: p.midiValue ?? 100)
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = MIDIOutput.shared.send(bytes)
                DispatchQueue.main.async {
                    if !ok { log("MIDI message could not be sent") }
                    completion(ok)
                }
            }
        case .sendOSC:
            guard let data = OSCMessage.encode(address: nonEmpty(p.oscAddress) ?? "/aom", arguments: OSCMessage.arguments(from: p.text ?? "")) else {
                log("OSC address must start with /"); completion(false); return
            }
            OSCMessage.send(data, host: nonEmpty(p.oscHost) ?? "127.0.0.1", port: p.oscPort ?? 8000) { ok in
                if !ok { log("OSC message could not be sent") }
                completion(ok)
            }
        case .pickScreenColor:
            let picker = NSColorSampler()
            sampler = picker
            picker.show { color in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        sampler = nil
                        guard let color else { completion(false); return }
                        let hex = ColorHex.string(color)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hex, forType: .string)
                        if let name = nonEmpty(p.variableName) { WorkflowVariables.set(name, value: hex) }
                        GestureHUD.shared.show(title: "Color Copied", detail: hex, icon: "eyedropper")
                        completion(true)
                    }
                }
            }
        case .hapticFeedback:
            let pattern: NSHapticFeedbackManager.FeedbackPattern
            switch p.hapticPattern {
            case "alignment": pattern = .alignment
            case "levelChange": pattern = .levelChange
            default: pattern = .generic
            }
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            completion(true)
        case .postDistributedNotification:
            guard let name = nonEmpty(p.notificationName) else { log("Enter a notification name"); completion(false); return }
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(name), object: nonEmpty(p.text),
                                                                          userInfo: nil, deliverImmediately: true)
            completion(true)
        case .restartRecording:
            guard ScreenRecordingService.shared.isRecording else { log("No screen recording in progress"); completion(false); return }
            ScreenRecordingService.shared.restartRecording()
            completion(true)
        default:
            completion(false)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    @MainActor
    private static func application(bundleID: String?) -> NSRunningApplication? {
        if let bundleID = nonEmpty(bundleID) {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        return NSWorkspace.shared.frontmostApplication
    }

    // MARK: Clipboard

    @MainActor
    private static func pasteHistoryItem(_ p: ActionParameters, _ completion: @escaping (Bool) -> Void) {
        let store = ClipboardStore.shared
        var pool = store.entries
        if let name = nonEmpty(p.pinboardName) {
            guard let board = store.boards.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                log("No pinboard named “\(name)”"); completion(false); return
            }
            pool = store.filtered(board: board.id)
        }
        let index = (p.clipboardItemIndex ?? 1) - 1
        guard pool.indices.contains(index) else { log("The clipboard history has no item \(index + 1)"); completion(false); return }
        do {
            try store.write(entryIDs: [pool[index].id], plainText: p.pastePlainText ?? store.settings.plainText, playSound: false)
        } catch {
            log("Clipboard item could not be written: \(error.localizedDescription)"); completion(false); return
        }
        let front = NSWorkspace.shared.frontmostApplication
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let front, front.processIdentifier != getpid(), ClipboardStackPasteMonitor.sendPaste(to: front) { completion(true); return }
            completion(SyntheticInput.key(9, flags: .maskCommand))
        }
    }

    // MARK: Menus and windows

    @MainActor
    private static func showContextMenu() -> Bool {
        let point = CGEvent(source: nil)?.location ?? .zero
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
           var current = hit {
            for _ in 0..<6 {
                if AX.actions(current).contains(kAXShowMenuAction as String) {
                    return AXUIElementPerformAction(current, kAXShowMenuAction as CFString) == .success
                }
                guard let parent = AX.element(current, kAXParentAttribute) else { break }
                current = parent
            }
        }
        // Elements without AXShowMenu still answer a secondary click.
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
              let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) else { return false }
        // Always post the release too, whatever the press reported.
        let pressed = SyntheticInput.post(down), released = SyntheticInput.post(up)
        return pressed && released
    }

    @MainActor
    private static func activateWindow(titleMatching query: String, bundleID: String?) -> Bool {
        var apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && (bundleID == nil || $0.bundleIdentifier == bundleID)
        }
        // Recently used apps first, so the most likely window wins a tie.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        apps.sort { ($0.processIdentifier == front ? 0 : 1) < ($1.processIdentifier == front ? 0 : 1) }
        for app in apps {
            for window in AX.windows(pid: app.processIdentifier)
            where WindowGeometry.titleMatches(AX.string(window, kAXTitleAttribute) ?? "", query: query) {
                if AX.bool(window, kAXMinimizedAttribute) == true {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                if app.isHidden { app.unhide() }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                return app.activate()
            }
        }
        log("No window title matches “\(query)”")
        return false
    }

    @MainActor
    private static func gatherWindows(_ completion: @escaping (Bool) -> Void) {
        let manager = WindowManager.shared
        let displays = manager.screens()
        let point = CGEvent(source: nil)?.location ?? .zero
        guard let target = displays.firstIndex(where: { $0.frame.contains(point) }) else { completion(false); return }
        var placements: [(WindowManager.Target, CGRect)] = []
        for window in manager.standardWindowTargets() {
            guard let frame = manager.frame(of: window),
                  let source = WindowGeometry.screenIndex(for: frame, screens: displays.map(\.frame)), source != target else { continue }
            placements.append((window, WindowGeometry.carried(frame, from: displays[source].visible, to: displays[target].visible)))
        }
        guard !placements.isEmpty else { log("Every window is already on this display", error: false); completion(true); return }
        manager.applyPlacements(placements) { moved, failed in
            log("Gathered \(moved) windows\(failed > 0 ? ", \(failed) could not move" : "")", error: failed > 0)
            // Some windows left behind is a failure, not a success (3.3.1, alongside audit F09).
            completion(ActionOutcome.batch(attempted: moved + failed, failed: failed))
        }
    }

    @MainActor
    private static func tileFrontWindows(_ completion: @escaping (Bool) -> Void) {
        let manager = WindowManager.shared
        let candidates = manager.standardWindowTargets().compactMap { target in manager.frame(of: target).map { (target, $0) } }
        var picked: [(WindowManager.Target, CGRect)] = []
        for window in OnScreenWindow.current() where window.layer == 0 && window.pid != getpid() {
            guard let match = candidates.first(where: { candidate in
                candidate.0.pid == window.pid && WindowGeometry.close(candidate.1, window.bounds)
                    && !picked.contains(where: { $0.0 === candidate.0 })
            }) else { continue }
            picked.append(match)
            if picked.count == 2 { break }
        }
        let displays = manager.screens()
        guard picked.count == 2,
              let index = WindowGeometry.screenIndex(for: picked[0].1, screens: displays.map(\.frame)) else {
            log("Two accessible windows are needed"); completion(false); return
        }
        let halves = WindowGeometry.sideBySide(in: displays[index].visible)
        manager.applyPlacements([(picked[0].0, halves.left), (picked[1].0, halves.right)]) { moved, _ in completion(moved == 2) }
    }

    // MARK: System

    @MainActor
    private static func ejectAll(_ completion: @escaping (Bool) -> Void) {
        let keys: Set<URLResourceKey> = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
                                         .volumeIsRootFileSystemKey, .volumeIsInternalKey]
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
                .filter { url in
                    guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsRootFileSystem != true else { return false }
                    return values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsLocal == false
                }
            var failed: [String] = []
            for volume in volumes {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
                catch { failed.append(volume.lastPathComponent) }
            }
            DispatchQueue.main.async {
                if volumes.isEmpty { GestureHUD.shared.show(title: "No Disks to Eject", icon: "eject") }
                else if failed.isEmpty { GestureHUD.shared.show(title: "Ejected \(volumes.count) Disk\(volumes.count == 1 ? "" : "s")", icon: "eject") }
                else { log("Could not eject: \(failed.joined(separator: ", ")) — a file may be open") }
                completion(failed.isEmpty)
            }
        }
    }

    @MainActor
    private static func bluetooth(_ p: ActionParameters, _ completion: @escaping (Bool) -> Void) {
        guard let wanted = nonEmpty(p.bluetoothDevice) else { log("Choose a paired Bluetooth device"); completion(false); return }
        let mode = p.switchMode ?? "toggle"
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            let address = wanted.replacingOccurrences(of: ":", with: "-").lowercased()
            guard let device = devices.first(where: {
                $0.name?.caseInsensitiveCompare(wanted) == .orderedSame || $0.addressString?.lowercased() == address
            }) else {
                DispatchQueue.main.async { log("No paired Bluetooth device named “\(wanted)”"); completion(false) }
                return
            }
            let connect = mode == "on" || (mode == "toggle" && !device.isConnected())
            let result = connect ? device.openConnection() : device.closeConnection()
            DispatchQueue.main.async {
                let ok = result == kIOReturnSuccess
                if ok { GestureHUD.shared.show(title: "\(device.name ?? wanted) \(connect ? "Connected" : "Disconnected")", icon: "antenna.radiowaves.left.and.right") }
                else { log("Bluetooth \(connect ? "connect" : "disconnect") failed (\(String(format: "0x%08X", result)))") }
                completion(ok)
            }
        }
    }

    static func pairedBluetoothNames() -> [String] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap(\.name).sorted()
    }

    // MARK: OCR

    @MainActor
    private static func recognizeScreenText(_ p: ActionParameters, isCancelled: @escaping () -> Bool, _ completion: @escaping (Bool) -> Void) {
        guard ScreenCaptureService.hasPermission else { log("Finding text needs Screen Recording permission"); completion(false); return }
        let click = p.imageMatchClick ?? false
        if click, needsAccessibility(completion) { return }
        let point = CGEvent(source: nil)?.location ?? .zero
        let bounds = NSScreen.screens.compactMap { screen -> CGRect? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayBounds($0.uint32Value) }
        }
        guard let display = bounds.first(where: { $0.contains(point) }) ?? bounds.first else { completion(false); return }
        let name = nonEmpty(p.variableName) ?? "screenText"
        let query = nonEmpty(p.text)
        Task { @MainActor in
            do {
                let capture = try await ScreenCaptureService.shared.captureArea(display, showsCursor: false, pixelSnap: true)
                let result = try await TextRecognitionService.recognize(capture.image, options: TextRecognitionOptions.fromSettings())
                guard !isCancelled() else { completion(false); return }
                guard let query else {
                    WorkflowVariables.set(name, value: TextActionSupport.variableValue(result.text))
                    completion(!result.text.isEmpty)
                    return
                }
                guard let box = ScreenTextSearch.locate(query, in: result.lines) else {
                    WorkflowVariables.set(name, value: "false")
                    log("“\(query)” is not on screen", error: false)
                    completion(false)
                    return
                }
                let target = ScreenTextSearch.globalPoint(CGPoint(x: box.midX, y: box.midY),
                                                          imageSize: CGSize(width: capture.image.width, height: capture.image.height),
                                                          globalRect: capture.globalRect)
                WorkflowVariables.set(name, value: "true")
                WorkflowVariables.set(name + "_x", value: String(format: "%.1f", target.x))
                WorkflowVariables.set(name + "_y", value: String(format: "%.1f", target.y))
                if click {
                    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left),
                          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left) else {
                        completion(false); return
                    }
                    let pressed = SyntheticInput.post(down), released = SyntheticInput.post(up)
                    completion(pressed && released)
                    return
                }
                completion(true)
            } catch {
                log("Text search: \(error.localizedDescription)")
                completion(false)
            }
        }
    }
}
