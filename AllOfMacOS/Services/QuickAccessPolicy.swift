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

    /// Converts an `NSEvent.scrollingDelta*` value into physical finger motion
    /// (positive = right / down) so the gesture is independent of the user's
    /// "natural scrolling" setting. With natural scrolling
    /// (`isDirectionInvertedFromDevice == true`) deltas already follow the fingers.
    static func fingerDelta(_ scrollingDelta: CGFloat, invertedFromDevice: Bool) -> CGFloat {
        invertedFromDevice ? scrollingDelta : -scrollingDelta
    }

    /// Two-finger swipe toward the overlay's screen edge dismisses it; a swipe
    /// down temporarily hides every overlay (CleanShot quick tips).
    static func swipeGesture(fingerDX: CGFloat, fingerDY: CGFloat,
                             isLeftCorner: Bool, threshold: CGFloat = 65) -> QuickAccessSwipe? {
        if abs(fingerDX) >= abs(fingerDY) {
            let towardEdge = isLeftCorner ? fingerDX < -threshold : fingerDX > threshold
            return towardEdge ? .dismiss : nil
        }
        return fingerDY > threshold ? .hideAll : nil
    }
}

enum QuickAccessSwipe: Equatable {
    case dismiss, hideAll
}

/// Right-click menu of a Quick Access card, in CleanShot's emitted order.
/// Only commands AOM implements are listed; `nil` marks a separator.
enum QuickAccessMenuCommand: String, CaseIterable {
    case share, closeAll, saveAll, temporarilyHide, quickLook, openInFinder,
         print, saveAs, moveToTrash, openWith
    case annotate, pin, rotateLeft, flipHorizontal, scaleRetina, resize, extractText
    // AOM extras, kept at the end so the CleanShot block stays familiar.
    case copyQRCode, copyFile, fileInfo, editVideo

    var title: String {
        switch self {
        case .share: return "Share"
        case .closeAll: return "Close All…"
        case .saveAll: return "Save All…"
        case .temporarilyHide: return "Temporarily Hide"
        case .quickLook: return "Quick Look"
        case .openInFinder: return "Open in Finder"
        case .print: return "Print…"
        case .saveAs: return "Save As…"
        case .moveToTrash: return "Move to Trash"
        case .openWith: return "Open With"
        case .annotate: return "Open Annotation Tool…"
        case .pin: return "Pin to the Screen"
        case .rotateLeft: return "Rotate Left"
        case .flipHorizontal: return "Flip Horizontal"
        case .scaleRetina: return "Scale Retina to 1x"
        case .resize: return "Resize…"
        case .extractText: return "Extract Text"
        case .copyQRCode: return "Copy QR Code"
        case .copyFile: return "Copy File"
        case .fileInfo: return "File Information"
        case .editVideo: return "Open Video Editor…"
        }
    }

    var symbol: String {
        switch self {
        case .share: return "square.and.arrow.up"
        case .closeAll: return "xmark.rectangle"
        case .saveAll: return "square.and.arrow.down.on.square"
        case .temporarilyHide: return "eye.slash"
        case .quickLook: return "eye"
        case .openInFinder: return "folder"
        case .print: return "printer"
        case .saveAs: return "square.and.arrow.down"
        case .moveToTrash: return "trash"
        case .openWith: return "arrow.up.forward.app"
        case .annotate: return "pencil.tip.crop.circle"
        case .pin: return "pin"
        case .rotateLeft: return "rotate.left"
        case .flipHorizontal: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .scaleRetina: return "arrow.down.right.and.arrow.up.left"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .extractText: return "text.viewfinder"
        case .copyQRCode: return "qrcode.viewfinder"
        case .copyFile: return "doc.on.doc"
        case .fileInfo: return "info.circle"
        case .editVideo: return "film"
        }
    }

    static func layout(isVideo: Bool, canScaleRetina: Bool) -> [QuickAccessMenuCommand?] {
        var items: [QuickAccessMenuCommand?] = [
            .share, nil,
            .closeAll, .saveAll, .temporarilyHide, nil,
            .quickLook, .openInFinder,
        ]
        if !isVideo { items.append(.print) }
        items += [.saveAs, .moveToTrash, .openWith, nil]
        if isVideo {
            items += [.editVideo, nil, .copyFile, .fileInfo]
        } else {
            items += [.annotate, .pin, .rotateLeft, .flipHorizontal]
            if canScaleRetina { items.append(.scaleRetina) }
            items += [.resize, .extractText, nil, .copyQRCode, .copyFile, .fileInfo]
        }
        return items
    }
}
