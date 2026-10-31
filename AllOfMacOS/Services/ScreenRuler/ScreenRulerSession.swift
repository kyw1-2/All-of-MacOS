import CoreGraphics
import Foundation

/// A display's frozen pixels and where they sit.
struct ScreenRulerSnapshot {
    let display: ScreenRulerDisplay
    let bitmap: ScreenRulerBitmap

    init(display: ScreenRulerDisplay, bitmap: ScreenRulerBitmap) {
        // The image decides the pixel grid: if a capture came back at another
        // size than asked, its own size (and so its scale) is the truth.
        self.display = ScreenRulerDisplay(id: display.id, frame: display.frame,
                                          scale: display.frame.width > 0 ? CGFloat(bitmap.width) / display.frame.width : display.scale,
                                          pixelWidth: bitmap.width, pixelHeight: bitmap.height)
        self.bitmap = bitmap
    }
}

/// The hover measurement: the runs of the start pixel's colour left/right
/// and up/down from the pointer, edge to edge.
struct ScreenRulerDistances: Equatable {
    let display: ScreenRulerDisplay
    let pixel: ScreenRulerPixel
    let horizontal: ScreenRulerSpan
    let vertical: ScreenRulerSpan
}

/// A dragged box, as drawn or shrunk to the content inside it.
struct ScreenRulerArea: Equatable {
    let display: ScreenRulerDisplay
    let rect: ScreenRulerPixelRect
    /// Shrunk to content (PixelSnap's snap) rather than kept as drawn.
    let snapped: Bool
}

enum ScreenRulerMeasurement: Equatable {
    case distances(ScreenRulerDistances)
    case area(ScreenRulerArea)

    var display: ScreenRulerDisplay {
        switch self {
        case .distances(let distances): return distances.display
        case .area(let area): return area.display
        }
    }

    /// Width and height in pixels.
    var pixelSize: (width: Int, height: Int) {
        switch self {
        case .distances(let distances): return (distances.horizontal.length, distances.vertical.length)
        case .area(let area): return (area.rect.width, area.rect.height)
        }
    }

    func size(in unit: ScreenRulerUnit) -> (width: Double, height: Double) {
        let pixels = pixelSize
        let scale = display.scale
        return (ScreenRulerGeometry.value(pixels: pixels.width, scale: scale, unit: unit),
                ScreenRulerGeometry.value(pixels: pixels.height, scale: scale, unit: unit))
    }
}

/// The measuring session's state machine, free of AppKit so it can be tested
/// with synthetic bitmaps. The overlay feeds it pointer and key input in
/// global top-left points and draws what it holds.
///
///     hovering ──press──▶ dragging ──release──▶ hovering (area in focus)
///         ▲  │ move: live distances      │ move: box follows
///         │  └ ⇧ hold · ⌘C copy · Space unit · arrows nudge
///         └──────────── Esc / right-click / hotkey ──▶ exited
struct ScreenRulerSession {
    enum Phase: Equatable { case hovering, dragging, exited }

    /// A press that moves less than this (in points) is a click, not a box.
    static let clickSlop: CGFloat = 3

    let snapshots: [ScreenRulerSnapshot]
    var options: ScreenRulerOptions

    private(set) var phase: Phase = .hovering
    /// The unit shown now; starts at the setting, Space flips it.
    private(set) var unit: ScreenRulerUnit
    /// The pointer in global top-left points.
    private(set) var pointer: CGPoint?
    /// The distances at the pointer, updated on every move while hovering.
    private(set) var live: ScreenRulerDistances?
    /// The box being dragged (drawn as is) while dragging.
    private(set) var dragArea: ScreenRulerArea?
    /// The last finished box; it stays in focus until the next press.
    private(set) var area: ScreenRulerArea?
    /// Measurements kept on screen with ⇧, oldest first.
    private(set) var held: [ScreenRulerMeasurement] = []
    /// The last text ⌘C produced.
    private(set) var lastCopied: String?

    private var dragAnchor: CGPoint?
    private var dragSnapshotIndex: Int?

    init(snapshots: [ScreenRulerSnapshot], options: ScreenRulerOptions) {
        self.snapshots = snapshots
        self.options = options
        self.unit = options.unit
    }

    var displays: [ScreenRulerDisplay] { snapshots.map(\.display) }
    var isActive: Bool { phase != .exited }

    /// What ⌘C copies and ⇧ keeps: the finished box while it is on screen,
    /// otherwise the distances at the pointer.
    var focus: ScreenRulerMeasurement? {
        if let area { return .area(area) }
        return live.map(ScreenRulerMeasurement.distances)
    }

    // MARK: - Pointer

    mutating func move(to point: CGPoint) {
        guard isActive else { return }
        switch phase {
        case .hovering:
            pointer = point
            live = distances(at: point)
        case .dragging:
            guard let index = dragSnapshotIndex, let anchor = dragAnchor else { return }
            let display = snapshots[index].display
            let current = display.clamped(point)
            pointer = current
            dragArea = ScreenRulerArea(display: display,
                                       rect: ScreenRulerPixelRect(spanning: display.pixel(atGlobal: anchor),
                                                                  display.pixel(atGlobal: current)),
                                       snapped: false)
        case .exited:
            break
        }
    }

