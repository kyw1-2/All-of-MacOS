import Foundation

/// Why the bar went away.
enum TextActionDismissReason: Equatable {
    case escape, typing, clickElsewhere, scroll, appSwitch, timeout, action, newSelection, paused, secureInput
}

/// When the bar hides, as a pure state machine fed with events and the time
/// (seconds of system uptime), so every rule is tested without a window:
/// Esc, typing, a click elsewhere, scrolling and an app switch hide it at
/// once; the pointer away from it for `hideDelay` seconds hides it too; the
/// pointer over it keeps it. Modifier keys alone (⌥ for the alternate
/// click) are not typing.
struct TextActionBarLifecycle: Equatable {
    enum Phase: Equatable { case hidden, shown }

    enum Event: Equatable {
        case shown(at: TimeInterval)
        case pointerEntered
        case pointerExited(at: TimeInterval)
        case tick(at: TimeInterval)
        /// A key press elsewhere; `escape` for Esc.
        case keyDown(escape: Bool)
        case mouseDown(insideBar: Bool)
        case scrolled
        case appSwitched
        /// An action ran; paging and submenus keep the bar.
        case actionFinished(keepsBar: Bool)
        case newSelection
        case paused
        case secureInput
    }

    enum Effect: Equatable {
        case hide(TextActionDismissReason)
        /// Check again at this time (one timer, never a polling loop).
        case wake(at: TimeInterval)
    }

    private(set) var phase: Phase = .hidden
    private(set) var pointerInside = false
    /// When the bar hides unless the pointer comes back.
    private(set) var deadline: TimeInterval?
    var hideDelay: TimeInterval

    init(hideDelay: TimeInterval) {
        self.hideDelay = hideDelay
    }

    mutating func handle(_ event: Event) -> Effect? {
        if case .shown(let now) = event {
            phase = .shown
            pointerInside = false
            deadline = now + hideDelay
            return .wake(at: now + hideDelay)
        }
        guard phase == .shown else { return nil }
        switch event {
        case .shown:
            return nil
        case .pointerEntered:
            pointerInside = true
            deadline = nil
            return nil
        case .pointerExited(let now):
            pointerInside = false
            deadline = now + hideDelay
            return .wake(at: now + hideDelay)
        case .tick(let now):
            guard !pointerInside, let deadline else { return nil }
            return now >= deadline ? hide(.timeout) : .wake(at: deadline)
        case .keyDown(let escape):
            return hide(escape ? .escape : .typing)
        case .mouseDown(let inside):
            return inside ? nil : hide(.clickElsewhere)
        case .scrolled:
            return hide(.scroll)
        case .appSwitched:
            return hide(.appSwitch)
        case .actionFinished(let keepsBar):
            return keepsBar ? nil : hide(.action)
        case .newSelection:
            return hide(.newSelection)
        case .paused:
            return hide(.paused)
        case .secureInput:
            return hide(.secureInput)
        }
    }

    private mutating func hide(_ reason: TextActionDismissReason) -> Effect {
        phase = .hidden
        pointerInside = false
        deadline = nil
        return .hide(reason)
    }
}
