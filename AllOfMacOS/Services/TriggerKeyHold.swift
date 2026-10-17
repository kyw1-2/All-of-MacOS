import Foundation
import AppKit

/// Global keyboard/mouse timing knobs (BTT: Settings → Keyboard / Normal Mouse,
/// "Long Press Duration" and "Max Quick Release Time"). BTT's shipped defaults
/// are not recoverable statically, so these are AOM's own choices.
enum TriggerTimingSettings {
    static let keyboardLongPressKey = "AOMKeyboardLongPressMs"
    static let keyboardQuickReleaseKey = "AOMKeyboardQuickReleaseMaxMs"
    static let mouseLongPressKey = "AOMMouseLongPressMs"
    static let mouseQuickReleaseKey = "AOMMouseQuickReleaseMaxMs"
    static let mouseDragThresholdKey = "AOMMouseDragThresholdPx"
    static let mouseMultiClickKey = "AOMMouseMultiClickIntervalMs"

    /// Where the knobs live: the app's defaults, or a throwaway suite under
    /// XCTest / UI preview so tests never read or write real preferences.
    static let store: UserDefaults = TriggerSuppression.defaultsForCurrentProcess(tag: "Timing")

    /// Chosen defaults (not BTT's, which are unknown): 500 ms long press, 250 ms quick release.
    static let defaultKeyboardLongPressMs = 500
    static let defaultKeyboardQuickReleaseMs = 250
    static let defaultMouseLongPressMs = 500
    static let defaultMouseQuickReleaseMs = 250
    static let defaultMouseDragThresholdPx = 40
    static let longPressRangeMs = 100...5000
    static let quickReleaseRangeMs = 50...2000
    static let dragThresholdRangePx = 5...500
    static let multiClickRangeMs = 150...1500

    /// Reads a clamped integer setting. `defaults` is injectable so tests never
    /// read the user's real preferences.
    static func value(_ key: String, default fallback: Int, range: ClosedRange<Int>,
                      defaults: UserDefaults = TriggerTimingSettings.store) -> Int {
        let stored = defaults.object(forKey: key) as? Int ?? fallback
        return min(max(stored, range.lowerBound), range.upperBound)
    }
    static func keyboardLongPressMs(_ d: UserDefaults = TriggerTimingSettings.store) -> Int {
        value(keyboardLongPressKey, default: defaultKeyboardLongPressMs, range: longPressRangeMs, defaults: d)
    }
    static func keyboardQuickReleaseMs(_ d: UserDefaults = TriggerTimingSettings.store) -> Int {
        value(keyboardQuickReleaseKey, default: defaultKeyboardQuickReleaseMs, range: quickReleaseRangeMs, defaults: d)
    }
    static func mouseLongPressMs(_ d: UserDefaults = TriggerTimingSettings.store) -> Int {
        value(mouseLongPressKey, default: defaultMouseLongPressMs, range: longPressRangeMs, defaults: d)
    }
    static func mouseDragThresholdPx(_ d: UserDefaults = TriggerTimingSettings.store) -> Int {
        value(mouseDragThresholdKey, default: defaultMouseDragThresholdPx, range: dragThresholdRangePx, defaults: d)
    }
    /// Max gap between presses of a multi-click. Defaults to the system double-click interval.
    static func mouseMultiClickMs(_ d: UserDefaults = TriggerTimingSettings.store, system: TimeInterval = NSEvent.doubleClickInterval) -> Int {
        value(mouseMultiClickKey, default: Int(system * 1000), range: multiClickRangeMs, defaults: d)
    }
}

/// Pure hold-time rules for keyboard triggers (min/max hold, long press,
/// quick release). The monitor feeds it durations; it never reads a clock.
enum TriggerKeyHold {

    /// How a pressed key's trigger is scheduled.
    enum Plan: Equatable {
        /// Fire at once on key down.
        case immediately
        /// Fire after the key has been held this long (cancelled if released first).
        case afterHold(ms: Int)
        /// Decide on release, from how long the key was held.
        case onRelease
    }

    static func plan(phase: KeyboardPhase, minHoldMs: Int, longPressMs: Int) -> Plan {
        switch phase {
        case .keyDown: return minHoldMs > 0 ? .afterHold(ms: minHoldMs) : .immediately
        case .longPress: return .afterHold(ms: max(longPressMs, minHoldMs))
        case .keyUp, .quickRelease: return .onRelease
        }
    }

    /// For `.onRelease` plans: whether a key held `heldMs` should fire.
    /// `maxHoldMs == 0` means unlimited. Boundaries are inclusive.
    static func acceptsRelease(phase: KeyboardPhase, heldMs: Int, minHoldMs: Int, maxHoldMs: Int,
                               quickReleaseMaxMs: Int) -> Bool {
        guard heldMs >= minHoldMs, maxHoldMs == 0 || heldMs <= maxHoldMs else { return false }
        switch phase {
        case .keyUp: return true
        case .quickRelease: return heldMs <= quickReleaseMaxMs
        case .keyDown, .longPress: return false
        }
    }

    /// Phases whose trigger may use `repeatWhileHeld` (needs a live key-down).
    static func supportsRepeat(_ phase: KeyboardPhase) -> Bool { phase == .keyDown }
}
