import Foundation
import AppKit

enum ExecutionPolicy: String, Codable, CaseIterable {
    case ignoreWhileRunning = "Ignore while running"
    case restart = "Restart"
    case parallel = "Parallel (up to 4)"
}
enum KeyboardPhase: String, Codable, CaseIterable { case keyDown = "Key down", keyUp = "Key up" }

/// Physical key sequence stroke. Modifier-only presses use their native
/// keycodes (e.g. left Command = 55), not a fake printable shortcut.
///
/// `isRequired` mirrors BTT's `BTTKEYRequired`: an optional stroke may appear
/// in the sequence but does not have to. Older presets omit the key, and a
/// missing key must mean "required" so they keep matching as before.
struct KeySequenceStroke: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt
    var isRequired: Bool = true
    var displayName: String {
        if [54, 55].contains(keyCode) { return "⌘" }
        if [58, 61].contains(keyCode) { return "⌥" }
        if [59, 62].contains(keyCode) { return "⌃" }
        if [56, 60].contains(keyCode) { return "⇧" }
        if keyCode == 63 { return "fn" }
        return KeyboardShortcut(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers)).displayString
    }

    init(keyCode: UInt16, modifiers: UInt, isRequired: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRequired = isRequired
    }

    enum CodingKeys: String, CodingKey { case keyCode, modifiers, isRequired }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = try container.decode(UInt.self, forKey: .modifiers)
        // Absent means required: every preset written before optional strokes
        // existed must keep its original meaning.
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? true
    }
}

/// Normalized on-canvas stroke coordinates. Existing preset decoding remains valid.
struct DrawingPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// Scheduled and system-event triggers. These have no physical input, so they
/// fire from a monitor that watches time or device state rather than from the
/// trackpad, keyboard, or mouse path.
enum SystemTriggerKind: Codable, Hashable {
    /// Fires once a day at the given local time.
    case daily(hour: Int, minute: Int)
    /// Fires on selected weekdays (1 = Sunday ... 7 = Saturday) at the given time.
    case weekly(days: [Int], hour: Int, minute: Int)
    /// Fires every N minutes while enabled, anchored to when it was registered.
    case everyMinutes(Int)
    /// Fires when the display configuration changes: a display connects or disconnects.
    case displayChanged
    /// Fires when the set of running applications changes in a way that matches.
    case appLaunched(String)     // bundle identifier
    case appQuit(String)
    /// Fires when the Mac switches between AC power and battery.
    case powerSourceChanged(ac: Bool)
    /// Fires when the screensaver starts or the screen locks.
    case screenLocked
    case screenUnlocked

    var displayName: String {
        switch self {
        case .daily(let h, let m): return String(format: "Every day at %02d:%02d", h, m)
        case .weekly(let days, let h, let m):
            let names = SystemTriggerKind.weekdayNames(days)
            return String(format: "%@ at %02d:%02d", names, h, m)
        case .everyMinutes(let n): return n == 1 ? "Every minute" : "Every \(n) minutes"
        case .displayChanged: return "Display configuration changes"
        case .appLaunched(let id): return "App launches: \(SystemTriggerKind.appName(id))"
        case .appQuit(let id): return "App quits: \(SystemTriggerKind.appName(id))"
        case .powerSourceChanged(let ac): return ac ? "Power connected" : "Switched to battery"
        case .screenLocked: return "Screen locks"
        case .screenUnlocked: return "Screen unlocks"
        }
    }

    var symbolName: String {
        switch self {
        case .daily, .weekly: return "clock"
        case .everyMinutes: return "timer"
        case .displayChanged: return "display"
        case .appLaunched: return "app.badge.checkmark"
        case .appQuit: return "app.badge"
        case .powerSourceChanged: return "bolt"
        case .screenLocked: return "lock"
        case .screenUnlocked: return "lock.open"
        }
    }

    static func weekdayNames(_ days: [Int]) -> String {
        let symbols = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let sorted = days.filter { (1...7).contains($0) }.sorted()
        if sorted.isEmpty { return "No days" }
        if sorted == Array(1...7) { return "Every day" }
        if sorted == [2, 3, 4, 5, 6] { return "Weekdays" }
        if sorted == [1, 7] { return "Weekends" }
        return sorted.map { symbols[$0] }.joined(separator: ", ")
    }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

enum TriggerInput: Codable, Hashable {
    case trackpadGesture(TrackpadGesture)
    case keyboardShortcut(KeyboardShortcut)
    case keySequence([KeySequenceStroke])
    case mouseButton(MouseButton)
    case drawingPattern(String)
    case namedTrigger(String)
    case systemEvent(SystemTriggerKind)

