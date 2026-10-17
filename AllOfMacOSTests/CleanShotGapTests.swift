import AppKit
import XCTest
@testable import AllOfMacOS

/// Coverage for the CleanShot X 5.0.1 gap items: All-In-One ratio lock and
/// handles, object clipboard, Background Tool layout / presets, colour
/// library, image combine, secure redaction and multi-page printing.
/// Evidence notes: ~/.cache/aom-rea-20261017/cleanshot5/EVIDENCE-NOTES.md
@MainActor
final class CleanShotGapTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AOMCleanShotGapTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func solidImage(width: Int, height: Int, color: NSColor = .red) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// High-contrast "text": glyph-like bars, never pure black, never equal to
    /// the black-out colour (values 40…215).
    private func textLikeImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_103_515_245 &+ 12345
                let glyph = ((x / 3) % 4 == 0 || (y / 5) % 3 == 0) != ((x * 7 + y * 3) % 11 < 4)
                let base: Int = glyph ? 40 : 215
                let jitter = Int((seed >> 16) % 9) - 4
                let value = UInt8(min(215, max(40, base + jitter)))
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i + 1] = UInt8(255 - Int(value)); pixels[i + 2] = value; pixels[i + 3] = 255
            }
        }
        return AnnotationSecureRedaction.image(from: .init(width: width, height: height, pixels: pixels))!
    }

    private func rgba(_ image: CGImage) -> AnnotationSecureRedaction.Buffer {
        AnnotationSecureRedaction.rgba(image)!
    }

    private func pixel(_ buffer: AnnotationSecureRedaction.Buffer, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * buffer.width + x) * 4
        return Array(buffer.pixels[i..<(i + 4)])
    }

    // MARK: - 1. All-In-One aspect ratio

    func testAspectRatioMenuOrderAndStorage() {
        XCTAssertEqual(([SelectionAspectRatio.freeform] + SelectionAspectRatio.presets).map(\.title),
                       ["Freeform", "1:1", "4:3", "3:2", "16:10", "16:9", "21:9", "9:16", "3:4", "2:3"])
        for ratio in SelectionAspectRatio.presets + [.freeform, SelectionAspectRatio.custom(width: 5, height: 4)!] {
            XCTAssertEqual(SelectionAspectRatio(storageValue: ratio.storageValue), ratio)
        }
        XCTAssertEqual(SelectionAspectRatio.custom(width: 5, height: 4)?.storageValue, "custom:5:4")
        XCTAssertNil(SelectionAspectRatio.custom(width: 0, height: 4))
        XCTAssertNil(SelectionAspectRatio.custom(width: .nan, height: 4))
        XCTAssertNil(SelectionAspectRatio.custom(width: 1000, height: 1))
        XCTAssertNil(SelectionAspectRatio(storageValue: "garbage"))
        XCTAssertEqual(SelectionAspectRatio(width: 16, height: 9).value!, 16.0 / 9.0, accuracy: 1e-9)
        XCTAssertNil(SelectionAspectRatio.freeform.value)
    }

    func testAspectRatioIsRemembered() {
        XCTAssertEqual(SelectionAspectRatioStore.load(defaults), .freeform)
        SelectionAspectRatioStore.save(SelectionAspectRatio(width: 21, height: 9), defaults)
        XCTAssertEqual(SelectionAspectRatioStore.load(defaults).title, "21:9")
        SelectionAspectRatioStore.save(SelectionAspectRatio.custom(width: 7, height: 5)!, defaults)
        XCTAssertEqual(SelectionAspectRatioStore.load(defaults), SelectionAspectRatio.custom(width: 7, height: 5))
        defaults.set("custom:-1:0", forKey: SelectionAspectRatioStore.lastRatioKey)
        XCTAssertEqual(SelectionAspectRatioStore.load(defaults), .freeform)
    }

    func testNewDragRespectsRatioDirectionCenterAndBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let ratio: CGFloat = 16.0 / 9.0
        let rect = SelectionGeometry.dragRect(anchor: CGPoint(x: 100, y: 100), current: CGPoint(x: 420, y: 150),
                                              ratio: ratio, fromCenter: false, bounds: bounds)
        XCTAssertEqual(rect.origin, CGPoint(x: 100, y: 100))
        XCTAssertEqual(rect.width / rect.height, ratio, accuracy: 1e-6)
        XCTAssertEqual(rect.width, 320, accuracy: 1e-6)

        // Dragging up-left from the anchor.
        let back = SelectionGeometry.dragRect(anchor: CGPoint(x: 500, y: 500), current: CGPoint(x: 400, y: 300),
                                              ratio: 1, fromCenter: false, bounds: bounds)
        XCTAssertEqual(back, CGRect(x: 300, y: 300, width: 200, height: 200))

        // ⌥: anchor is the centre.
        let centred = SelectionGeometry.dragRect(anchor: CGPoint(x: 500, y: 400), current: CGPoint(x: 550, y: 420),
                                                 ratio: nil, fromCenter: true, bounds: bounds)
        XCTAssertEqual(centred, CGRect(x: 450, y: 380, width: 100, height: 40))

        // Clamped at the screen edge while keeping the ratio.
        let clamped = SelectionGeometry.dragRect(anchor: CGPoint(x: 900, y: 100), current: CGPoint(x: 1400, y: 200),
                                                 ratio: ratio, fromCenter: false, bounds: bounds)
        XCTAssertLessThanOrEqual(clamped.maxX, bounds.maxX + 1e-6)
        XCTAssertEqual(clamped.width / clamped.height, ratio, accuracy: 1e-6)

        // Freeform is unchanged from a plain rectangle.
        let free = SelectionGeometry.dragRect(anchor: CGPoint(x: 10, y: 20), current: CGPoint(x: 60, y: 25),
                                              ratio: nil, fromCenter: false, bounds: bounds)
        XCTAssertEqual(free, CGRect(x: 10, y: 20, width: 50, height: 5))
    }

    // MARK: - 2. Selection resize handles

    func testHandleHitTestingPrefersCornersThenEdges() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionHandle.allCases.count, 8)
        XCTAssertEqual(SelectionHandle.hit(CGPoint(x: 101, y: 99), in: rect), .topLeft)
        XCTAssertEqual(SelectionHandle.hit(CGPoint(x: 300, y: 200), in: rect), .bottomRight)
        XCTAssertEqual(SelectionHandle.hit(CGPoint(x: 200, y: 101), in: rect), .top)
        XCTAssertEqual(SelectionHandle.hit(CGPoint(x: 150, y: 101), in: rect), .top, "edges grab along their length")
        XCTAssertEqual(SelectionHandle.hit(CGPoint(x: 299, y: 160), in: rect), .right)
        XCTAssertNil(SelectionHandle.hit(CGPoint(x: 200, y: 150), in: rect), "inside moves, not resizes")
        XCTAssertNil(SelectionHandle.hit(CGPoint(x: 50, y: 50), in: rect))
        for handle in SelectionHandle.allCases { XCTAssertFalse(handle.accessibilityName.isEmpty) }
    }

    func testHandleResizeFreeformCenterRatioAndClamp() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

        XCTAssertEqual(SelectionGeometry.resize(rect, handle: .bottomRight, to: CGPoint(x: 400, y: 300),
                                                ratio: nil, fromCenter: false, bounds: bounds),
                       CGRect(x: 100, y: 100, width: 300, height: 200))
        // Edge handle only changes one axis.
        XCTAssertEqual(SelectionGeometry.resize(rect, handle: .left, to: CGPoint(x: 50, y: 999),
                                                ratio: nil, fromCenter: false, bounds: bounds),
                       CGRect(x: 50, y: 100, width: 250, height: 100))
        // ⌥ resizes symmetrically about the centre.
        XCTAssertEqual(SelectionGeometry.resize(rect, handle: .right, to: CGPoint(x: 350, y: 150),
                                                ratio: nil, fromCenter: true, bounds: bounds),
                       CGRect(x: 50, y: 100, width: 300, height: 100))
        // ⇧ / ratio lock on a corner keeps 2:1 and the opposite corner fixed.
        let kept = SelectionGeometry.resize(rect, handle: .bottomRight, to: CGPoint(x: 500, y: 200),
                                            ratio: 2, fromCenter: false, bounds: bounds)
        XCTAssertEqual(kept.origin, rect.origin)
        XCTAssertEqual(kept.width / kept.height, 2, accuracy: 1e-6)
        XCTAssertEqual(kept.width, 400, accuracy: 1e-6)
        // Ratio lock on an edge handle grows the other axis about the centre line.
        let edge = SelectionGeometry.resize(rect, handle: .bottom, to: CGPoint(x: 0, y: 250),
                                            ratio: 2, fromCenter: false, bounds: bounds)
        XCTAssertEqual(edge.minY, 100)
        XCTAssertEqual(edge.height, 150, accuracy: 1e-6)
        XCTAssertEqual(edge.width, 300, accuracy: 1e-6)
        XCTAssertEqual(edge.midX, rect.midX, accuracy: 1e-6)
        // Clamped to the screen with the ratio preserved.
        let clamped = SelectionGeometry.resize(rect, handle: .topLeft, to: CGPoint(x: -500, y: -500),
                                               ratio: 2, fromCenter: false, bounds: bounds)
        XCTAssertGreaterThanOrEqual(clamped.minX, 0)
        XCTAssertGreaterThanOrEqual(clamped.minY, 0)
        XCTAssertEqual(clamped.maxX, rect.maxX, accuracy: 1e-6)
        XCTAssertEqual(clamped.maxY, rect.maxY, accuracy: 1e-6)
        XCTAssertEqual(clamped.width / clamped.height, 2, accuracy: 1e-6)
        // Freeform clamp, and a drag past the anchor cannot invert the rect.
        let free = SelectionGeometry.resize(rect, handle: .right, to: CGPoint(x: 5000, y: 0),
                                            ratio: nil, fromCenter: false, bounds: bounds)
        XCTAssertEqual(free.maxX, 1000)
        let tiny = SelectionGeometry.resize(rect, handle: .right, to: CGPoint(x: 0, y: 0),
                                            ratio: nil, fromCenter: false, bounds: bounds)
        XCTAssertEqual(tiny.width, SelectionGeometry.minimumSide)
        XCTAssertEqual(tiny.minX, rect.minX)
    }

    func testRatioFieldsAndApplyingRatioToPendingSelection() {
        let current = CGSize(width: 400, height: 300)
        XCTAssertEqual(SelectionGeometry.lockedSize(width: 800, height: 300, current: current, ratio: 16.0 / 9),
                       CGSize(width: 800, height: 450))
        XCTAssertEqual(SelectionGeometry.lockedSize(width: 400, height: 200, current: current, ratio: 2),
                       CGSize(width: 400, height: 200))
        XCTAssertEqual(SelectionGeometry.lockedSize(width: 400, height: 100, current: current, ratio: 2),
                       CGSize(width: 200, height: 100))
        XCTAssertEqual(SelectionGeometry.lockedSize(width: 10, height: 20, current: current, ratio: nil),
                       CGSize(width: 10, height: 20))

        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let applied = SelectionGeometry.applying(ratio: 1, to: CGRect(x: 100, y: 100, width: 400, height: 100),
                                                 within: bounds)
        XCTAssertEqual(applied.width, applied.height, accuracy: 1e-6)
        XCTAssertTrue(bounds.contains(applied))
    }

    // MARK: - 3. Object copy / paste / duplicate

    func testObjectClipboardRoundTripsWithPNGAndFreshIdentity() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AOMGapTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var document = AnnotationDocument(baseImage: solidImage(width: 200, height: 120, color: .white))
        let arrow = AnnotationObject(kind: .arrow, rect: CGRect(x: 20, y: 20, width: 80, height: 40))
        let text = AnnotationObject(kind: .text, rect: CGRect(x: 10, y: 70, width: 100, height: 30), text: "Hello")
        document.add(arrow)
        document.add(text)

        let image = document.renderObjectsImage(ids: [arrow.id], scale: 1)
        let png = try XCTUnwrap(image)
        XCTAssertLessThan(png.width, 200, "PNG is cropped to the object")
        XCTAssertTrue(AnnotationObjectClipboard.write([arrow, text], image: png, scale: 1, to: pasteboard))
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertTrue(AnnotationObjectClipboard.hasObjects(on: pasteboard))

        let read = try XCTUnwrap(AnnotationObjectClipboard.read(from: pasteboard))
        XCTAssertEqual(read, [arrow, text])
        let ids = document.insertCopies(of: read, offset: AnnotationObjectClipboard.pasteStep * 2)
        XCTAssertEqual(document.objects.count, 4)
        XCTAssertTrue(Set(ids).isDisjoint(with: [arrow.id, text.id]))
        let pasted = try XCTUnwrap(document.objects.first { $0.id == ids[0] })
        XCTAssertEqual(pasted.rect, arrow.rect.offsetBy(dx: 20, dy: 20))
        XCTAssertEqual(pasted.kind, .arrow)
        // One undo removes the whole paste.
        document.undo()
        XCTAssertEqual(document.objects.count, 2)

        // A foreign / corrupted payload is rejected.
        pasteboard.clearContents()
        pasteboard.setData(Data("{\"version\":1,\"objects\":[]}".utf8), forType: AnnotationObjectClipboard.pasteboardType)
        XCTAssertNil(AnnotationObjectClipboard.read(from: pasteboard))
    }

    func testDuplicateMovesFreehandPointsAndRemoveObjectsIsOneUndo() {
        var document = AnnotationDocument(baseImage: solidImage(width: 100, height: 100))
        let stroke = AnnotationObject(kind: .draw, rect: CGRect(x: 10, y: 10, width: 10, height: 10),
                                      points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)])
        document.add(stroke)
        let ids = document.insertCopies(of: [stroke], offset: 10)
        let copy = document.objects.first { $0.id == ids[0] }!
        XCTAssertEqual(copy.points, [CGPoint(x: 20, y: 20), CGPoint(x: 30, y: 30)])
        document.removeObjects(Set(document.objects.map(\.id)))
        XCTAssertTrue(document.objects.isEmpty)
        document.undo()
        XCTAssertEqual(document.objects.count, 2)
    }

    // MARK: - 4 / 5. Background layout, auto balance

    func testBackgroundLayoutPaddingInsetRatioAlignment() {
        var background = AnnotationBackground()
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(AnnotationBackgroundLayout.compute(imageSize: size, background: background, scale: 2,
                                                          content: nil).canvasSize, size)
        background.padding = 10
        background.inset = 5
        var layout = AnnotationBackgroundLayout.compute(imageSize: size, background: background, scale: 2, content: nil)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 200 + 20 + 40, height: 100 + 20 + 40))
        XCTAssertEqual(layout.blockRect, CGRect(x: 20, y: 20, width: 220, height: 120))
        XCTAssertEqual(layout.imageRect, CGRect(x: 30, y: 30, width: 200, height: 100))

        background.inset = 0
        background.ratio = .square
        layout = AnnotationBackgroundLayout.compute(imageSize: size, background: background, scale: 1, content: nil)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 220, height: 220))
        XCTAssertEqual(layout.imageRect.midY, 110, accuracy: 0.5)
        background.alignment = 6 // bottom-left hugs that corner
        layout = AnnotationBackgroundLayout.compute(imageSize: size, background: background, scale: 1, content: nil)
        XCTAssertEqual(layout.imageRect.minX, 0)
        XCTAssertEqual(layout.imageRect.maxY, 220)
        background.alignment = 2 // top-right
        layout = AnnotationBackgroundLayout.compute(imageSize: size, background: background, scale: 1, content: nil)
        XCTAssertEqual(layout.imageRect.maxX, 220)
        XCTAssertEqual(layout.imageRect.minY, 0)
        background.ratio = .r16x9
        background.alignment = 4
        layout = AnnotationBackgroundLayout.compute(imageSize: CGSize(width: 100, height: 300), background: background,
                                                    scale: 1, content: nil)
        XCTAssertEqual(layout.canvasSize.width / layout.canvasSize.height, 16.0 / 9, accuracy: 0.01)
        XCTAssertEqual(AnnotationBackground.Ratio.allCases.map(\.title),
                       ["Auto", "1:1", "3:4", "4:3", "3:2", "16:9", "4:5", "9:16"])
    }

    func testContentBoundsDetectsUniformBorders() {
        // 100×60 white image with a dark block at x 30..<90, y 10..<50.
        let context = CGContext(data: nil, width: 100, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        context.setFillColor(NSColor.darkGray.cgColor)
        // CG is bottom-left: top-left y 10..<50 ⇒ CG y 10..<50 as well for a 60-high image.
        context.fill(CGRect(x: 30, y: 10, width: 60, height: 40))
        let image = context.makeImage()!
        let bounds = AnnotationContentBounds.detect(in: image)
        XCTAssertEqual(bounds.insets, .init(left: 30, top: 10, right: 10, bottom: 10))
        XCTAssertEqual(bounds.edgeRGBA.0, 255)
        XCTAssertEqual(bounds.edgeRGBA.3, 255)
        XCTAssertEqual(AnnotationContentBounds.detect(in: solidImage(width: 20, height: 20)).insets, .zero)
    }

    func testAutoBalanceCentersVisualContentDeterministically() {
        var background = AnnotationBackground()
        background.padding = 20
        background.autoBalance = true
        let content = AnnotationContentBounds(insets: .init(left: 30, top: 10, right: 10, bottom: 10),
                                              edgeRGBA: (255, 255, 255, 255))
        let size = CGSize(width: 100, height: 60)
        let layout = AnnotationBackgroundLayout.compute(imageSize: size, background: background, scale: 1,
                                                        content: content)
        // Visual margin = canvas edge → content edge, equal on both sides.
        let leftMargin = layout.imageRect.minX + 30
        let rightMargin = layout.canvasSize.width - (layout.imageRect.maxX - 10)
        XCTAssertEqual(leftMargin, rightMargin, accuracy: 0.5)
        let topMargin = layout.imageRect.minY + 10
        let bottomMargin = layout.canvasSize.height - (layout.imageRect.maxY - 10)
        XCTAssertEqual(topMargin, bottomMargin, accuracy: 0.5)
        // Same input, same output.
        XCTAssertEqual(layout, AnnotationBackgroundLayout.compute(imageSize: size, background: background, scale: 1,
                                                                  content: content))
        // Imbalance larger than the padding grows the canvas instead of clipping.
        background.padding = 0
        background.inset = 1
        let grown = AnnotationBackgroundLayout.compute(imageSize: size, background: background, scale: 1,
                                                       content: content)
        XCTAssertGreaterThanOrEqual(grown.canvasSize.width, 102 + 20)
        XCTAssertEqual(grown.imageRect.minX + 30, grown.canvasSize.width - (grown.imageRect.maxX - 10), accuracy: 0.5)
        // Off: no shift.
        background.autoBalance = false
        background.inset = 0
        background.padding = 20
        let plain = AnnotationBackgroundLayout.compute(imageSize: size, background: background, scale: 1,
                                                       content: content)
        XCTAssertEqual(plain.imageRect.minX, 20)
    }

    func testRenderUsesLayoutInsetAndEdgeColor() throws {
        var document = AnnotationDocument(baseImage: solidImage(width: 40, height: 30, color: .blue))
        document.background.kind = .solid
        document.background.color = .white
        document.background.padding = 10
        document.background.inset = 4
        document.background.shadow = 0
        document.background.cornerRadius = 0
        let rendered = try XCTUnwrap(document.render(scale: 1))
        XCTAssertEqual(rendered.width, 40 + 20 + 8)
        XCTAssertEqual(document.imageOrigin(scale: 1), CGPoint(x: 14, y: 14))
        let buffer = rgba(rendered)
        let insetPixel = pixel(buffer, 11, 11) // inside the inset band: the screenshot's edge colour
        XCTAssertGreaterThan(insetPixel[2], 200)
        XCTAssertLessThan(insetPixel[0], 40)
        let padPixel = pixel(buffer, 2, 2)
        XCTAssertGreaterThan(padPixel[0], 240)
    }

    func testBackgroundDecodesLegacyProjectsAndValidates() throws {
        let legacy = #"{"kind":"solid","gradientPreset":"ocean","cornerRadius":8,"color":"red","gradientStart":"purple","gradientEnd":"blue","padding":24}"#
        let decoded = try JSONDecoder().decode(AnnotationBackground.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.padding, 24)
        XCTAssertEqual(decoded.kind, .solid)
        XCTAssertEqual(decoded.inset, 0)
        XCTAssertEqual(decoded.shadow, 0.5)
        XCTAssertEqual(decoded.alignment, 4)
        XCTAssertEqual(decoded.ratio, .auto)
        XCTAssertFalse(decoded.autoBalance)
        var modern = decoded
        modern.kind = .wallpaper
        modern.wallpaperPath = "/System/Library/Desktop Pictures/x.heic"
        modern.ratio = .r4x5
        modern.autoBalance = true
        let again = try JSONDecoder().decode(AnnotationBackground.self, from: JSONEncoder().encode(modern))
        XCTAssertEqual(again, modern)
        var invalid = modern
        invalid.alignment = 12
        XCTAssertFalse(invalid.isValid)
        invalid = modern
        invalid.shadow = 3
        XCTAssertFalse(invalid.isValid)
    }

    func testProjectRoundTripKeepsNewBackgroundFields() throws {
        var document = AnnotationDocument(baseImage: solidImage(width: 30, height: 20))
        document.background.padding = 12
        document.background.ratio = .r16x9
        document.background.alignment = 7
        document.background.inset = 3
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gap-\(UUID().uuidString).aomannotation")
        defer { try? FileManager.default.removeItem(at: url) }
        try AnnotationProject(document: document, scale: 1).write(to: url)
        let (read, _) = try AnnotationProject.read(from: url)
        XCTAssertEqual(read.background, document.background)
    }

    func testWallpaperCatalogReadsDescriptorsAtRuntime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gap-wall-\(UUID().uuidString)")
        let thumbs = dir.appendingPathComponent(".thumbnails")
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = NSBitmapImageRep(cgImage: solidImage(width: 8, height: 8)).representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("Loose.png"))
        try png.write(to: thumbs.appendingPathComponent("Described.png"))
        let plist: [String: Any] = ["thumbnailPath": thumbs.appendingPathComponent("Described.png").path]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Described.madesktop"))
        let found = AnnotationWallpaperLibrary.scan(dir)
        XCTAssertEqual(Set(found.map(\.name)), ["Loose", "Described"])
        let image = AnnotationWallpaperLibrary.image(atPath: found[0].path, maxPixelSize: 64)
        XCTAssertNotNil(image)
    }

    // MARK: - 6. Presets

    func testBackgroundPresetsLifecycleAndPersistence() throws {
        var store = AnnotationBackgroundPresetStore.load(defaults)
        XCTAssertTrue(store.presets.isEmpty)
        var background = AnnotationBackground()
        background.padding = 40
        background.kind = .gradient
        background.gradientPreset = .aurora
        XCTAssertNil(store.add(name: "   ", background: background))
        let id = try XCTUnwrap(store.add(name: "  Docs  ", background: background))
        XCTAssertEqual(store.presets.first?.name, "Docs")
        XCTAssertTrue(store.rename(id, to: "Blog"))
        XCTAssertFalse(store.rename(id, to: ""))
        background.padding = 64
        XCTAssertTrue(store.update(id, with: background))
        store.autoApplyID = id
        store.notePrevious(background)
        store.save(defaults)

        let reloaded = AnnotationBackgroundPresetStore.load(defaults)
        XCTAssertEqual(reloaded, store)
        XCTAssertEqual(reloaded.autoApplyPreset?.name, "Blog")
        XCTAssertEqual(AnnotationBackgroundPresetStore.automaticBackground(defaults)?.padding, 64)
        XCTAssertEqual(reloaded.previous?.gradientPreset, .aurora)
        // Stored as JSON under AOM keys.
        let raw = try XCTUnwrap(defaults.data(forKey: AnnotationBackgroundPresetStore.presetsKey))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: raw))

        store.delete(id)
        XCTAssertNil(store.autoApplyID, "deleting the auto preset turns auto-apply off")
        store.save(defaults)
        XCTAssertNil(AnnotationBackgroundPresetStore.automaticBackground(defaults))
        var used = AnnotationBackground()
        used.padding = 8
        used.kind = .blurred
        AnnotationBackgroundPresetStore.rememberPrevious(used, defaults)
        AnnotationBackgroundPresetStore.rememberPrevious(AnnotationBackground(), defaults)
        XCTAssertEqual(AnnotationBackgroundPresetStore.load(defaults).previous, used)
        // "None" backgrounds are not recorded as previous settings.
        store.previous = nil
        store.notePrevious(AnnotationBackground())
        XCTAssertNil(store.previous)
    }

    // MARK: - 7. Colour library

    func testColorLibraryHexMyColorsLimitAndRecents() {
        XCTAssertEqual(AnnotationColorLibrary.normalizedHex("#ff3b30"), "FF3B30FF")
        XCTAssertEqual(AnnotationColorLibrary.normalizedHex("abc"), "AABBCCFF")
        XCTAssertEqual(AnnotationColorLibrary.normalizedHex("11223380"), "11223380")
        XCTAssertNil(AnnotationColorLibrary.normalizedHex("12345"))
        XCTAssertNil(AnnotationColorLibrary.normalizedHex("GGGGGG"))
        XCTAssertEqual(AnnotationColorLibrary.components(ofHex: "FF000080")!.3, 128)
        XCTAssertEqual(AnnotationColorLibrary.hex(r: 300, g: -1, b: 16), "FF0010FF")
        XCTAssertEqual(AnnotationColorLibrary.hex(of: AnnotationColorLibrary.color(fromHex: "336699")!), "336699FF")

        var library = AnnotationColorLibrary()
        XCTAssertEqual(library.addToMyColors("nope"), .invalid)
        for index in 0..<AnnotationColorLibrary.myColorsLimit {
            XCTAssertEqual(library.addToMyColors(AnnotationColorLibrary.hex(r: index, g: 0, b: 0)), .added)
        }
        XCTAssertEqual(library.addToMyColors("000000"), .duplicate)
        XCTAssertEqual(library.addToMyColors("FFFFFF"), .limitReached)
        XCTAssertTrue(library.replaceMyColor(at: 0, with: "FFFFFF"))
        library.removeMyColor(at: 1)
        XCTAssertEqual(library.myColors.count, AnnotationColorLibrary.myColorsLimit - 1)

        for index in 0..<15 { library.noteRecent(AnnotationColorLibrary.hex(r: 0, g: index, b: 0)) }
        library.noteRecent("000300")
        XCTAssertEqual(library.recent.count, AnnotationColorLibrary.recentLimit)
        XCTAssertEqual(library.recent.first, "000300FF")
        XCTAssertEqual(library.recent.filter { $0 == "000300FF" }.count, 1)

        library.save(defaults)
        XCTAssertEqual(AnnotationColorLibrary.load(defaults), library)
    }

    // MARK: - 8. Image combine

    func testCombinePlacesImagesOnEachSideAndShiftsAnnotations() throws {
        let base = solidImage(width: 40, height: 20, color: .red)
        let added = solidImage(width: 10, height: 30, color: .blue)
        let marker = AnnotationObject(kind: .rectangle, rect: CGRect(x: 5, y: 5, width: 4, height: 4))
        let cases: [(AnnotationCombinePlacement, CGSize, CGPoint, CGPoint)] = [
            // placement, size, a pixel that must be blue, object origin after
            (.right, CGSize(width: 50, height: 30), CGPoint(x: 45, y: 5), CGPoint(x: 5, y: 5)),
            (.left, CGSize(width: 50, height: 30), CGPoint(x: 5, y: 5), CGPoint(x: 15, y: 5)),
            (.bottom, CGSize(width: 40, height: 50), CGPoint(x: 5, y: 45), CGPoint(x: 5, y: 5)),
            (.top, CGSize(width: 40, height: 50), CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 35)),
        ]
        for (placement, size, bluePoint, origin) in cases {
            var document = AnnotationDocument(baseImage: base)
            document.add(marker)
            XCTAssertTrue(document.combine(added, placement: placement, scale: 1), "\(placement)")
            XCTAssertEqual(document.croppedImage.width, Int(size.width), "\(placement)")
            XCTAssertEqual(document.croppedImage.height, Int(size.height), "\(placement)")
            XCTAssertEqual(document.objects[0].rect.origin, origin, "\(placement)")
            let buffer = rgba(document.croppedImage)
            let blue = pixel(buffer, Int(bluePoint.x), Int(bluePoint.y))
            XCTAssertGreaterThan(blue[2], 200, "\(placement)")
            XCTAssertLessThan(blue[0], 60, "\(placement)")
            document.undo()
            XCTAssertEqual(document.croppedImage.width, 40)
            XCTAssertEqual(document.objects.count, 1)
        }
        // A 1× file into a 2× document is resampled to the same point size.
        var retina = AnnotationDocument(baseImage: solidImage(width: 80, height: 40))
        XCTAssertTrue(retina.combine(solidImage(width: 10, height: 10), placement: .right, scale: 2, imageScale: 1))
        XCTAssertEqual(retina.croppedImage.width, 100)
    }

    func testDropZoneFollowsNearestEdge() {
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(AnnotationCombinePlacement.zone(for: CGPoint(x: 390, y: 100), in: size), .right)
        XCTAssertEqual(AnnotationCombinePlacement.zone(for: CGPoint(x: 10, y: 100), in: size), .left)
        XCTAssertEqual(AnnotationCombinePlacement.zone(for: CGPoint(x: 200, y: 5), in: size), .top)
        XCTAssertEqual(AnnotationCombinePlacement.zone(for: CGPoint(x: 120, y: 195), in: size), .bottom)
        XCTAssertEqual(AnnotationCombinePlacement.zone(for: CGPoint(x: 200, y: 100), in: size), .bottom)
        XCTAssertEqual(AnnotationCombinePlacement.allCases.map(\.title),
                       ["Place on the top", "Place on the bottom", "Place on the left", "Place on the right"])
    }

    // MARK: - 9. Secure redaction

    func testRedactStylesIncludeSecureBlurInCleanShotOrder() {
        XCTAssertEqual(AnnotationRedactionStyle.allCases.map(\.title), ["Pixelate", "Blur", "Secure Blur", "Black Out"])
        XCTAssertEqual(AnnotationToolbarItem.redact.kinds, [.pixelate, .blur, .secureBlur, .redact])
        XCTAssertTrue(AnnotationKind.secureBlur.isSecureRedaction)
        XCTAssertTrue(AnnotationKind.redact.isSecureRedaction)
        XCTAssertFalse(AnnotationKind.blur.isSecureRedaction)
        XCTAssertFalse(AnnotationKind.pixelate.isSecureRedaction)
    }

    func testBlackOutOverwritesEveryPixelOpaqueEvenAtLowOpacity() throws {
        let source = textLikeImage(width: 120, height: 80)
        var document = AnnotationDocument(baseImage: source)
        var style = AnnotationStyle()
        style.opacity = 0.05
        // Fractional rect: the integral expansion must still cover every touched pixel.
        document.add(AnnotationObject(kind: .redact, rect: CGRect(x: 20.4, y: 10.6, width: 50.2, height: 30.3),
                                      style: style))
        let output = rgba(try XCTUnwrap(document.render(scale: 1)))
        let original = rgba(source)
        for y in 10..<41 {
            for x in 20..<71 {
                XCTAssertEqual(pixel(output, x, y), [0, 0, 0, 255], "pixel \(x),\(y)")
            }
        }
        XCTAssertEqual(pixel(output, 5, 5), pixel(original, 5, 5), "outside untouched")
    }

    func testSecureBlurDestroysOriginalPixelsAndStructure() throws {
        let source = textLikeImage(width: 160, height: 100)
        let original = rgba(source)
        var document = AnnotationDocument(baseImage: source)
        var style = AnnotationStyle()
        style.opacity = 0.1 // must not matter
        let region = CGRect(x: 16, y: 12, width: 96, height: 64)
        document.add(AnnotationObject(kind: .secureBlur, rect: region, style: style))
        let rendered = try XCTUnwrap(document.render(scale: 1))
        let output = rgba(rendered)

        var equal = 0
        var originalEnergy = 0, outputEnergy = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                let out = pixel(output, x, y), src = pixel(original, x, y)
                XCTAssertEqual(out[3], 255, "opaque at \(x),\(y)")
                if out[0] == src[0] && out[1] == src[1] && out[2] == src[2] { equal += 1 }
                if x + 1 < Int(region.maxX) {
                    originalEnergy += abs(Int(src[0]) - Int(pixel(original, x + 1, y)[0]))
                    outputEnergy += abs(Int(out[0]) - Int(pixel(output, x + 1, y)[0]))
                }
            }
        }
        XCTAssertEqual(equal, 0, "no original pixel survives verbatim")
        // Text structure (horizontal edges) is gone: output detail is noise-level.
        XCTAssertLessThan(Double(outputEnergy), Double(originalEnergy) * 0.15)
        // Deterministic: identical on re-render (stable preview / export).
        XCTAssertEqual(rgba(try XCTUnwrap(document.render(scale: 1))).pixels, output.pixels)
        // Outside the region is untouched.
        XCTAssertEqual(pixel(output, 2, 2), pixel(original, 2, 2))
    }

    func testSecureStylesStayOverwrittenOnAnExpandedCanvas() throws {
        let source = textLikeImage(width: 100, height: 60)
        let original = rgba(source)
        var document = AnnotationDocument(baseImage: source)
        document.background.padding = 12
        document.background.shadow = 0
        document.background.cornerRadius = 0
        document.add(AnnotationObject(kind: .secureBlur, rect: CGRect(x: 10, y: 10, width: 40, height: 30)))
        document.add(AnnotationObject(kind: .redact, rect: CGRect(x: 60, y: 10, width: 30, height: 30)))
        let output = rgba(try XCTUnwrap(document.render(scale: 1)))
        let offset = 12
        for y in 10..<40 {
            for x in 10..<50 {
                let out = pixel(output, x + offset, y + offset), src = pixel(original, x, y)
                XCTAssertEqual(out[3], 255)
                XCTAssertFalse(out[0] == src[0] && out[1] == src[1] && out[2] == src[2])
            }
            for x in 60..<90 { XCTAssertEqual(pixel(output, x + offset, y + offset), [0, 0, 0, 255]) }
        }
    }

    func testFlattenRedactionsBurnsPixelsAndPreservesStacking() throws {
        let source = textLikeImage(width: 80, height: 60)
        var document = AnnotationDocument(baseImage: source)
        let below = AnnotationObject(kind: .rectangle, rect: CGRect(x: 2, y: 2, width: 10, height: 10))
        let redaction = AnnotationObject(kind: .redact, rect: CGRect(x: 20, y: 20, width: 20, height: 20))
        let above = AnnotationObject(kind: .arrow, rect: CGRect(x: 40, y: 5, width: 20, height: 20))
        document.add(below); document.add(redaction); document.add(above)
        let before = rgba(try XCTUnwrap(document.render(scale: 1)))
        XCTAssertTrue(document.flattenRedactions(scale: 1))
        XCTAssertEqual(document.objects.map(\.id), [above.id], "only objects above the top redaction stay editable")
        XCTAssertEqual(pixel(rgba(document.baseImage), 30, 30), [0, 0, 0, 255], "base image itself is redacted")
        XCTAssertEqual(rgba(try XCTUnwrap(document.render(scale: 1))).pixels, before.pixels, "same visual result")
        document.undo()
        XCTAssertEqual(document.objects.count, 3)
        var empty = AnnotationDocument(baseImage: source)
        XCTAssertFalse(empty.flattenRedactions(scale: 1))
    }

    func testSecureBlurPipelineIsDeterministicPerSeed() {
        let source = textLikeImage(width: 48, height: 48)
        let seed = UUID()
        let a = AnnotationSecureRedaction.secureBlur(region: source, blockSize: 16, seed: seed)
        let b = AnnotationSecureRedaction.secureBlur(region: source, blockSize: 16, seed: seed)
        XCTAssertEqual(rgba(a!).pixels, rgba(b!).pixels)
        let c = AnnotationSecureRedaction.secureBlur(region: source, blockSize: 16, seed: UUID())
        XCTAssertNotEqual(rgba(a!).pixels, rgba(c!).pixels, "noise differs between objects")
    }

    // MARK: - 10. Multi-page print

    func testPaginationSinglePageAndFitToWidth() {
        let single = CapturePrintPagination.compute(imageSize: CGSize(width: 300, height: 200),
                                                    printableSize: CGSize(width: 500, height: 700), overlap: 24)
        XCTAssertEqual(single.pageCount, 1)
        XCTAssertEqual(single.scale, 1, "never enlarged")
        let wide = CapturePrintPagination.compute(imageSize: CGSize(width: 1000, height: 400),
                                                  printableSize: CGSize(width: 500, height: 700), overlap: 0)
        XCTAssertEqual(wide.scale, 0.5)
        XCTAssertEqual(wide.contentSize, CGSize(width: 500, height: 200))
        XCTAssertEqual(wide.pageCount, 1)
    }

    func testPaginationSplitsTallCapturesWithOverlapAndFooter() {
        // 500 × 3000 pt scroll capture on a 500 × 720 printable area, 20 pt footer.
        let pages = CapturePrintPagination.compute(imageSize: CGSize(width: 500, height: 3000),
                                                   printableSize: CGSize(width: 500, height: 720),
                                                   overlap: 0, footerHeight: 20)
        XCTAssertEqual(pages.pageHeight, 700)
        XCTAssertEqual(pages.pageCount, 5) // 0,700,1400,2100,2800
        XCTAssertEqual(pages.pages.map(\.minY), [0, 700, 1400, 2100, 2800])
        XCTAssertGreaterThanOrEqual(pages.viewSize.height, 3000)

        let overlapped = CapturePrintPagination.compute(imageSize: CGSize(width: 500, height: 3000),
                                                        printableSize: CGSize(width: 500, height: 720),
                                                        overlap: 48, footerHeight: 20)
        XCTAssertEqual(overlapped.pages[1].minY, 652)
        // Consecutive pages share exactly `overlap` points.
        for (a, b) in zip(overlapped.pages, overlapped.pages.dropFirst()) {
            XCTAssertEqual(a.maxY - b.minY, 48, accuracy: 1e-9)
        }
        XCTAssertGreaterThanOrEqual(overlapped.pages.last!.maxY, 3000)
        XCTAssertLessThan(overlapped.pages.last!.minY, 3000)

        // Exact multiple: no empty trailing page.
        let exact = CapturePrintPagination.compute(imageSize: CGSize(width: 100, height: 1400),
                                                   printableSize: CGSize(width: 100, height: 700), overlap: 0)
        XCTAssertEqual(exact.pageCount, 2)
        // Absurd overlap is clamped so pagination always advances.
        let clamped = CapturePrintPagination.compute(imageSize: CGSize(width: 100, height: 2000),
                                                     printableSize: CGSize(width: 100, height: 400), overlap: 10_000)
        XCTAssertEqual(clamped.overlap, 200)
        XCTAssertEqual(clamped.pageCount, 9)
        XCTAssertEqual(CapturePrintPagination.pageLabel(2, of: 5), "Page 2 of 5")
    }

    func testPrintViewPaginatesForPrintInfo() {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.leftMargin = 36; info.rightMargin = 36; info.topMargin = 36; info.bottomMargin = 36
        let options = CapturePrintOptions(overlap: 0, showsPageNumbers: true)
        // 1080 × 6000 px at 2× = 540 × 3000 pt.
        let view = CapturePrintView(image: solidImage(width: 1080, height: 6000), scale: 2, options: options)
        let pagination = view.paginate(for: info)
        XCTAssertEqual(pagination.pageHeight, 720 - CapturePrintView.footerHeight)
        XCTAssertEqual(pagination.pageCount, Int((3000 / pagination.pageHeight).rounded(.up)))
        XCTAssertEqual(view.rectForPage(1), pagination.pages[0])
        XCTAssertEqual(view.rectForPage(pagination.pageCount), pagination.pages.last)
        XCTAssertEqual(view.frame.height, pagination.viewSize.height)
        XCTAssertTrue(view.isFlipped)
        options.showsPageNumbers = false
        XCTAssertEqual(view.paginate(for: info).pageHeight, 720)
    }
}
