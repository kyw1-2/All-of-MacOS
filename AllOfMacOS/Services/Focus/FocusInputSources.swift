import AppKit
import Carbon

/// A keyboard input source the person has enabled in System Settings ›
/// Keyboard › Input Sources ("ABC", "2-Set Korean").
struct FocusInputSource: Identifiable, Equatable, Hashable {
    /// `kTISPropertyInputSourceID`.
    let id: String
    let name: String
    let languages: [String]

    /// Korean, Chinese, Japanese and Vietnamese input methods: macOS can show
    /// them selected in the menu bar while the app still types with the
    /// previous source until its window loses and regains focus.
    var isCJKV: Bool {
        guard let language = languages.first else { return false }
        return ["ko", "ja", "vi"].contains(language) || language.hasPrefix("zh")
    }

    /// A Latin layout such as ABC or U.S. (for the suggested rules).
    var isLatinLayout: Bool { id.hasPrefix("com.apple.keylayout.") && !isCJKV }
    var isKorean: Bool { languages.first == "ko" }
}

/// The Text Input Sources calls Focus needs, behind a seam for tests.
@MainActor
protocol FocusInputSourceSystem: AnyObject {
    func enabledSources() -> [FocusInputSource]
    func currentSourceID() -> String?
    func select(_ id: String) -> Bool
    var isSecureInputOn: Bool { get }
}

/// Carbon Text Input Sources (`TISCreateInputSourceList`,
/// `TISSelectInputSource`). Reads are cheap; selection happens only on app
/// switches with a rule.
@MainActor
final class FocusTISInputSources: FocusInputSourceSystem {
    let isolated: Bool
    init(isolated: Bool) { self.isolated = isolated }

    private func list() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as [String: Any]
        guard let array = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else { return [] }
        return (array as NSArray) as? [TISInputSource] ?? []
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString, as type: T.Type) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    private static func describe(_ source: TISInputSource) -> FocusInputSource? {
        guard let id = property(source, kTISPropertyInputSourceID, as: String.self) else { return nil }
        let name = property(source, kTISPropertyLocalizedName, as: String.self) ?? id
        let languages = property(source, kTISPropertyInputSourceLanguages, as: [String].self) ?? []
        return FocusInputSource(id: id, name: name, languages: languages)
    }

    func enabledSources() -> [FocusInputSource] {
        var seen = Set<String>()
        return list().compactMap(Self.describe).filter { seen.insert($0.id).inserted }
    }

    func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.property(source, kTISPropertyInputSourceID, as: String.self)
    }

    func select(_ id: String) -> Bool {
        guard !isolated, let source = list().first(where: { Self.property($0, kTISPropertyInputSourceID, as: String.self) == id })
        else { return false }
        return TISSelectInputSource(source) == noErr
    }

    var isSecureInputOn: Bool { IsSecureEventInputEnabled() }
}

/// Which input source an app should get when it comes to the front
/// (Input Source Pro): its rule first, then (in Remember mode) the source it
/// last used. Sources that are no longer enabled are ignored.
enum FocusInputSourcePolicy {
    static func target(for bundleID: String?, rules: [FocusInputSourceRule], remembered: [String: String],
                       remembers: Bool, available: Set<String>) -> String? {
        guard let bundleID else { return nil }
        if let rule = rules.first(where: { $0.bundleID == bundleID }) {
            guard rule.isEnabled else { return nil }
            return available.contains(rule.sourceID) ? rule.sourceID : nil
        }
        guard remembers, let last = remembered[bundleID], available.contains(last) else { return nil }
        return last
    }

    /// Remember mode records the source of apps without a rule only.
    static func remembers(_ bundleID: String?, rules: [FocusInputSourceRule], remembers: Bool) -> Bool {
        guard remembers, let bundleID else { return false }
        return !rules.contains { $0.bundleID == bundleID }
    }

    /// Suggested rules for installed apps: terminals and code editors use
    /// the first Latin layout, KakaoTalk the first Korean source.
    static let latinApps: [(String, String)] = [
        ("com.apple.Terminal", "Terminal"), ("com.googlecode.iterm2", "iTerm"), ("com.mitchellh.ghostty", "Ghostty"),
        ("dev.warp.Warp-Stable", "Warp"), ("com.microsoft.VSCode", "Visual Studio Code"), ("com.apple.dt.Xcode", "Xcode"),
        ("com.todesktop.230313mzl4w4u92", "Cursor")
    ]
    static let koreanApps: [(String, String)] = [("com.kakao.KakaoTalkMac", "KakaoTalk")]

