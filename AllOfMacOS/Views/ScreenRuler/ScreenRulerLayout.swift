import CoreGraphics
import Foundation

/// Where a label sits relative to the point it belongs to.
enum ScreenRulerLabelSide: Equatable {
    case above, below, right
}

struct ScreenRulerLabel: Equatable {
    var text: String
    /// The point the label belongs to, in display points (top-left origin).
    var anchor: CGPoint
    var side: ScreenRulerLabelSide
}

/// What one measurement draws on its display, in display points with a
/// top-left origin. Lines are axis-aligned rectangles a whole number of
/// pixels thick, so they land on the pixel grid and stay crisp.
struct ScreenRulerMarks: Equatable {
    var lines: [CGRect] = []
    var box: CGRect?
    var dashed = false
    var labels: [ScreenRulerLabel] = []
}

/// Pure geometry for the overlay's drawing, kept free of AppKit for tests.
enum ScreenRulerLayout {
    /// End ticks are this many points long across the line.
    static let tickLength: CGFloat = 7
    /// Gap between a mark and its label, in points.
    static let labelGap: CGFloat = 4

    /// Line thickness in pixels: one, or two with Increase Contrast.
    static func linePixels(increasedContrast: Bool) -> Int { increasedContrast ? 2 : 1 }

    /// The hover crosshair: a line over the horizontal run (on the pointer's
    /// pixel row) and one over the vertical run (on its column), each with a
    /// tick at an edge it found (none where the run reached the screen
    /// border), and a W label above the first and an H label beside the second.
    static func marks(for distances: ScreenRulerDistances, unit: ScreenRulerUnit, showsBoth: Bool,
                      increasedContrast: Bool = false) -> ScreenRulerMarks {
        let display = distances.display
        let scale = display.scale
        let thickness = CGFloat(linePixels(increasedContrast: increasedContrast)) / scale
        let pixel = distances.pixel
        let h = distances.horizontal
        let v = distances.vertical
        // The line covers the pointer's own pixel row / column.
        let rowTop = CGFloat(pixel.y) / scale
        let columnLeft = CGFloat(pixel.x) / scale
        let left = CGFloat(h.lower) / scale, right = CGFloat(h.upper) / scale
        let top = CGFloat(v.lower) / scale, bottom = CGFloat(v.upper) / scale
        let rowMid = rowTop + 0.5 / scale
        let columnMid = columnLeft + 0.5 / scale
        let tick = snapped(tickLength, scale: scale)

        var lines = [CGRect(x: left, y: rowTop, width: right - left, height: thickness),
                     CGRect(x: columnLeft, y: top, width: thickness, height: bottom - top)]
        // Ticks sit on the run's first and last pixel, so line plus ticks
        // cover exactly the pixels measured.
        if !h.reachesLowerBorder {
            lines.append(CGRect(x: left, y: snapped(rowMid - tick / 2, scale: scale), width: thickness, height: tick))
        }
        if !h.reachesUpperBorder {
            lines.append(CGRect(x: right - thickness, y: snapped(rowMid - tick / 2, scale: scale), width: thickness, height: tick))
        }
        if !v.reachesLowerBorder {
            lines.append(CGRect(x: snapped(columnMid - tick / 2, scale: scale), y: top, width: tick, height: thickness))
        }
        if !v.reachesUpperBorder {
            lines.append(CGRect(x: snapped(columnMid - tick / 2, scale: scale), y: bottom - thickness, width: tick, height: thickness))
        }
        let width = ScreenRulerFormat.length(pixels: h.length, scale: scale, unit: unit, showsBoth: showsBoth)
        let height = ScreenRulerFormat.length(pixels: v.length, scale: scale, unit: unit, showsBoth: showsBoth)
        return ScreenRulerMarks(lines: lines, box: nil, dashed: false, labels: [
            ScreenRulerLabel(text: width, anchor: CGPoint(x: (left + right) / 2, y: rowTop), side: .above),
            ScreenRulerLabel(text: height, anchor: CGPoint(x: columnLeft + thickness, y: (top + bottom) / 2), side: .right)
        ])
    }

    /// A box: dashed while dragging, solid when finished, with "W × H" under it.
    static func marks(for area: ScreenRulerArea, dragging: Bool, unit: ScreenRulerUnit,
                      showsBoth: Bool) -> ScreenRulerMarks {
        let box = area.display.localRect(area.rect)
        let text = ScreenRulerFormat.size(width: area.rect.width, height: area.rect.height,
                                          scale: area.display.scale, unit: unit, showsBoth: showsBoth)
        return ScreenRulerMarks(lines: [], box: box, dashed: dragging,
                                labels: [ScreenRulerLabel(text: text, anchor: CGPoint(x: box.midX, y: box.maxY), side: .below)])
    }

    static func marks(for measurement: ScreenRulerMeasurement, unit: ScreenRulerUnit, showsBoth: Bool,
                      increasedContrast: Bool = false) -> ScreenRulerMarks {
        switch measurement {
        case .distances(let distances):
            return marks(for: distances, unit: unit, showsBoth: showsBoth, increasedContrast: increasedContrast)
        case .area(let area):
            return marks(for: area, dragging: false, unit: unit, showsBoth: showsBoth)
        }
    }

    /// The frame for a label of `size` beside `anchor`, flipped to the other
    /// side when it would leave `bounds`, then kept inside it.
    static func labelFrame(size: CGSize, for label: ScreenRulerLabel, in bounds: CGRect) -> CGRect {
        let gap = labelGap
        var frame: CGRect
        switch label.side {
        case .above:
            frame = CGRect(x: label.anchor.x - size.width / 2, y: label.anchor.y - gap - size.height,
                           width: size.width, height: size.height)
            if frame.minY < bounds.minY { frame.origin.y = label.anchor.y + gap }
        case .below:
            frame = CGRect(x: label.anchor.x - size.width / 2, y: label.anchor.y + gap,
                           width: size.width, height: size.height)
            if frame.maxY > bounds.maxY { frame.origin.y = label.anchor.y - gap - size.height }
        case .right:
            frame = CGRect(x: label.anchor.x + gap, y: label.anchor.y - size.height / 2,
                           width: size.width, height: size.height)
            if frame.maxX > bounds.maxX { frame.origin.x = label.anchor.x - gap - size.width }
        }
        frame.origin.x = min(max(bounds.minX, frame.minX), bounds.maxX - size.width)
        frame.origin.y = min(max(bounds.minY, frame.minY), bounds.maxY - size.height)
        return frame
    }

    /// Rounds a length or position to the display's pixel grid.
    static func snapped(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}
