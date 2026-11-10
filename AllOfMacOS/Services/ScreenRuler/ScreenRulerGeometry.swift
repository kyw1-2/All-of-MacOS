import CoreGraphics
import Foundation

/// A pixel position in a display's captured image (top row 0, left column 0).
struct ScreenRulerPixel: Equatable, Hashable {
    var x: Int
    var y: Int
}

/// A rectangle of whole pixels in a display's captured image.
struct ScreenRulerPixelRect: Equatable, Hashable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var minX: Int { x }
    var minY: Int { y }
    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The smallest rect holding both pixels (each pixel counts whole).
    init(spanning a: ScreenRulerPixel, _ b: ScreenRulerPixel) {
        x = min(a.x, b.x)
        y = min(a.y, b.y)
        width = abs(a.x - b.x) + 1
        height = abs(a.y - b.y) + 1
    }

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The part inside a `width` × `height` image; empty when outside it.
    func clamped(width imageWidth: Int, height imageHeight: Int) -> ScreenRulerPixelRect {
        let left = min(max(0, minX), imageWidth)
        let top = min(max(0, minY), imageHeight)
        let right = min(max(0, maxX), imageWidth)
        let bottom = min(max(0, maxY), imageHeight)
        return ScreenRulerPixelRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }
}

/// One display as the ruler sees it: its frame in global points with a
/// top-left origin (the space of ScreenCaptureKit, Quartz events and
/// `CGWarpMouseCursorPosition`), its backing scale and its pixel size.
///
/// Three coordinate spaces meet here:
/// - global points: top-left of the primary display is (0, 0), y grows down;
/// - display points: the same, relative to this display's top-left corner;
/// - image pixels: display points × scale, whole numbers, row 0 at the top.
struct ScreenRulerDisplay: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int

    init(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat) {
        self.init(id: id, frame: frame, scale: scale,
                  pixelWidth: Int((frame.width * scale).rounded()), pixelHeight: Int((frame.height * scale).rounded()))
    }

    init(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.frame = frame
        self.scale = max(scale, 0.01)
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
    }

    /// Half-open containment, so a point on the seam between two displays
    /// belongs to exactly one of them.
    func contains(_ global: CGPoint) -> Bool {
        global.x >= frame.minX && global.x < frame.maxX && global.y >= frame.minY && global.y < frame.maxY
    }

    func localPoint(fromGlobal global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - frame.minX, y: global.y - frame.minY)
    }

    func globalPoint(fromLocal local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + frame.minX, y: local.y + frame.minY)
    }

    /// The pixel under a global point, kept inside the image.
    func pixel(atGlobal global: CGPoint) -> ScreenRulerPixel {
        pixel(atLocal: localPoint(fromGlobal: global))
    }

    func pixel(atLocal local: CGPoint) -> ScreenRulerPixel {
        func index(_ value: CGFloat, _ count: Int) -> Int {
            guard value.isFinite else { return 0 }
            return min(max(0, Int((value * scale).rounded(.down))), count - 1)
        }
        return ScreenRulerPixel(x: index(local.x, pixelWidth), y: index(local.y, pixelHeight))
    }

    /// A pixel boundary (the left/top edge of pixel `x`/`y`) in display points.
    func localPoint(pixelX x: CGFloat, pixelY y: CGFloat) -> CGPoint {
        CGPoint(x: x / scale, y: y / scale)
    }

    /// The centre of a pixel in global points (where a nudge puts the pointer).
    func globalCenter(of pixel: ScreenRulerPixel) -> CGPoint {
        globalPoint(fromLocal: localPoint(pixelX: CGFloat(pixel.x) + 0.5, pixelY: CGFloat(pixel.y) + 0.5))
    }

    /// A pixel rect in display points.
    func localRect(_ rect: ScreenRulerPixelRect) -> CGRect {
        CGRect(x: CGFloat(rect.x) / scale, y: CGFloat(rect.y) / scale,
               width: CGFloat(rect.width) / scale, height: CGFloat(rect.height) / scale)
    }

    func globalRect(_ rect: ScreenRulerPixelRect) -> CGRect {
        localRect(rect).offsetBy(dx: frame.minX, dy: frame.minY)
    }

    /// The nearest point on this display (a drag keeps to the display it started on).
    func clamped(_ global: CGPoint) -> CGPoint {
        let inset = 0.5 / scale
        return CGPoint(x: min(max(frame.minX, global.x), frame.maxX - inset),
                       y: min(max(frame.minY, global.y), frame.maxY - inset))
    }
}

enum ScreenRulerGeometry {
    /// AppKit's global space (origin at the primary display's bottom-left,
    /// y up, `NSEvent.mouseLocation`, `NSScreen.frame`) to global top-left points.
    static func globalPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// An `NSScreen.frame` (bottom-left origin) as a global top-left frame.
    static func globalRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display holding the point, else the nearest one.
    static func display(containing point: CGPoint, in displays: [ScreenRulerDisplay]) -> ScreenRulerDisplay? {
        if let exact = displays.first(where: { $0.contains(point) }) { return exact }
        return displays.min { distance(point, $0.frame) < distance(point, $1.frame) }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// A pixel count in the chosen unit on a display of `scale`.
    static func value(pixels: Int, scale: CGFloat, unit: ScreenRulerUnit) -> Double {
        switch unit {
        case .pixels: return Double(pixels)
        case .points: return points(fromPixels: pixels, scale: scale)
        }
    }

    static func points(fromPixels pixels: Int, scale: CGFloat) -> Double {
        Double(pixels) / Double(max(scale, 0.01))
    }

    static func pixels(fromPoints points: Double, scale: CGFloat) -> Double {
        points * Double(scale)
    }
}
