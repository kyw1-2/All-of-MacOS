import AppKit
import UniformTypeIdentifiers

/// An app → input source rule ("Terminal always uses ABC").
struct FocusInputSourceRule: Codable, Equatable, Identifiable {
    var id: UUID
    var bundleID: String
    var appName: String
    /// `kTISPropertyInputSourceID` ("com.apple.keylayout.ABC",
    /// "com.apple.inputmethod.Korean.2SetKorean").
    var sourceID: String
    var isEnabled: Bool

    init(id: UUID = UUID(), bundleID: String, appName: String, sourceID: String, isEnabled: Bool = true) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.sourceID = sourceID
        self.isEnabled = isEnabled
    }
}

/// The lists people make on the Focus page, in one file
/// (Application Support/AllOfMacOS/Focus/lists.json). They are data, not
/// preferences: Reset Preferences keeps them.
struct FocusLists: Codable, Equatable {
    var version = 1
    var distractingApps: [FocusAppRef] = []
    var idleRules: [FocusIdleRule] = []
    var inputSourceRules: [FocusInputSourceRule] = []
    /// The input source last used in each app without a rule (Remember mode).
    var rememberedInputSources: [String: String] = [:]

    init() {}

    enum CodingKeys: String, CodingKey { case version, distractingApps, idleRules, inputSourceRules, rememberedInputSources }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        distractingApps = (try? c.decodeIfPresent([FocusAppRef].self, forKey: .distractingApps)) ?? []
        idleRules = (try? c.decodeIfPresent([FocusIdleRule].self, forKey: .idleRules)) ?? []
        inputSourceRules = (try? c.decodeIfPresent([FocusInputSourceRule].self, forKey: .inputSourceRules)) ?? []
        rememberedInputSources = (try? c.decodeIfPresent([String: String].self, forKey: .rememberedInputSources)) ?? [:]
    }
}

@MainActor
final class FocusListsStore: ObservableObject {
    static let fileName = "lists.json"

    @Published var lists: FocusLists {
        didSet {
            guard lists != oldValue else { return }
            FocusStorage.save(lists, named: Self.fileName, in: directory)
            onChange?(oldValue, lists)
        }
    }
    let directory: URL
    /// Called after every change with the old and new lists.
    var onChange: ((FocusLists, FocusLists) -> Void)?

    init(directory: URL) {
        self.directory = directory
        lists = FocusStorage.load(FocusLists.self, named: Self.fileName, in: directory) ?? FocusLists()
    }

    // MARK: Distracting apps

    func addDistraction(_ app: FocusAppRef) {
        guard !FocusIdlePolicy.isProtected(app.bundleID),
              !lists.distractingApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        lists.distractingApps.append(app)
    }

    func removeDistraction(_ bundleID: String) {
        lists.distractingApps.removeAll { $0.bundleID == bundleID }
    }

    // MARK: Idle rules

    @discardableResult
    func addIdleRule(for app: FocusAppRef) -> FocusIdleRule? {
        guard !FocusIdlePolicy.isProtected(app.bundleID),
              !lists.idleRules.contains(where: { $0.bundleID == app.bundleID }) else { return nil }
        let rule = FocusIdleRule(bundleID: app.bundleID, name: app.name)
        lists.idleRules.append(rule)
        return rule
    }

    func updateIdleRule(_ rule: FocusIdleRule) {
        guard let index = lists.idleRules.firstIndex(where: { $0.id == rule.id }) else { return }
        lists.idleRules[index] = rule
    }

    func removeIdleRule(_ id: UUID) {
        lists.idleRules.removeAll { $0.id == id }
    }

    func insertIdleRule(_ rule: FocusIdleRule, at index: Int) {
        guard !lists.idleRules.contains(where: { $0.id == rule.id }) else { return }
        lists.idleRules.insert(rule, at: min(max(0, index), lists.idleRules.count))
    }

    // MARK: Input sources

    func setInputSourceRule(bundleID: String, appName: String, sourceID: String) {
        if let index = lists.inputSourceRules.firstIndex(where: { $0.bundleID == bundleID }) {
            lists.inputSourceRules[index].sourceID = sourceID
            lists.inputSourceRules[index].isEnabled = true
        } else {
            lists.inputSourceRules.append(FocusInputSourceRule(bundleID: bundleID, appName: appName, sourceID: sourceID))
        }
    }

    func removeInputSourceRule(_ id: UUID) {
        lists.inputSourceRules.removeAll { $0.id == id }
    }

    func remember(sourceID: String, for bundleID: String) {
        guard lists.rememberedInputSources[bundleID] != sourceID else { return }
        lists.rememberedInputSources[bundleID] = sourceID
    }

    func forgetRememberedInputSources() {
        lists.rememberedInputSources.removeAll()
    }
}

/// App names and icons for bundle identifiers, from the running app or
/// Launch Services. Icons are cached; nothing is read off disk twice.
@MainActor
enum FocusAppCatalog {
    private static var icons: [String: NSImage] = [:]

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func icon(for bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let image: NSImage
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let icon = running.icon {
            image = icon
        } else if let url = url(for: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        icons[bundleID] = image
        return image
    }

    static func name(for bundleID: String, fallback: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName { return name }
        if let url = url(for: bundleID) { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        return fallback
    }

    /// Running regular apps (not AOM, not Finder), sorted by name, for the
    /// Add App menus.
    static func runningChoices() -> [FocusAppRef] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> FocusAppRef? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  !FocusIdlePolicy.isProtected(id), seen.insert(id).inserted else { return nil }
            return FocusAppRef(bundleID: id, name: app.localizedName ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An app bundle chosen in an open panel.
    static func ref(forAppAt url: URL) -> FocusAppRef? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return FocusAppRef(bundleID: id, name: name)
    }
}