    mutating func press(at point: CGPoint) {
        guard phase == .hovering, let index = snapshotIndex(containing: point) else { return }
        let display = snapshots[index].display
        let anchor = display.clamped(point)
        phase = .dragging
        dragSnapshotIndex = index
        dragAnchor = anchor
        pointer = anchor
        // A new press replaces the box in focus (a held copy stays).
        area = nil
        live = nil
        dragArea = ScreenRulerArea(display: display,
                                   rect: ScreenRulerPixelRect(spanning: display.pixel(atGlobal: anchor),
                                                              display.pixel(atGlobal: anchor)),
                                   snapped: false)
    }

    /// Ends a drag. `keepsAsDrawn` (⌥) skips the shrink to content.
    mutating func release(at point: CGPoint, keepsAsDrawn: Bool = false) {
        guard phase == .dragging, let index = dragSnapshotIndex, let anchor = dragAnchor else { return }
        let snapshot = snapshots[index]
        let display = snapshot.display
        let end = display.clamped(point)
        phase = .hovering
        dragSnapshotIndex = nil
        dragAnchor = nil
        dragArea = nil
        if hypot(end.x - anchor.x, end.y - anchor.y) >= Self.clickSlop {
            let drawn = ScreenRulerPixelRect(spanning: display.pixel(atGlobal: anchor), display.pixel(atGlobal: end))
            if options.snapsArea, !keepsAsDrawn,
               let content = snapshot.bitmap.contentBounds(in: drawn, tolerance: options.tolerance) {
                area = ScreenRulerArea(display: display, rect: content, snapped: true)
            } else {
                area = ScreenRulerArea(display: display, rect: drawn, snapped: false)
            }
        }
        // A click only clears the box in focus.
        pointer = end
        live = distances(at: end)
    }

    // MARK: - Keys

    /// ⇧: keeps the measurement in focus on screen. Returns what it kept, or
    /// nil when there was nothing new to keep (pressing ⇧ twice keeps one).
    @discardableResult
    mutating func hold() -> ScreenRulerMeasurement? {
        guard phase == .hovering, let focus, !held.contains(focus) else { return nil }
        held.append(focus)
        return focus
    }

    /// ⌫: removes the newest kept measurement.
    @discardableResult
    mutating func removeLastHeld() -> Bool {
        guard isActive, !held.isEmpty else { return false }
        held.removeLast()
        return true
    }

    /// Space: flips between points and pixels for this session.
    mutating func toggleUnit() {
        guard isActive else { return }
        unit = unit.toggled
    }

    /// ⌘C: the clipboard text for the measurement in focus.
    mutating func copyText() -> String? {
        guard isActive, let focus else { return nil }
        let text = ScreenRulerFormat.copyText(for: focus, unit: unit, format: options.copyFormat)
        lastCopied = text
        return text
    }

    /// Arrow keys: the pointer moved by whole pixels of the display under it,
    /// as a global point at the target pixel's centre (kept on that display).
    func nudgedPointer(dx: Int, dy: Int) -> CGPoint? {
        guard isActive, let pointer else { return nil }
        let index = phase == .dragging ? dragSnapshotIndex : snapshotIndex(containing: pointer)
        guard let index else { return nil }
        let display = snapshots[index].display
        let pixel = display.pixel(atGlobal: pointer)
        let target = ScreenRulerPixel(x: min(max(0, pixel.x + dx), display.pixelWidth - 1),
                                      y: min(max(0, pixel.y + dy), display.pixelHeight - 1))
        return display.globalCenter(of: target)
    }

    /// Esc, right-click or the hotkey: nothing responds afterwards.
    mutating func exit() {
        phase = .exited
        dragArea = nil
        dragAnchor = nil
        dragSnapshotIndex = nil
    }

    // MARK: - Lookups

    func snapshotIndex(containing point: CGPoint) -> Int? {
        guard let display = ScreenRulerGeometry.display(containing: point, in: displays) else { return nil }
        return snapshots.firstIndex { $0.display.id == display.id }
    }

    func snapshot(for displayID: CGDirectDisplayID) -> ScreenRulerSnapshot? {
        snapshots.first { $0.display.id == displayID }
    }

    /// The hover distances at a global point.
    func distances(at point: CGPoint) -> ScreenRulerDistances? {
        guard let index = snapshotIndex(containing: point) else { return nil }
        let snapshot = snapshots[index]
        let pixel = snapshot.display.pixel(atGlobal: snapshot.display.clamped(point))
        guard let horizontal = snapshot.bitmap.span(from: pixel, axis: .horizontal, tolerance: options.tolerance),
              let vertical = snapshot.bitmap.span(from: pixel, axis: .vertical, tolerance: options.tolerance) else { return nil }
        return ScreenRulerDistances(display: snapshot.display, pixel: pixel, horizontal: horizontal, vertical: vertical)
    }

    /// The sRGB hex colour under the pointer.
    var pointerColorHex: String? {
        guard let live, let snapshot = snapshot(for: live.display.id) else { return nil }
        return snapshot.bitmap.srgbHex(at: live.pixel)
    }
}
