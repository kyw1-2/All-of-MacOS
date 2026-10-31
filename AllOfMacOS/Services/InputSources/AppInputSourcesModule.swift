import AppKit
import Carbon

/// Per-app input sources (Input Source Pro parity, 3.4): Terminal types in
/// English, KakaoTalk in Korean, and so on. When an app becomes active, AOM
/// selects the input source its rule names, or (with Remember on) the one
/// that app used last. It reacts only to app activation (no polling, no
/// event tap) and never reads what is typed.
///
/// Preferences (all reset by Settings › Data › Reset Preferences):
/// `AOMInputSourcesEnabled`, `AOMInputSourcesRules`, `AOMInputSourcesRemember`,
/// `AOMInputSourcesFallback`, `AOMInputSourcesMemory`.
struct AppInputSourcesRule: Codable, Equatable, Identifiable, Hashable {
    var bundleID: String
    var appName: String
    var inputSourceID: String
    var id: String { bundleID }
}

enum AppInputSourcesPolicy {
    /// Which input source to select for the app that just became active, or
    /// nil to leave the current one. A rule wins; then, with Remember on,
    /// the source the app used last; then the fallback for other apps.
    /// A target that is already selected, or no longer enabled, gives nil.
    static func target(for bundleID: String?, rules: [AppInputSourcesRule], memory: [String: String],
                       remembers: Bool, fallback: String?, current: String?, enabled: Set<String>) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let wanted: String?
        if let rule = rules.first(where: { $0.bundleID == bundleID }) {
            wanted = rule.inputSourceID
        } else if remembers, let remembered = memory[bundleID] {
            wanted = remembered
        } else {
            wanted = fallback
        }
        guard let wanted, !wanted.isEmpty, wanted != current, enabled.contains(wanted) else { return nil }
        return wanted
    }

    /// The memory after the app that is being left used `source`: only apps
    /// without a rule are remembered, at most `limit` apps (oldest dropped).
    static func remembering(_ source: String?, for bundleID: String?, in memory: [String: String],
                            order: [String], rules: [AppInputSourcesRule], limit: Int = 200) -> (memory: [String: String], order: [String]) {
        guard let source, !source.isEmpty, let bundleID, !bundleID.isEmpty,
              !rules.contains(where: { $0.bundleID == bundleID }) else { return (memory, order) }
        var memory = memory
        var order = order.filter { $0 != bundleID }
        memory[bundleID] = source
        order.append(bundleID)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            memory.removeValue(forKey: oldest)
        }
        return (memory, order)
    }
}

/// Reads and writes the preferences; injectable for tests.
struct AppInputSourcesSettings {
    static let enabledKey = "AOMInputSourcesEnabled"
    static let rulesKey = "AOMInputSourcesRules"
    static let rememberKey = "AOMInputSourcesRemember"
    static let fallbackKey = "AOMInputSourcesFallback"
    static let memoryKey = "AOMInputSourcesMemory"
    static let memoryOrderKey = "AOMInputSourcesMemoryOrder"

    var defaults: UserDefaults = .standard

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
    var remembers: Bool {
        get { defaults.bool(forKey: Self.rememberKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.rememberKey) }
    }
    var fallback: String? {
        get { defaults.string(forKey: Self.fallbackKey).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue ?? "", forKey: Self.fallbackKey) }
    }
    var rules: [AppInputSourcesRule] {
        get {
            guard let data = defaults.data(forKey: Self.rulesKey),
                  let decoded = try? JSONDecoder().decode([AppInputSourcesRule].self, from: data) else { return [] }
            var seen = Set<String>()
            return decoded.filter { seen.insert($0.bundleID).inserted }
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.rulesKey) }
    }
    var memory: [String: String] {
        get { defaults.dictionary(forKey: Self.memoryKey) as? [String: String] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: Self.memoryKey) }
    }
    var memoryOrder: [String] {
        get { defaults.stringArray(forKey: Self.memoryOrderKey) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Self.memoryOrderKey) }
    }
}

/// The running switcher: one NSWorkspace activation observer while it is on,
/// nothing at all while it is off.
@MainActor
final class AppInputSources: ObservableObject {
    static let shared = AppInputSources()

    @Published private(set) var lastSwitch: (app: String, source: String)?
    private var observer: NSObjectProtocol?
    private var activeBundleID: String?
    private let settings = AppInputSourcesSettings()

    var isRunning: Bool { observer != nil }

    /// Starts or stops observing to match the switch.
    func refresh() {
        if settings.isEnabled { begin() } else { end() }
    }

    private func begin() {
        guard observer == nil, !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        activeBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appDidActivate(app) }
        }
    }

    private func end() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        activeBundleID = nil
    }

    private func appDidActivate(_ app: NSRunningApplication?) {
        let bundleID = app?.bundleIdentifier
        let current = InputSources.currentID()
        // The source still selected belongs to the app being left.
        if settings.remembers, let previous = activeBundleID, previous != Bundle.main.bundleIdentifier {
            let next = AppInputSourcesPolicy.remembering(current, for: previous, in: settings.memory,
                                                         order: settings.memoryOrder, rules: settings.rules)
            settings.memory = next.memory
            settings.memoryOrder = next.order
        }
        activeBundleID = bundleID
        guard mayAct(in: bundleID) else { return }
        let enabled = Set(InputSources.enabled().map(\.id))
        guard let target = AppInputSourcesPolicy.target(for: bundleID, rules: settings.rules, memory: settings.memory,
                                                        remembers: settings.remembers, fallback: settings.fallback,
                                                        current: current, enabled: enabled),
              let chosen = InputSources.select(target) else { return }
        lastSwitch = (app?.localizedName ?? bundleID ?? "", chosen.name)
        // macOS can restore a document's own source right after activation
        // (Keyboard › "Automatically switch to a document's input source");
        // check once more a moment later, only if the same app is in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.activeBundleID == bundleID, self.mayAct(in: bundleID),
                      InputSources.currentID() != target else { return }
                _ = InputSources.select(target)
            }
        }
    }

    /// Pause AOM (everywhere or for this app) stops it; AOM's own windows and
    /// secure input (a password field) are left alone.
    private func mayAct(in bundleID: String?) -> Bool {
        AutomationGate.isOn && bundleID != Bundle.main.bundleIdentifier && !IsSecureEventInputEnabled()
            && !TriggerSuppression.shared.isPaused && !TriggerSuppression.shared.isPaused(forApp: bundleID)
    }
}

/// The module's entry point for app launch (the integrator adds
/// `AppInputSourcesModule.start()` to `AOMProductivityModules.start()`).
@MainActor
enum AppInputSourcesModule {
    static func start() { AppInputSources.shared.refresh() }
}
