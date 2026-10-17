import Foundation

/// A named Background Tool configuration.
struct AnnotationBackgroundPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var background: AnnotationBackground
}

/// Background presets, "Apply Previous Settings" and "Automatically apply
/// preset to new screenshots", persisted as JSON in UserDefaults.
struct AnnotationBackgroundPresetStore: Equatable {
    static let presetsKey = "AOMAnnotationBackgroundPresets"
    static let previousKey = "AOMAnnotationBackgroundPrevious"
    static let autoApplyKey = "AOMAnnotationBackgroundAutoPresetID"
    static let panelOpenKey = "AOMAnnotationBackgroundPanelOpen"
    static let limit = 50
    static let nameLimit = 80

    var presets: [AnnotationBackgroundPreset] = []
    /// The last background the user applied (for "Apply Previous Settings").
    var previous: AnnotationBackground?
    /// The preset applied automatically to newly opened screenshots.
    var autoApplyID: UUID?

    var autoApplyPreset: AnnotationBackgroundPreset? {
        autoApplyID.flatMap { id in presets.first { $0.id == id } }
    }

    static func sanitizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return String(name.prefix(nameLimit))
    }

    /// Adds a preset; returns its id, or nil for an empty name / invalid settings.
    @discardableResult
    mutating func add(name: String, background: AnnotationBackground) -> UUID? {
        guard let name = Self.sanitizedName(name), background.isValid else { return nil }
        let preset = AnnotationBackgroundPreset(name: name, background: background)
        presets.append(preset)
        if presets.count > Self.limit { presets.removeFirst(presets.count - Self.limit) }
        return preset.id
    }

    @discardableResult
    mutating func rename(_ id: UUID, to name: String) -> Bool {
        guard let name = Self.sanitizedName(name), let index = presets.firstIndex(where: { $0.id == id }) else {
            return false
        }
        presets[index].name = name
        return true
    }

    /// Overwrites a preset's settings with the current ones.
    @discardableResult
    mutating func update(_ id: UUID, with background: AnnotationBackground) -> Bool {
        guard background.isValid, let index = presets.firstIndex(where: { $0.id == id }) else { return false }
        presets[index].background = background
        return true
    }

    mutating func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if autoApplyID == id { autoApplyID = nil }
    }

    mutating func notePrevious(_ background: AnnotationBackground) {
        guard background.isExpanded, background.isValid else { return }
        previous = background
    }

    // MARK: - Persistence

    static func load(_ defaults: UserDefaults = .standard) -> AnnotationBackgroundPresetStore {
        var store = AnnotationBackgroundPresetStore()
        if let data = defaults.data(forKey: presetsKey),
           let list = try? JSONDecoder().decode([AnnotationBackgroundPreset].self, from: data) {
            store.presets = list.filter { $0.background.isValid && !$0.name.isEmpty }.suffix(limit).map { $0 }
        }
        if let data = defaults.data(forKey: previousKey),
           let previous = try? JSONDecoder().decode(AnnotationBackground.self, from: data), previous.isValid {
            store.previous = previous
        }
        if let raw = defaults.string(forKey: autoApplyKey), let id = UUID(uuidString: raw),
           store.presets.contains(where: { $0.id == id }) {
            store.autoApplyID = id
        }
        return store
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.presetsKey) }
        if let previous, let data = try? JSONEncoder().encode(previous) {
            defaults.set(data, forKey: Self.previousKey)
        }
        if let autoApplyID { defaults.set(autoApplyID.uuidString, forKey: Self.autoApplyKey) }
        else { defaults.removeObject(forKey: Self.autoApplyKey) }
    }

    /// Records `background` as the "previous settings" without touching presets.
    static func rememberPrevious(_ background: AnnotationBackground, _ defaults: UserDefaults = .standard) {
        guard background.isExpanded, background.isValid,
              let data = try? JSONEncoder().encode(background) else { return }
        defaults.set(data, forKey: previousKey)
    }

    /// The background a freshly captured screenshot should open with, if the
    /// user enabled automatic application. Exposed for the capture pipeline too.
    static func automaticBackground(_ defaults: UserDefaults = .standard) -> AnnotationBackground? {
        load(defaults).autoApplyPreset?.background
    }
}
