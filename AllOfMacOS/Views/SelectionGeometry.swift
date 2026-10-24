import AppKit
import CoreGraphics

/// The All-In-One aspect-ratio lock (CleanShot `oneOverlayLastSelectedRatio`).
///
/// `width`/`height` of zero means Freeform. Ratios are unit-free, so the same
/// value applies to points and pixels (the backing scale is uniform).
struct SelectionAspectRatio: Hashable, Identifiable {
    var width: Double
    var height: Double
    var isCustom: Bool = false

    var id: String { storageValue }

    static let freeform = SelectionAspectRatio(width: 0, height: 0)

    /// Menu order: Freeform, landscape presets, portrait presets, then Custom….
    static let presets: [SelectionAspectRatio] = [
        .init(width: 1, height: 1), .init(width: 4, height: 3), .init(width: 3, height: 2),
        .init(width: 16, height: 10), .init(width: 16, height: 9), .init(width: 21, height: 9),
        .init(width: 9, height: 16), .init(width: 3, height: 4), .init(width: 2, height: 3),
    ]

    var isFreeform: Bool { !(width > 0 && height > 0) }

    /// Width ÷ height, or nil for Freeform.
    var value: CGFloat? { isFreeform ? nil : CGFloat(width / height) }

    var title: String {
        if isFreeform { return "Freeform" }
        return "\(Self.format(width)):\(Self.format(height))"
    }

    var menuTitle: String { isCustom ? "Custom (\(title))" : title }

    /// "freeform", "16:9" or "custom:5:4".
    var storageValue: String {
        if isFreeform { return "freeform" }
        return (isCustom ? "custom:" : "") + "\(Self.format(width)):\(Self.format(height))"
    }

    init(width: Double, height: Double, isCustom: Bool = false) {
        self.width = width
        self.height = height
        self.isCustom = isCustom
    }

    init?(storageValue: String) {
        if storageValue == "freeform" { self = .freeform; return }
        var parts = storageValue.split(separator: ":").map(String.init)
        var custom = false
        if parts.first == "custom" { custom = true; parts.removeFirst() }
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
              let ratio = Self.custom(width: w, height: h) else { return nil }
        self = custom ? ratio : SelectionAspectRatio(width: w, height: h)
    }

    /// A validated custom ratio; nil for non-finite, non-positive or absurd values.
    static func custom(width: Double, height: Double) -> SelectionAspectRatio? {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 100_000, height <= 100_000, width / height <= 100, height / width <= 100 else { return nil }
        return SelectionAspectRatio(width: width, height: height, isCustom: true)
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Remembers the last All-In-One ratio across sessions.
enum SelectionAspectRatioStore {
    static let lastRatioKey = "AOMAllInOneLastRatio"

    static func load(_ defaults: UserDefaults = .standard) -> SelectionAspectRatio {
        defaults.string(forKey: lastRatioKey).flatMap(SelectionAspectRatio.init(storageValue:)) ?? .freeform
    }

    static func save(_ ratio: SelectionAspectRatio, _ defaults: UserDefaults = .standard) {
        defaults.set(ratio.storageValue, forKey: lastRatioKey)
    }
}

/// The eight resize handles on the pending All-In-One selection.
enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight }

    /// -1 moves the left edge, +1 the right edge, 0 leaves x alone (top-left origin).
    var xDirection: CGFloat {
        switch self {
        case .topLeft, .left, .bottomLeft: return -1
        case .topRight, .right, .bottomRight: return 1
        case .top, .bottom: return 0
        }
    }

    /// -1 moves the top edge, +1 the bottom edge, 0 leaves y alone.
    var yDirection: CGFloat {
        switch self {
        case .topLeft, .top, .topRight: return -1
        case .bottomLeft, .bottom, .bottomRight: return 1
        case .left, .right: return 0
        }
    }

    var accessibilityName: String {
        switch self {
        case .topLeft: return "Top-left resize handle"
        case .top: return "Top resize handle"
        case .topRight: return "Top-right resize handle"
        case .right: return "Right resize handle"
        case .bottomRight: return "Bottom-right resize handle"
        case .bottom: return "Bottom resize handle"
        case .bottomLeft: return "Bottom-left resize handle"
        case .left: return "Left resize handle"
        }
    }

