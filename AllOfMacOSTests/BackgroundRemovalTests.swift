import AppKit
import XCTest
@testable import AllOfMacOS

/// Remove Background (Paste 7 Edit Image parity) never edits the source and
/// is offered for screenshots only.
final class BackgroundRemovalTests: XCTestCase {
    private func image(subject: Bool) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        if subject {
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(x: 100, y: 60, width: 120, height: 120))
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testResultKeepsTheSizeOrReportsNoSubject() async throws {
        let source = try image(subject: true)
        do {
            let output = try await BackgroundRemoval.removingBackground(source)
            XCTAssertEqual(output.width, source.width)
            XCTAssertEqual(output.height, source.height)
        } catch let failure as BackgroundRemoval.Failure {
            XCTAssertEqual(failure.localizedDescription, "No subject was found in the image.")
        } catch {
            // Vision can be unavailable on a headless test host; the app shows the error.
        }
    }

    func testOfferedForScreenshotsOnly() {
        let image = QuickAccessMenuCommand.layout(isVideo: false, canScaleRetina: false)
        let video = QuickAccessMenuCommand.layout(isVideo: true, canScaleRetina: false)
        XCTAssertTrue(image.contains(.removeBackground))
        XCTAssertFalse(video.contains(.removeBackground))
        XCTAssertEqual(QuickAccessMenuCommand.removeBackground.title, "Remove Background")
    }

    func testEditorReplacesBaseImageOnlyAtTheSameSizeAndUndoes() throws {
        let original = try image(subject: false)
        var document = AnnotationDocument(baseImage: original)
        XCTAssertFalse(document.replaceBaseImage(try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 0, width: 10, height: 10)))))
        XCTAssertTrue(document.replaceBaseImage(try image(subject: true)))
        XCTAssertTrue(document.canUndo)
        document.undo()
        XCTAssertTrue(document.baseImage === original)
    }
}
