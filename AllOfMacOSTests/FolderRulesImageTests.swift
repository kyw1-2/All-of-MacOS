import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AllOfMacOS

/// Optimize Image: the plan (sizes, formats, quality) and real encodes of
/// generated images in a temporary folder.
final class FolderRulesImageTests: XCTestCase {
    private var kit: FolderRulesTestKit!

    override func setUpWithError() throws { kit = try FolderRulesTestKit() }
    override func tearDown() { kit.remove() }

    func testTargetSizesKeepTheAspectRatio() {
        XCTAssertTrue(FolderRulesImageOptimizer.targetSize(width: 4032, height: 3024, maxDimension: 2560) == (2560, 1920))
        XCTAssertTrue(FolderRulesImageOptimizer.targetSize(width: 3024, height: 4032, maxDimension: 2560) == (1920, 2560))
        XCTAssertTrue(FolderRulesImageOptimizer.targetSize(width: 5000, height: 5000, maxDimension: 1000) == (1000, 1000))
        XCTAssertTrue(FolderRulesImageOptimizer.targetSize(width: 1200, height: 800, maxDimension: 2560) == (1200, 800), "already fits")
        XCTAssertTrue(FolderRulesImageOptimizer.targetSize(width: 9000, height: 10, maxDimension: 0) == (9000, 10), "0 keeps the size")
        XCTAssertTrue(FolderRulesImageOptimizer.targetSize(width: 9000, height: 10, maxDimension: 900) == (900, 1), "never below 1 px")
    }

    func testThePlanPicksFormatsAndQuality() throws {
        var options = FolderRuleImageOptions(maxDimension: 2000, quality: 0.7, stripLocation: true, screenshotOutput: .heic)
        let jpeg = try FolderRulesImageOptimizer.plan(typeIdentifier: "public.jpeg", width: 4000, height: 3000,
                                                      isScreenshot: false, options: options).get()
        XCTAssertEqual(jpeg.output, .jpeg)
        XCTAssertEqual(jpeg.quality, 0.7)
        XCTAssertTrue(jpeg.resizes)
        XCTAssertEqual([jpeg.targetWidth, jpeg.targetHeight], [2000, 1500])
        let screenshot = try FolderRulesImageOptimizer.plan(typeIdentifier: "public.png", width: 1440, height: 900,
                                                            isScreenshot: true, options: options).get()
        XCTAssertEqual(screenshot.output, .heic)
        XCTAssertTrue(screenshot.changesFormat)
        XCTAssertFalse(screenshot.resizes)
        let png = try FolderRulesImageOptimizer.plan(typeIdentifier: "public.png", width: 1440, height: 900,
                                                     isScreenshot: false, options: options).get()
        XCTAssertEqual(png.output, .png, "only screenshots change format")
        XCTAssertNil(png.quality, "PNG is lossless")
        options.screenshotOutput = .keep
        XCTAssertEqual(try FolderRulesImageOptimizer.plan(typeIdentifier: "public.png", width: 10, height: 10, isScreenshot: true,
                                                          options: options).get().output, .png)
        options.quality = 7
        XCTAssertEqual(try FolderRulesImageOptimizer.plan(typeIdentifier: "public.heic", width: 10, height: 10, isScreenshot: false,
                                                          options: options).get().quality, 1, "quality is clamped to 0.1–1")
        XCTAssertThrowsError(try FolderRulesImageOptimizer.plan(typeIdentifier: "com.compuserve.gif", width: 10, height: 10,
                                                                isScreenshot: false, options: options).get())
    }

