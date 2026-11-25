import Foundation

/// Identity includes the preset. An imported preset can contain the same UUIDs.
struct AutomationEditorID: Hashable {
    let preset: UUID
    let trigger: UUID

    func latest(in preset: Preset) -> Trigger? {
        guard preset.id == self.preset else { return nil }
        return preset.triggers.first { $0.id == trigger }
    }
}

struct AutomationEditorDraft {
    var expandedSteps: Set<UUID> = []
    var showsInput = false
    var showsOptions = false
    var name: String?
    var restoreNameFocus = false
    var scrollAnchor: String?
    var inspectedStep: UUID?

    mutating func reconcileSteps(_ live: Set<UUID>) {
        expandedSteps.formIntersection(live)
        if let inspectedStep, !live.contains(inspectedStep) { self.inspectedStep = nil }
    }
}

/// Reorder siblings only; a drag cannot silently change a step's condition
/// by moving it across the THEN/OTHERWISE boundary. The destination row's
/// upper/lower half determines the edge, including after the final step.
enum AutomationStepOrder {
    static func move(_ actions: [TriggerAction], source: UUID, target: UUID, after: Bool) -> [TriggerAction]? {
        guard source != target else { return nil }
        var reordered = actions
        let found = ActionTree.edit(&reordered, id: source) { siblings, index in
            guard let destination = siblings.firstIndex(where: { $0.id == target }) else { return }
            let step = siblings.remove(at: index)
            let edge = destination - (index < destination ? 1 : 0) + (after ? 1 : 0)
            siblings.insert(step, at: edge)
        }
        guard found, reordered != actions else { return nil }
        return reordered
    }

    static func move(_ actions: [TriggerAction], source: UUID, offset: Int) -> [TriggerAction]? {
        var reordered = actions
        guard ActionTree.edit(&reordered, id: source, change: { siblings, index in
            let next = index + offset
            if siblings.indices.contains(next) { siblings.swapAt(index, next) }
        }), reordered != actions else { return nil }
        return reordered
    }
}
