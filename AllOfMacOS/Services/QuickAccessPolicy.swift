import Foundation

/// Pure quick-access rules; kept outside AppKit to make state transitions
/// deterministic and regression-testable.
enum QuickAccessShortcut: Equatable {
    case close, copy, save, edit, pin, quickLook
}

enum QuickAccessPolicy {
    static func shortcut(keyCode: UInt16, command: Bool) -> QuickAccessShortcut? {
        if keyCode == 53 || (command && keyCode == 13) { return .close }
        if command {
            switch keyCode {
            case 8: return .copy      // Cmd-C
            case 1: return .save      // Cmd-S
            case 14: return .edit     // Cmd-E
            case 35: return .pin      // Cmd-P
            default: return nil
            }
        }
        switch keyCode {
        case 36: return .save         // Return
        case 49: return .quickLook    // Space
        default: return nil
        }
    }

    static let maximumVisible = 3
    static let maximumRestoreHistory = 20

    static func visibleAfterAdding<T>(_ items: [T], new item: T) -> (visible: [T], displaced: [T]) {
        let candidates = items + [item]
        guard candidates.count > maximumVisible else { return (candidates, []) }
        return (Array(candidates.suffix(maximumVisible)),
                Array(candidates.prefix(candidates.count - maximumVisible)))
    }

    static func shouldDismissForSwipe(_ translation: CGFloat, predicted: CGFloat, isLeftCorner: Bool) -> Bool {
        let sign: CGFloat = isLeftCorner ? -1 : 1
        return translation * sign > 55 || predicted * sign > 140
    }

    static func elapsedForAutoClose(_ elapsed: TimeInterval, hovered: Bool, dragging: Bool) -> TimeInterval {
        (hovered || dragging) ? 0 : max(0, elapsed)
    }

    static func effectiveInterval(mode: OverlayAutoClose, configured: Int, forced: TimeInterval?) -> TimeInterval? {
        if let forced { return forced > 0 ? forced : nil }
        return mode == .afterInterval ? TimeInterval(max(1, configured)) : nil
    }

    static func shouldCloseAfterDrag(mode: OverlayAutoClose, separateToggle: Bool, succeeded: Bool) -> Bool {
        succeeded && (mode == .afterDrag || separateToggle)
    }
}