    func testOptimizingAJPEGResizesReencodesAndDropsTheLocation() throws {
        let photo = kit.watched.appendingPathComponent("Trip.jpg")
        try writeImage(photo, type: .jpeg, width: 3200, height: 2400, gps: true, quality: 1)
        XCTAssertNotNil(properties(photo)[kCGImagePropertyGPSDictionary], "the fixture has a location")
        let info = try XCTUnwrap(FolderRuleFileReader.read(photo))
        let options = FolderRuleImageOptions(maxDimension: 1600, quality: 0.6, stripLocation: true)
        let step = try FolderRulesImageOptimizer.optimize(photo, info: info, options: options, environment: kit.environment())
        XCTAssertEqual(step.record.result, .done, step.record.summary)
        let output = try XCTUnwrap(step.next)
        XCTAssertEqual(output.lastPathComponent, "Trip.jpg")
        let result = properties(output)
        XCTAssertEqual(result[kCGImagePropertyPixelWidth] as? Int, 1600)
        XCTAssertEqual(result[kCGImagePropertyPixelHeight] as? Int, 1200)
        XCTAssertNil(result[kCGImagePropertyGPSDictionary], "location removed")
        XCTAssertEqual(CGImageSourceGetType(CGImageSourceCreateWithURL(output as CFURL, nil)!) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(kit.names(in: kit.trash), ["Trip.jpg"], "the original waits in the Trash")
        XCTAssertNotNil(FolderRuleMetadata.attribute(FolderRuleMetadata.optimizedAttribute, at: output.path))
        XCTAssertTrue(step.record.summary.contains("3200×2400 → 1600×1200"))
        // Marked: a second run leaves it alone.
        let again = try FolderRulesImageOptimizer.optimize(output, info: try XCTUnwrap(FolderRuleFileReader.read(output)),
                                                           options: options, environment: kit.environment())
        XCTAssertEqual(again.record.result, .skipped)
        // Undo puts the original back and the optimized copy in the Trash.
        let undone = FolderRuleExecutor(environment: kit.environment()).undo([step.record])
        XCTAssertNil(undone.failure)
        XCTAssertEqual(properties(photo)[kCGImagePropertyPixelWidth] as? Int, 3200)
    }

    func testPNGScreenshotsBecomeJPEGOnAWhiteBackground() throws {
        let shot = kit.watched.appendingPathComponent("Screenshot 1.png")
        try writeImage(shot, type: .png, width: 800, height: 500, gps: false, transparent: true)
        let flag = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        XCTAssertTrue(FolderRuleMetadata.setAttribute(FolderRuleMetadata.screenCaptureAttribute, flag, at: shot.path))
        let info = try XCTUnwrap(FolderRuleFileReader.read(shot))
        XCTAssertTrue(info.isScreenCapture)
        let options = FolderRuleImageOptions(maxDimension: 0, quality: 0.85, screenshotOutput: .jpeg, original: .overwrite)
        let step = try FolderRulesImageOptimizer.optimize(shot, info: info, options: options, environment: kit.environment())
        XCTAssertEqual(step.record.result, .done, step.record.summary)
        let output = try XCTUnwrap(step.next)
        XCTAssertEqual(output.lastPathComponent, "Screenshot 1.jpg")
        XCTAssertEqual(kit.names(in: kit.trash), ["Screenshot 1.png"], "a format change keeps the original in the Trash, even with Overwrite")
        XCTAssertEqual(FolderRuleFileReader.read(output)?.isScreenCapture, true, "the screenshot flag follows the image")
        // The transparent corner turned white, not black.
        let pixel = try XCTUnwrap(cornerPixel(output))
        XCTAssertGreaterThan(pixel, 0.9)
    }

    func testOverwriteReplacesInPlaceAndNothingToDoIsSkipped() throws {
        let photo = kit.watched.appendingPathComponent("Big.heic")
        try writeImage(photo, type: .heic, width: 2000, height: 1000, gps: false, quality: 1)
        let info = try XCTUnwrap(FolderRuleFileReader.read(photo))
        let options = FolderRuleImageOptions(maxDimension: 1000, quality: 0.5, original: .overwrite)
        let step = try FolderRulesImageOptimizer.optimize(photo, info: info, options: options, environment: kit.environment())
        XCTAssertEqual(step.record.result, .done, step.record.summary)
        XCTAssertEqual(step.next, photo)
        XCTAssertEqual(properties(photo)[kCGImagePropertyPixelWidth] as? Int, 1000)
        XCTAssertEqual(kit.names(in: kit.trash), [], "overwritten in place")
        XCTAssertNil(step.record.undo)

        let small = kit.watched.appendingPathComponent("Icon.png")
        try writeImage(small, type: .png, width: 64, height: 64, gps: false)
        let skip = try FolderRulesImageOptimizer.optimize(small, info: try XCTUnwrap(FolderRuleFileReader.read(small)),
                                                          options: FolderRuleImageOptions(maxDimension: 2560), environment: kit.environment())
        XCTAssertEqual(skip.record.result, .skipped, "a small PNG without location has nothing to optimize")
        XCTAssertEqual(kit.names(in: kit.trash), [])
    }

    // MARK: Helpers

    private func writeImage(_ url: URL, type: UTType, width: Int, height: Int, gps: Bool, quality: Double = 0.9,
                            transparent: Bool = false) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if !transparent {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Detail, so the encoders have something to compress.
        for index in 0..<40 {
            context.setFillColor(CGColor(red: Double(index % 7) / 7, green: Double(index % 5) / 5, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: (index * 37) % max(1, width - 40) + 20, y: (index * 53) % max(1, height - 40) + 20, width: 30, height: 20))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.5839, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 127.0588, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    /// The brightness of the top-left pixel, 0–1.
    private func cornerPixel(_ url: URL) throws -> Double? {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: -(image.height - 1), width: image.width, height: image.height))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}
