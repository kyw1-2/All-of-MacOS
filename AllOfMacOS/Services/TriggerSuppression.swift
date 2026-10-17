import Foundation
import AppKit
import Combine

/// Which family of input a trigger belongs to, for suppression rules that only
/// apply to some families (e.g. "disable trackpad gestures after a keystroke").
enum TriggerSuppressionKind: Equatable {
    case trackpad, keyboard, mouse, drawing
    /// Scheduled/system events and Named Triggers: no physical input at all.
    case system

    init(_ input: TriggerInput?) {
        switch input {
        case .trackpadGesture: self = .trackpad
        case .keyboardShortcut, .keySequence: self = .keyboard
        case .mouseButton, .mouse: self = .mouse
        case .drawingPattern: self = .drawing
        case .namedTrigger, .systemEvent, .none: self = .system
        }
    }
}

/// Persisted suppression options (AOM counterpart of BTT's General →
/// "Disable BetterTouchTool while holding …" and Trackpad → "Disable trackpad
/// gestures after hitting a keyboard key").
struct TriggerSuppressionSettings: Codable, Equatable {
    /// Raw `NSEvent.ModifierFlags` limited to ⌘ ⇧ ⌃ ⌥ fn. Triggers are
    /// disabled while ANY of these is held. 0 = feature off.
    var disableWhileHoldingModifiers: UInt = 0
    /// Palm-rejection style: ignore trackpad triggers shortly after a key press.
    var disableTrackpadAfterKeyEnabled: Bool = false
    var disableTrackpadAfterKeyMs: Int = 500

    static let defaultAfterKeyMs = 500
    static let afterKeyRangeMs = 50...5000

    init() {}
    enum CodingKeys: String, CodingKey { case disableWhileHoldingModifiers, disableTrackpadAfterKeyEnabled, disableTrackpadAfterKeyMs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disableWhileHoldingModifiers = try c.decodeIfPresent(UInt.self, forKey: .disableWhileHoldingModifiers) ?? 0
        disableTrackpadAfterKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .disableTrackpadAfterKeyEnabled) ?? false
        disableTrackpadAfterKeyMs = try c.decodeIfPresent(Int.self, forKey: .disableTrackpadAfterKeyMs) ?? Self.defaultAfterKeyMs
    }
}

/// Why a trigger was blocked. Rendered by the UI via `description`.
enum TriggerSuppressionReason: Equatable, CustomStringConvertible {
    case paused(until: Date?)
    case pausedForApp(String)
    case holdingModifiers
    case recentKeystroke

    var description: String {
        switch self {
        case .paused(let until):
            guard let until else { return "Paused until resumed" }
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        case .pausedForApp(let id): return "Paused for \(id)"
        case .holdingModifiers: return "Disabled while holding a modifier key"
        case .recentKeystroke: return "Disabled briefly after a keystroke"
        }
    }
}

/// Central "should this trigger fire right now?" authority.
///
/// Pure rule evaluation lives in `evaluate` and takes every environmental input
/// (clock, frontmost app, held modifiers, time since last key) as a value so it
/// can be unit tested without real input. The class wraps it with runtime-only
/// pause state (a/b) and persisted settings (c/d), and publishes both for UI.
///
/// Threading: like every monitor in AOM it is used from the main thread only.
final class TriggerSuppression: ObservableObject {

    /// Runtime-only pause state. Deliberately never persisted: a relaunch
    /// always starts un-paused so a forgotten pause cannot silently disable AOM.
    struct PauseState: Equatable {
        /// `nil` with `indefinite == false` means not paused.
        var until: Date?
        var indefinite = false
        var appBundleIDs: Set<String> = []
        var isGloballyPaused: Bool { indefinite || until != nil }
    }

    static let settingsKey = "AOMTriggerSuppression.v1"
    static let suiteNamePrefix = "AOMTestTriggerSuppression-"

    /// Under XCTest the shared instance must never touch the user's real prefs.
    static let shared: TriggerSuppression = {
        TriggerSuppression(defaults: defaultsForCurrentProcess())
    }()

