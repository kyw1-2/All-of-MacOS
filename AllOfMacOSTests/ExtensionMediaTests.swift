import AppKit
import XCTest
@testable import AllOfMacOS

final class ExtensionMediaTests: XCTestCase {
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    func testThumbnailDecodeBoundsImageAndRenderingBeforeComposition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.aomannotation")
        var document = AnnotationDocument(baseImage: try image(width: 4000, height: 3000))
        document.cropRect = CGRect(x: 1000, y: 500, width: 2000, height: 2000)
        document.objects = [AnnotationObject(kind: .rectangle, rect: CGRect(x: 40, y: 40, width: 80, height: 80))]
        try AnnotationProject(document: document, scale: 2).write(to: file)
        let (thumbnail, scale) = try AnnotationProject.read(from: file, thumbnailMaxPixelSize: 128)
        XCTAssertLessThanOrEqual(thumbnail.baseImage.width, 128)
        XCTAssertLessThanOrEqual(thumbnail.baseImage.height, 128)
        XCTAssertEqual(scale, 2 * 128 / 4000, accuracy: 0.001)
        XCTAssertEqual(thumbnail.cropRect?.width ?? 0, 2000 * 128 / 4000, accuracy: 1)
        XCTAssertEqual(thumbnail.objects, document.objects, "Objects stay in source points; render scale shrinks them.")
        let rendered = try XCTUnwrap(thumbnail.render(scale: scale))
        XCTAssertLessThanOrEqual(rendered.width * rendered.height, 128 * 128)
        let (original, originalScale) = try AnnotationProject.read(from: file)
        XCTAssertEqual(original.baseImage.width, 4000)
        XCTAssertEqual(originalScale, 2)
    }

    func testShareAcceptsExtensionlessURLsAndDataAndValidatesActualImageBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image(width: 16, height: 12)).representation(using: .png, properties: [:]))
        let extensionless = directory.appendingPathComponent("provider-temp")
        try png.write(to: extensionless)
        let first = try XCTUnwrap(AOMSharedImageStaging.stage(extensionless as NSURL, in: directory))
        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: first), png)
        let second = try XCTUnwrap(AOMSharedImageStaging.stage(png as NSData, in: directory))
        XCTAssertEqual(try Data(contentsOf: second), png)
        XCTAssertNotEqual(first, second)
        let misleading = directory.appendingPathComponent("not-an-image.png")
        try Data("not image bytes".utf8).write(to: misleading)
        XCTAssertNil(try AOMSharedImageStaging.stage(misleading as NSURL, in: directory))
    }
}
