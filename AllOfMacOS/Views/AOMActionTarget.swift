import Foundation

/// A preview is not an action target. Only a user's selection (keyboard or
/// pointer) or an action explicitly addressed to a row can authorize a command.
struct AOMActionTarget<ID: Hashable>: Equatable {
    var selected: ID?

    func preview(in visible: [ID], autoHighlight: Bool) -> ID? {
        if let selected, visible.contains(selected) { return selected }
        return autoHighlight ? visible.first : nil
    }

    mutating func reconcile(in visible: [ID], pending: Bool) {
        if !pending, let selected, !visible.contains(selected) { self.selected = nil }
    }

    func resolve<Item>(in visible: [Item], pending: Bool, id: (Item) -> ID,
                       addressedTo row: ID? = nil, expecting selection: ID? = nil) -> Item? {
        guard !pending else { return nil }
        let target = row ?? selected
        guard let target, selection == nil || target == selection else { return nil }
        return visible.first { id($0) == target }
    }
}

/// A deferred focus request belongs to one presentation, even on the same row.
struct AOMFocusGeneration: Equatable {
    private(set) var token = UUID()
    mutating func invalidate() { token = UUID() }
    func matches(_ token: UUID) -> Bool { self.token == token }
}