    /// `.standard` in the real app; a per-process throwaway suite under XCTest
    /// or UI preview. `tag` keeps independent subsystems in separate suites.
    static func defaultsForCurrentProcess(tag: String = "") -> UserDefaults {
        guard PresetManager.isRunningTests || PresetManager.isUIPreview else { return .standard }
        let name = suiteNamePrefix + tag + String(ProcessInfo.processInfo.processIdentifier)
        let defaults = UserDefaults(suiteName: name) ?? UserDefaults()
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Published state

    @Published private(set) var pause = PauseState()
    @Published var settings: TriggerSuppressionSettings {
        didSet { if settings != oldValue { persist() } }
    }

    // MARK: Injected environment

    private let defaults: UserDefaults
    private let now: () -> Date
    private let frontmostBundleID: () -> String?
    private let heldModifiers: () -> UInt
    private let secondsSinceLastKeyDown: () -> TimeInterval
    private let schedulesExpiry: Bool
    private var expiryTimer: Timer?

    init(defaults: UserDefaults,
         now: @escaping () -> Date = Date.init,
         frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         heldModifiers: @escaping () -> UInt = { NSEvent.modifierFlags.rawValue },
         secondsSinceLastKeyDown: @escaping () -> TimeInterval = {
             // Hardware-level keyDown age. Events AOM posts itself do not
             // count, which is what keeps a "type text" action from silencing
             // the trackpad.
             CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
         },
         schedulesExpiry: Bool = true) {
        self.defaults = defaults
        self.now = now
        self.frontmostBundleID = frontmostBundleID
        self.heldModifiers = heldModifiers
        self.secondsSinceLastKeyDown = secondsSinceLastKeyDown
        self.schedulesExpiry = schedulesExpiry
        if let data = defaults.data(forKey: Self.settingsKey),
           let stored = try? JSONDecoder().decode(TriggerSuppressionSettings.self, from: data) {
            settings = stored
        } else {
            settings = TriggerSuppressionSettings()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    // MARK: Pause API (a)

    static let modifierMask: UInt = NSEvent.ModifierFlags([.command, .shift, .control, .option, .function]).rawValue

    /// "Disable Triggers for X seconds". Non-positive durations are ignored.
    func pause(for seconds: TimeInterval) {
        guard seconds > 0, seconds.isFinite else { return }
        let end = now().addingTimeInterval(seconds)
        // Never shorten an existing indefinite pause; extend rather than shrink a timed one.
        if pause.indefinite { return }
        if let current = pause.until, current > end { return }
        pause.until = end
        scheduleExpiry()
    }

    func pauseUntilResumed() {
        pause.indefinite = true
        pause.until = nil
        expiryTimer?.invalidate(); expiryTimer = nil
    }

    /// Clears global AND per-app pauses.
    func resume() {
        pause = PauseState()
        expiryTimer?.invalidate(); expiryTimer = nil
    }

    // MARK: Pause API (b)

    func pauseApp(_ bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        pause.appBundleIDs.insert(id)
    }
    func resumeApp(_ bundleID: String) { pause.appBundleIDs.remove(bundleID) }
    func toggleApp(_ bundleID: String) {
        if pause.appBundleIDs.contains(bundleID) { resumeApp(bundleID) } else { pauseApp(bundleID) }
    }
    /// "Disable BTT For Active App".
    @discardableResult
    func pauseFrontmostApp() -> String? {
        guard let id = frontmostBundleID() else { return nil }
        pauseApp(id); return id
    }

    /// Drops an expired timed pause so published state is current.
    func refresh() {
        if let until = pause.until, until <= now() { pause.until = nil }
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate(); expiryTimer = nil
        guard schedulesExpiry, let until = pause.until else { return }
        let timer = Timer(timeInterval: max(0.05, until.timeIntervalSince(now())), repeats: false) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    // MARK: Queries

    var isPaused: Bool { refresh(); return pause.isGloballyPaused }

    /// Menu-bar/UI status line, or nil when nothing is paused.
    var statusDescription: String? {
        refresh()
        var parts: [String] = []
        if pause.indefinite { parts.append("Paused until resumed") }
        else if let until = pause.until { parts.append(TriggerSuppressionReason.paused(until: until).description) }
        if !pause.appBundleIDs.isEmpty { parts.append("Paused for \(pause.appBundleIDs.count) app(s)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The reason this family of input is blocked now, or nil if allowed.
    func reason(for kind: TriggerSuppressionKind) -> TriggerSuppressionReason? {
        refresh()
        return Self.evaluate(kind: kind, pause: pause, settings: settings, now: now(),
                             frontmostBundleID: frontmostBundleID(),
                             heldModifiers: heldModifiers(),
                             secondsSinceLastKeyDown: settings.disableTrackpadAfterKeyEnabled && kind == .trackpad
                                ? secondsSinceLastKeyDown() : .infinity)
    }

    /// True when `trigger` (nil = unregistered/ad-hoc) may fire now.
    func allows(_ trigger: Trigger?) -> Bool { reason(for: TriggerSuppressionKind(trigger?.input)) == nil }
    func allows(kind: TriggerSuppressionKind) -> Bool { reason(for: kind) == nil }

    // MARK: Pure rule (unit-tested with injected values)

    static func evaluate(kind: TriggerSuppressionKind,
                         pause: PauseState,
                         settings: TriggerSuppressionSettings,
                         now: Date,
                         frontmostBundleID: String?,
                         heldModifiers: UInt,
                         secondsSinceLastKeyDown: TimeInterval) -> TriggerSuppressionReason? {
        // (a) global pause applies to everything, including system triggers.
        if pause.indefinite { return .paused(until: nil) }
        if let until = pause.until, until > now { return .paused(until: until) }
        // (b) per-app pause, keyed by the frontmost app's bundle id.
        if let front = frontmostBundleID, pause.appBundleIDs.contains(front) { return .pausedForApp(front) }
        // (c) Modifier-held disable covers pointer-style input. Keyboard
        // triggers are exempt: a ⌘-disables-AOM rule would otherwise make
        // every ⌘-shortcut trigger impossible to fire. System/named triggers
        // have no physical input to be "held over".
        let mask = settings.disableWhileHoldingModifiers & modifierMask
        if mask != 0, kind != .keyboard, kind != .system, heldModifiers & mask != 0 { return .holdingModifiers }
        // (d) trackpad-only palm rejection after a key press.
        if kind == .trackpad, settings.disableTrackpadAfterKeyEnabled {
            let window = Double(clamp(settings.disableTrackpadAfterKeyMs)) / 1000
            if secondsSinceLastKeyDown >= 0, secondsSinceLastKeyDown < window { return .recentKeystroke }
        }
        return nil
    }

    static func clamp(_ ms: Int) -> Int {
        min(max(ms, TriggerSuppressionSettings.afterKeyRangeMs.lowerBound), TriggerSuppressionSettings.afterKeyRangeMs.upperBound)
    }
}
