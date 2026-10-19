import Foundation

/// One pass for all visible scope badges. Activation-group membership takes
/// precedence over application scope, including disabled gestures.
struct AOMSidebarSummary {
    private(set) var enabled = 0
    private(set) var global = 0
    private(set) var applications: [String: Int] = [:]
    private(set) var groups: [UUID: Int] = [:]

    init(triggers: [Trigger]) {
        for trigger in triggers {
            if trigger.isEnabled { enabled += 1 }
            if let group = trigger.activationGroupID { groups[group, default: 0] += 1 }
            else if let bundle = trigger.appBundleID, !bundle.isEmpty { applications[bundle, default: 0] += 1 }
            else { global += 1 }
        }
    }
}
