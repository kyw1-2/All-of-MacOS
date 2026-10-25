import Foundation
import CoreGraphics
import AppKit

/// Tracks pre-snapped window geometries to power Swish's "Unsnap" and gesture chaining features.
/// When a window is snapped into a grid zone, its unconstrained pre-snap frame is stored.
/// A reverse gesture or unsnap command smoothly restores this original frame.
final class SwishWindowHistory {
    static let shared = SwishWindowHistory()

    struct Snapshot: Equatable {
        let windowID: CGWindowID?
        let pid: pid_t
        let initialFrame: CGRect // Frame before snap in AX coordinates
        let snappedFrame: CGRect  // Snapped target frame
        let timestamp: Date
    }

    private var storage: [String: Snapshot] = [:]
    private let lock = NSLock()

    init() {}

    private func key(pid: pid_t, windowID: CGWindowID?) -> String {
        if let windowID { return "\(pid):\(windowID)" }
        return "\(pid)"
    }

    /// Records the frame of a window immediately before it is modified by a snap action.
    func recordPreSnap(pid: pid_t, windowID: CGWindowID? = nil, initialFrame: CGRect, targetSnapFrame: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        let k = key(pid: pid, windowID: windowID)
        // If this window is already in a snapped state, do not overwrite the initial original frame
        if storage[k] == nil {
            storage[k] = Snapshot(
                windowID: windowID,
                pid: pid,
                initialFrame: initialFrame,
                snappedFrame: targetSnapFrame,
                timestamp: Date()
            )
        }
    }

    /// Retrieves and removes the pre-snap frame for a window (Unsnap).
    func popPreSnapFrame(pid: pid_t, windowID: CGWindowID? = nil) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        let k = key(pid: pid, windowID: windowID)
        return storage.removeValue(forKey: k)?.initialFrame
    }

    /// Checks if a window is currently recorded as snapped.
    func isSnapped(pid: pid_t, windowID: CGWindowID? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(pid: pid, windowID: windowID)] != nil
    }

    /// Clears expired entries or memory for terminated apps.
    func purge(olderThan timeInterval: TimeInterval = 3600) {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-timeInterval)
        storage = storage.filter { $0.value.timestamp >= cutoff }
    }
}
