import Foundation

/// Where a tweak reads and writes. The live store goes through cfprefsd
/// (CFPreferences, the same path as `defaults write`); tests use an
/// in-memory store so no real Apple domain is ever written.
protocol SystemPreferenceStore {
    func value(_ key: String, domain: String) -> Any?
    /// `nil` removes the key (back to Apple's default).
    func set(_ value: Any?, key: String, domain: String) throws
}

struct CFPreferenceStore: SystemPreferenceStore {
    /// `NSGlobalDomain` is CFPreferences' "any application".
    static let globalDomain = "NSGlobalDomain"

    private func cfDomain(_ domain: String) -> CFString {
        domain == Self.globalDomain ? kCFPreferencesAnyApplication : domain as CFString
    }

    func value(_ key: String, domain: String) -> Any? {
        CFPreferencesAppSynchronize(cfDomain(domain))
        return CFPreferencesCopyAppValue(key as CFString, cfDomain(domain))
    }

    func set(_ value: Any?, key: String, domain: String) throws {
        let plist: CFPropertyList? = value.map { $0 as AnyObject }
        CFPreferencesSetAppValue(key as CFString, plist, cfDomain(domain))
        guard CFPreferencesAppSynchronize(cfDomain(domain)) else { throw SystemToolError.settingNotSaved(key) }
    }
}

final class MemoryPreferenceStore: SystemPreferenceStore {
    private(set) var values: [String: Any] = [:]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func value(_ key: String, domain: String) -> Any? { values["\(domain)/\(key)"] }
    func set(_ value: Any?, key: String, domain: String) throws { values["\(domain)/\(key)"] = value }
}

/// A hidden preference (TinkerTool / OnyX style) with its current value
/// readable, so the tile shows the state before and after a click.
struct SystemTweak: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A boolean; `inverted` when the tile's "On" means the key is false
        /// (Screenshot Shadows is on while `disable-shadow` is false).
        case flag(defaultValue: Bool, inverted: Bool)
        /// On writes `onValue`; off removes the key (Apple's default).
        case number(onValue: Double)
        /// One of a fixed set of strings.
        case choice(options: [String], defaultValue: String)
        /// A folder path; `~` paths are expanded when shown.
        case path(defaultValue: String)
    }

    /// What has to restart for the change to show.
    enum Apply: Equatable { case restartFinder, restartDock, nextScreenshot }

    let id: String
    let domain: String
    let key: String
    let kind: Kind
    let apply: Apply

    static let finder = "com.apple.finder"
    static let dock = "com.apple.dock"
    static let screenshots = "com.apple.screencapture"

    static let showAllExtensions = SystemTweak(id: "extensions", domain: CFPreferenceStore.globalDomain, key: "AppleShowAllExtensions",
                                               kind: .flag(defaultValue: false, inverted: false), apply: .restartFinder)
    static let pathBar = SystemTweak(id: "pathbar", domain: finder, key: "ShowPathbar",
                                     kind: .flag(defaultValue: false, inverted: false), apply: .restartFinder)
    static let statusBar = SystemTweak(id: "statusbar", domain: finder, key: "ShowStatusBar",
                                       kind: .flag(defaultValue: false, inverted: false), apply: .restartFinder)
    static let fullPathInTitle = SystemTweak(id: "posixtitle", domain: finder, key: "_FXShowPosixPathInTitle",
                                             kind: .flag(defaultValue: false, inverted: false), apply: .restartFinder)
    static let dockActiveAppsOnly = SystemTweak(id: "dockactive", domain: dock, key: "static-only",
                                                kind: .flag(defaultValue: false, inverted: false), apply: .restartDock)
    static let dockInstantAutoHide = SystemTweak(id: "dockdelay", domain: dock, key: "autohide-delay",
                                                 kind: .number(onValue: 0), apply: .restartDock)
    static let dockRecentApps = SystemTweak(id: "dockrecents", domain: dock, key: "show-recents",
                                            kind: .flag(defaultValue: true, inverted: false), apply: .restartDock)
    static let screenshotShadows = SystemTweak(id: "shotshadow", domain: screenshots, key: "disable-shadow",
                                               kind: .flag(defaultValue: false, inverted: true), apply: .nextScreenshot)
    static let screenshotFormat = SystemTweak(id: "shotformat", domain: screenshots, key: "type",
                                              kind: .choice(options: ["png", "jpg", "heic", "pdf", "tiff"], defaultValue: "png"),
                                              apply: .nextScreenshot)
    static let screenshotFolder = SystemTweak(id: "shotfolder", domain: screenshots, key: "location",
                                              kind: .path(defaultValue: "~/Desktop"), apply: .nextScreenshot)

    static let all: [SystemTweak] = [showAllExtensions, pathBar, statusBar, fullPathInTitle, dockActiveAppsOnly,
                                     dockInstantAutoHide, dockRecentApps, screenshotShadows, screenshotFormat, screenshotFolder]

    // MARK: Reading

    /// The tile's on/off state for flag and number tweaks; nil for the others.
    func isOn(in store: SystemPreferenceStore) -> Bool? {
        let raw = store.value(key, domain: domain)
        switch kind {
        case .flag(let fallback, let inverted):
            let value = Self.bool(raw) ?? fallback
            return inverted ? !value : value
        case .number(let onValue):
            guard let number = Self.double(raw) else { return false }
            return number == onValue
        case .choice, .path:
            return nil
        }
    }

    /// The current string for choice and path tweaks (the default when unset
    /// or set to something outside the known options).
    func currentString(in store: SystemPreferenceStore) -> String? {
        let raw = store.value(key, domain: domain) as? String
        switch kind {
        case .choice(let options, let fallback):
            guard let raw = raw?.lowercased() else { return fallback }
            if raw == "jpeg" { return "jpg" }
            return options.contains(raw) ? raw : fallback
        case .path(let fallback):
            let value = (raw?.isEmpty == false ? raw! : fallback)
            return (value as NSString).expandingTildeInPath
        case .flag, .number:
            return nil
        }
    }

    // MARK: Writing

    /// The value that switches a flag or number tweak to `on`. A number
    /// tweak turned off removes its key, which restores Apple's default.
    func storedValue(on: Bool) -> Any? {
        switch kind {
        case .flag(_, let inverted): return inverted ? !on : on
        case .number(let onValue): return on ? onValue : nil
        case .choice, .path: return nil
        }
    }

    /// Flips a flag or number tweak and returns the new state.
    @discardableResult
    func toggle(in store: SystemPreferenceStore) throws -> Bool {
        let next = !(isOn(in: store) ?? false)
        try store.set(storedValue(on: next), key: key, domain: domain)
        return next
    }

    /// Sets a choice tweak; unknown options are refused rather than written.
    func setChoice(_ option: String, in store: SystemPreferenceStore) throws {
        guard case .choice(let options, _) = kind, options.contains(option) else {
            throw SystemToolError.settingNotSaved(key)
        }
        try store.set(option, key: key, domain: domain)
    }

    /// Sets a path tweak to an existing folder.
    func setFolder(_ url: URL, in store: SystemPreferenceStore) throws {
        guard case .path = kind else { throw SystemToolError.settingNotSaved(key) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        try store.set(url.path, key: key, domain: domain)
    }

    /// `defaults` values arrive as Bool, NSNumber or the strings "YES"/"1".
    static func bool(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String:
            switch value.lowercased() {
            case "1", "yes", "true": return true
            case "0", "no", "false": return false
            default: return nil
            }
        default: return nil
        }
    }

    static func double(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    static func == (lhs: SystemTweak, rhs: SystemTweak) -> Bool { lhs.id == rhs.id }
}
