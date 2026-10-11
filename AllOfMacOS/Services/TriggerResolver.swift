import Foundation
import AppKit

/// Decides which registered triggers apply to an input that just fired.
///
/// Each monitor used to repeat this rule inline — read the frontmost app,
/// keep the entries whose input matches, then let app-specific entries
/// shadow globals *entirely*: when any entry targets the frontmost app,
/// globals for that same input are skipped rather than merged. That was five
/// copies of a rule with a non-obvious priority decision, and a place where
/// one monitor could quietly drift from the others.
///
/// The monitors keep their registrations as flat tuples rather than `Trigger`
/// values, so the core takes accessors instead of a concrete type. Matching is
/// by equality on the payload, so callers pass the value they already compared
/// against.
enum TriggerResolver {
    static let modifierMask: UInt = NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue
    static func modifiersMatch(_ required: UInt?, _ actual: UInt) -> Bool {
        required.map { ($0 & modifierMask) == (actual & modifierMask) } ?? true
    }

    /// Entries that should fire for `payload` given `frontBundleID`.
    ///
    /// App-specific entries take priority: when any entry targets the
    /// frontmost app, globals are skipped rather than merged.
    static func resolve<Item, Payload: Equatable>(
        _ items: [Item],
        payload: Payload,
        frontBundleID: String?,
        payloadOf: (Item) -> Payload?,
        appBundleIDOf: (Item) -> String?,
        modifiers: UInt = 0,
        requiredModifiersOf: (Item) -> UInt? = { _ in nil },
        groups: [ActivationGroup] = [],
        activationGroupIDOf: (Item) -> UUID? = { _ in nil }
    ) -> [Item] {
        let candidates = items.filter { payloadOf($0) == payload && modifiersMatch(requiredModifiersOf($0), modifiers) }
        guard !candidates.isEmpty else { return [] } // Fast path for unrelated keyboard/mouse events.
        let appSpecific = candidates.filter {
            activationGroupIDOf($0) == nil && appBundleIDOf($0) != nil && appBundleIDOf($0) == frontBundleID
        }
        // Explicit app bindings always beat grouped and global bindings.
        if !appSpecific.isEmpty {
            let exact = appSpecific.filter { requiredModifiersOf($0) != nil }
            return exact.isEmpty ? appSpecific : exact
        }
        // The first configured matching group with bindings wins. Disabled groups
        // and excluded apps never participate, even if they still own triggers.
        let activeGroups = groups.filter { $0.matches(frontBundleID) }
        for group in activeGroups {
            let matched = candidates.filter { activationGroupIDOf($0) == group.id }
            if !matched.isEmpty {
                let exact = matched.filter { requiredModifiersOf($0) != nil }
                return exact.isEmpty ? matched : exact
            }
        }
        // A matching group's opt-out blocks *only global* bindings, not app overrides.
        if activeGroups.contains(where: { $0.disableGlobalTriggers }) { return [] }
        let global = candidates.filter { appBundleIDOf($0) == nil && activationGroupIDOf($0) == nil }
        let exact = global.filter { requiredModifiersOf($0) != nil }
        return exact.isEmpty ? global : exact
    }
}