    /// The handle under `point`, preferring corners; `tolerance` is the hit radius.
    static func hit(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat = 7) -> SelectionHandle? {
        let ordered = allCases.filter(\.isCorner) + allCases.filter { !$0.isCorner }
        for handle in ordered {
            let p = handle.position(in: rect)
            if abs(point.x - p.x) <= tolerance && abs(point.y - p.y) <= tolerance { return handle }
        }
        // Edges are grabbable along their whole length, as in CleanShot.
        let inY = point.y > rect.minY + tolerance && point.y < rect.maxY - tolerance
        let inX = point.x > rect.minX + tolerance && point.x < rect.maxX - tolerance
        if inY && abs(point.x - rect.minX) <= tolerance / 2 { return .left }
        if inY && abs(point.x - rect.maxX) <= tolerance / 2 { return .right }
        if inX && abs(point.y - rect.minY) <= tolerance / 2 { return .top }
        if inX && abs(point.y - rect.maxY) <= tolerance / 2 { return .bottom }
        return nil
    }

    /// The system resize cursor for this handle.
    @MainActor var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

/// Pure, AppKit-free selection geometry (top-left origin), shared by the new
/// drag and the handle resize so the ratio lock behaves identically in both.
enum SelectionGeometry {
    static let minimumSide: CGFloat = 4

    /// A new selection dragged from `anchor` to `current`.
    /// - Parameters:
    ///   - ratio: width ÷ height lock, nil for freeform.
    ///   - fromCenter: ⌥ — `anchor` is the centre rather than a corner.
    ///   - bounds: the rect never leaves these bounds (ratio is preserved when clamping).
    /// Snap guides: the x and y positions of on-screen window and display
    /// edges (global top-left points).
    struct SnapGuides: Equatable {
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []

        init(xs: [CGFloat] = [], ys: [CGFloat] = []) {
            self.xs = Array(Set(xs)).sorted()
            self.ys = Array(Set(ys)).sorted()
        }

        init(rects: [CGRect]) {
            self.init(xs: rects.flatMap { [$0.minX, $0.maxX] }, ys: rects.flatMap { [$0.minY, $0.maxY] })
        }
    }

    /// Moves each coordinate of `point` onto the nearest guide within
    /// `threshold`; coordinates with no guide that close are unchanged.
    static func snapped(_ point: CGPoint, to guides: SnapGuides, threshold: CGFloat = 6) -> CGPoint {
        func nearest(_ value: CGFloat, _ candidates: [CGFloat]) -> CGFloat {
            guard let best = candidates.min(by: { abs($0 - value) < abs($1 - value) }),
                  abs(best - value) <= threshold else { return value }
            return best
        }
        return CGPoint(x: nearest(point.x, guides.xs), y: nearest(point.y, guides.ys))
    }

