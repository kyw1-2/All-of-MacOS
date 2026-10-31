import AppKit
import Carbon
import Combine
import Foundation

// Per-app input sources (Input Source Pro-style, 3.4.0): an app can always
// get one input source (Terminal in ABC, KakaoTalk in 2-Set Korean), and
// every other app gets back the one it was last used with, so a Korean
// sentence typed into Terminal, deleted and retyped stops happening.
// Off by default. Stored in Application Support/AllOfMacOS/InputSources.

/// One fixed source for an app.
struct AppInputSourceRule: Codable, Equatable, Identifiable {
    var id: UUID
    var bundleID: String
    var appName: String
    var sourceID: String
    var sourceName: String

    init(id: UUID = UUID(), bundleID: String, appName: String, sourceID: String, sourceName: String) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.sourceID = sourceID
        self.sourceName = sourceName
    }
}

struct AppInputSourceSettings: Codable, Equatable {
    var isEnabled = false
    /// Apps without a fixed source get back the one they were last used with.
    var remembersLastUsed = true
    var rules: [AppInputSourceRule] = []
    /// The remembered source per app (bundle id → input source id).
    var remembered: [String: String] = [:]
    /// Apps AOM never switches (games, remote desktops).
    var excludedBundleIDs: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey { case isEnabled, remembersLastUsed, rules, remembered, excludedBundleIDs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        remembersLastUsed = try c.decodeIfPresent(Bool.self, forKey: .remembersLastUsed) ?? true
        rules = (try? c.decodeIfPresent([AppInputSourceRule].self, forKey: .rules)) ?? []
        remembered = (try? c.decodeIfPresent([String: String].self, forKey: .remembered)) ?? [:]
        excludedBundleIDs = (try? c.decodeIfPresent([String].self, forKey: .excludedBundleIDs)) ?? []
    }
}

/// The decisions, pure so the tests cover them without touching input sources.
enum AppInputSourcePolicy {
    /// The source an app should get when it comes to the front, or nil to
    /// leave the current one: a fixed rule first, then the remembered one.
    /// Only sources that are still enabled count.
    static func target(for bundleID: String?, settings: AppInputSourceSettings, available: Set<String>) -> String? {
        guard settings.isEnabled, let bundleID, !bundleID.isEmpty, !settings.excludedBundleIDs.contains(bundleID) else { return nil }
        if let rule = settings.rules.first(where: { $0.bundleID == bundleID }) {
            return available.contains(rule.sourceID) ? rule.sourceID : nil
        }
        if settings.remembersLastUsed, let remembered = settings.remembered[bundleID], available.contains(remembered) {
            return remembered
        }
        return nil
    }

    /// The person changed the source in an app: remember it, unless AOM made
    /// the change itself or the app has a fixed source anyway.
    static func remembering(_ sourceID: String, for bundleID: String?, settings: AppInputSourceSettings,
                            changedByAOM: Bool) -> AppInputSourceSettings? {
        guard settings.isEnabled, settings.remembersLastUsed, !changedByAOM, let bundleID, !bundleID.isEmpty,
              !settings.excludedBundleIDs.contains(bundleID), bundleID != Bundle.main.bundleIdentifier,
              !settings.rules.contains(where: { $0.bundleID == bundleID }),
              settings.remembered[bundleID] != sourceID else { return nil }
        var next = settings
        next.remembered[bundleID] = sourceID
        // Keep the memory small: at most 200 apps.
        if next.remembered.count > 200, let drop = next.remembered.keys.sorted().first(where: { $0 != bundleID }) {
            next.remembered.removeValue(forKey: drop)
        }
        return next
    }
}

final class AppInputSourceStore {
    let url: URL

    init(directory: URL = AppInputSourceStore.defaultDirectory) {
        url = directory.appendingPathComponent("settings.json")
    }

    static var defaultDirectory: URL {
        if let preview = PresetManager.previewDirectory { return preview.appendingPathComponent("InputSources", isDirectory: true) }
        if PresetManager.isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("AOMTestInputSources-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllOfMacOS/InputSources", isDirectory: true)
    }

