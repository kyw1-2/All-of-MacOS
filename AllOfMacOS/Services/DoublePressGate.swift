import Foundation

/// Single-press / double-press discrimination for shortcuts.
///
/// 3.4.32 audit: the UGREEN side buttons were bound with `Cycle Through
/// Actions` plus a 600 ms `delayBeforeMs` on the first child. That gave a
/// half-second lag on every single click and still ran both children on a
/// double click, because cycling only advanced an index. This gate keeps the
/// ordinary press fast and makes the second press a separate, real trigger.
///
/// The gate is pure: it never reads a clock, so the rule is testable.
struct DoublePressGate: Equatable {
    private var lastPress: [String: TimeInterval] = [:]

    /// Records a press and reports whether it completed a pair.
    ///
    /// The first press of a pair returns false (the caller defers its
    /// single-press action); a press that arrives within `window` of the
    /// previous one returns true and clears the pair, so a third press starts
    /// a new pair instead of staying "double" forever.
    mutating func register(_ key: String, now: TimeInterval, window: TimeInterval) -> Bool {
        // A completed pair clears the stamp. Stamping the second press instead
        // (the obvious `defer`) made a third press complete a phantom pair and
        // run the double-press actions twice.
        if let previous = lastPress[key], now - previous <= window {
            lastPress[key] = nil
            return true
        }
        lastPress[key] = now
        return false
    }

    /// Forgets a pending press, e.g. after the deferred action ran.
    mutating func clear(_ key: String) {
        lastPress.removeValue(forKey: key)
    }

    mutating func reset() {
        lastPress.removeAll()
    }
}
