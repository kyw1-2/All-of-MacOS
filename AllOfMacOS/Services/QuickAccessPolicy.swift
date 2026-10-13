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

    /// Bounded layout for 1–3 overlays on short displays.
    /// Cards may overlap gracefully when their combined height exceeds the
    /// usable screen, but they must never all collapse into one clamped origin.
    static func stackStride(visibleHeight: CGFloat, cardHeight: CGFloat,
                            count: Int, margin: CGFloat = 20) -> CGFloat {
        guard count > 1 else { return 0 }
        let space = max(0, visibleHeight - 2 * margin - cardHeight)
        return min(cardHeight + 12, space / CGFloat(count - 1))
    }

    static func restoredIDs(_ stored: [String], present: Set<UUID>) -> [UUID] {
        Array(stored.compactMap(UUID.init(uuidString:))
            .filter { present.contains($0) }.suffix(maximumRestoreHistory))
    }
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

    /// The reference application advertises Option as the temporary inverse
    /// of its saved drag-close preference. Only a successful drop can close.
    /// This AOM behavior is independently specified, not runtime parity proof.
    static func shouldCloseAfterDrag(mode: OverlayAutoClose, separateToggle: Bool,
                                     succeeded: Bool, optionPressed: Bool = false) -> Bool {
        guard succeeded else { return false }
        return (mode == .afterDrag || separateToggle) != optionPressed
    }

    /// Option temporarily inverts whether Save asks for a destination/name.
    /// An explicit Save As action must always show the panel instead.
    static func shouldPromptSave(asksForName: Bool, optionPressed: Bool) -> Bool {
        asksForName != optionPressed
    }
}