    func load() -> AppInputSourceSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppInputSourceSettings.self, from: data) else { return AppInputSourceSettings() }
        return settings
    }

    func save(_ settings: AppInputSourceSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

/// Switches the input source when an app comes to the front. Watches app
/// activation and source changes only while it is on (no cost otherwise),
/// respects Pause AOM and per-app pauses, and never acts while secure input
/// is on (a password field).
@MainActor
final class AppInputSourceMemory: ObservableObject {
    static let shared = AppInputSourceMemory(store: AppInputSourceStore())

    @Published private(set) var settings: AppInputSourceSettings
    /// The enabled keyboard input sources, for the pickers.
    @Published private(set) var sources: [InputSources.Source] = []
    /// What happened last ("Switched Terminal to ABC"), for the settings row.
    @Published private(set) var lastSwitch: String?

    private let store: AppInputSourceStore
    private var started = false
    private var activationObserver: NSObjectProtocol?
    private var sourceObserver: NSObjectProtocol?
    private var aomSwitchUntil = Date.distantPast
    private var saveWork: DispatchWorkItem?

    init(store: AppInputSourceStore) {
        self.store = store
        settings = store.load()
    }

    /// Starts following app activation. Nothing calls it on its own: the app
    /// may run only one input-source switcher (two would fight over every
    /// activation), so whoever picks this one starts it from
    /// `AOMProductivityModules.start()`.
    func start() {
        guard !started else { return }
        started = true
        updateObservers()
    }

    func refreshSources() {
        sources = InputSources.enabled()
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        settings.isEnabled = on
        changed()
        if on, let app = NSWorkspace.shared.frontmostApplication { activated(app) }
    }

    func setRemembersLastUsed(_ on: Bool) {
        settings.remembersLastUsed = on
        if !on { settings.remembered.removeAll() }
        changed()
    }

    /// A fixed source for an app (replaces its earlier rule).
    func setRule(bundleID: String, appName: String, source: InputSources.Source) {
        settings.rules.removeAll { $0.bundleID == bundleID }
        settings.rules.append(AppInputSourceRule(bundleID: bundleID, appName: appName, sourceID: source.id, sourceName: source.name))
        settings.remembered.removeValue(forKey: bundleID)
        changed()
    }

    func removeRule(_ id: UUID) {
        settings.rules.removeAll { $0.id == id }
        changed()
    }

    func restoreRule(_ rule: AppInputSourceRule) {
        guard !settings.rules.contains(where: { $0.bundleID == rule.bundleID }) else { return }
        settings.rules.append(rule)
        changed()
    }

    func forgetRemembered() {
        settings.remembered.removeAll()
        changed()
    }

    private func changed() {
        updateObservers()
        saveWork?.cancel()
        let snapshot = settings
        let store = self.store
        let work = DispatchWorkItem { try? store.save(snapshot) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Watching

    private func updateObservers() {
        let wanted = started && settings.isEnabled && (settings.remembersLastUsed || !settings.rules.isEmpty)
        if wanted, activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.activated(app) }
            }
            sourceObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sourceChanged() }
            }
            refreshSources()
        } else if !wanted {
            if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
            if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
            activationObserver = nil
            sourceObserver = nil
        }
    }

    private var mayAct: Bool {
        AutomationGate.isOn && !TriggerSuppression.shared.isPaused && !IsSecureEventInputEnabled()
    }

    private func activated(_ app: NSRunningApplication) {
        guard settings.isEnabled, mayAct, !TriggerSuppression.shared.isPaused(forApp: app.bundleIdentifier) else { return }
        let available = Set(InputSources.enabled().map(\.id))
        guard let target = AppInputSourcePolicy.target(for: app.bundleIdentifier, settings: settings, available: available),
              target != InputSources.currentID() else { return }
        let bundleID = app.bundleIdentifier
        let name = app.localizedName ?? bundleID ?? "the app"
        // A moment after activation, so macOS's own per-document switch
        // (Keyboard settings) doesn't undo it; checked once and retried.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated { self?.select(target, for: bundleID, appName: name, attempt: 1) }
        }
    }

    private func select(_ target: String, for bundleID: String?, appName: String, attempt: Int) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID, mayAct else { return }
        guard InputSources.currentID() != target else { return }
        aomSwitchUntil = Date().addingTimeInterval(0.8)
        let chosen = InputSources.select(target)
        if let chosen { lastSwitch = "Switched \(appName) to \(chosen.name)" }
        guard attempt < 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, InputSources.currentID() != target else { return }
                self.select(target, for: bundleID, appName: appName, attempt: attempt + 1)
            }
        }
    }

    private func sourceChanged() {
        guard let current = InputSources.currentID() else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let next = AppInputSourcePolicy.remembering(current, for: front, settings: settings,
                                                          changedByAOM: Date() < aomSwitchUntil) else { return }
        settings = next
        changed()
    }
}
