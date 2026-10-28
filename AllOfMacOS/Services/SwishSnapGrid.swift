import AppKit

// The rest of Swish 1.13's snapping options, recovered from its settings
// strings: "snapThirds", "snapSixths", "snapNinths", "snapAlmost",
// "snappingDragUnsnap", "snappingResizeAdjacent", "Resnapping after …",
// "snappingStageManagerOffset", "tooltipAnimationTime" and the keyboard
// hotkeys of its Advanced tab (arrows / WASD / IJKL / HJKL).
//
// Everything here is pure: grid cells, the chaining tables, target frames and
// the geometry the title-bar snap's mouse, keyboard and display handlers
// decide with. `TitleBarWindowSnap` does the Accessibility work. This is AOM's
// own implementation of that behaviour, not Swish code.

/// A cell of a snapping grid: `columnSpan` × `rowSpan` units at (`column`,
/// `row`) of a `columns` × `rows` grid, origin at the top left.
///
/// Cells are kept in lowest terms, so two cells covering the same region
/// compare equal: the left half of a 2 × 2 grid is the left half of a 2 × 1
/// grid, and three ninths stacked in a column are a third. Halves, quarters,
/// thirds and two thirds convert to and from `CustomSnapZone.Layout`. Sixths,
/// ninths and their spans have no layout and exist only here, so saved presets
/// and snap zones (`CustomSnapZone.Layout` raw values) are untouched.
struct SwishGridCell: Hashable, CustomStringConvertible {
    let columns: Int
    let rows: Int
    let column: Int
    let row: Int
    let columnSpan: Int
    let rowSpan: Int

