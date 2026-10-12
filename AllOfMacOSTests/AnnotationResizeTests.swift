import XCTest
import AppKit
import CoreGraphics
@testable import AllOfMacOS

/// Deterministic coverage for the independently implemented Resize Image dialog
/// informed by REA 5.0.1 ANResizeControlViewController NIB evidence.
final class AnnotationResizeTests: XCTestCase {
    private func image(width: Int = 100, height: Int = 60) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testResizeChangesPixelsAndScalesEditableAnnotations() {
        var document = AnnotationDocument(baseImage: image())
        let rectangle = AnnotationObject(kind: .rectangle,
                                         rect: CGRect(x: 10, y: 5, width: 20, height: 10))
        let freehand = AnnotationObject(kind: .draw,
                                        rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                                        points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)])
        document.add(rectangle)
        document.add(freehand)
        XCTAssertTrue(document.resize(toPixelWidth: 200, height: 120, scale: 1))
        XCTAssertEqual(document.croppedImage.width, 200)
        XCTAssertEqual(document.croppedImage.height, 120)
        XCTAssertEqual(document.objects[0].rect, CGRect(x: 20, y: 10, width: 40, height: 20))
        XCTAssertEqual(document.objects[1].points, [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)])
        XCTAssertEqual(document.objects[0].style.thickness, 6)
        document.undo()
        XCTAssertEqual(document.croppedImage.width, 100)
        XCTAssertEqual(document.objects[0].rect, rectangle.rect)
        XCTAssertEqual(document.objects[1].points, freehand.points)
        document.redo()
        XCTAssertEqual(document.croppedImage.width, 200)
        XCTAssertEqual(document.objects[1].points[1], CGPoint(x: 60, y: 60))
    }

    func testInvalidDimensionsDoNotMutateOrDestroyUndoHistory() {
        var document = AnnotationDocument(baseImage: image())
        document.add(AnnotationObject(kind: .rectangle,
                                      rect: CGRect(x: 1, y: 1, width: 12, height: 7)))
        for (w,h) in [(0,10),(-1,12),(17000,3),(16000,16000)] {
            XCTAssertFalse(document.resize(toPixelWidth: w, height: h, scale: 1))
        }
        XCTAssertFalse(document.resize(toPixelWidth: 50, height: 40, scale: 0))
        XCTAssertEqual(document.croppedImage.width, 100)
        XCTAssertEqual(document.objects.count, 1)
        document.undo()
        XCTAssertTrue(document.objects.isEmpty)
    }

    func testFlattenRemovesEditableLayersAndUndoRestoresBackground() {
        var document = AnnotationDocument(baseImage: image())
        document.add(AnnotationObject(kind: .rectangle,
                                      rect: CGRect(x: 1, y: 1, width: 20, height: 20)))
        document.beginChange()
        document.background.padding = 4
        XCTAssertTrue(document.resize(toPixelWidth: 220, height: 140,
                                      scale: 1, flattenAnnotations: true))
        XCTAssertEqual(document.croppedImage.width, 220)
        XCTAssertTrue(document.objects.isEmpty)
        XCTAssertEqual(document.background.padding, 0)
        document.undo()
        XCTAssertEqual(document.croppedImage.width, 100)
        XCTAssertEqual(document.objects.count, 1)
        XCTAssertEqual(document.background.padding, 4)
        document.redo()
        XCTAssertTrue(document.objects.isEmpty)
        XCTAssertEqual(document.background.padding, 0)
    }

    func testSolidRedactionReplacesUnderlyingPixelsEvenWithLowOpacity() {
        var document = AnnotationDocument(baseImage: image(width: 50, height: 50))
        var transparent = AnnotationStyle()
        transparent.opacity = 0.1
        transparent.color = .white
        document.add(AnnotationObject(kind: .redact,
                                      rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                                      style: transparent))
        guard let output = document.render(scale: 1) else {
            return XCTFail("Could not render redaction")
        }
        let bmp = NSBitmapImageRep(cgImage: output)
        let center = bmp.colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!
        XCTAssertLessThan(center.redComponent, 0.02)
        XCTAssertLessThan(center.greenComponent, 0.02)
        XCTAssertLessThan(center.blueComponent, 0.02)
        let outside = bmp.colorAt(x: 2, y: 2)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(outside.redComponent, 0.95)
        XCTAssertLessThan(outside.greenComponent, 0.05)
        document.undo()
        XCTAssertTrue(document.objects.isEmpty)
    }

    func testResizeUsesCroppedImageAsSource() {
        var document = AnnotationDocument(baseImage: image(width: 100, height: 80))
        document.setCrop(CGRect(x: 5, y: 5, width: 40, height: 20))
        XCTAssertTrue(document.resize(toPixelWidth: 80, height: 40, scale: 1))
        XCTAssertNil(document.cropRect)
        XCTAssertEqual(document.croppedImage.width, 80)
        document.undo()
        XCTAssertEqual(document.cropRect, CGRect(x: 5, y: 5, width: 40, height: 20))
        XCTAssertEqual(document.baseImage.width, 100)
    }
}