    static func suggestions(sources: [FocusInputSource], isInstalled: (String) -> Bool,
                            existing: [FocusInputSourceRule]) -> [FocusInputSourceRule] {
        let taken = Set(existing.map(\.bundleID))
        var result: [FocusInputSourceRule] = []
        if let latin = sources.first(where: \.isLatinLayout) {
            for (id, name) in latinApps where !taken.contains(id) && isInstalled(id) {
                result.append(FocusInputSourceRule(bundleID: id, appName: name, sourceID: latin.id))
            }
        }
        if let korean = sources.first(where: \.isKorean) {
            for (id, name) in koreanApps where !taken.contains(id) && isInstalled(id) {
                result.append(FocusInputSourceRule(bundleID: id, appName: name, sourceID: korean.id))
            }
        }
        return result
    }
}

/// Switches the input source when an app comes to the front, and in
/// Remember mode records the one each app was left with. Holds one
/// activation observer and one input-source observer while on, nothing
/// while off. Never acts while secure input is on, while AOM is paused, or
/// for an app AOM is paused for.
@MainActor
final class FocusInputSourceController: ObservableObject {
    @Published private(set) var sources: [FocusInputSource] = []
    @Published private(set) var lastSwitch: (app: String, source: String, date: Date)?
    @Published private(set) var isActive = false

    let settings: FocusSettingsStore
    let lists: FocusListsStore
    private let inputSources: FocusInputSourceSystem
    private let system: FocusSystem
    private let clock: () -> Date
    private let schedules: Bool
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var frontmost: String?

    init(inputSources: FocusInputSourceSystem, system: FocusSystem, settings: FocusSettingsStore, lists: FocusListsStore,
         clock: @escaping () -> Date = Date.init, schedules: Bool = true) {
        self.inputSources = inputSources
        self.system = system
        self.settings = settings
        self.lists = lists
        self.clock = clock
        self.schedules = schedules
    }

    var shouldRun: Bool {
        let options = settings.settings
        return options.inputSourcesEnabled && (options.remembersInputSources || !lists.lists.inputSourceRules.isEmpty)
    }

    func reloadSources() {
        let latest = inputSources.enabledSources()
        if latest != sources { sources = latest }
    }

    func name(for sourceID: String) -> String {
        sources.first { $0.id == sourceID }?.name ?? sourceID.components(separatedBy: ".").last ?? sourceID
    }

    func refresh() {
        reloadSources()
        if shouldRun { activate() } else { deactivate() }
    }

    private func activate() {
        guard !isActive else { return }
        isActive = true
        frontmost = system.frontmostBundleID
        guard schedules else { return }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.appActivated(id) }
        })
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectedSourceChanged() }
        })
        // A source enabled or removed in System Settings.
        distributedObservers.append(distributed.addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSources() }
        })
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
    }

    func tearDown() { deactivate() }

    /// An app came to the front: record what the previous app was left
    /// with (Remember mode), then select this app's source.
    func appActivated(_ bundleID: String?) {
        let previous = frontmost
        frontmost = bundleID
        guard isActive, !FocusIdlePolicy.aomBundleIDs.contains(bundleID ?? "") else { return }
        let options = settings.settings
        let current = inputSources.currentSourceID()
        if let previous, let current, !FocusIdlePolicy.aomBundleIDs.contains(previous),
           FocusInputSourcePolicy.remembers(previous, rules: lists.lists.inputSourceRules, remembers: options.remembersInputSources) {
            lists.remember(sourceID: current, for: previous)
        }
        guard let bundleID, !system.isAOMPaused, !system.isPaused(forApp: bundleID), !inputSources.isSecureInputOn else { return }
        let available = Set(sources.isEmpty ? inputSources.enabledSources().map(\.id) : sources.map(\.id))
        guard let target = FocusInputSourcePolicy.target(for: bundleID, rules: lists.lists.inputSourceRules,
                                                         remembered: lists.lists.rememberedInputSources,
                                                         remembers: options.remembersInputSources, available: available),
              target != current else { return }
        if inputSources.select(target) {
            let appName = lists.lists.inputSourceRules.first { $0.bundleID == bundleID }?.appName
                ?? FocusAppCatalog.name(for: bundleID, fallback: bundleID)
            lastSwitch = (appName, name(for: target), clock())
        }
    }

    /// The person switched input source: in Remember mode, note it for the
    /// front app (if it has no rule).
    func selectedSourceChanged() {
        guard isActive, settings.settings.remembersInputSources, let front = frontmost ?? system.frontmostBundleID,
              !FocusIdlePolicy.aomBundleIDs.contains(front),
              FocusInputSourcePolicy.remembers(front, rules: lists.lists.inputSourceRules, remembers: true),
              let current = inputSources.currentSourceID() else { return }
        lists.remember(sourceID: current, for: front)
    }

    func addSuggestedRules() -> Int {
        reloadSources()
        let suggestions = FocusInputSourcePolicy.suggestions(sources: sources,
                                                             isInstalled: { FocusAppCatalog.url(for: $0) != nil },
                                                             existing: lists.lists.inputSourceRules)
        for rule in suggestions {
            lists.setInputSourceRule(bundleID: rule.bundleID, appName: rule.appName, sourceID: rule.sourceID)
        }
        refresh()
        return suggestions.count
    }
}