    /// Out-of-range spans and positions are clamped into the grid.
    init(columns: Int, rows: Int, column: Int, row: Int, columnSpan: Int = 1, rowSpan: Int = 1) {
        let columns = max(1, columns), rows = max(1, rows)
        let columnSpan = min(max(1, columnSpan), columns), rowSpan = min(max(1, rowSpan), rows)
        let column = min(max(0, column), columns - columnSpan), row = min(max(0, row), rows - rowSpan)
        let x = Self.gcd(Self.gcd(columns, column), columnSpan)
        let y = Self.gcd(Self.gcd(rows, row), rowSpan)
        self.columns = columns / x
        self.column = column / x
        self.columnSpan = columnSpan / x
        self.rows = rows / y
        self.row = row / y
        self.rowSpan = rowSpan / y
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// The whole area (maximize).
    static let full = SwishGridCell(columns: 1, rows: 1, column: 0, row: 0)

    /// A cell of the 3 × 2 grid: a sixth, or two sixths side by side.
    static func sixth(_ column: Int, _ row: Int, columnSpan: Int = 1) -> SwishGridCell {
        SwishGridCell(columns: 3, rows: 2, column: column, row: row, columnSpan: columnSpan)
    }

    /// A cell of the 3 × 3 grid: a ninth, two-ninths or four-ninths.
    static func ninth(_ column: Int, _ row: Int, columnSpan: Int = 1, rowSpan: Int = 1) -> SwishGridCell {
        SwishGridCell(columns: 3, rows: 3, column: column, row: row, columnSpan: columnSpan, rowSpan: rowSpan)
    }

    var description: String { "\(columns)×\(rows)@(\(column),\(row))+\(columnSpan)×\(rowSpan)" }

    /// The region in a unit square, origin at the top left.
    var unitRect: CGRect {
        CGRect(x: CGFloat(column) / CGFloat(columns), y: CGFloat(row) / CGFloat(rows),
               width: CGFloat(columnSpan) / CGFloat(columns), height: CGFloat(rowSpan) / CGFloat(rows))
    }

    /// The share of the area the cell covers.
    var area: Double { Double(columnSpan * rowSpan) / Double(columns * rows) }

    var touchesLeft: Bool { column == 0 }
    var touchesRight: Bool { column + columnSpan == columns }
    var touchesTop: Bool { row == 0 }
    var touchesBottom: Bool { row + rowSpan == rows }
    var fullWidth: Bool { columnSpan == columns }
    var fullHeight: Bool { rowSpan == rows }

    /// The same-sized cell moved by whole cells (clamped into the grid).
    func shifted(columns dx: Int = 0, rows dy: Int = 0) -> SwishGridCell {
        SwishGridCell(columns: columns, rows: rows, column: column + dx, row: row + dy,
                      columnSpan: columnSpan, rowSpan: rowSpan)
    }

    /// One cell wider: away from the side edge the cell touches, or across
    /// the whole width when it touches neither (a cell in the middle column).
    func widened() -> SwishGridCell {
        if touchesLeft != touchesRight {
            return SwishGridCell(columns: columns, rows: rows, column: touchesLeft ? column : column - 1, row: row,
                                 columnSpan: columnSpan + 1, rowSpan: rowSpan)
        }
        return SwishGridCell(columns: columns, rows: rows, column: 0, row: row, columnSpan: columns, rowSpan: rowSpan)
    }

    /// One cell taller: away from the top or bottom edge the cell touches, or
    /// the whole height when it touches neither (a cell in the middle row).
    func heightened() -> SwishGridCell {
        if touchesTop != touchesBottom {
            return SwishGridCell(columns: columns, rows: rows, column: column, row: touchesTop ? row : row - 1,
                                 columnSpan: columnSpan, rowSpan: rowSpan + 1)
        }
        return SwishGridCell(columns: columns, rows: rows, column: column, row: 0, columnSpan: columnSpan, rowSpan: rows)
    }

    init?(_ layout: CustomSnapZone.Layout) {
        switch layout {
        case .maximize: self = .full
        case .leftHalf: self.init(columns: 2, rows: 1, column: 0, row: 0)
        case .rightHalf: self.init(columns: 2, rows: 1, column: 1, row: 0)
        case .topHalf: self.init(columns: 1, rows: 2, column: 0, row: 0)
        case .bottomHalf: self.init(columns: 1, rows: 2, column: 0, row: 1)
        case .topLeft: self.init(columns: 2, rows: 2, column: 0, row: 0)
        case .topRight: self.init(columns: 2, rows: 2, column: 1, row: 0)
        case .bottomLeft: self.init(columns: 2, rows: 2, column: 0, row: 1)
        case .bottomRight: self.init(columns: 2, rows: 2, column: 1, row: 1)
        case .leftThird: self.init(columns: 3, rows: 1, column: 0, row: 0)
        case .centerThird: self.init(columns: 3, rows: 1, column: 1, row: 0)
        case .rightThird: self.init(columns: 3, rows: 1, column: 2, row: 0)
        case .leftTwoThirds: self.init(columns: 3, rows: 1, column: 0, row: 0, columnSpan: 2)
        case .rightTwoThirds: self.init(columns: 3, rows: 1, column: 1, row: 0, columnSpan: 2)
        case .center, .nextDisplay: return nil
        }
    }

    private static let layoutsByCell: [SwishGridCell: CustomSnapZone.Layout] = {
        var table: [SwishGridCell: CustomSnapZone.Layout] = [:]
        for layout in CustomSnapZone.Layout.allCases {
            if let cell = SwishGridCell(layout) { table[cell] = layout }
        }
        return table
    }()

    /// The tiling layout covering the same region, if there is one.
    var layout: CustomSnapZone.Layout? { Self.layoutsByCell[self] }
}

extension SwishSnap {
    // MARK: Grids and places

    /// The snapping grid (Swish's "snapThirds", "snapSixths" and
    /// "snapNinths"). Halves and quarters belong to every grid.
    /// - 2 × 2: halves and quarters only; a third is never reached.
    /// - 3 × 2: thirds and two thirds, and "the upper and lower halves of
    ///   those thirds" (sixths, and two sixths side by side).
    /// - 3 × 3: thirds and two thirds, and ninths, two-ninths and four-ninths
    ///   (plus the rows of the 3 × 3 grid).
    enum Grid: String, CaseIterable, Equatable {
        case twoByTwo = "2x2", threeByTwo = "3x2", threeByThree = "3x3"

        /// Thirds and two thirds are reachable.
        var thirds: Bool { self != .twoByTwo }