    static func dragRect(anchor: CGPoint, current: CGPoint, ratio: CGFloat?, fromCenter: Bool,
                         bounds: CGRect) -> CGRect {
        let dx = current.x - anchor.x, dy = current.y - anchor.y
        let sx: CGFloat = dx >= 0 ? 1 : -1
        let sy: CGFloat = dy >= 0 ? 1 : -1
        var w = abs(dx) * (fromCenter ? 2 : 1)
        var h = abs(dy) * (fromCenter ? 2 : 1)
        if let ratio, ratio > 0 { (w, h) = fitRatio(w: w, h: h, ratio: ratio) }

        // Room available from the anchor in the drag direction.
        let maxW: CGFloat, maxH: CGFloat
        if fromCenter {
            maxW = 2 * max(0, min(anchor.x - bounds.minX, bounds.maxX - anchor.x))
            maxH = 2 * max(0, min(anchor.y - bounds.minY, bounds.maxY - anchor.y))
        } else {
            maxW = max(0, sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX)
            maxH = max(0, sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY)
        }
        (w, h) = clampSize(w: w, h: h, maxW: maxW, maxH: maxH, ratio: ratio)

        let x = fromCenter ? anchor.x - w / 2 : (sx > 0 ? anchor.x : anchor.x - w)
        let y = fromCenter ? anchor.y - h / 2 : (sy > 0 ? anchor.y : anchor.y - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// `original` resized by dragging `handle` to `point`.
    /// - Parameters:
    ///   - ratio: width ÷ height to keep (a ratio lock, or ⇧ with the current ratio).
    ///   - fromCenter: ⌥ — opposite edges move symmetrically about the centre.
    static func resize(_ original: CGRect, handle: SelectionHandle, to point: CGPoint,
                       ratio: CGFloat?, fromCenter: Bool, bounds: CGRect,
                       minimum: CGFloat = minimumSide) -> CGRect {
        let center = CGPoint(x: original.midX, y: original.midY)
        // The fixed coordinate on each axis (opposite edge), when not from centre.
        let anchorX = handle.xDirection > 0 ? original.minX : original.maxX
        let anchorY = handle.yDirection > 0 ? original.minY : original.maxY

        var w = original.width, h = original.height
        if handle.xDirection != 0 {
            w = fromCenter ? 2 * abs(point.x - center.x) : (point.x - anchorX) * handle.xDirection
        }
        if handle.yDirection != 0 {
            h = fromCenter ? 2 * abs(point.y - center.y) : (point.y - anchorY) * handle.yDirection
        }
        w = max(minimum, w)
        h = max(minimum, h)

        if let ratio, ratio > 0 {
            if handle.isCorner {
                (w, h) = fitRatio(w: w, h: h, ratio: ratio)
            } else if handle.xDirection != 0 {
                h = w / ratio
            } else {
                w = h * ratio
            }
        }

        // An axis is centred when resizing from the centre, or when a ratio
        // lock drags the perpendicular axis of an edge handle along.
        let centeredX = fromCenter || handle.xDirection == 0
        let centeredY = fromCenter || handle.yDirection == 0
        let maxW = centeredX
            ? 2 * max(0, min(center.x - bounds.minX, bounds.maxX - center.x))
            : max(0, handle.xDirection > 0 ? bounds.maxX - anchorX : anchorX - bounds.minX)
        let maxH = centeredY
            ? 2 * max(0, min(center.y - bounds.minY, bounds.maxY - center.y))
            : max(0, handle.yDirection > 0 ? bounds.maxY - anchorY : anchorY - bounds.minY)
        // Without a ratio, an untouched axis keeps its size.
        let lockedW = ratio == nil && handle.xDirection == 0
        let lockedH = ratio == nil && handle.yDirection == 0
        (w, h) = clampSize(w: w, h: h, maxW: lockedW ? .greatestFiniteMagnitude : maxW,
                           maxH: lockedH ? .greatestFiniteMagnitude : maxH, ratio: ratio)

        let x: CGFloat
        if lockedW { x = original.minX }
        else if centeredX { x = center.x - w / 2 }
        else { x = handle.xDirection > 0 ? anchorX : anchorX - w }
        let y: CGFloat
        if lockedH { y = original.minY }
        else if centeredY { y = center.y - h / 2 }
        else { y = handle.yDirection > 0 ? anchorY : anchorY - h }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Re-shapes an existing selection to `ratio`, keeping its centre and
    /// area-ish size (the width is kept when it fits), clamped to `bounds`.
    static func applying(ratio: CGFloat?, to rect: CGRect, within bounds: CGRect) -> CGRect {
        guard let ratio, ratio > 0, rect.width > 0, rect.height > 0 else { return rect }
        var w = rect.width, h = rect.width / ratio
        (w, h) = clampSize(w: w, h: h, maxW: bounds.width, maxH: bounds.height, ratio: ratio)
        let proposed = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        return AllInOneSelection.clamped(proposed, within: bounds)
    }

    /// The W × H fields (in pixels) with a ratio lock: the edited dimension wins.
    static func lockedSize(width: CGFloat?, height: CGFloat?, current: CGSize, ratio: CGFloat?) -> CGSize {
        var size = CGSize(width: width ?? current.width, height: height ?? current.height)
        guard let ratio, ratio > 0 else { return size }
        if let width, abs(width - current.width) >= 0.5 { size.height = (width / ratio).rounded() }
        else { size.width = (size.height * ratio).rounded() }
        return size
    }

    /// The larger of the two dimensions dictates the size, so the rect keeps
    /// following the pointer instead of lagging behind it.
    private static func fitRatio(w: CGFloat, h: CGFloat, ratio: CGFloat) -> (CGFloat, CGFloat) {
        if w / ratio >= h { return (w, w / ratio) }
        return (h * ratio, h)
    }

    private static func clampSize(w: CGFloat, h: CGFloat, maxW: CGFloat, maxH: CGFloat,
                                  ratio: CGFloat?) -> (CGFloat, CGFloat) {
        if let ratio, ratio > 0 {
            let factor = min(1, maxW / max(w, 0.0001), maxH / max(h, 0.0001))
            return (w * factor, w * factor / ratio)
        }
        return (min(w, maxW), min(h, maxH))
    }
}
