import Foundation

/// A shortcut from the Shortcuts app, chosen to run when a focus phase
/// starts or ends. The identifier survives a rename; the name is shown.
struct FocusShortcutRef: Codable, Equatable, Hashable, Identifiable {
    var name: String
    var identifier: String?

    var id: String { identifier ?? name }
    /// What `shortcuts run` gets: the identifier when known.
    var runArgument: String { identifier ?? name }
}

/// Every Focus option, stored as one JSON value under
/// `AOMFocusSettings.v1` (Reset Preferences restores the defaults). Unknown
/// or missing fields decode to their defaults; numbers are clamped.
struct FocusSettings: Codable, Equatable {
    // Sessions
    var plan = FocusPlan()
    var showsMenuBarCountdown = true
    /// A system sound name ("Glass"), or "" for none.
    var endSound = "Glass"
    var hidesDistractions = false
    var showsDistractionHUD = true
    var mutesSound = false
    var keepsAwake = false
    var startShortcut: FocusShortcutRef?
    var endShortcut: FocusShortcutRef?

    // Idle apps and memory
    var idleAppsEnabled = false
    var memoryPressureEnabled = false
    var memoryPressureMinimumIdleMinutes = 5

    // Break reminders
    var eyeBreaksEnabled = false
    var standBreaksEnabled = false
    var standMinutes = 50

    static let endSounds = ["Glass", "Hero", "Ping", "Purr", "Submarine", "Tink"]
    static let minimumIdleRange = 1...120
    static let standRange = 20...120

    init() {}

    enum CodingKeys: String, CodingKey {
        case plan, showsMenuBarCountdown, endSound, hidesDistractions, showsDistractionHUD, mutesSound, keepsAwake
        case startShortcut, endShortcut, idleAppsEnabled, memoryPressureEnabled, memoryPressureMinimumIdleMinutes
        case eyeBreaksEnabled, standBreaksEnabled, standMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FocusSettings()
        plan = (try? c.decodeIfPresent(FocusPlan.self, forKey: .plan)) ?? d.plan
        showsMenuBarCountdown = (try? c.decodeIfPresent(Bool.self, forKey: .showsMenuBarCountdown)) ?? d.showsMenuBarCountdown
        endSound = (try? c.decodeIfPresent(String.self, forKey: .endSound)) ?? d.endSound
        hidesDistractions = (try? c.decodeIfPresent(Bool.self, forKey: .hidesDistractions)) ?? d.hidesDistractions
        showsDistractionHUD = (try? c.decodeIfPresent(Bool.self, forKey: .showsDistractionHUD)) ?? d.showsDistractionHUD
        mutesSound = (try? c.decodeIfPresent(Bool.self, forKey: .mutesSound)) ?? d.mutesSound
        keepsAwake = (try? c.decodeIfPresent(Bool.self, forKey: .keepsAwake)) ?? d.keepsAwake
        startShortcut = try? c.decodeIfPresent(FocusShortcutRef.self, forKey: .startShortcut)
        endShortcut = try? c.decodeIfPresent(FocusShortcutRef.self, forKey: .endShortcut)
        idleAppsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .idleAppsEnabled)) ?? d.idleAppsEnabled
        memoryPressureEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .memoryPressureEnabled)) ?? d.memoryPressureEnabled
        memoryPressureMinimumIdleMinutes = FocusPlan.clamp(
            (try? c.decodeIfPresent(Int.self, forKey: .memoryPressureMinimumIdleMinutes)) ?? d.memoryPressureMinimumIdleMinutes,
            Self.minimumIdleRange)
        eyeBreaksEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .eyeBreaksEnabled)) ?? d.eyeBreaksEnabled
        standBreaksEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .standBreaksEnabled)) ?? d.standBreaksEnabled
        standMinutes = FocusPlan.clamp((try? c.decodeIfPresent(Int.self, forKey: .standMinutes)) ?? d.standMinutes, Self.standRange)
    }
}

/// Reads and writes `FocusSettings` in one UserDefaults key. Tests pass a
/// throwaway suite; the app uses `.standard`.
@MainActor
final class FocusSettingsStore: ObservableObject {
    static let defaultsKey = "AOMFocusSettings.v1"

    @Published var settings: FocusSettings {
        didSet {
            guard settings != oldValue else { return }
            if !reloading { persist() }
            onChange?(oldValue, settings)
        }
    }

    /// Called after every change with the old and new values.
    var onChange: ((FocusSettings, FocusSettings) -> Void)?
    private let defaults: UserDefaults
    private var reloading = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        settings = Self.stored(in: defaults) ?? FocusSettings()
    }

    /// Re-reads the stored value, for example after Settings › Data › Reset
    /// Preferences removed it. Never writes the defaults back.
    func reload() {
        reloading = true
        defer { reloading = false }
        let stored = Self.stored(in: defaults) ?? FocusSettings()
        if stored != settings { settings = stored }
    }

    private static func stored(in defaults: UserDefaults) -> FocusSettings? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(FocusSettings.self, from: data)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