        /// The rows a full-height column of three splits into when it is
        /// swiped up or down: sixths in 3 × 2, ninths in 3 × 3.
        var rowsForThirds: Int { self == .threeByThree ? 3 : 2 }

        /// Whether a swipe can produce `cell` in this grid. A cell left from a
        /// finer grid (a sixth after switching to 2 × 2) is free-floating.
        func contains(_ cell: SwishGridCell) -> Bool {
            switch (cell.columns, cell.rows) {
            case (1, 1), (2, 1), (1, 2), (2, 2): return true
            case (3, 1): return thirds
            case (3, 2): return self == .threeByTwo
            case (1, 3), (3, 3): return self == .threeByThree
            default: return false
            }
        }

        /// Every cell of the grid, smallest first, so the most specific
        /// match wins when a frame is recognised.
        var cells: [SwishGridCell] { Grid.cellTable[self] ?? [] }

        private static let cellTable: [Grid: [SwishGridCell]] =
            Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.enumerateCells()) })

        private func enumerateCells() -> [SwishGridCell] {
            var families = [(2, 2)]
            switch self {
            case .twoByTwo: break
            case .threeByTwo: families.append((3, 2))
            case .threeByThree: families.append((3, 3))
            }
            var seen = Set<SwishGridCell>()
            var result: [SwishGridCell] = []
            for (columns, rows) in families {
                for columnSpan in 1...columns {
                    for column in 0...(columns - columnSpan) {
                        for rowSpan in 1...rows {
                            for row in 0...(rows - rowSpan) {
                                let cell = SwishGridCell(columns: columns, rows: rows, column: column, row: row,
                                                         columnSpan: columnSpan, rowSpan: rowSpan)
                                if seen.insert(cell).inserted { result.append(cell) }
                            }
                        }
                    }
                }
            }
            return result.sorted {
                ($0.area, $0.row, $0.column, $0.rows, $0.columns) < ($1.area, $1.row, $1.column, $1.rows, $1.columns)
            }
        }
    }

    /// Where a title-bar snap puts a window.
    enum Place: Hashable {
        /// A cell of a grid: halves, quarters, thirds, sixths, ninths and spans of them.
        case grid(SwishGridCell)
        /// The centred free frame a swipe down gives (`CustomSnapZone.Layout.center`).
        case center
        /// Swish's "Almost Maximize": the visible area less a small gap all round.
        case almostMaximize

        init?(_ layout: CustomSnapZone.Layout) {
            if layout == .center { self = .center; return }
            guard let cell = SwishGridCell(layout) else { return nil }
            self = .grid(cell)
        }

        /// The tiling layout with the same frame, if there is one.
        var layout: CustomSnapZone.Layout? {
            switch self {
            case .grid(let cell): return cell.layout
            case .center: return .center
            case .almostMaximize: return nil
            }
        }
    }

    /// Whether the current options can produce `place`; one they cannot (a
    /// third in 2 × 2, a ninth in 3 × 2, almost-maximize turned off) makes
    /// the window free-floating.
    static func usable(_ place: Place, grid: Grid, almost: Bool) -> Bool {
        switch place {
        case .grid(let cell): return grid.contains(cell)
        case .center: return true
        case .almostMaximize: return almost
        }
    }

    /// Any cell finer than halves: three columns or three rows.
    static func isThird(_ place: Place) -> Bool {
        if case .grid(let cell) = place { return cell.columns == 3 || cell.rows == 3 }
        return false
    }

    // MARK: Chaining

    /// Swish-style chaining on a grid: a swipe moves the window on from the
    /// place it is in.
    /// - Free-floating or centred: sideways a half (a longer swipe a third
    ///   when the grid has thirds); up maximizes (a longer swipe: the top
    ///   half); down centres the window, and on a centred one puts it back
    ///   (a longer swipe: the bottom half).
    /// - Maximized: sideways a half, up stays, down puts the window back.
    /// - Almost maximize on: every swipe that would maximize almost-maximizes
    ///   instead (a free window or the top half swiped up), and an
    ///   almost-maximized window swiped up maximizes; sideways it becomes a
    ///   half and down puts it back.
    /// - A full-height column (a half, a third, two thirds) swiped up or down
    ///   takes the top or bottom row of the grid: a half becomes a quarter;
    ///   in 3 × 2 a third becomes its upper or lower sixth and two thirds the
    ///   two sixths above or below; in 3 × 3 a third becomes its top or
    ///   bottom ninth and two thirds two-ninths.
    /// - A column swiped sideways keeps 3.3.1's table: away from its edge it
    ///   moves over (the other half, the next third; two thirds become the
    ///   opposite half); toward its edge it steps half → third → two thirds →
    ///   half with thirds on, and stays put in 2 × 2.
    /// - A full-width row (the top or bottom half, a row of the 3 × 3 grid)
    ///   swiped sideways takes its left or right end (a quarter, or a ninth in
    ///   3 × 3); swiped up or down it moves a row; up from the top it
    ///   maximizes and down from the bottom it puts the window back.
    /// - Any other cell (a quarter, a sixth, a ninth and their spans) moves one
    ///   cell in the swipe's direction. Swiped toward an edge it already
    ///   touches it grows one cell along that edge, away from the corner (a
    ///   cell in the middle of the edge spans all of it): a quarter becomes a
    ///   half, a corner sixth or ninth two of them, and a corner two-ninths
    ///   swiped toward its other edge four-ninths.
    /// - An L-shaped or diagonal swipe picks a quarter outright, from anywhere.
    /// A place the options cannot produce (`usable`) is free-floating.
    static func step(from place: Place?, stroke: Stroke, grid: Grid, almost: Bool = false) -> Move {
        if let cross = stroke.cross, cross.axis != stroke.direction.axis { return .cell(layout(for: stroke)) }
        let current = place.flatMap { usable($0, grid: grid, almost: almost) ? $0 : nil }
        let direction = stroke.direction
        let long = stroke.tier >= 2
        let maximize: Move = almost ? .place(.almostMaximize) : .cell(.maximize)
        switch current {
        case .grid(let cell)?:
            return step(cell, direction, grid: grid, maximize: maximize, long: long)
        case .almostMaximize?:
            switch direction {
            case .left: return .cell(.leftHalf)
            case .right: return .cell(.rightHalf)
            case .up: return .cell(.maximize)
            case .down: return long ? .cell(.bottomHalf) : .restore
            }
        case .center?, nil:
            switch direction {
            case .left: return .cell(grid.thirds && long ? .leftThird : .leftHalf)
            case .right: return .cell(grid.thirds && long ? .rightThird : .rightHalf)
            case .up: return long ? .cell(.topHalf) : maximize
            case .down: return current == .center ? .restore : .cell(long ? .bottomHalf : .center)
            }
        }
    }

    /// `long`: a longer swipe (tier 2). From maximize (or almost-maximize) a
    /// short swipe down puts the window back, as in Swish; a longer one goes
    /// on to the bottom half (3.3.2 review: from maximize nothing reached
    /// the bottom without first restoring), like a longer swipe down on a
    /// free window.
    private static func step(_ cell: SwishGridCell, _ direction: Direction, grid: Grid, maximize: Move,
                             long: Bool = false) -> Move {
        if cell == .full {
            switch direction {
            case .left: return .cell(.leftHalf)
            case .right: return .cell(.rightHalf)
            case .up: return .cell(.maximize)
            case .down: return long ? .cell(.bottomHalf) : .restore
            }
        }
        if direction.axis == .vertical {
            let up = direction == .up
            if cell.fullHeight {
                let rows = cell.columns == 3 ? grid.rowsForThirds : 2
                return .to(.grid(SwishGridCell(columns: cell.columns, rows: rows, column: cell.column,
                                               row: up ? 0 : rows - 1, columnSpan: cell.columnSpan)))
            }
            guard up ? cell.touchesTop : cell.touchesBottom else { return .to(.grid(cell.shifted(rows: up ? -1 : 1))) }
            if cell.fullWidth { return up ? maximize : .restore }
            return .to(.grid(cell.widened()))
        }
        let left = direction == .left
        if cell.fullWidth {
            let columns = cell.rows == 3 ? 3 : 2
            return .to(.grid(SwishGridCell(columns: columns, rows: cell.rows, column: left ? 0 : columns - 1,
                                           row: cell.row, rowSpan: cell.rowSpan)))
        }
        if cell.fullHeight { return columnStep(cell, left: left, thirds: grid.thirds) }
        guard left ? cell.touchesLeft : cell.touchesRight else { return .to(.grid(cell.shifted(columns: left ? -1 : 1))) }
        return .to(.grid(cell.heightened()))
    }

    /// A full-height column swiped sideways: the 3.3.1 table of halves, thirds and two thirds.
    private static func columnStep(_ cell: SwishGridCell, left: Bool, thirds: Bool) -> Move {
        switch (cell.layout, left) {
        case (.leftHalf?, true): return .cell(thirds ? .leftThird : .leftHalf)
        case (.leftHalf?, false): return .cell(.rightHalf)
        case (.rightHalf?, false): return .cell(thirds ? .rightThird : .rightHalf)
        case (.rightHalf?, true): return .cell(.leftHalf)
        case (.leftThird?, true): return .cell(.leftTwoThirds)
        case (.leftThird?, false), (.rightThird?, true): return .cell(.centerThird)
        case (.centerThird?, true): return .cell(.leftThird)
        case (.centerThird?, false): return .cell(.rightThird)
        case (.rightThird?, false): return .cell(.rightTwoThirds)
        case (.leftTwoThirds?, true), (.rightTwoThirds?, true): return .cell(.leftHalf)
        case (.leftTwoThirds?, false), (.rightTwoThirds?, false): return .cell(.rightHalf)
        default: return .to(.grid(cell))
        }
    }

    // MARK: Frames

    /// The place a frame fills, so the next swipe or hotkey chains from it:
    /// any cell of the grid (and almost-maximize when it is on) within
    /// `tolerance`, or, for an app with a minimum size, the half, quarter or
    /// third it overflows least, as `cell(of:)` finds it. Sixths and ninths
    /// are only matched exactly: AOM's history keeps the place of a
    /// size-limited window it snapped there. Nil: free-floating.
    static func place(of frame: CGRect, visible: CGRect, margin: CGFloat, grid: Grid,
                      almost: Bool = false, tolerance: CGFloat = 16) -> Place? {
        func error(_ rect: CGRect) -> CGFloat {
            max(abs(rect.minX - frame.minX), abs(rect.minY - frame.minY),
                abs(rect.maxX - frame.maxX), abs(rect.maxY - frame.maxY))
        }
        func fits(_ rect: CGRect) -> Bool { error(rect) <= tolerance }
        if almost {
            // On a small display the two are only 16 pt apart: the closer one wins.
            let near = error(almostMaximizeFrame(visible: visible, margin: margin))
            let full = error(targetFrame(place: .grid(.full), visible: visible, margin: margin))
            if near <= tolerance, near < full { return .almostMaximize }
        }
        if let cell = grid.cells.first(where: { fits(targetFrame(place: .grid($0), visible: visible, margin: margin)) }) {
            return .grid(cell)
        }
        return cell(of: frame, visible: visible, margin: margin, tolerance: tolerance, thirds: grid.thirds)
            .flatMap(Place.init)
    }

    /// The window's frame for a place, in Accessibility (top-left)
    /// coordinates within `visible`, each cell inset by `margin`.
    static func targetFrame(place: Place, visible: CGRect, margin: CGFloat) -> CGRect {
        switch place {
        case .almostMaximize:
            return almostMaximizeFrame(visible: visible, margin: margin)
        case .center:
            return targetFrame(layout: .center, visible: visible, margin: margin)
        case .grid(let cell):
            if let layout = cell.layout { return targetFrame(layout: layout, visible: visible, margin: margin) }
            let unit = cell.unitRect
            let rect = CGRect(x: visible.minX + unit.minX * visible.width, y: visible.minY + unit.minY * visible.height,
                              width: unit.width * visible.width, height: unit.height * visible.height)
            return margin > 0 ? rect.insetBy(dx: margin, dy: margin) : rect
        }
    }

    /// Swish's "Almost Maximize": centred, inset by 3 % of each dimension and
    /// at least 16 pt (or the margin, when that is larger).
    static func almostMaximizeFrame(visible: CGRect, margin: CGFloat) -> CGRect {
        let dx = max(16, visible.width * 0.03, margin)
        let dy = max(16, visible.height * 0.03, margin)
        return visible.insetBy(dx: dx, dy: dy)
    }

    /// Swish's "snappingStageManagerOffset": while Stage Manager is on, its
    /// strip of recent apps keeps the left `offset` points of the visible
    /// area (never more than half of it).
    static func stageManagerArea(_ visible: CGRect, offset: CGFloat, stageManager: Bool) -> CGRect {
        guard stageManager, offset > 0, offset.isFinite else { return visible }
        let inset = min(offset, visible.width / 2)
        return CGRect(x: visible.minX + inset, y: visible.minY, width: visible.width - inset, height: visible.height)
    }

    /// Re-snapping after the displays changed (Swish logs "Resnapping after
    /// …"): the frame `place` has on the display the window is on now
    /// (`screens` are the displays' frames, `areas` the areas windows snap in
    /// on them), or nil when the window already sits there or no display
    /// holds it.
    static func resnapFrame(place: Place, current: CGRect, screens: [CGRect], areas: [CGRect],
                            margin: CGFloat) -> CGRect? {
        guard screens.count == areas.count,
              let index = WindowGeometry.screenIndex(for: current, screens: screens) else { return nil }
        let target = targetFrame(place: place, visible: areas[index], margin: margin)
        return WindowGeometry.close(target, current) ? nil : target
    }

    /// Swish and Windows: dragging a snapped window by its title bar gives it
    /// back its size from before the snap, under the pointer. The pointer
    /// keeps its relative position along the title bar and its distance from
    /// the top edge. `grab` is where the button went down on the `snapped`
    /// frame, `pointer` where it is now; top-left coordinates.
    static func unsnapDragFrame(snapped: CGRect, original: CGSize, grab: CGPoint, pointer: CGPoint) -> CGRect {
        let share = snapped.width > 0 ? min(max((grab.x - snapped.minX) / snapped.width, 0), 1) : 0.5
        let fromTop = min(max(grab.y - snapped.minY, 0), max(0, original.height - 1))
        return CGRect(x: pointer.x - share * original.width, y: pointer.y - fromTop,
                      width: original.width, height: original.height)
    }

    // MARK: Resizing adjacent windows (Swish "snappingResizeAdjacent")

    /// A side of a window.
    enum Edge: CaseIterable, Equatable { case left, right, top, bottom }

    /// The side of `a` that `b` sits against: their facing edges within
    /// `tolerance` of each other (a margin's gap counts, a small overlap too)
    /// and overlapping along it by at least `minimumOverlap`.
    static func sharedEdge(of a: CGRect, with b: CGRect, tolerance: CGFloat = 8,
                           minimumOverlap: CGFloat = 40) -> Edge? {
        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        if overlapY >= minimumOverlap {
            if abs(b.minX - a.maxX) <= tolerance { return .right }
            if abs(a.minX - b.maxX) <= tolerance { return .left }
        }
        if overlapX >= minimumOverlap {
            if abs(b.minY - a.maxY) <= tolerance { return .bottom }
            if abs(a.minY - b.maxY) <= tolerance { return .top }
        }
        return nil
    }

    /// The edges a user resize moved: on each axis the one edge that moved
    /// while the other stayed put (a corner moves one of each). A window that
    /// moved (both edges of an axis shifted) was not resized: none.
    static func resizedEdges(from before: CGRect, to after: CGRect, tolerance: CGFloat = 3) -> [Edge] {
        func moved(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > tolerance }
        let left = moved(before.minX, after.minX), right = moved(before.maxX, after.maxX)
        let top = moved(before.minY, after.minY), bottom = moved(before.maxY, after.maxY)
        if (left && right) || (top && bottom) { return [] }
        let candidates: [(moved: Bool, edge: Edge)] = [(left, .left), (right, .right), (top, .top), (bottom, .bottom)]
        return candidates.filter { $0.moved }.map { $0.edge }
    }

    /// The neighbour's frame once its edge against `edge` of the resized
    /// window follows that window's new frame, keeping the gap between them.
    /// Nil when that would leave the neighbour narrower or shorter than
    /// `minimum`.
    static func followingFrame(neighbour: CGRect, resizedBefore before: CGRect, resizedAfter after: CGRect,
                               edge: Edge, minimum: CGFloat = 120) -> CGRect? {
        var frame = neighbour
        switch edge {
        case .right:
            let minX = after.maxX + (neighbour.minX - before.maxX)
            frame = CGRect(x: minX, y: neighbour.minY, width: neighbour.maxX - minX, height: neighbour.height)
        case .left:
            let maxX = after.minX - (before.minX - neighbour.maxX)
            frame = CGRect(x: neighbour.minX, y: neighbour.minY, width: maxX - neighbour.minX, height: neighbour.height)
        case .bottom:
            let minY = after.maxY + (neighbour.minY - before.maxY)
            frame = CGRect(x: neighbour.minX, y: minY, width: neighbour.width, height: neighbour.maxY - minY)
        case .top:
            let maxY = after.minY - (before.minY - neighbour.maxY)
            frame = CGRect(x: neighbour.minX, y: neighbour.minY, width: neighbour.width, height: maxY - neighbour.minY)
        }
        guard frame.width >= minimum, frame.height >= minimum else { return nil }
        return frame
    }

    /// Swish's "Drag the divider to resize multiple windows at once", in one
    /// pass when the button comes up: of the snapped windows sharing an edge
    /// (`before`, read when the button went down), exactly one was resized
    /// (`after`); the others that shared an edge it moved and did not change
    /// themselves follow it. Returns their new frames by key.
    static func adjacentMoves(before: [String: CGRect], after: [String: CGRect], tolerance: CGFloat = 8,
                              minimum: CGFloat = 120) -> [String: CGRect] {
        let changed = before.compactMap { key, frame -> String? in
            guard let now = after[key] else { return nil }
            return WindowGeometry.close(frame, now) ? nil : key
        }
        guard changed.count == 1, let key = changed.first, let old = before[key], let new = after[key] else { return [:] }
        let edges = resizedEdges(from: old, to: new)
        guard !edges.isEmpty else { return [:] }
        var moves: [String: CGRect] = [:]
        for (other, frame) in before where other != key {
            guard let now = after[other], WindowGeometry.close(frame, now),
                  let edge = sharedEdge(of: old, with: frame, tolerance: tolerance), edges.contains(edge),
                  let next = followingFrame(neighbour: frame, resizedBefore: old, resizedAfter: new,
                                            edge: edge, minimum: minimum) else { continue }
            moves[other] = next
        }
        return moves
    }

    /// The windows whose shared edge passes within `reach` of a point (the
    /// button going down), from their snapped frames: the only ones the
    /// resize-adjacent pass reads. Top-left coordinates.
    static func edgeCandidates(at point: CGPoint, frames: [String: CGRect], tolerance: CGFloat = 8,
                               reach: CGFloat = 12) -> Set<String> {
        var keys = Set<String>()
        let list = Array(frames)
        for (index, first) in list.enumerated() {
            for second in list[(index + 1)...] {
                // Each pair once, ordered so `a` is the left or upper window.
                for (a, b) in [(first, second), (second, first)] {
                    guard let edge = sharedEdge(of: a.value, with: b.value, tolerance: tolerance) else { continue }
                    let near: Bool
                    switch edge {
                    case .right:
                        near = point.x >= a.value.maxX - reach && point.x <= b.value.minX + reach
                            && point.y >= max(a.value.minY, b.value.minY) - reach
                            && point.y <= min(a.value.maxY, b.value.maxY) + reach
                    case .bottom:
                        near = point.y >= a.value.maxY - reach && point.y <= b.value.minY + reach
                            && point.x >= max(a.value.minX, b.value.minX) - reach
                            && point.x <= min(a.value.maxX, b.value.maxX) + reach
                    case .left, .top:
                        continue
                    }
                    if near { keys.insert(a.key); keys.insert(b.key) }
                }
            }
        }
        return keys
    }

    // MARK: Keyboard hotkeys (Swish's Advanced tab)

    /// The four keys that, with ⌃⌥, swipe the front window in their
    /// direction. Key codes are US key positions, so they stay put on other
    /// layouts.
    enum HotkeyScheme: String, CaseIterable {
        case off, arrows, wasd, ijkl, hjkl

        /// Key codes for left, right, up and down; nil when off.
        var keyCodes: (left: UInt16, right: UInt16, up: UInt16, down: UInt16)? {
            switch self {
            case .off: return nil
            case .arrows: return (123, 124, 126, 125)
            case .wasd: return (0, 2, 13, 1)        // A D W S
            case .ijkl: return (38, 37, 34, 40)     // J L I K
            case .hjkl: return (4, 37, 40, 38)      // H L K J (vi)
            }
        }
    }

    /// The hotkeys' modifiers: ⌃⌥ (Control-Option), nothing else.
    static let hotkeyModifiers: NSEvent.ModifierFlags = [.control, .option]

    /// The swipe a key press stands for, or nil. Arrow keys carry the
    /// function and numeric-pad flags, so those are ignored; ⌘ or ⇧ never match.
    static func hotkeyDirection(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, scheme: HotkeyScheme) -> Direction? {
        guard let keys = scheme.keyCodes,
              modifiers.intersection([.command, .option, .control, .shift]) == hotkeyModifiers else { return nil }
        switch keyCode {
        case keys.left: return .left
        case keys.right: return .right
        case keys.up: return .up
        case keys.down: return .down
        default: return nil
        }
    }

    // MARK: Preview animation (Swish "tooltipAnimationTime")

    enum AnimationSpeed: String, CaseIterable {
        case fast, normal, off

        var scale: Double {
            switch self {
            case .fast: return 0.5
            case .normal: return 1
            case .off: return 0
            }
        }
    }

    /// How long a preview animation lasts: `base` scaled by the speed, none
    /// at all when animation is off, and no frame motion under Reduce Motion
    /// (fades still run).
    static func animationDuration(_ base: Double, speed: AnimationSpeed, reduceMotion: Bool, movesFrame: Bool) -> Double {
        guard !(reduceMotion && movesFrame) else { return 0 }
        return max(0, base * speed.scale)
    }
}