    var displayName: String {
        switch self {
        case .trackpadGesture(let gesture): return gesture.rawValue
        case .keyboardShortcut(let shortcut): return shortcut.displayString
        case .keySequence(let strokes): return strokes.map(\.displayName).joined(separator: " → ")
        case .mouseButton(let button): return button.rawValue
        case .drawingPattern(let name): return "Drawing: \(name)"
        case .namedTrigger(let name): return name
        case .systemEvent(let kind): return kind.displayName
        }
    }

    var category: TriggerCategory {
        switch self {
        case .trackpadGesture: return .trackpad
        case .keyboardShortcut, .keySequence: return .keyboard
        case .mouseButton: return .normalMouse
        case .drawingPattern: return .drawings
        case .namedTrigger, .systemEvent: return .otherTriggers
        }
    }
}

struct Trigger: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var input: TriggerInput
    var actions: [TriggerAction]
    var isEnabled: Bool
    var appBundleID: String? // nil means global unless activationGroupID is set
    var activationGroupID: UUID?
    var order: Int
    var isFavorite = false
    var suppressClick: Bool
    var hapticFeedback: Bool = false
    // nil preserves legacy wildcard behavior; zero explicitly requires no modifiers.
    var requiredModifiers: UInt?
    var executionPolicy: ExecutionPolicy = .ignoreWhileRunning
    var keyboardPhase: KeyboardPhase = .keyDown
    var repeatWhileHeld: Bool = false
    var holdDelayMs: Int = 400
    var holdIntervalMs: Int = 150
    var sequenceMaxGapMs: Int = 450
    /// When false the required strokes may arrive in any order, matching BTT's
    /// `BTTKEYOrderRelevant`. Absent means order matters.
    var sequenceOrderRelevant: Bool = true
    var sequenceHoldMs: Int = 0 // A one-key sequence fires after this uninterrupted hold, if > 0.
    var drawingSamples: [[DrawingPoint]] = [] // User-drawn templates for .drawingPattern
    var drawingCertainty: Double = 0.7
    var drawingIgnoreDirection: Bool = false

    var supportsHold: Bool {
        switch input {
        case .keyboardShortcut, .mouseButton: return true
        case .trackpadGesture(let g): return g.rawValue.contains("Click")
        default: return false
        }
    }
    var modifierLabel: String {
        guard let value = requiredModifiers else { return "Any modifiers" }
        if value == 0 { return "No modifiers" }
        let flags = NSEvent.ModifierFlags(rawValue: value)
        return [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.function, "fn")]
            .filter { flags.contains($0.0) }.map { $0.1 }.joined()
    }

    init(name: String, input: TriggerInput, appBundleID: String? = nil) {
        self.id = UUID()
        self.name = name
        self.input = input
        self.actions = []
        self.isEnabled = true
        self.appBundleID = appBundleID
        self.activationGroupID = nil
        self.order = 0
        self.suppressClick = false
    }

    enum CodingKeys: String, CodingKey {
        case id, name, input, actions, isFavorite, isEnabled, appBundleID, activationGroupID, order, suppressClick, hapticFeedback, requiredModifiers, executionPolicy, keyboardPhase, repeatWhileHeld, holdDelayMs, holdIntervalMs, sequenceMaxGapMs, sequenceOrderRelevant, sequenceHoldMs, drawingSamples, drawingCertainty, drawingIgnoreDirection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        input = try container.decode(TriggerInput.self, forKey: .input)
        actions = try container.decode([TriggerAction].self, forKey: .actions)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        appBundleID = try container.decodeIfPresent(String.self, forKey: .appBundleID)
        activationGroupID = try container.decodeIfPresent(UUID.self, forKey: .activationGroupID)
        order = try container.decode(Int.self, forKey: .order)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        suppressClick = try container.decodeIfPresent(Bool.self, forKey: .suppressClick) ?? false
        hapticFeedback = try container.decodeIfPresent(Bool.self, forKey: .hapticFeedback) ?? false
        requiredModifiers = try container.decodeIfPresent(UInt.self, forKey: .requiredModifiers)
        executionPolicy = try container.decodeIfPresent(ExecutionPolicy.self, forKey: .executionPolicy) ?? .ignoreWhileRunning
        keyboardPhase = try container.decodeIfPresent(KeyboardPhase.self, forKey: .keyboardPhase) ?? .keyDown
        repeatWhileHeld = try container.decodeIfPresent(Bool.self, forKey: .repeatWhileHeld) ?? false
        holdDelayMs = try container.decodeIfPresent(Int.self, forKey: .holdDelayMs) ?? 400
        holdIntervalMs = try container.decodeIfPresent(Int.self, forKey: .holdIntervalMs) ?? 150
        sequenceMaxGapMs = try container.decodeIfPresent(Int.self, forKey: .sequenceMaxGapMs) ?? 450
        sequenceOrderRelevant = try container.decodeIfPresent(Bool.self, forKey: .sequenceOrderRelevant) ?? true
        sequenceHoldMs = try container.decodeIfPresent(Int.self, forKey: .sequenceHoldMs) ?? 0
        drawingSamples = try container.decodeIfPresent([[DrawingPoint]].self, forKey: .drawingSamples) ?? []
        drawingCertainty = try container.decodeIfPresent(Double.self, forKey: .drawingCertainty) ?? 0.7
        drawingIgnoreDirection = try container.decodeIfPresent(Bool.self, forKey: .drawingIgnoreDirection) ?? false
    }

    var displayName: String {
        if name.isEmpty {
            return input.displayName
        }
        return name
    }
}


