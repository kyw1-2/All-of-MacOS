import AppKit

/// Public trackpad feedback API. No private actuator symbols or simulated clicks.
final class GestureHaptics {
    static let shared = GestureHaptics {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    private let perform: () -> Void
    private var last: TimeInterval = -.infinity
    init(perform: @escaping () -> Void) { self.perform = perform }
    @discardableResult func feedback(enabled: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard enabled, now.isFinite, now - last >= 0.08 else { return false }
        last = now; perform(); return true
    }
}
