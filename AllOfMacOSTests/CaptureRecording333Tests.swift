import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AllOfMacOS

// 3.3.3 capture-recording stream: C05 video backgrounds, C06 click display
// options and the §10 CS-옵션 recording contract gaps. Every frame here is
// synthetic and every file lives in a temporary folder; nothing records the
// screen, the microphone or the camera, and nothing touches Finder.

/// Reads rendered pixels in Core Image orientation (x from the left, y from
/// the bottom), as sRGB bytes.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CIImage, bounds: CGRect? = nil) {
        let rect = bounds ?? image.extent
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
        let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: srgb)!
        self.init(cg)
    }

    init(_ cg: CGImage) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        width = cg.width
        height = cg.height
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                    bytesPerRow: cg.width * 4, space: srgb,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        bytes = data
    }

    func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        let row = height - 1 - y
        let index = (row * width + x) * 4
        return (Double(bytes[index]) / 255, Double(bytes[index + 1]) / 255, Double(bytes[index + 2]) / 255)
    }
}

private func assertColor(_ pixel: (r: Double, g: Double, b: Double), is expected: (r: Double, g: Double, b: Double),
                         tolerance: Double = 0.12, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(pixel.r, expected.r, accuracy: tolerance, "red \(message)", file: file, line: line)
    XCTAssertEqual(pixel.g, expected.g, accuracy: tolerance, "green \(message)", file: file, line: line)
    XCTAssertEqual(pixel.b, expected.b, accuracy: tolerance, "blue \(message)", file: file, line: line)
}