enum TriggerSortMode: String, CaseIterable { case manual = "Manual", alphabetical = "Alphabetical" }

enum TriggerListQuery {
    static func tokens(_ query: String) -> [String] {
        var result: [String] = []; var token = ""; var quoted = false; var escaped = false
        for char in query {
            if escaped { token.append(char); escaped = false }
            else if char == "\\" { escaped = true }
            else if char == "\"" { quoted.toggle() }
            else if char.isWhitespace && !quoted {
                if !token.isEmpty { result.append(token); token = "" }
            } else { token.append(char) }
        }
        if escaped { token.append("\\") }
        if !token.isEmpty { result.append(token) }
        return result
    }
    static func scopeLabel(_ trigger: Trigger, preset: Preset) -> String {
        if let id = trigger.activationGroupID {
            return preset.activationGroups.first { $0.id == id }?.name ?? "Missing group"
        }
        return preset.appTargets.first { $0.bundleID == trigger.appBundleID }?.name ?? trigger.appBundleID ?? "All Apps"
    }
    static func matches(_ trigger: Trigger, query: String, preset: Preset) -> Bool {
        let actions = ActionTree.rows(trigger.actions).flatMap { [$0.action.displayName, $0.action.actionType.rawValue] }.joined(separator: " ")
        let scope = scopeLabel(trigger, preset: preset)
        let group = preset.activationGroups.first { $0.id == trigger.activationGroupID }
        let app = trigger.activationGroupID == nil ? scope + " " + (trigger.appBundleID ?? "All Apps") : ""
        let all = [trigger.displayName, trigger.input.displayName, actions, scope].joined(separator: " ")
        func contains(_ text: String, _ value: String) -> Bool { text.localizedStandardContains(value) }
        return tokens(query).allSatisfy { token in
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return contains(all, token) }
            let value = String(parts[1]); guard !value.isEmpty else { return false }
            switch parts[0].lowercased() {
            case "app": return contains(app, value)
            case "group": return contains(group?.name ?? "", value)
            case "action": return contains(actions, value)
            case "type":
                let alias: String
                switch trigger.input.category {
                case .normalMouse: alias = "mouse normal mouse"
                case .drawings: alias = "drawing drawings mouse gestures"
                case .otherTriggers: alias = "other named automation automations"
                default: alias = trigger.input.category.rawValue
                }
                return contains(alias, value)
            case "enabled":
                switch value.lowercased() {
                case "no", "false", "0": return !trigger.isEnabled
                case "yes", "true", "1": return trigger.isEnabled
                default: return false
                }
            default: return contains(all, token)
            }
        }
    }
    static func sorted(_ triggers: [Trigger], mode: TriggerSortMode) -> [Trigger] {
        triggers.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            if mode == .manual && $0.order != $1.order { return $0.order < $1.order }
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct TriggerConflictKey: Hashable {
    let input: TriggerInput
    let app: String?
    let group: UUID?
    let modifiers: UInt?
    let phase: KeyboardPhase?
    init(_ trigger: Trigger) {
        input = trigger.input; group = trigger.activationGroupID
        app = group == nil ? trigger.appBundleID : nil
        modifiers = trigger.requiredModifiers.map { $0 & TriggerResolver.modifierMask }
        if case .keyboardShortcut = trigger.input { phase = trigger.keyboardPhase } else { phase = nil }
    }
    static func counts(_ triggers: [Trigger]) -> [UUID: Int] {
        let groups = Dictionary(grouping: triggers, by: TriggerConflictKey.init)
        return Dictionary(uniqueKeysWithValues: triggers.map { ($0.id, max(0, (groups[TriggerConflictKey($0)]?.count ?? 1) - 1)) })
    }
}
