import XCTest
import AppKit
import CoreGraphics
import CoreText
@testable import AllOfMacOS

/// 3.3.3 annotation work: C03 text styles, the eraser, free image layers and
/// line/arrow direction. Synthetic images and temp files only.
final class CaptureAnnotation333Tests: XCTestCase {
    private typealias Buffer = AnnotationSecureRedaction.Buffer

    // MARK: - Helpers

    private func solid(_ width: Int, _ height: Int, _ color: NSColor) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func rgba(_ image: CGImage) -> Buffer { AnnotationSecureRedaction.rgba(image)! }

    /// RGBA at (x, y), top-left origin.
    private func pixel(_ buffer: Buffer, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * buffer.width + x) * 4
        return Array(buffer.pixels[i..<(i + 4)])
    }

    private func isRed(_ p: [UInt8]) -> Bool { p[0] > 200 && p[1] < 90 && p[2] < 90 }
    private func isBlue(_ p: [UInt8]) -> Bool { p[2] > 200 && p[0] < 80 }
    private func isWhite(_ p: [UInt8]) -> Bool { p[0] > 235 && p[1] > 235 && p[2] > 235 }
    private func isDark(_ p: [UInt8]) -> Bool { p[0] < 100 && p[1] < 100 && p[2] < 100 }

    private func count(_ buffer: Buffer, where test: ([UInt8]) -> Bool) -> Int {
        var total = 0
        for y in 0..<buffer.height { for x in 0..<buffer.width where test(pixel(buffer, x, y)) { total += 1 } }
        return total
    }

    private func hex(_ color: NSColor) -> String { AnnotationColorLibrary.hex(of: color) }

    private func temporaryProjectURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aom333-annotation-\(UUID().uuidString).aomannotation")
    }

    /// A text object fitted to its text, rendered on `base` at scale 1.
    private func renderText(_ text: String, style: AnnotationStyle, base: CGImage,
                            origin: CGPoint = CGPoint(x: 10, y: 10), width: CGFloat) -> (AnnotationObject, Buffer) {
        var document = AnnotationDocument(baseImage: base)
        let height = AnnotationTextRenderer.fittedHeight(text: text, style: style, width: width)
        let object = AnnotationObject(kind: .text, rect: CGRect(x: origin.x, y: origin.y, width: width, height: height),
                                      style: style, text: text)
        document.add(object)
        return (object, rgba(document.render(scale: 1)!))
    }

    /// The text box the renderer draws for `object` at scale 1, top-left origin.
    private func boxRect(of object: AnnotationObject, imageHeight: CGFloat) -> CGRect {
        let style = object.style
        let size = style.fontSize
        let metrics = AnnotationTextRenderer.metrics(for: style, fontSize: size)
        let contextRect = CGRect(x: object.rect.minX, y: imageHeight - object.rect.maxY,
                                 width: object.rect.width, height: object.rect.height)
        var frame = contextRect.insetBy(dx: metrics.padding.width, dy: metrics.padding.height)
        frame.origin.y += metrics.tail
        frame.size.height -= metrics.tail
        let attributed = AnnotationTextRenderer.attributedText(object.text, style: style,
                                                               font: style.resolvedFont(size: size),
                                                               color: style.resolvedTextColor)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let used = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, frame.size, nil)
        let box = AnnotationTextRenderer.boxRect(usedSize: used, frame: frame, padding: metrics.padding,
                                                 alignment: style.resolvedTextAlignment)
        return CGRect(x: box.minX, y: imageHeight - box.maxY, width: box.width, height: box.height)
    }

    // MARK: - 1. Text styles

    func testTextStylesRoundTripThroughTheProject() throws {
        var document = AnnotationDocument(baseImage: solid(240, 120, .white))
        var style = AnnotationTextStylePreset.bubble.applied(to: AnnotationStyle())
        style.fontName = "Helvetica Neue"
        style.fontWeight = .heavy
        style.fontSize = 30
        style.italic = true
        style.textAlignment = .center
        style.textBackgroundHex = "112233FF"
        style.textColorHex = "FFEEDDFF"
        style.textOutline = true
        style.textOutlineHex = "00FF00FF"
        style.textOutlineWidth = 18
        style.textShadow = true
        document.add(AnnotationObject(kind: .text, rect: CGRect(x: 5, y: 6, width: 200, height: 70), style: style, text: "Styled"))
        let url = temporaryProjectURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try AnnotationProject(document: document, scale: 1).write(to: url)
        let (read, _) = try AnnotationProject.read(from: url)
        XCTAssertEqual(read.objects, document.objects)
        XCTAssertEqual(read.objects[0].style.textBackground, .bubble)
        XCTAssertEqual(read.objects[0].style.fontWeight, .heavy)
        XCTAssertEqual(read.objects[0].style.textAlignment, .center)
        XCTAssertFalse(read.objects[0].style.usesClassicTextRendering)
    }

    func testObjectsFrom332DecodeWithTheNewFieldsUnset() throws {
        let legacy = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"text","rect":[[1,2],[30,40]],
         "style":{"color":"red","thickness":3,"fontSize":24,"opacity":1,"arrowStyle":"standard",
                  "pixelBlockSize":16,"blurRadius":8,"cornerRadius":0,"bold":true},
         "text":"Hi","points":[]}
        """
        let object = try JSONDecoder().decode(AnnotationObject.self, from: Data(legacy.utf8))
        XCTAssertNil(object.image)
        XCTAssertNil(object.rotation)
        XCTAssertNil(object.style.fontWeight)
        XCTAssertNil(object.style.textBackground)
        XCTAssertNil(object.style.textShadow)
        XCTAssertTrue(object.style.usesClassicTextRendering)
        XCTAssertEqual(AnnotationTextStylePreset.matching(object.style), .classic)
        // Defaults still encode without any 3.3.3 key, so a 3.3.2 build reads them unchanged.
        let styleKeys = Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(AnnotationStyle())) as? [String: Any] ?? [:]).keys)
        XCTAssertTrue(styleKeys.isDisjoint(with: ["fontWeight", "textAlignment", "textBackground", "textBackgroundHex",
                                                   "textColorHex", "textOutlineHex", "textOutlineWidth", "textShadow"]))
        let objectKeys = Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AnnotationObject(kind: .rectangle, rect: .zero))) as? [String: Any] ?? [:]).keys)
        XCTAssertTrue(objectKeys.isDisjoint(with: ["image", "rotation"]))
    }

    func testPresetsSetTheLookAndKeepColourSizeFamilyAndAlignment() {
        var base = AnnotationStyle()
        base.color = .purple
        base.fontSize = 33
        base.fontName = "Helvetica Neue"
        base.italic = true
        base.textAlignment = .right
        var looks: [AnnotationStyle.TextLook] = []
        for preset in AnnotationTextStylePreset.allCases {
            let styled = preset.applied(to: base)
            XCTAssertEqual(styled.color, .purple, "\(preset)")
            XCTAssertEqual(styled.fontSize, 33, "\(preset)")
            XCTAssertEqual(styled.fontName, "Helvetica Neue", "\(preset)")
            XCTAssertEqual(styled.italic, true, "\(preset)")
            XCTAssertEqual(styled.textAlignment, .right, "\(preset)")
            XCTAssertEqual(AnnotationTextStylePreset.matching(styled), preset, "\(preset) is recognised")
            XCTAssertFalse(preset.displayName.isEmpty)
            looks.append(styled.textLook)
        }
        XCTAssertEqual(Set(looks.map { "\($0)" }).count, AnnotationTextStylePreset.allCases.count, "every preset looks different")
        XCTAssertEqual(AnnotationTextStylePreset.matching(AnnotationStyle()), .classic)
        // Re-applying Classic undoes another preset's look.
        let restored = AnnotationTextStylePreset.classic.applied(to: AnnotationTextStylePreset.bubble.applied(to: AnnotationStyle()))
        XCTAssertEqual(restored, AnnotationStyle())
    }

    func testClassicTextRenderingIsUnchanged() {
        let base = solid(240, 60, .white)
        var style = AnnotationStyle()
        style.color = .blue
        style.fontSize = 24
        let object = AnnotationObject(kind: .text, rect: CGRect(x: 8, y: 8, width: 220, height: 34), style: style,
                                      text: "Classic 3.3.2")
        var document = AnnotationDocument(baseImage: base)
        document.add(object)
        let rendered = rgba(document.renderFlat(objects: document.objects, scale: 1)!)

        // The 3.3.2 drawText, verbatim, in the same context setup as renderFlat.
        let context = CGContext(data: nil, width: 240, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: 240, height: 60))
        context.saveGState()
        context.setAlpha(1)
        let rect = CGRect(x: 8, y: 60 - 42, width: 220, height: 34)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: style.resolvedColor,
            .strokeColor: NSColor.black.withAlphaComponent(0.55),
            .strokeWidth: -3.0,
        ]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: "Classic 3.3.2", attributes: attributes))
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
        let reference = rgba(context.makeImage()!)
        XCTAssertEqual(rendered.pixels, reference.pixels)
    }

    func testLabelAndBubbleBoxesUseTheMainColourAndContrastingGlyphs() {
        let base = solid(300, 120, .white)
        var red = AnnotationStyle()
        red.color = .red
        red.fontSize = 24
        let labelStyle = AnnotationTextStylePreset.label.applied(to: red)
        let (labelObject, label) = renderText("Hi", style: labelStyle, base: base, width: 280)
        let box = boxRect(of: labelObject, imageHeight: 120)
        // The top padding strip, clear of the glyphs.
        let probeX = Int(box.minX + 10), probeY = Int(box.minY + 2)
        XCTAssertTrue(isRed(pixel(label, probeX, probeY)), "\(pixel(label, probeX, probeY))")
        let (_, classic) = renderText("Hi", style: red, base: base, width: 280)
        XCTAssertTrue(isWhite(pixel(classic, probeX, probeY)))

        XCTAssertEqual(hex(labelStyle.resolvedTextColor), "FFFFFFFF", "white on red")
        var yellow = red
        yellow.color = .yellow
        XCTAssertEqual(hex(AnnotationTextStylePreset.label.applied(to: yellow).resolvedTextColor), "000000FF", "black on yellow")
        let light = AnnotationTextStylePreset.lightLabel.applied(to: red)
        XCTAssertEqual(light.resolvedTextBoxColor.map(hex), "FFFFFFFF")
        XCTAssertEqual(hex(light.resolvedTextColor), hex(red.resolvedColor))
        var explicit = labelStyle
        explicit.textColorHex = "00FF00FF"
        XCTAssertEqual(hex(explicit.resolvedTextColor), "00FF00FF")
        XCTAssertNil(red.resolvedTextBoxColor)

        // Speech bubble: a tail under the box's lower-left corner.
        let (bubbleObject, bubble) = renderText("Hi", style: AnnotationTextStylePreset.bubble.applied(to: red),
                                                base: base, width: 280)
        let bubbleBox = boxRect(of: bubbleObject, imageHeight: 120)
        let tailX = Int(bubbleBox.minX + 24 * 0.45)
        XCTAssertTrue(isRed(pixel(bubble, tailX, Int(bubbleBox.maxY + 6))), "\(pixel(bubble, tailX, Int(bubbleBox.maxY + 6)))")
        XCTAssertTrue(isWhite(pixel(bubble, tailX, Int(bubbleBox.maxY + 15))), "past the tail tip")
        XCTAssertTrue(isWhite(pixel(label, tailX, Int(box.maxY + 6))), "a label has no tail")
    }

    func testOutlineAndShadowPaintAroundTheGlyphs() {
        var red = AnnotationStyle()
        red.color = .red
        red.fontSize = 32
        let black = solid(300, 80, .black)
        let (_, outlined) = renderText("HHH", style: AnnotationTextStylePreset.outline.applied(to: red), base: black, width: 280)
        let (_, plain) = renderText("HHH", style: AnnotationTextStylePreset.plain.applied(to: red), base: black, width: 280)
        let whiteish: ([UInt8]) -> Bool = { $0[0] > 200 && $0[1] > 200 && $0[2] > 200 }
        XCTAssertGreaterThan(count(outlined, where: whiteish), 50, "white outline")
        XCTAssertEqual(count(plain, where: whiteish), 0)

        var blue = red
        blue.color = .blue
        let white = solid(300, 80, .white)
        let (_, shadowed) = renderText("HHH", style: AnnotationTextStylePreset.shadow.applied(to: blue), base: white, width: 280)
        let (_, flat) = renderText("HHH", style: AnnotationTextStylePreset.plain.applied(to: blue), base: white, width: 280)
        let gray: ([UInt8]) -> Bool = {
            abs(Int($0[0]) - Int($0[1])) < 10 && abs(Int($0[1]) - Int($0[2])) < 10 && $0[0] < 225
        }
        XCTAssertGreaterThan(count(shadowed, where: gray), 50, "grey shadow pixels")
        XCTAssertEqual(count(flat, where: gray), 0)
    }

    func testAlignmentMovesTheTextInsideItsBox() {
        let white = solid(300, 50, .white)
        var style = AnnotationTextStylePreset.plain.applied(to: AnnotationStyle())
        style.color = .black
        style.fontSize = 20
        func inkCentroidX(_ alignment: AnnotationTextAlignment) -> CGFloat {
            var aligned = style
            aligned.textAlignment = alignment == .left ? nil : alignment
            let (_, buffer) = renderText("ab", style: aligned, base: white, origin: CGPoint(x: 0, y: 5), width: 300)
            var weight: CGFloat = 0, sum: CGFloat = 0
            for y in 0..<buffer.height {
                for x in 0..<buffer.width {
                    let ink = CGFloat(255 - Int(pixel(buffer, x, y)[0]))
                    weight += ink
                    sum += ink * CGFloat(x)
                }
            }
            return weight > 0 ? sum / weight : -1
        }
        let left = inkCentroidX(.left), center = inkCentroidX(.center), right = inkCentroidX(.right)
        XCTAssertGreaterThan(left, 0)
        XCTAssertLessThan(left, 60)
        XCTAssertEqual(center, 150, accuracy: 20)
        XCTAssertGreaterThan(right, 240)
    }

    func testFontWeightAndFamilyResolve() {
        var style = AnnotationStyle()
        style.fontName = "Helvetica Neue"
        style.fontWeight = .bold
        let bold = style.resolvedFont(size: 20)
        XCTAssertEqual(bold.familyName, "Helvetica Neue")
        XCTAssertGreaterThanOrEqual(NSFontManager.shared.weight(of: bold), 8)
        style.fontWeight = .light
        XCTAssertLessThan(NSFontManager.shared.weight(of: style.resolvedFont(size: 20)), 5)
        style.fontWeight = .regular
        style.italic = true
        XCTAssertTrue(style.resolvedFont(size: 20).fontDescriptor.symbolicTraits.contains(.italic))

        func systemWeight(_ weight: AnnotationFontWeight?) -> CGFloat {
            var system = AnnotationStyle()
            system.fontWeight = weight
            let traits = system.resolvedFont(size: 20).fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return (traits?[.weight] as? CGFloat) ?? (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        }
        XCTAssertGreaterThan(systemWeight(.heavy), systemWeight(nil), "heavy is heavier than the semibold default")
        XCTAssertLessThan(systemWeight(.light), systemWeight(.regular))
        // A family name NSFont(name:) alone does not resolve.
        if NSFontManager.shared.availableFontFamilies.contains("Avenir Next") {
            var avenir = AnnotationStyle()
            avenir.fontName = "Avenir Next"
            avenir.fontWeight = .medium
            XCTAssertEqual(avenir.resolvedFont(size: 20).familyName, "Avenir Next")
        }
    }

    func testFittedHeightGrowsForLinesBoxesAndTails() {
        var style = AnnotationStyle()
        style.fontSize = 20
        let one = AnnotationTextRenderer.fittedHeight(text: "One", style: style, width: 200)
        XCTAssertGreaterThanOrEqual(one, 28, "never below 1.4 × the font size")
        XCTAssertGreaterThan(AnnotationTextRenderer.fittedHeight(text: "One\nTwo\nThree", style: style, width: 200), one * 1.8)
        XCTAssertGreaterThan(AnnotationTextRenderer.fittedHeight(text: "word word word word word word word word",
                                                                 style: style, width: 80), one * 2)
        let label = AnnotationTextRenderer.fittedHeight(text: "One", style: AnnotationTextStylePreset.label.applied(to: style), width: 200)
        let bubble = AnnotationTextRenderer.fittedHeight(text: "One", style: AnnotationTextStylePreset.bubble.applied(to: style), width: 200)
        XCTAssertGreaterThanOrEqual(label, one)
        XCTAssertGreaterThan(bubble, label, "the tail needs room")
    }

    // MARK: - 2. Eraser

    func testEraserHitTestingFollowsWhatIsPainted() {
        var thin = AnnotationStyle()
        thin.thickness = 4
        func touches(_ object: AnnotationObject, _ x: CGFloat, _ y: CGFloat, radius: CGFloat) -> Bool {
            AnnotationEraser.touches(object, from: CGPoint(x: x, y: y), to: CGPoint(x: x, y: y), radius: radius)
        }
        let line = AnnotationObject(kind: .line, rect: CGRect(x: 10, y: 10, width: 90, height: 0), style: thin,
                                    points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10)])
        XCTAssertTrue(touches(line, 50, 13, radius: 2), "3 pt away, half thickness 2 + radius 2")
        XCTAssertFalse(touches(line, 50, 20, radius: 2))
        XCTAssertTrue(AnnotationEraser.touches(line, from: CGPoint(x: 50, y: 0), to: CGPoint(x: 50, y: 40), radius: 1),
                      "a fast sweep across the line between two samples")

        var outline = AnnotationStyle()
        outline.thickness = 2
        let frame = CGRect(x: 20, y: 20, width: 60, height: 40)
        let rectangle = AnnotationObject(kind: .rectangle, rect: frame, style: outline)
        XCTAssertFalse(touches(rectangle, 50, 40, radius: 4), "an outline's inside is not painted")
        XCTAssertTrue(touches(rectangle, 20, 40, radius: 2))
        let ellipse = AnnotationObject(kind: .ellipse, rect: frame, style: outline)
        XCTAssertFalse(touches(ellipse, 50, 40, radius: 4))
        XCTAssertTrue(touches(ellipse, 80, 40, radius: 2))
        let filled = AnnotationObject(kind: .filledRectangle, rect: frame)
        XCTAssertTrue(touches(filled, 50, 40, radius: 1))
        XCTAssertFalse(touches(filled, 100, 100, radius: 1))
        let blur = AnnotationObject(kind: .blur, rect: frame)
        XCTAssertTrue(touches(blur, 50, 40, radius: 1))

        let stroke = AnnotationObject(kind: .draw, rect: CGRect(x: 0, y: 50, width: 100, height: 0), style: thin,
                                      points: [CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)])
        XCTAssertTrue(touches(stroke, 60, 53, radius: 2))
        XCTAssertFalse(touches(stroke, 60, 60, radius: 2))

        // Arrows: the stored drag direction, or 3.3.2's top-left → bottom-right.
        let dragged = AnnotationObject(kind: .arrow, rect: CGRect(x: 10, y: 10, width: 90, height: 90), style: thin,
                                       points: [CGPoint(x: 10, y: 100), CGPoint(x: 100, y: 10)])
        let legacy = AnnotationObject(kind: .arrow, rect: CGRect(x: 10, y: 10, width: 90, height: 90), style: thin)
        XCTAssertTrue(touches(dragged, 20, 90, radius: 2))
        XCTAssertFalse(touches(legacy, 20, 90, radius: 2))
        XCTAssertTrue(touches(legacy, 50, 50, radius: 2))

        let counter = AnnotationObject(kind: .counter, rect: CGRect(x: 10, y: 10, width: 28, height: 28), text: "1")
        XCTAssertTrue(touches(counter, 24, 24, radius: 1))
        XCTAssertFalse(touches(counter, 60, 60, radius: 1))

        // A rotated image layer is hit where it is drawn, not where its rect was.
        let image = AnnotationObject(kind: .image, rect: CGRect(x: 0, y: 40, width: 100, height: 20), rotation: .pi / 2)
        XCTAssertTrue(touches(image, 50, 5, radius: 1))
        XCTAssertFalse(touches(image, 5, 50, radius: 1))

        XCTAssertFalse(touches(AnnotationObject(kind: .eraser, rect: frame), 50, 40, radius: 10))
    }

    func testObjectEraserDeletesWhatItTouchesAsOneUndoStep() {
        var document = AnnotationDocument(baseImage: solid(200, 200, .white))
        let a = AnnotationObject(kind: .filledRectangle, rect: CGRect(x: 10, y: 10, width: 20, height: 20))
        let b = AnnotationObject(kind: .filledRectangle, rect: CGRect(x: 100, y: 10, width: 20, height: 20))
        let c = AnnotationObject(kind: .filledRectangle, rect: CGRect(x: 10, y: 150, width: 20, height: 20))
        document.addObjects([a, b, c])
        // One drag: the first step takes the snapshot, later steps do not.
        XCTAssertEqual(document.eraseObjects(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 20, y: 20), radius: 3,
                                             registersUndo: true), 1)
        XCTAssertEqual(document.eraseObjects(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 110, y: 20), radius: 3,
                                             registersUndo: false), 1)
        XCTAssertEqual(document.objects, [c])
        // A miss changes nothing and records nothing.
        XCTAssertEqual(document.eraseObjects(from: CGPoint(x: 190, y: 190), to: CGPoint(x: 195, y: 195), radius: 2,
                                             registersUndo: true), 0)
        document.undo()
        XCTAssertEqual(document.objects, [a, b, c], "one undo restores the whole drag")
        document.redo()
        XCTAssertEqual(document.objects, [c])
    }

    func testStrokeEraserCutsPenStrokesAndLeavesOtherObjects() {
        var document = AnnotationDocument(baseImage: solid(200, 100, .white))
        var pen = AnnotationStyle()
        pen.thickness = 2
        let points = stride(from: 0, through: 100, by: 10).map { CGPoint(x: CGFloat($0), y: 50) }
        let stroke = AnnotationObject(kind: .draw, rect: CGRect(x: 0, y: 50, width: 100, height: 0), style: pen, points: points)
        let box = AnnotationObject(kind: .filledRectangle, rect: CGRect(x: 40, y: 40, width: 20, height: 20))
        let top = AnnotationObject(kind: .rectangle, rect: CGRect(x: 150, y: 10, width: 20, height: 20))
        document.addObjects([box, stroke, top])

        XCTAssertEqual(document.eraseStrokes(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50), radius: 5,
                                             registersUndo: true), 1)
        XCTAssertEqual(document.objects.map(\.kind), [.filledRectangle, .draw, .draw, .rectangle])
        let left = document.objects[1], right = document.objects[2]
        XCTAssertEqual(left.id, stroke.id, "the first piece keeps the stroke's identity")
        XCTAssertNotEqual(right.id, stroke.id)
        // Cut 5 (radius) + 1 (half the pen) either side of x = 50.
        XCTAssertTrue(left.points.allSatisfy { $0.x < 44 }, "\(left.points)")
        XCTAssertTrue(right.points.allSatisfy { $0.x > 56 }, "\(right.points)")
        XCTAssertGreaterThan(left.points.map(\.x).max() ?? 0, 40, "the cut lands between the original points")
        XCTAssertEqual(left.points.count + right.points.count, points.count - 1 + 2, "originals plus one point per cut")
        XCTAssertEqual(left.rect, AnnotationEraser.boundingRect(of: left.points))
        XCTAssertEqual(right.style, pen)
        XCTAssertEqual(document.objects[0], box, "stroke mode never deletes other kinds")
        XCTAssertEqual(document.objects[3], top)
        document.undo()
        XCTAssertEqual(document.objects, [box, stroke, top])

        // A stroke erased end to end disappears.
        let short = AnnotationObject(kind: .drawHighlight, rect: CGRect(x: 10, y: 80, width: 4, height: 0), style: pen,
                                     points: [CGPoint(x: 10, y: 80), CGPoint(x: 14, y: 80)])
        document.add(short)
        XCTAssertEqual(document.eraseStrokes(from: CGPoint(x: 12, y: 80), to: CGPoint(x: 12, y: 80), radius: 5,
                                             registersUndo: true), 1)
        XCTAssertFalse(document.objects.contains { $0.id == short.id })
    }

    func testEraserSettingsDefaultAndClamp() throws {
        let suite = "AOM333AnnotationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AnnotationSettings.eraserMode(defaults), .object)
        XCTAssertEqual(AnnotationSettings.eraserSize(defaults), AnnotationEraser.defaultRadius)
        AnnotationSettings.setEraserMode(.stroke, defaults)
        AnnotationSettings.setEraserSize(1000, defaults)
        XCTAssertEqual(AnnotationSettings.eraserMode(defaults), .stroke)
        XCTAssertEqual(AnnotationSettings.eraserSize(defaults), AnnotationEraser.radiusRange.upperBound)
        defaults.set("garbage", forKey: AnnotationSettings.Key.eraserMode)
        XCTAssertEqual(AnnotationSettings.eraserMode(defaults), .object)
        XCTAssertEqual(AnnotationSettings.backedUpKeys, ["AOMAnnotationEraserMode", "AOMAnnotationEraserSize"])
        XCTAssertEqual(AnnotationToolbarItem.forShortcut("x"), .eraser)
        XCTAssertEqual(AnnotationToolbarItem.segments.last, .eraser)
    }

    // MARK: - 3. Image layers

    private func twoTone(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    func testImageLayerRoundTripsThroughTheProjectAndRendersTheSame() throws {
        var document = AnnotationDocument(baseImage: solid(200, 100, .white))
        let id = try XCTUnwrap(document.insertImageLayer(twoTone(40, 20), imageScale: 1, scale: 1, center: CGPoint(x: 60, y: 50)))
        var layer = try XCTUnwrap(document.objects.first { $0.id == id })
        XCTAssertEqual(layer.kind, .image)
        XCTAssertEqual(layer.rect, CGRect(x: 40, y: 40, width: 40, height: 20))
        layer.rotation = .pi / 6
        layer.style.opacity = 0.8
        document.update(layer)
        document.add(AnnotationObject(kind: .text, rect: CGRect(x: 100, y: 10, width: 90, height: 50),
                                      style: AnnotationTextStylePreset.bubble.applied(to: AnnotationStyle()), text: "Hi"))
        let url = temporaryProjectURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try AnnotationProject(document: document, scale: 1).write(to: url)
        let (read, scale) = try AnnotationProject.read(from: url)
        XCTAssertEqual(scale, 1)
        XCTAssertEqual(read.objects, document.objects)
        XCTAssertEqual(read.objects[0].image?.cgImage?.width, 40)
        XCTAssertEqual(rgba(read.render(scale: 1)!).pixels, rgba(document.render(scale: 1)!).pixels)
    }

    func testImageLayerRendersInZOrderAndArrangeIsUndoable() throws {
        var document = AnnotationDocument(baseImage: solid(200, 100, .white))
        let id = try XCTUnwrap(document.insertImageLayer(solid(40, 20, .red), imageScale: 1, scale: 1))
        XCTAssertEqual(document.objects[0].rect, CGRect(x: 80, y: 40, width: 40, height: 20), "centred")
        var buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isRed(pixel(buffer, 100, 50)))
        XCTAssertTrue(isWhite(pixel(buffer, 60, 50)))
        var cover = AnnotationStyle()
        cover.color = .blue
        let box = AnnotationObject(kind: .filledRectangle, rect: CGRect(x: 90, y: 45, width: 20, height: 10), style: cover)
        document.add(box)
        buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isBlue(pixel(buffer, 100, 50)))
        XCTAssertTrue(document.arrange([id], .bringToFront))
        XCTAssertEqual(document.objects.map(\.id), [box.id, id])
        buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isRed(pixel(buffer, 100, 50)))
        XCTAssertFalse(document.arrange([id], .bringToFront), "already in front")
        document.undo()
        XCTAssertEqual(document.objects.map(\.id), [id, box.id])
        // A 2× image keeps its point size in a 2× document.
        var retina = AnnotationDocument(baseImage: solid(400, 200, .white))
        let retinaID = try XCTUnwrap(retina.insertImageLayer(solid(40, 20, .red), imageScale: 2, scale: 2))
        XCTAssertEqual(retina.objects.first { $0.id == retinaID }?.rect.size, CGSize(width: 20, height: 10))
    }

    func testRotatedImageLayerRendersRotatedClockwise() throws {
        var document = AnnotationDocument(baseImage: solid(200, 200, .white))
        _ = try XCTUnwrap(document.insertImageLayer(solid(100, 20, .red), imageScale: 1, scale: 1,
                                                    center: CGPoint(x: 100, y: 100)))
        var buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isRed(pixel(buffer, 60, 100)))
        XCTAssertTrue(isWhite(pixel(buffer, 100, 60)))
        var layer = document.objects[0]
        layer.rotation = .pi / 2
        document.update(layer)
        buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isRed(pixel(buffer, 100, 60)))
        XCTAssertTrue(isWhite(pixel(buffer, 60, 100)))
        // +45° turns the right end down, as on screen.
        layer.rotation = .pi / 4
        document.update(layer)
        buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isRed(pixel(buffer, 128, 128)))
        XCTAssertTrue(isWhite(pixel(buffer, 128, 72)))
        XCTAssertTrue(AnnotationTransformGeometry.contains(CGPoint(x: 128, y: 128), rect: layer.rect, rotation: .pi / 4))
        XCTAssertFalse(AnnotationTransformGeometry.contains(CGPoint(x: 128, y: 72), rect: layer.rect, rotation: .pi / 4))
        let bounds = layer.visualBounds
        XCTAssertGreaterThan(bounds.height, 80, "the rotated layer's bounds cover its drawn extent")
    }

    func testTransformGeometryResizesFromTheOppositeHandleAndRotates() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(AnnotationTransformGeometry.resize(rect, rotation: 0, anchor: CGPoint(x: 1, y: 1),
                                                          to: CGPoint(x: 150, y: 100), keepAspect: false),
                       CGRect(x: 0, y: 0, width: 150, height: 100))
        XCTAssertEqual(AnnotationTransformGeometry.resize(rect, rotation: 0, anchor: CGPoint(x: 1, y: 1),
                                                          to: CGPoint(x: 150, y: 100), keepAspect: true),
                       CGRect(x: 0, y: 0, width: 200, height: 100), "⇧ keeps 2:1")
        XCTAssertEqual(AnnotationTransformGeometry.resize(rect, rotation: 0, anchor: CGPoint(x: -1, y: 0),
                                                          to: CGPoint(x: -100, y: 25), keepAspect: true),
                       CGRect(x: -100, y: -25, width: 200, height: 100), "an edge handle with ⇧ grows both sides")
        XCTAssertEqual(AnnotationTransformGeometry.resize(rect, rotation: 0, anchor: CGPoint(x: 1, y: 1),
                                                          to: CGPoint(x: -50, y: -50), keepAspect: false),
                       CGRect(x: 0, y: 0, width: 4, height: 4), "never flips")

        let angle = CGFloat.pi / 3
        let fixed = AnnotationTransformGeometry.point(at: CGPoint(x: -1, y: -1), of: rect, rotation: angle)
        let pointer = CGPoint(x: 80, y: 120)
        let resized = AnnotationTransformGeometry.resize(rect, rotation: angle, anchor: CGPoint(x: 1, y: 1),
                                                         to: pointer, keepAspect: false)
        let stayed = AnnotationTransformGeometry.point(at: CGPoint(x: -1, y: -1), of: resized, rotation: angle)
        let dragged = AnnotationTransformGeometry.point(at: CGPoint(x: 1, y: 1), of: resized, rotation: angle)
        XCTAssertEqual(stayed.x, fixed.x, accuracy: 1e-6)
        XCTAssertEqual(stayed.y, fixed.y, accuracy: 1e-6)
        XCTAssertEqual(dragged.x, pointer.x, accuracy: 1e-6)
        XCTAssertEqual(dragged.y, pointer.y, accuracy: 1e-6)

        let center = CGPoint(x: 50, y: 50)
        XCTAssertEqual(AnnotationTransformGeometry.rotation(center: center, pointer: CGPoint(x: 50, y: 0), snap: false), 0, accuracy: 1e-9)
        XCTAssertEqual(AnnotationTransformGeometry.rotation(center: center, pointer: CGPoint(x: 100, y: 50), snap: false), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(AnnotationTransformGeometry.rotation(center: center, pointer: CGPoint(x: 0, y: 50), snap: false), -.pi / 2, accuracy: 1e-9)
        let nearFifteen = CGPoint(x: center.x + sin(0.27) * 40, y: center.y - cos(0.27) * 40)
        XCTAssertEqual(AnnotationTransformGeometry.rotation(center: center, pointer: nearFifteen, snap: true), .pi / 12, accuracy: 1e-9)
        XCTAssertEqual(AnnotationTransformGeometry.normalized(2.5 * .pi), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(AnnotationTransformGeometry.normalized(-2.5 * .pi), -.pi / 2, accuracy: 1e-9)
        let box = AnnotationTransformGeometry.boundingBox(of: rect, rotation: .pi / 2)
        XCTAssertEqual(box.minX, 25, accuracy: 1e-6)
        XCTAssertEqual(box.minY, -25, accuracy: 1e-6)
        XCTAssertEqual(box.width, 50, accuracy: 1e-6)
        XCTAssertEqual(box.height, 100, accuracy: 1e-6)
    }

    func testRedactionsOverAnImageLayerHideTheLayersPixels() throws {
        var document = AnnotationDocument(baseImage: solid(100, 100, .white))
        _ = try XCTUnwrap(document.insertImageLayer(solid(40, 40, .blue), imageScale: 1, scale: 1))
        XCTAssertEqual(document.objects[0].rect, CGRect(x: 30, y: 30, width: 40, height: 40))
        var style = AnnotationStyle()
        style.pixelBlockSize = 8
        document.add(AnnotationObject(kind: .pixelate, rect: CGRect(x: 35, y: 35, width: 30, height: 30), style: style))
        for kind in [AnnotationKind.pixelate, .blur, .secureBlur] {
            document.objects[1].kind = kind
            let buffer = rgba(document.render(scale: 1)!)
            XCTAssertTrue(isBlue(pixel(buffer, 50, 50)), "\(kind) samples the layer: \(pixel(buffer, 50, 50))")
        }
        // Flattening burns the same pixels into the screenshot.
        document.objects[1].kind = .pixelate
        XCTAssertTrue(document.flattenRedactions(scale: 1))
        XCTAssertTrue(document.objects.isEmpty)
        XCTAssertTrue(isBlue(pixel(rgba(document.baseImage), 50, 50)))
    }

    func testArrangeKeepsRelativeOrderAndIsOneUndoStep() {
        var document = AnnotationDocument(baseImage: solid(50, 50, .white))
        let objects = (0..<4).map { AnnotationObject(kind: .rectangle, rect: CGRect(x: CGFloat($0), y: 0, width: 5, height: 5)) }
        document.addObjects(objects)
        let ids = objects.map(\.id)
        XCTAssertTrue(document.arrange([ids[0], ids[2]], .bringToFront))
        XCTAssertEqual(document.objects.map(\.id), [ids[1], ids[3], ids[0], ids[2]])
        XCTAssertTrue(document.arrange([ids[2]], .sendToBack))
        XCTAssertEqual(document.objects.map(\.id), [ids[2], ids[1], ids[3], ids[0]])
        XCTAssertTrue(document.arrange([ids[1]], .bringForward))
        XCTAssertEqual(document.objects.map(\.id), [ids[2], ids[3], ids[1], ids[0]])
        XCTAssertTrue(document.arrange([ids[0]], .sendBackward))
        XCTAssertEqual(document.objects.map(\.id), [ids[2], ids[3], ids[0], ids[1]])
        XCTAssertFalse(document.arrange([ids[2]], .sendToBack), "already at the back")
        XCTAssertFalse(document.arrange([], .bringToFront))
        document.undo()
        XCTAssertEqual(document.objects.map(\.id), [ids[2], ids[3], ids[1], ids[0]])
    }

    func testImagePayloadLimitsAndForgedDataAreRefused() throws {
        let payload = try XCTUnwrap(AnnotationImagePayload(image: solid(5000, 4, .red)))
        XCTAssertEqual(payload.pixelWidth, 4096, "inserted images are capped at 4096 px")
        XCTAssertEqual(payload.pixelHeight, 3)
        XCTAssertTrue(payload.isValid)
        XCTAssertNotNil(payload.cgImage)

        func forged(_ change: (inout [String: Any]) -> Void) throws -> AnnotationImagePayload {
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
            fields["assetID"] = UUID().uuidString
            change(&fields)
            return try JSONDecoder().decode(AnnotationImagePayload.self,
                                            from: JSONSerialization.data(withJSONObject: fields))
        }
        XCTAssertNil(try forged { $0["pixelWidth"] = 100 }.cgImage, "data must match the recorded size")
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: solid(10, 10, .red)).representation(using: .jpeg, properties: [:]))
        XCTAssertNil(try forged {
            $0["pngData"] = jpeg.base64EncodedString()
            $0["pixelWidth"] = 10
            $0["pixelHeight"] = 10
        }.cgImage, "PNG only")

        var document = AnnotationDocument(baseImage: solid(20, 20, .white))
        document.add(AnnotationObject(kind: .image, rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                      image: try forged { $0["pixelWidth"] = 100_000 }))
        let url = temporaryProjectURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try AnnotationProject(document: document, scale: 1).write(to: url)
        XCTAssertThrowsError(try AnnotationProject.read(from: url))

        var rotated = AnnotationDocument(baseImage: solid(20, 20, .white))
        rotated.add(AnnotationObject(kind: .image, rect: CGRect(x: 0, y: 0, width: 10, height: 10), rotation: 1000))
        try AnnotationProject(document: rotated, scale: 1).write(to: url)
        XCTAssertThrowsError(try AnnotationProject.read(from: url), "rotation out of range")
    }

    func testThumbnailReadDecodesLayersSmallWithoutTouchingTheFullOpen() throws {
        var document = AnnotationDocument(baseImage: solid(300, 200, .white))
        _ = try XCTUnwrap(document.insertImageLayer(solid(300, 200, .red), imageScale: 1, scale: 1))
        let url = temporaryProjectURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try AnnotationProject(document: document, scale: 1).write(to: url)
        let (thumbnail, _) = try AnnotationProject.read(from: url, thumbnailMaxPixelSize: 64)
        let small = try XCTUnwrap(thumbnail.objects.first?.image)
        XCTAssertLessThanOrEqual(max(small.pixelWidth, small.pixelHeight), 64)
        XCTAssertNotEqual(small.assetID, document.objects[0].image?.assetID)
        XCTAssertEqual(thumbnail.objects[0].rect, document.objects[0].rect)
        let (full, _) = try AnnotationProject.read(from: url)
        XCTAssertEqual(full.objects[0].image?.pixelWidth, 300)
        XCTAssertEqual(full.objects[0].image?.cgImage?.width, 300)
    }

    func testObjectClipboardCarriesImageLayers() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AOM333Annotation.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var document = AnnotationDocument(baseImage: solid(100, 100, .white))
        _ = try XCTUnwrap(document.insertImageLayer(solid(20, 20, .red), imageScale: 1, scale: 1))
        var layer = document.objects[0]
        layer.rotation = 0.5
        document.update(layer)
        XCTAssertTrue(AnnotationObjectClipboard.write(document.objects, image: nil, scale: 1, to: pasteboard))
        let read = try XCTUnwrap(AnnotationObjectClipboard.read(from: pasteboard))
        XCTAssertEqual(read, document.objects)
        let ids = document.insertCopies(of: read, offset: 10)
        let copy = try XCTUnwrap(document.objects.first { $0.id == ids.first })
        XCTAssertEqual(copy.image?.assetID, layer.image?.assetID)
        XCTAssertEqual(copy.rotation, 0.5)
        XCTAssertEqual(copy.rect, layer.rect.offsetBy(dx: 10, dy: 10))
    }

    // MARK: - 4. Line and arrow direction

    func testLinesAndArrowsFollowTheDragDirection() {
        var style = AnnotationStyle()
        style.color = .black
        style.thickness = 4
        var document = AnnotationDocument(baseImage: solid(100, 100, .white))
        // Dragged from the bottom-left to the top-right.
        document.add(AnnotationObject(kind: .line, rect: CGRect(x: 10, y: 10, width: 80, height: 80), style: style,
                                      points: [CGPoint(x: 10, y: 90), CGPoint(x: 90, y: 10)]))
        var buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isDark(pixel(buffer, 30, 70)), "on the dragged diagonal")
        XCTAssertTrue(isWhite(pixel(buffer, 30, 30)))
        // Without stored ends (3.3.2 objects) the old top-left → bottom-right course stays.
        document.objects[0].points = []
        buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isDark(pixel(buffer, 30, 30)))
        XCTAssertTrue(isWhite(pixel(buffer, 30, 70)))

        // Dragged from the top-right to the bottom-left: the head is at the bottom-left.
        document.objects = [AnnotationObject(kind: .arrow, rect: CGRect(x: 10, y: 10, width: 80, height: 80), style: style,
                                             points: [CGPoint(x: 90, y: 10), CGPoint(x: 10, y: 90)])]
        buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isDark(pixel(buffer, 19, 85)), "beside the shaft near the end: only the head reaches here")
        XCTAssertTrue(isWhite(pixel(buffer, 85, 19)), "the same spot at the start: shaft only")
        // Resizing the arrow's rect keeps the direction (points move with it).
        let moved = document.objects[0].offsetBy(dx: 0, dy: 0)
        XCTAssertEqual(moved.lineEndpoints.start, CGPoint(x: 90, y: 10))
        XCTAssertEqual(moved.lineEndpoints.end, CGPoint(x: 10, y: 90))
    }

    // MARK: - 4. Spotlights and crop presets

    func testSeveralSpotlightsShareOneDimLayer() {
        var document = AnnotationDocument(baseImage: solid(200, 100, .white))
        var style = AnnotationStyle()
        style.spotlightOpacity = 0.5
        document.add(AnnotationObject(kind: .spotlight, rect: CGRect(x: 10, y: 10, width: 40, height: 40), style: style))
        var buffer = rgba(document.render(scale: 1)!)
        let dimmed = Int(pixel(buffer, 150, 80)[0])
        XCTAssertTrue(isWhite(pixel(buffer, 30, 30)))
        XCTAssertEqual(dimmed, 128, accuracy: 3)
        document.add(AnnotationObject(kind: .spotlight, rect: CGRect(x: 120, y: 20, width: 40, height: 40), style: style))
        buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isWhite(pixel(buffer, 30, 30)), "the first cutout stays bright")
        XCTAssertTrue(isWhite(pixel(buffer, 140, 40)), "and so does the second")
        XCTAssertEqual(Int(pixel(buffer, 100, 80)[0]), dimmed, accuracy: 3, "dimmed once, not twice")
        // Overlapping cutouts stay bright where they overlap.
        document.objects[1].rect = CGRect(x: 30, y: 30, width: 40, height: 40)
        document.objects[1].style.spotlightShape = .ellipse
        buffer = rgba(document.render(scale: 1)!)
        XCTAssertTrue(isWhite(pixel(buffer, 40, 40)))
        XCTAssertTrue(isWhite(pixel(buffer, 50, 50)))
        XCTAssertEqual(Int(pixel(buffer, 150, 80)[0]), dimmed, accuracy: 3)
    }

    func testCropPresetsGiveTheLargestCentredSelection() {
        let size = CGSize(width: 300, height: 200)
        XCTAssertEqual(AnnotationCropPreset.freeform.ratio(imageSize: size), 0)
        XCTAssertEqual(AnnotationCropPreset.original.ratio(imageSize: size), 1.5, accuracy: 1e-9)
        XCTAssertEqual(AnnotationCropPreset.r9x16.ratio(imageSize: size), 9.0 / 16.0, accuracy: 1e-9)
        let bounds = CGRect(origin: .zero, size: size)
        XCTAssertEqual(AnnotationCropPreset.centredRect(ratio: 1, in: bounds), CGRect(x: 50, y: 0, width: 200, height: 200))
        let portrait = AnnotationCropPreset.centredRect(ratio: 9.0 / 16.0, in: bounds)
        XCTAssertEqual(portrait.height, 200, accuracy: 1e-9)
        XCTAssertEqual(portrait.width / portrait.height, 9.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(portrait.midX, 150, accuracy: 1e-9)
        let wide = AnnotationCropPreset.centredRect(ratio: 21.0 / 9.0, in: bounds)
        XCTAssertEqual(wide.width, 300, accuracy: 1e-9)
        XCTAssertEqual(wide.midY, 100, accuracy: 1e-9)
        XCTAssertEqual(AnnotationCropPreset.centredRect(ratio: 0, in: bounds), bounds)
        XCTAssertEqual(Set(AnnotationCropPreset.allCases.map(\.title)).count, AnnotationCropPreset.allCases.count)
    }
}
