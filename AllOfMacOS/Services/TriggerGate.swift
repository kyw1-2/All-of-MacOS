import Foundation

/// The single choke point every physical or system trigger passes before its
/// actions run (called from `ActionExecutor.fire`). Applies, in order:
///
/// 1. `TriggerSuppression` — global/app pause, modifier hold, post-keystroke.
/// 2. The trigger's own `delayBeforeTriggeringMs`.
///
/// Named-trigger calls and editor test runs use `ActionExecutor.executeActions`
/// directly and are intentionally not gated: the trigger that called them
/// already was.
enum TriggerGate {
    /// Schedules `work` after `delay`. Replaceable so tests need not wait.
    static var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// Triggers whose delay has just elapsed; their re-dispatch must not wait again.
    private static var delayElapsed = Set<UUID>()
    static var suppression: () -> TriggerSuppression = { TriggerSuppression.shared }

    /// Returns true when the caller should run the trigger's actions now. When
    /// it returns false the trigger was either blocked or deferred;
    /// `redispatch` is invoked after the delay and goes through the gate again,
    /// so suppression is re-checked at the moment the actions would really run.
    static func admit(triggerID: UUID, trigger: Trigger?, redispatch: @escaping () -> Void) -> Bool {
        guard !ActionExecutor.inactiveTriggerIDs.contains(triggerID) else { return false }
        if let trigger = trigger ?? ActionExecutor.registeredTriggers.first(where: { $0.id == triggerID }) {
            guard suppression().allows(trigger) else { return false }
            let delay = trigger.delayBeforeTriggeringMs
            guard delay > 0, !delayElapsed.contains(triggerID) else { return true }
            schedule(Double(min(delay, 600_000)) / 1000) {
                // A trigger deleted or disabled during the delay must not run.
                guard ActionExecutor.registeredTriggers.contains(where: { $0.id == triggerID }) else { return }
                delayElapsed.insert(triggerID)
                defer { delayElapsed.remove(triggerID) }
                redispatch()
            }
            return false
        }
        // Ad-hoc fire with no registered trigger: only the global pause applies.
        return suppression().allows(kind: .system)
    }
}
