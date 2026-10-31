import AppKit

/// A display for placing pills: its frame in Accessibility coordinates
/// (top-left origin, y down) and its backing scale.
struct ClickHintsDisplay: Equatable {
    var id: UInt32
    var frame: CGRect
    var scale: CGFloat

    /// The current displays. AppKit frames have a bottom-left origin on the
    /// primary display; Accessibility frames a top-left one.
    @MainActor
    static func current() -> [ClickHintsDisplay] {
        let screens = NSScreen.screens
        guard let primaryTop = screens.first?.frame.maxY else { return [] }
        return screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return ClickHintsDisplay(id: number?.uint32Value ?? 0,
                                     frame: WindowGeometry.accessibilityFrame(screen.frame, primaryTop: primaryTop),
                                     scale: max(1, screen.backingScaleFactor))
        }
    }
}

/// Where one pill goes.
struct ClickHintsPlacedPill: Equatable {
    var displayID: UInt32
    /// Global Accessibility coordinates.
    var frame: CGRect
    /// Points from the display's top-left corner.
    var localFrame: CGRect
}

/// Puts each pill on its element's top-left corner, keeps it whole on the
/// display that shows that corner, on that display's pixel grid, and nudges
/// it right when an earlier (more likely) pill is already there.
enum ClickHintsPlacement {
    /// The pill sits this far up and left of the element's corner, so it
    /// marks the corner without hiding the element's first letters.
    static let cornerOffset = CGPoint(x: -3, y: -3)
    static let gap: CGFloat = 2
    static let nudges = 4

    /// `anchors` are the targets' visible frames, `sizes` the pill sizes,
    /// both in rank order. nil where no display is near.
    static func place(anchors: [CGRect], sizes: [CGSize], displays: [ClickHintsDisplay],
                      offset: CGPoint = cornerOffset) -> [ClickHintsPlacedPill?] {
        var placed: [ClickHintsPlacedPill?] = []
        var occupied: [UInt32: [CGRect]] = [:]
        for (anchor, size) in zip(anchors, sizes) {
            guard let display = display(for: anchor, in: displays) else {
                placed.append(nil)
                continue
            }
            var frame = CGRect(origin: CGPoint(x: anchor.minX + offset.x, y: anchor.minY + offset.y), size: size)
            frame = fit(frame, in: display.frame, scale: display.scale)
            var taken = occupied[display.id] ?? []
            var attempt = 0
            // Pills may touch (stacked rows); only a real overlap moves one.
            while attempt < nudges, let blocker = taken.first(where: { $0.insetBy(dx: 1, dy: 1).intersects(frame) }) {
                var moved = frame
                moved.origin.x = blocker.maxX + gap
                moved = fit(moved, in: display.frame, scale: display.scale)
                // Clamping at the right edge may land it back on the blocker.
                if moved.intersects(blocker) { break }
                frame = moved
                attempt += 1
            }
            taken.append(frame)
            occupied[display.id] = taken
            let local = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            placed.append(ClickHintsPlacedPill(displayID: display.id, frame: frame, localFrame: local))
        }
        return placed
    }

    /// The display that shows the anchor's top-left corner; else the one
    /// with most of the anchor; else the nearest.
    static func display(for anchor: CGRect, in displays: [ClickHintsDisplay]) -> ClickHintsDisplay? {
        let corner = CGPoint(x: anchor.minX, y: anchor.minY)
        if let owner = displays.first(where: { contains($0.frame, corner) }) { return owner }
        var best: (display: ClickHintsDisplay, area: CGFloat)?
        for display in displays {
            let part = display.frame.intersection(anchor)
            guard !part.isNull else { continue }
            let area = part.width * part.height
            if area > (best?.area ?? 0) { best = (display, area) }
        }
        if let best { return best.display }
        return displays.min { ClickHintsCollector.distance($0.frame, corner) < ClickHintsCollector.distance($1.frame, corner) }
    }

    /// Half-open containment, so a point on a shared edge belongs to one display.
    static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
    }

    /// Moves the frame inside `bounds` (a pill larger than the display keeps
    /// its top-left corner on it).
    static func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
        result.origin.y = min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
        return result
    }

    /// Clamps the frame into `bounds` with its origin on the display's pixel
    /// grid (1×, 2×, 3×), so text and hairlines stay sharp and rounding never
    /// pushes the pill past an edge.
    static func fit(_ frame: CGRect, in bounds: CGRect, scale: CGFloat) -> CGRect {
        let s = max(1, scale)
        let clampedFrame = clamped(frame, to: bounds)
        let minX = (bounds.minX * s).rounded(.up) / s, minY = (bounds.minY * s).rounded(.up) / s
        let maxX = max(minX, ((bounds.maxX - frame.width) * s).rounded(.down) / s)
        let maxY = max(minY, ((bounds.maxY - frame.height) * s).rounded(.down) / s)
        let x = min(max((clampedFrame.minX * s).rounded() / s, minX), maxX)
        let y = min(max((clampedFrame.minY * s).rounded() / s, minY), maxY)
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }
}
