import Foundation

enum FileWatcherPolling {
    /// Kernel events remain immediate; polling catches what they miss.
    static func interval(fileArmed: Bool, parentArmed: Bool) -> TimeInterval {
        fileArmed && parentArmed ? 30 : 1
    }
}
