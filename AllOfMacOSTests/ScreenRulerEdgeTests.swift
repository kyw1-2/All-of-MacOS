import CoreGraphics
import XCTest
@testable import AllOfMacOS

/// A synthetic screen: RGB fills on an opaque canvas, top row first.
struct ScreenRulerCanvas {
    typealias RGB = (UInt8, UInt8, UInt8)
    static let white: RGB = (255, 255, 255)
    static let black: RGB = (0, 0, 0)

    let width: Int
    let height: Int
    private(set) var bytes: [UInt8]

    init(width: Int, height: Int, color: RGB = ScreenRulerCanvas.white) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 255, count: width * height * 4)
        fill(ScreenRulerPixelRect(x: 0, y: 0, width: width, height: height), color)
    }

    mutating func set(_ x: Int, _ y: Int, _ color: RGB) {
        let index = (y * width + x) * 4
        bytes[index] = color.0
        bytes[index + 1] = color.1
        bytes[index + 2] = color.2
        bytes[index + 3] = 255
    }

    mutating func fill(_ rect: ScreenRulerPixelRect, _ color: RGB) {
        for y in rect.minY..<rect.maxY {
            for x in rect.minX..<rect.maxX { set(x, y, color) }
        }
    }

    var bitmap: ScreenRulerBitmap { ScreenRulerBitmap(width: width, height: height, rgba: bytes)! }

    /// A one-display snapshot of this canvas at `scale`, placed at `origin` (global points).
    func snapshot(id: CGDirectDisplayID = 1, scale: CGFloat = 1, origin: CGPoint = .zero) -> ScreenRulerSnapshot {
        let frame = CGRect(x: origin.x, y: origin.y, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return ScreenRulerSnapshot(display: ScreenRulerDisplay(id: id, frame: frame, scale: scale), bitmap: bitmap)
    }

    /// The canvas as a CGImage, for the render review.
    var image: CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

/// Edge scanning and shrink-wrap on synthetic bitmaps (no screen is read).
final class ScreenRulerEdgeTests: XCTestCase {
    private func span(_ canvas: ScreenRulerCanvas, _ x: Int, _ y: Int, _ axis: ScreenRulerBitmap.Axis,
                      tolerance: Double = 0.1) -> ScreenRulerSpan? {
        canvas.bitmap.span(from: ScreenRulerPixel(x: x, y: y), axis: axis, tolerance: tolerance)
    }

    // MARK: Solid colours

    func testASolidScreenRunsFromBorderToBorder() throws {
        let canvas = ScreenRulerCanvas(width: 40, height: 30, color: (30, 120, 200))
        let h = try XCTUnwrap(span(canvas, 17, 11, .horizontal))
        XCTAssertEqual(h, ScreenRulerSpan(lower: 0, upper: 40, reachesLowerBorder: true, reachesUpperBorder: true))
        let v = try XCTUnwrap(span(canvas, 17, 11, .vertical))
        XCTAssertEqual(v, ScreenRulerSpan(lower: 0, upper: 30, reachesLowerBorder: true, reachesUpperBorder: true))
    }

    func testTheRunStopsAtTheFirstPixelOfAnotherColour() throws {
        var canvas = ScreenRulerCanvas(width: 200, height: 100)
        canvas.fill(ScreenRulerPixelRect(x: 40, y: 20, width: 80, height: 40), (128, 128, 128))
        // Inside the button: its own size.
        let insideH = try XCTUnwrap(span(canvas, 60, 30, .horizontal))
        XCTAssertEqual(insideH, ScreenRulerSpan(lower: 40, upper: 120, reachesLowerBorder: false, reachesUpperBorder: false))
        XCTAssertEqual(insideH.length, 80)
        let insideV = try XCTUnwrap(span(canvas, 60, 30, .vertical))
        XCTAssertEqual(insideV, ScreenRulerSpan(lower: 20, upper: 60, reachesLowerBorder: false, reachesUpperBorder: false))
        // Beside it: the gap from the screen edge to the button.
        let gap = try XCTUnwrap(span(canvas, 10, 40, .horizontal))
        XCTAssertEqual(gap, ScreenRulerSpan(lower: 0, upper: 40, reachesLowerBorder: true, reachesUpperBorder: false))
        let below = try XCTUnwrap(span(canvas, 60, 80, .vertical))
        XCTAssertEqual(below, ScreenRulerSpan(lower: 60, upper: 100, reachesLowerBorder: false, reachesUpperBorder: true))
    }

    func testZeroToleranceCountsAnyDifference() throws {
        var canvas = ScreenRulerCanvas(width: 20, height: 1)
        canvas.set(15, 0, (254, 255, 255))
        XCTAssertEqual(try XCTUnwrap(span(canvas, 2, 0, .horizontal, tolerance: 0)).upper, 15)
        XCTAssertEqual(try XCTUnwrap(span(canvas, 2, 0, .horizontal, tolerance: 0.01)).upper, 20)
    }

    // MARK: Gradients

    func testAGradientWithinToleranceIsOneSurface() throws {
        // 100 → 124 across the row: every pixel within 10% (26) of any start.
        var canvas = ScreenRulerCanvas(width: 25, height: 3)
        for x in 0..<25 { for y in 0..<3 { canvas.set(x, y, (UInt8(100 + x), UInt8(100 + x), UInt8(100 + x))) } }
        let run = try XCTUnwrap(span(canvas, 12, 1, .horizontal, tolerance: 0.1))
        XCTAssertEqual(run, ScreenRulerSpan(lower: 0, upper: 25, reachesLowerBorder: true, reachesUpperBorder: true))
    }

    func testAGradientStopsWhereItDriftsBeyondToleranceFromTheStartPixel() throws {
        // Each step is tiny, but the drift from the start pixel adds up: the
        // edge is where it passes the tolerance, not "never".
        var canvas = ScreenRulerCanvas(width: 101, height: 1)
        for x in 0...100 { canvas.set(x, 0, (UInt8(50 + x), UInt8(50 + x), UInt8(50 + x))) }
        // Start 100 (x = 50), tolerance 4% = 10 → values 90...110 are the same surface.
        let run = try XCTUnwrap(span(canvas, 50, 0, .horizontal, tolerance: 0.04))
        XCTAssertEqual(ScreenRulerBitmap.threshold(for: 0.04), 10)
        XCTAssertEqual(run, ScreenRulerSpan(lower: 40, upper: 61, reachesLowerBorder: false, reachesUpperBorder: false))
    }

    // MARK: Anti-aliasing

    func testAnAntiAliasedEdgeEndsAtTheFirstBlendPastTheTolerance() throws {
        // White, then 10%, 50% and 90% blends into black, then black.
        var canvas = ScreenRulerCanvas(width: 60, height: 1)
        canvas.set(50, 0, (230, 230, 230))
        canvas.set(51, 0, (128, 128, 128))
        canvas.set(52, 0, (26, 26, 26))
        canvas.fill(ScreenRulerPixelRect(x: 53, y: 0, width: 7, height: 1), ScreenRulerCanvas.black)
        // 15% (38): the faint 10% blend still reads as the white surface.
        XCTAssertEqual(try XCTUnwrap(span(canvas, 10, 0, .horizontal, tolerance: 0.15)).upper, 51)
        // 5% (13): the faint blend is already the edge.
        XCTAssertEqual(try XCTUnwrap(span(canvas, 10, 0, .horizontal, tolerance: 0.05)).upper, 50)
        // From inside the black, the 90% blend (26 from black) is within 15%.
        XCTAssertEqual(try XCTUnwrap(span(canvas, 57, 0, .horizontal, tolerance: 0.15)).lower, 52)
    }

    // MARK: Image borders

    func testEdgesAtTheImageBorders() throws {
        var canvas = ScreenRulerCanvas(width: 10, height: 10)
        canvas.fill(ScreenRulerPixelRect(x: 0, y: 0, width: 3, height: 10), (0, 0, 255))
        // The first column: the run starts at the border, ends at the colour change.
        XCTAssertEqual(try XCTUnwrap(span(canvas, 0, 5, .horizontal)),
                       ScreenRulerSpan(lower: 0, upper: 3, reachesLowerBorder: true, reachesUpperBorder: false))
        // The last column and row.
        XCTAssertEqual(try XCTUnwrap(span(canvas, 9, 9, .horizontal)),
                       ScreenRulerSpan(lower: 3, upper: 10, reachesLowerBorder: false, reachesUpperBorder: true))
        XCTAssertEqual(try XCTUnwrap(span(canvas, 9, 9, .vertical)),
                       ScreenRulerSpan(lower: 0, upper: 10, reachesLowerBorder: true, reachesUpperBorder: true))
        // A one-pixel image and a pixel outside the image.
        let dot = ScreenRulerCanvas(width: 1, height: 1)
        XCTAssertEqual(try XCTUnwrap(span(dot, 0, 0, .vertical)),
                       ScreenRulerSpan(lower: 0, upper: 1, reachesLowerBorder: true, reachesUpperBorder: true))
        XCTAssertNil(span(canvas, 10, 0, .horizontal))
        XCTAssertNil(span(canvas, -1, 0, .horizontal))
    }

    // MARK: Shrink-wrap

    func testShrinkWrapFindsTheObjectInsideTheBox() throws {
        var canvas = ScreenRulerCanvas(width: 200, height: 120)
        canvas.fill(ScreenRulerPixelRect(x: 30, y: 40, width: 20, height: 10), ScreenRulerCanvas.black)
        let bounds = canvas.bitmap.contentBounds(in: ScreenRulerPixelRect(x: 10, y: 10, width: 90, height: 90), tolerance: 0.1)
        XCTAssertEqual(bounds, ScreenRulerPixelRect(x: 30, y: 40, width: 20, height: 10))
    }

    func testShrinkWrapKeepsAntiAliasedPixelsAndSeveralObjects() throws {
        var canvas = ScreenRulerCanvas(width: 100, height: 100)
        canvas.fill(ScreenRulerPixelRect(x: 20, y: 20, width: 10, height: 10), ScreenRulerCanvas.black)
        canvas.set(19, 25, (180, 180, 180))  // a blend left of the square
        canvas.fill(ScreenRulerPixelRect(x: 50, y: 60, width: 5, height: 5), (0, 128, 0))
        let bounds = canvas.bitmap.contentBounds(in: ScreenRulerPixelRect(x: 5, y: 5, width: 80, height: 80), tolerance: 0.1)
        XCTAssertEqual(bounds, ScreenRulerPixelRect(x: 19, y: 20, width: 36, height: 45))
        // A blend inside the tolerance is background.
        var faint = ScreenRulerCanvas(width: 40, height: 40)
        faint.fill(ScreenRulerPixelRect(x: 10, y: 10, width: 4, height: 4), ScreenRulerCanvas.black)
        faint.set(9, 12, (250, 250, 250))
        XCTAssertEqual(faint.bitmap.contentBounds(in: ScreenRulerPixelRect(x: 0, y: 0, width: 40, height: 40), tolerance: 0.1),
                       ScreenRulerPixelRect(x: 10, y: 10, width: 4, height: 4))
    }

    func testShrinkWrapClipsAnObjectTheBoxCuts() throws {
        var canvas = ScreenRulerCanvas(width: 100, height: 100)
        canvas.fill(ScreenRulerPixelRect(x: 40, y: 40, width: 40, height: 40), ScreenRulerCanvas.black)
        // The box ends inside the square: the result stays inside the box.
        let bounds = canvas.bitmap.contentBounds(in: ScreenRulerPixelRect(x: 10, y: 10, width: 50, height: 50), tolerance: 0.1)
        XCTAssertEqual(bounds, ScreenRulerPixelRect(x: 40, y: 40, width: 20, height: 20))
    }

    func testShrinkWrapOfBackgroundOnlyFindsNothing() {
        let canvas = ScreenRulerCanvas(width: 50, height: 50, color: (40, 40, 40))
        XCTAssertNil(canvas.bitmap.contentBounds(in: ScreenRulerPixelRect(x: 5, y: 5, width: 30, height: 30), tolerance: 0.1))
        XCTAssertNil(canvas.bitmap.contentBounds(in: ScreenRulerPixelRect(x: 60, y: 60, width: 10, height: 10), tolerance: 0.1),
                     "a box outside the image holds nothing")
    }

    func testShrinkWrapOnAGradientBackgroundWithinTolerance() throws {
        var canvas = ScreenRulerCanvas(width: 60, height: 60)
        for x in 0..<60 { for y in 0..<60 { canvas.set(x, y, (UInt8(200 + x / 6), UInt8(200 + x / 6), 255)) } }
        canvas.fill(ScreenRulerPixelRect(x: 25, y: 30, width: 6, height: 3), (200, 0, 0))
        XCTAssertEqual(canvas.bitmap.contentBounds(in: ScreenRulerPixelRect(x: 0, y: 0, width: 60, height: 60), tolerance: 0.1),
                       ScreenRulerPixelRect(x: 25, y: 30, width: 6, height: 3))
    }

    func testTheBackgroundIsTheCommonestBorderColour() throws {
        var canvas = ScreenRulerCanvas(width: 30, height: 30)
        // An object touching the box's left edge does not become the background.
        canvas.fill(ScreenRulerPixelRect(x: 0, y: 10, width: 8, height: 8), ScreenRulerCanvas.black)
        let box = ScreenRulerPixelRect(x: 0, y: 0, width: 30, height: 30)
        XCTAssertEqual(canvas.bitmap.backgroundColor(around: box), 0xFFFF_FFFF)
        XCTAssertEqual(canvas.bitmap.contentBounds(in: box, tolerance: 0.1), ScreenRulerPixelRect(x: 0, y: 10, width: 8, height: 8))
    }

    // MARK: Capture copy and colour

    func testACaptureIsCopiedTopRowFirstWhateverItsByteOrder() throws {
        // ScreenCaptureKit hands over BGRA (premultiplied first, little endian).
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        // CG's origin is bottom-left: y 1...2 is the top row.
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        let bitmap = try XCTUnwrap(ScreenRulerBitmap(image: image))
        XCTAssertEqual(bitmap.width, 4)
        XCTAssertEqual(bitmap.height, 2)
        let topLeft = try XCTUnwrap(bitmap.rgba(at: ScreenRulerPixel(x: 0, y: 0)))
        XCTAssertEqual([topLeft.red, topLeft.green, topLeft.blue, topLeft.alpha], [255, 0, 0, 255])
        let bottomLeft = try XCTUnwrap(bitmap.rgba(at: ScreenRulerPixel(x: 0, y: 1)))
        XCTAssertEqual([bottomLeft.red, bottomLeft.green, bottomLeft.blue], [0, 0, 255])
        XCTAssertEqual(bitmap.srgbHex(at: ScreenRulerPixel(x: 0, y: 0)), "#FF0000")
        XCTAssertEqual(bitmap.srgbHex(at: ScreenRulerPixel(x: 3, y: 1)), "#0000FF")
    }

    func testTheHexColourIsTheSRGBValue() {
        var canvas = ScreenRulerCanvas(width: 2, height: 1)
        canvas.set(1, 0, (0x1E, 0x7B, 0x34))
        XCTAssertEqual(canvas.bitmap.srgbHex(at: ScreenRulerPixel(x: 1, y: 0)), "#1E7B34")
        XCTAssertEqual(canvas.bitmap.srgbHex(at: ScreenRulerPixel(x: 0, y: 0)), "#FFFFFF")
        XCTAssertNil(canvas.bitmap.srgbHex(at: ScreenRulerPixel(x: 2, y: 0)))
    }

    // MARK: Speed

    /// One pointer move on a 4K display scans one row and one column of
    /// pixels in memory; it must fit well inside a 120 Hz frame (8.3 ms),
    /// even in a debug build.
    func testAPointerMoveOnA4KScreenFitsInsideA120HzFrame() throws {
        var canvas = ScreenRulerCanvas(width: 3840, height: 2160)
        for index in 0..<40 {
            canvas.fill(ScreenRulerPixelRect(x: 60 + index * 90, y: 100 + (index % 7) * 280, width: 70, height: 44),
                        (UInt8(40 + index * 5), 90, 160))
        }
        let session = ScreenRulerSession(snapshots: [canvas.snapshot(scale: 2)], options: ScreenRulerOptions())
        var generator = SystemRandomNumberGenerator()
        let points = (0..<600).map { _ in CGPoint(x: Double.random(in: 0..<1920, using: &generator),
                                                   y: Double.random(in: 0..<1080, using: &generator)) }
        // The worst case: a uniform row and column, scanned edge to edge.
        let worst = CGPoint(x: 1, y: 2100 / 2)
        let start = CFAbsoluteTimeGetCurrent()
        var found = 0
        for point in points + [worst] where session.distances(at: point) != nil { found += 1 }
        let average = (CFAbsoluteTimeGetCurrent() - start) / Double(points.count + 1)
        XCTAssertEqual(found, points.count + 1)
        XCTAssertLessThan(average, 0.004, "average \(average * 1000) ms per move")
        print("ScreenRuler hover scan: \(String(format: "%.3f", average * 1000)) ms per move on 3840×2160")
    }
}
