import Foundation

/// Monotonic, completion-independent cadence for expensive background reads.
/// Explicit actions invalidate the cache; the owner prevents overlapping work.
struct RefreshThrottle {
    let interval: TimeInterval
    private var lastStart: TimeInterval?

    mutating func shouldStart(at now: TimeInterval, force: Bool = false) -> Bool {
        if !force, let lastStart, now >= lastStart, now - lastStart < interval { return false }
        lastStart = now
        return true
    }

    mutating func invalidate() { lastStart = nil }
}