// MARK: - Chaining during a commit (3.3.2 review)

/// A title-bar swipe that engaged while the previous commit was still
/// landing: its latest stroke, and whether its fingers have lifted. An app
/// that does not apply Accessibility writes at once keeps a commit in flight
/// for a few hundred milliseconds, and until the review such a second swipe
/// (left, then down for a quarter) was dropped. The service applies it to the
/// window that just moved once the commit lands. Pure.
struct SwishChainQueue: Equatable {
    struct Pending: Equatable {
        var stroke: SwishSnap.Stroke
        var lifted: Bool
    }

    private(set) var pending: Pending?

    /// A swipe engaged during the commit; a newer one replaces it.
    mutating func began(_ stroke: SwishSnap.Stroke) { pending = Pending(stroke: stroke, lifted: false) }

    /// Its stroke changed (direction, tier, a cross leg) before the commit landed.
    mutating func updated(_ stroke: SwishSnap.Stroke) {
        guard pending?.lifted == false else { return }
        pending?.stroke = stroke
    }

    /// Its fingers lifted before the commit landed.
    mutating func liftedFingers() { pending?.lifted = true }

    /// The touch still on the pad was cancelled (held still, a third finger,
    /// the watchdog). A swipe whose fingers already lifted stays: a later
    /// touch's cancel is not its own.
    mutating func cancelTouch() {
        if pending?.lifted == false { pending = nil }
    }

    /// The commit landed: what to apply now. Nothing after a failed commit
    /// (the window did not move, so where the stroke starts is unknown).
    mutating func landed(succeeded: Bool) -> Pending? {
        defer { pending = nil }
        return succeeded ? pending : nil
    }
}
