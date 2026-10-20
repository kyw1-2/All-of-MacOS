import AppKit
import ImageIO
import XCTest
@testable import AllOfMacOS

final class CaptureColorProfileTests: XCTestCase {
    func testWebPExplicitlyUsesSRGBWhileOtherFormatsHonorPreference() {
        XCTAssertEqual(CaptureColorProfile.display.effective(for: .webp), .sRGB)
        for format in [CaptureFormat.png, .jpeg, .tiff, .heic] {
            XCTAssertEqual(CaptureColorProfile.display.effective(for: format), .display)
        }
    }
    func testSRGBConversionChangesProfileAndPreservesDimensionsAndAlpha() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: 17, height: 11,
                                            bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: p3, components: [1, 0.3, 0, 0.5])!)
        context.fill(CGRect(x: 0, y: 0, width: 17, height: 11))
        let original = try XCTUnwrap(context.makeImage())
        let preserved = try XCTUnwrap(CaptureColorProfile.display.applying(to: original))
        XCTAssertTrue(original === preserved)
        let converted = try XCTUnwrap(CaptureColorProfile.sRGB.applying(to: original))
        XCTAssertEqual(converted.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(converted.width, 17)
        XCTAssertEqual(converted.height, 11)
        XCTAssertEqual(converted.alphaInfo, .premultipliedLast)
        let capture = CaptureResult(image: original, globalRect: CGRect(x: 0, y: 0, width: 17, height: 11), scale: 1, kind: .area)
        for format in [CaptureFormat.png, .jpeg, .tiff] {
            let data = try ScreenCaptureService.shared.encode(capture, format: format, colorProfile: .sRGB)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 17)
            XCTAssertEqual(decoded.height, 11)
            XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB)
        }
    }
}