private let redFrame = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
private let blackFrame = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
private let red = (r: 1.0, g: 0.0, b: 0.0)
private let blue = (r: 0.0, g: 0.0, b: 1.0)
private let black = (r: 0.0, g: 0.0, b: 0.0)

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-333-recording-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A 160 × 120, 1.6 s H.264 movie of grey frames that brighten over time.
private func makeSyntheticMovie(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120
    ])
    track.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120
    ])
    writer.add(track)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<16 {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess,
              let pixel else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, Int32(40 + index * 8), CVPixelBufferGetDataSize(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for _ in 0..<100 where !track.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    track.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

private func writePNG(color: CGColor, size: Int, to url: URL) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let image = context.makeImage()!
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
}

// MARK: - C05 video backgrounds

final class CaptureRecording333BackgroundTests: XCTestCase {
    private func solid(_ color: AOMRGBAColor, padding: Double, corner: Double = 0, shadow: Double = 0) -> AOMVideoBackground {
        AOMVideoBackground(kind: .solid, color: color, padding: padding, cornerRadius: corner, shadow: shadow)
    }

    func testPixelReaderUsesCoreImageOrientation() {
        let bottom = redFrame.cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        let top = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 10, width: 20, height: 10))
        let pixels = Pixels(top.composited(over: bottom))
        assertColor(pixels.rgb(5, 2), is: red)
        assertColor(pixels.rgb(5, 17), is: blue)
    }

    func testSolidBackgroundPadsTheVideoUniformly() {
        var settings = AOMStudioSettings()
        settings.background = solid(AOMRGBAColor(red: 0, green: 0, blue: 1), padding: 0.1)
        let output = AOMStudioRenderer.frame(redFrame.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)), time: 0, settings: settings)
        XCTAssertEqual(output.extent, CGRect(x: 0, y: 0, width: 200, height: 100))
        let pixels = Pixels(output)
        // 10 px of padding (10 % of the short side); the 2:1 video fits 160 × 80 at (20, 10).
        for (x, y) in [(5, 50), (15, 50), (185, 50), (100, 5), (100, 95)] { assertColor(pixels.rgb(x, y), is: blue, "background at \(x),\(y)") }
        for (x, y) in [(22, 50), (100, 12), (177, 87), (100, 50)] { assertColor(pixels.rgb(x, y), is: red, "video at \(x),\(y)") }
    }

    func testRoundedCornersShowTheBackgroundAtTheVideoCorner() {
        var settings = AOMStudioSettings()
        settings.background = solid(AOMRGBAColor(red: 0, green: 0, blue: 1), padding: 0.1, corner: 0.25)
        let pixels = Pixels(AOMStudioRenderer.frame(redFrame.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)), time: 0, settings: settings))
        // A 20 px radius (25 % of the 80 px video height).
        for (x, y) in [(21, 11), (178, 11), (21, 88), (178, 88)] { assertColor(pixels.rgb(x, y), is: blue, "rounded corner \(x),\(y)") }
        for (x, y) in [(100, 11), (21, 50), (30, 20), (100, 50)] { assertColor(pixels.rgb(x, y), is: red, "video \(x),\(y)") }
    }

    func testShadowDarkensTheBackgroundJustBelowTheVideo() {
        var settings = AOMStudioSettings()
        let frame = redFrame.cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        settings.background = solid(AOMRGBAColor(red: 1, green: 1, blue: 1), padding: 0.2, shadow: 1)
        let shaded = Pixels(AOMStudioRenderer.frame(frame, time: 0, settings: settings))
        settings.background?.shadow = 0
        let flat = Pixels(AOMStudioRenderer.frame(frame, time: 0, settings: settings))
        // The video is 240 × 120 at (80, 40); the shadow falls just below it.
        XCTAssertLessThan(shaded.rgb(200, 36).g, 0.95, "a shadow under the video")
        XCTAssertGreaterThan(flat.rgb(200, 36).g, 0.98, "no shadow when it is off")
        XCTAssertGreaterThan(shaded.rgb(4, 4).g, 0.98, "the far background stays clean")
        assertColor(shaded.rgb(200, 100), is: red)
    }

    func testGradientPresetRunsFromTheLowerLeftToTheUpperRight() {
        var settings = AOMStudioSettings()
        settings.background = AOMVideoBackground(kind: .gradient, gradient: .sunset, padding: 0.2, shadow: 0)
        let pixels = Pixels(AOMStudioRenderer.frame(redFrame.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)), time: 0, settings: settings))
        let colors = AOMGradientPreset.sunset.colors
        assertColor(pixels.rgb(1, 1), is: (colors.start.red, colors.start.green, colors.start.blue), tolerance: 0.1)
        assertColor(pixels.rgb(198, 98), is: (colors.end.red, colors.end.green, colors.end.blue), tolerance: 0.1)
        XCTAssertEqual(Set(AOMGradientPreset.allCases.map(\.displayName)).count, AOMGradientPreset.allCases.count)
    }

    func testImageBackgroundFillsTheCanvasAndAMissingImageFallsBackToTheGradient() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appendingPathComponent("green.png")
        try writePNG(color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), size: 64, to: picture)
        var settings = AOMStudioSettings()
        settings.background = AOMVideoBackground(kind: .image, gradient: .ocean, imagePath: picture.path, padding: 0.2, shadow: 0)
        let frame = redFrame.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let pictured = Pixels(AOMStudioRenderer.frame(frame, time: 0, settings: settings))
        assertColor(pictured.rgb(2, 2), is: (0, 1, 0))
        assertColor(pictured.rgb(197, 97), is: (0, 1, 0))
        assertColor(pictured.rgb(100, 50), is: red)

        settings.background?.imagePath = folder.appendingPathComponent("missing.png").path
        settings.background?.kind = .wallpaper
        let fallback = Pixels(AOMStudioRenderer.frame(frame, time: 0, settings: settings))
        let ocean = AOMGradientPreset.ocean.colors.start
        assertColor(fallback.rgb(1, 1), is: (ocean.red, ocean.green, ocean.blue), tolerance: 0.1)
    }

    func testAspectPresetsIncludeFourByThreeAndFillWithTheBackground() {
        let source = CGSize(width: 320, height: 180)
        func size(_ aspect: AOMStudioAspect) -> CGSize { AOMStudioSettings(aspect: aspect).outputSize(source: source) }
        XCTAssertEqual(size(.landscape), CGSize(width: 320, height: 180))
        XCTAssertEqual(size(.standard), CGSize(width: 320, height: 240))
        XCTAssertEqual(size(.square), CGSize(width: 320, height: 320))
        XCTAssertEqual(size(.portrait), CGSize(width: 180, height: 320))
        XCTAssertEqual(AOMStudioAspect.standard.displayName, "4:3 Standard")

        let frame = redFrame.cropped(to: CGRect(origin: .zero, size: source))
        var settings = AOMStudioSettings(aspect: .standard)
        let letterboxed = Pixels(AOMStudioRenderer.frame(frame, time: 0, settings: settings))
        assertColor(letterboxed.rgb(160, 5), is: black, "no background: black bars as before")
        settings.background = solid(AOMRGBAColor(red: 0, green: 0, blue: 1), padding: 0)
        let output = AOMStudioRenderer.frame(frame, time: 0, settings: settings)
        XCTAssertEqual(output.extent.size, CGSize(width: 320, height: 240))
        let filled = Pixels(output)
        assertColor(filled.rgb(160, 5), is: blue, "the bars take the background")
        assertColor(filled.rgb(160, 120), is: red)
    }

    func testProjectsFromBeforeBackgroundsDecodeAndRenderTheOldBackdrop() throws {
        let old = AOMStudioSettings(backdrop: .midnight, paddingFraction: 0.15)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "background")
        let decoded = try JSONDecoder().decode(AOMStudioSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.background)
        let pixels = Pixels(AOMStudioRenderer.frame(redFrame.cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60)), time: 0, settings: decoded))
        let midnight = AOMStudioBackdrop.midnight.color
        assertColor(pixels.rgb(1, 1), is: (Double(midnight.red), Double(midnight.green), Double(midnight.blue)), tolerance: 0.08)
        assertColor(pixels.rgb(40, 30), is: red)

        let converted = AOMVideoBackground(legacy: .midnight, padding: 0.15)
        XCTAssertEqual(converted.kind, .solid)
        XCTAssertEqual(converted.padding, 0.15)
        XCTAssertEqual(converted.cornerRadius, 0)
        XCTAssertEqual(converted.shadow, 0)
        XCTAssertEqual(AOMVideoBackground(legacy: .none, padding: 0.1).kind, .none)
    }

    func testBackgroundRoundTripsThroughAStudioProjectAndToleratesUnknownValues() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("take.mp4")
        try Data(repeating: 7, count: 2048).write(to: source)
        var settings = AOMStudioSettings()
        settings.background = AOMVideoBackground(kind: .gradient, color: AOMRGBAColor(red: 0.2, green: 0.3, blue: 0.4),
                                                 gradient: .aurora, padding: 0.12, cornerRadius: 0.1, shadow: 0.7)
        try AOMStudioProject(sourceName: "take.mp4", sourceBytes: 2048, sourceDuration: 3,
                             clips: [AOMStudioClip(start: 0, end: 3)], settings: settings).write(for: source)
        XCTAssertEqual(AOMStudioProject.read(for: source, duration: 3)?.settings.background, settings.background)

        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.background)) as? [String: Any])
        json["kind"] = "sparkles"
        json.removeValue(forKey: "shadow")
        let tolerant = try JSONDecoder().decode(AOMVideoBackground.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(tolerant.kind, .none, "an unknown kind does not lose the project")
        XCTAssertEqual(tolerant.gradient, .aurora)
        XCTAssertEqual(tolerant.padding, 0.12)
        XCTAssertEqual(tolerant.shadow, 0.5)

        settings.background?.padding = .nan
        XCTAssertFalse(settings.isValid)
        XCTAssertEqual(AOMRGBAColor(hex: "#3366FF")?.hex, "#3366FFFF")
        XCTAssertEqual(AOMRGBAColor(hex: "33a6ff80")?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertNil(AOMRGBAColor(hex: "#12345"))
        XCTAssertNil(AOMRGBAColor(hex: "zzzzzz"))
    }

    func testRenderedMP4CarriesTheBackgroundAndKeepsTheSource() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        try await makeSyntheticMovie(at: source)
        let before = try Data(contentsOf: source)
        var studio = AOMStudioSettings(aspect: .square)
        studio.background = solid(AOMRGBAColor(red: 0, green: 1, blue: 0), padding: 0.2, corner: 0.1, shadow: 0.6)
        XCTAssertTrue(studio.isActive)
        let output = try await RecordingExportService.render(source: source, start: 0, end: 1.5, muteAudio: true,
                                                             quality: .high, studio: studio)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 160))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let pixels = Pixels(try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil))
        assertColor(pixels.rgb(4, 4), is: (0, 1, 0), tolerance: 0.2)
        assertColor(pixels.rgb(155, 155), is: (0, 1, 0), tolerance: 0.2)
        let centre = pixels.rgb(80, 80)
        XCTAssertEqual(centre.r, centre.g, accuracy: 0.12, "the grey video sits in the middle")
        XCTAssertEqual(try Data(contentsOf: source), before, "the source movie is never changed")
    }
}
