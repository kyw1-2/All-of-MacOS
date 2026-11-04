import Foundation

enum FileWatcherPolling {
    /// Kernel events remain immediate. Polling is a recovery/sanity fallback.
    static func interval(fileArmed: Bool, parentArmed: Bool) -> TimeInterval {
        fileArmed && parentArmed ? 30 : 1
    }
}
