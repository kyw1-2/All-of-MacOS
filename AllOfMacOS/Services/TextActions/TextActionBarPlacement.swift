import CoreGraphics
import Foundation

/// One display as the placement sees it, in AppKit coordinates (origin at
/// the bottom left of the main display). `visibleFrame` leaves out the menu
/// bar and the Dock.
struct TextActionScreen: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
}

/// Where the bar goes: centred on the pointer over the selected line, above
/// it (or below), flipped when there is no room, always inside the visible
/// part of the pointer's display, never under the menu bar.
enum TextActionBarPlacement {
    /// Between the selection and the bar.
    static let gap: CGFloat = 8
    /// From the edges of the visible frame.
    static let margin: CGFloat = 6
    /// How far from the pointer the selection's bounds may be and still be
    /// trusted (a moved window leaves stale bounds behind).
    static let pointerTolerance: CGFloat = 48
    /// A selection taller than this is several lines: the bar keeps to the
    /// line under the pointer.
    static let tallSelection: CGFloat = 72
    /// The height of a text line when only the pointer is known.
    static let lineHeight: CGFloat = 22
    /// ChatGPT's native Ask ChatGPT bubble occupies the space above a
    /// selection. Put AOM below, with an extra 38 pt gap; near the Dock the
    /// existing placement engine flips it above with the same separation.
    static func nativePopoverClearance(bundleID: String?) -> CGFloat {
        guard let id = bundleID?.lowercased(),
              TextActionsGate.selectionCopyRecoveryHosts.contains(id) else { return 0 }
        return 38
    }

    /// Accessibility rectangle (top-left origin) to AppKit (bottom-left);
    /// `primaryHeight` is the main display's height.
    static func appKitRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The area the bar keeps clear of. The selection's bounds win when they
    /// are on a screen and near the pointer; a tall selection narrows to the
    /// pointer's line; otherwise a line-high box at the pointer.
    static func anchor(selection: CGRect?, pointer: CGPoint?, screens: [TextActionScreen]) -> CGRect? {
        if let selection, isBelievable(selection, screens: screens) {
            guard let pointer else { return selection }
            if selection.insetBy(dx: -pointerTolerance, dy: -pointerTolerance).contains(pointer) {
                guard selection.height > tallSelection else { return selection }
                let y = min(max(pointer.y - lineHeight / 2, selection.minY), selection.maxY - lineHeight)
                return CGRect(x: selection.minX, y: y, width: selection.width, height: lineHeight)
            }
        }
        guard let pointer else { return nil }
        return CGRect(x: pointer.x - 1, y: pointer.y - lineHeight / 2, width: 2, height: lineHeight)
    }

    static func isBelievable(_ rect: CGRect, screens: [TextActionScreen]) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 0, rect.height > 0, rect.height < 20_000, rect.width < 40_000 else { return false }
        return screens.contains { $0.frame.intersects(rect.insetBy(dx: -1, dy: -1)) }
    }

    /// The bar's origin (bottom-left, AppKit coordinates).
    static func origin(for size: CGSize, anchor: CGRect, pointer: CGPoint?, screens: [TextActionScreen],
                       position: TextActionBarPosition, extraClearance: CGFloat = 0) -> CGPoint {
        let screen = screen(for: anchor, pointer: pointer, screens: screens)
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -1_000, dy: -1_000)

        // Centre on the pointer, kept over the selection, then inside the screen.
        let centre: CGFloat
        if let pointer, anchor.width > 2 {
            centre = min(max(pointer.x, anchor.minX), anchor.maxX)
        } else {
            centre = anchor.midX
        }
        var x = centre - size.width / 2
        let lowestX = visible.minX + margin
        let highestX = visible.maxX - size.width - margin
        x = highestX < lowestX ? lowestX : min(max(x, lowestX), highestX)

        let clearance = max(0, extraClearance)
        let above = anchor.maxY + gap + clearance
        let below = anchor.minY - gap - size.height - clearance
        let topLimit = visible.maxY - margin
        let bottomLimit = visible.minY + margin
        let fitsAbove = above + size.height <= topLimit
        let fitsBelow = below >= bottomLimit
        var y: CGFloat
        switch position {
        case .above: y = fitsAbove || !fitsBelow ? above : below
        case .below: y = fitsBelow || !fitsAbove ? below : above
        }
        // Neither side fits: stay inside the visible frame, over the text if need be.
        y = min(max(y, bottomLimit), topLimit - size.height)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// The pointer's display, else the one holding the anchor's centre, else
    /// the one the anchor overlaps most, else the first.
    static func screen(for anchor: CGRect, pointer: CGPoint?, screens: [TextActionScreen]) -> TextActionScreen? {
        if let pointer, let hit = screens.first(where: { $0.frame.contains(pointer) }) { return hit }
        let centre = CGPoint(x: anchor.midX, y: anchor.midY)
        if let hit = screens.first(where: { $0.frame.contains(centre) }) { return hit }
        let overlapping = screens.map { ($0, $0.frame.intersection(anchor)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
        return overlapping?.0 ?? screens.first
    }
}

/// Splits the bar's items into pages that fit its width, like the iOS edit
/// menu: a chevron at the end goes on, one at the start goes back.
enum TextActionBarPaging {
    static func pages(widths: [CGFloat], maxWidth: CGFloat, chevron: CGFloat) -> [Range<Int>] {
        guard !widths.isEmpty else { return [] }
        if widths.reduce(0, +) <= maxWidth { return [0..<widths.count] }
        var pages: [Range<Int>] = []
        var start = 0
        while start < widths.count {
            // Room for a back chevron after the first page, and a forward one
            // unless the rest fits.
            let back: CGFloat = pages.isEmpty ? 0 : chevron
            var end = start
            var used = back
            while end < widths.count {
                let remaining = widths[end...].reduce(0, +)
                if used + remaining <= maxWidth { end = widths.count; break }
                if used + widths[end] + chevron > maxWidth { break }
                used += widths[end]
                end += 1
            }
            if end == start { end = start + 1 }  // one item wider than the bar still gets a page
            pages.append(start..<end)
            start = end
        }
        return pages
    }
}
