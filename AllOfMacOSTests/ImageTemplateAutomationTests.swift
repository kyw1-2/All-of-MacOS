import XCTest
import CoreGraphics
@testable import AllOfMacOS

final class ImageTemplateAutomationTests: XCTestCase {
    private func noise(_ width: Int, _ height: Int, seed: UInt32 = 1) throws -> ImageMatchPixels {
        var state = seed
        var bytes = [UInt8]()
        for _ in 0..<(width * height) {
            for _ in 0..<3 { state = state &* 1664525 &+ 1013904223; bytes.append(UInt8(truncatingIfNeeded: state >> 16)) }
            bytes.append(255)
        }
        return try ImageMatchPixels(width: width, height: height, rgba: bytes)
    }
    private func placing(_ template: ImageMatchPixels, in screen: ImageMatchPixels, x: Int, y: Int, noise: Int = 0) throws -> ImageMatchPixels {
        var pixels = screen.rgba
        for row in 0..<template.height {
            for column in 0..<template.width {
                for component in 0..<4 {
                    let source = (row * template.width + column) * 4 + component
                    let target = ((row + y) * screen.width + column + x) * 4 + component
                    pixels[target] = UInt8(min(255, Int(template.rgba[source]) + (component < 3 ? noise : 0)))
                }
            }
        }
        return try ImageMatchPixels(width: screen.width, height: screen.height, rgba: pixels)
    }
    func testFindsExactTemplateAtPixelOffsetAndIncludesLastLegalPosition() throws {
        let template = try noise(9, 7, seed: 88), screen = try noise(96, 64)
        for point in [(31, 17), (87, 57)] {
            let patched = try placing(template, in: screen, x: point.0, y: point.1)
            let match = try XCTUnwrap(ImageTemplateMatcher.find(in: patched, template: template, threshold: 1))
            XCTAssertEqual(match.x, point.0); XCTAssertEqual(match.y, point.1); XCTAssertEqual(match.score, 1)
        }
    }
    func testThresholdAcceptsSmallNoiseButRejectsWrongAppearance() throws {
        let template = try noise(10, 8, seed: 88), screen = try noise(80, 50)
        let patched = try placing(template, in: screen, x: 20, y: 10, noise: 3)
        XCTAssertNil(try ImageTemplateMatcher.find(in: patched, template: template, threshold: 1))
        let match = try XCTUnwrap(ImageTemplateMatcher.find(in: patched, template: template, threshold: 0.98))
        XCTAssertEqual(match.x, 20); XCTAssertEqual(match.y, 10); XCTAssertGreaterThan(match.score, 0.98)
        XCTAssertNil(try ImageTemplateMatcher.find(in: screen, template: template, threshold: 0.98))
    }
    func testTransparentPaddingDoesNotCompareInvisibleColor() throws {
        var bytes = try noise(5, 5, seed: 42).rgba
        for y in 0..<5 { for x in 0..<5 where x == 0 || y == 0 || x == 4 || y == 4 { bytes[(y * 5 + x) * 4 + 3] = 0 } }
        let template = try ImageMatchPixels(width: 5, height: 5, rgba: bytes)
        var screen = try placing(template, in: noise(30, 20), x: 11, y: 8).rgba
        for y in 0..<5 { for x in 0..<5 where x == 0 || y == 0 || x == 4 || y == 4 {
            let offset = ((y + 8) * 30 + x + 11) * 4
            screen[offset] = 255; screen[offset + 1] = 255; screen[offset + 2] = 255; screen[offset + 3] = 255
        } }
        let match = try XCTUnwrap(ImageTemplateMatcher.find(in: ImageMatchPixels(width: 30, height: 20, rgba: screen), template: template, threshold: 1))
        XCTAssertEqual(match.x, 11); XCTAssertEqual(match.y, 8)
    }
    func testCancellationAndComparisonBudgetFailWithoutReturningAnUnverifiedMatch() throws {
        let template = try noise(10, 10, seed: 2), screen = try noise(100, 100)
        XCTAssertThrowsError(try ImageTemplateMatcher.find(in: screen, template: template, threshold: 0.98, isCancelled: { true })) {
            XCTAssertEqual($0 as? ImageTemplateError, .cancelled)
        }
        XCTAssertThrowsError(try ImageTemplateMatcher.find(in: screen, template: template, threshold: 0.98, maximumComparisons: 1)) {
            XCTAssertEqual($0 as? ImageTemplateError, .budgetExceeded)
        }
        XCTAssertThrowsError(try ImageTemplateMatcher.find(in: screen, template: template, threshold: 0.98, timeout: 0)) {
            XCTAssertEqual($0 as? ImageTemplateError, .budgetExceeded)
        }
    }
    func testPointConversionUsesDisplayOriginAndActualPixelScale() throws {
        let screen = try noise(80, 50), template = try noise(8, 6)
        let point = ImageTemplateMatcher.center(.init(x: 20, y: 10, score: 1), template: template, screen: screen,
                                               bounds: CGRect(x: -1280, y: 200, width: 1280, height: 800))
        XCTAssertEqual(point.x, -896); XCTAssertEqual(point.y, 408)
    }
    func testRasterizationPreservesTopToBottomPixelOrder() throws {
        let input = try noise(4, 3, seed: 5)
        let data = Data(input.rgba) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        let image = try XCTUnwrap(CGImage(width: 4, height: 3, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        XCTAssertEqual(try ImageMatchPixels.rasterize(image, scale: 1), input)
    }
    func testRejectsInvalidDimensionsTransparentTemplateAndUnsafeActionConfig() throws {
        XCTAssertThrowsError(try ImageMatchPixels(width: -1, height: 1, rgba: []))
        let screen = try noise(4, 4)
        let transparent = try ImageMatchPixels(width: 2, height: 2, rgba: Array(repeating: 0, count: 16))
        XCTAssertThrowsError(try ImageTemplateMatcher.find(in: screen, template: transparent, threshold: 1))
        XCTAssertThrowsError(try ImageTemplateMatcher.find(in: screen, template: noise(5, 5), threshold: 1))
        var action = TriggerAction(actionType: .matchScreenImage)
        XCTAssertNotNil(ActionParameterValidation.problem(for: action))
        action.parameters.imageTemplatePath = "/tmp/template.png"
        XCTAssertNil(ActionParameterValidation.problem(for: action))
        action.parameters.imageMatchThreshold = 0.1
        XCTAssertNotNil(ActionParameterValidation.problem(for: action))
        action.parameters.imageMatchThreshold = 0.98; action.parameters.imageMatchVariable = "bad.name"
        XCTAssertNotNil(ActionParameterValidation.problem(for: action))
    }
}
