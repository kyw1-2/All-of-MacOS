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

/// Runs `body` and puts the listed UserDefaults keys back as they were.
private func preservingDefaults<T>(_ keys: [String], _ body: () async throws -> T) async rethrows -> T {
    let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    defer {
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
    return try await body()
}

// MARK: - C06 click display options

final class CaptureRecording333ClickTests: XCTestCase {
    private let frame = blackFrame.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
    private let redColor = AOMRGBAColor(red: 1, green: 0, blue: 0)
    private let greenColor = AOMRGBAColor(red: 0, green: 1, blue: 0)

    private func render(clicks: [AOMClickEvent], style: AOMClickStyle?, at time: Double) -> Pixels {
        var settings = AOMStudioSettings(clicks: clicks)
        settings.clickStyle = style
        return Pixels(AOMStudioRenderer.frame(frame, time: time, settings: settings))
    }

    func testClickMarksUseTheLeftAndTheRightClickColour() {
        let clicks = [AOMClickEvent(time: 0, x: 0.25, y: 0.5, button: 0), AOMClickEvent(time: 0, x: 0.75, y: 0.5, button: 1)]
        let style = AOMClickStyle(shape: .filled, leftColor: redColor, rightColor: greenColor, size: 1, duration: 1)
        let pixels = render(clicks: clicks, style: style, at: 0.3)
        let left = pixels.rgb(50, 50), right = pixels.rgb(150, 50)
        XCTAssertGreaterThan(left.r, 0.2); XCTAssertLessThan(left.g, 0.05)
        XCTAssertGreaterThan(right.g, 0.2); XCTAssertLessThan(right.r, 0.05)
        assertColor(pixels.rgb(100, 50), is: black, "nothing between the clicks")
    }

    /// The strongest red on the horizontal line through a mark, near `radius`.
    private func peak(_ pixels: Pixels, centreX: Int, radius: Int) -> Double {
        (-2...2).map { pixels.rgb(centreX + radius + $0, 50).r }.max() ?? 0
    }

    func testRingFilledAndDoubleRingShapes() {
        let click = [AOMClickEvent(time: 0, x: 0.25, y: 0.5)]
        // At 30 % of a 1 s mark the ring has a 17 px radius.
        let ring = render(clicks: click, style: AOMClickStyle(shape: .ring, leftColor: redColor, duration: 1), at: 0.3)
        assertColor(ring.rgb(50, 50), is: black, "a ring leaves its centre clear")
        XCTAssertGreaterThan(peak(ring, centreX: 50, radius: 17), 0.15, "the ring itself")
        let filled = render(clicks: click, style: AOMClickStyle(shape: .filled, leftColor: redColor, duration: 1), at: 0.3)
        XCTAssertGreaterThan(filled.rgb(50, 50).r, 0.2, "a filled mark covers its centre")
        let double = render(clicks: click, style: AOMClickStyle(shape: .double, leftColor: redColor, duration: 1), at: 0.3)
        XCTAssertGreaterThan(peak(double, centreX: 50, radius: 17), 0.15, "outer ring")
        XCTAssertGreaterThan(peak(double, centreX: 50, radius: 8), 0.15, "inner ring at 8.5 px")
        assertColor(double.rgb(50, 50), is: black)
    }

    func testClickDurationAndSizeAreApplied() {
        let click = AOMClickEvent(time: 0, x: 0.25, y: 0.5)
        XCTAssertEqual(AOMStudioTimeline.activeClicks(at: 1.0, clicks: [click], duration: 1.5).count, 1)
        XCTAssertEqual(AOMStudioTimeline.activeClicks(at: 1.0, clicks: [click]).count, 0, "0.65 s by default, as before")
        XCTAssertEqual(AOMStudioTimeline.activeClicks(at: 1.0, clicks: [click], duration: .nan).count, 0)
        let long = render(clicks: [click], style: AOMClickStyle(shape: .filled, leftColor: redColor, duration: 1.5), at: 1.0)
        XCTAssertGreaterThan(long.rgb(50, 50).r, 0.1, "still visible after a second")
        let legacy = render(clicks: [click], style: nil, at: 1.0)
        assertColor(legacy.rgb(50, 50), is: black)

        let small = render(clicks: [click], style: AOMClickStyle(leftColor: redColor, size: 1, duration: 1), at: 0.3)
        let large = render(clicks: [click], style: AOMClickStyle(leftColor: redColor, size: 2, duration: 1), at: 0.3)
        // Twice the size: a 34 px radius instead of 17.
        XCTAssertGreaterThan(peak(large, centreX: 50, radius: 34), 0.15)
        XCTAssertLessThan(peak(small, centreX: 50, radius: 34), 0.02)
        XCTAssertEqual(AOMClickStyle(size: 99, duration: -1).clampedSize, 3)
        XCTAssertEqual(AOMClickStyle(size: 99, duration: -1).clampedDuration, 0.2)
    }

    func testOldProjectsKeepTheBlueRingForEveryButton() {
        let pixels = render(clicks: [AOMClickEvent(time: 0, x: 0.25, y: 0.5, button: 1)], style: nil, at: 0.2)
        // 0.2 s into the 0.65 s ring: radius 8 + 0.31 × 30 ≈ 17 px.
        let onRing = (-2...2).map { pixels.rgb(50 + 17 + $0, 50) }.max { $0.b < $1.b }!
        XCTAssertGreaterThan(onRing.b, 0.12)
        XCTAssertGreaterThan(onRing.b, onRing.r + 0.1, "blue, not the new orange right-click colour")
        XCTAssertEqual(AOMClickStyle.legacy.color(button: 1), AOMClickStyle.defaultLeftColor)
        XCTAssertNotEqual(AOMClickStyle().color(button: 1), AOMClickStyle().color(button: 0))
    }

    func testCursorHighlightIsDrawnEvenWhenThePointerIsHidden() {
        let points = [AOMCursorPoint(time: 0, x: 0.5, y: 0.5), AOMCursorPoint(time: 1, x: 0.5, y: 0.5)]
        var settings = AOMStudioSettings(cursorPoints: points, cursorStyle: .hidden)
        assertColor(Pixels(AOMStudioRenderer.frame(frame, time: 0.5, settings: settings)).rgb(100, 50), is: black)
        settings.cursorHighlight = AOMCursorHighlight(color: AOMRGBAColor(red: 1, green: 0.84, blue: 0, alpha: 1), size: 1)
        let lit = Pixels(AOMStudioRenderer.frame(frame, time: 0.5, settings: settings))
        assertColor(lit.rgb(100, 50), is: (1, 0.84, 0), tolerance: 0.1)
        assertColor(lit.rgb(100 + 20, 50), is: (1, 0.84, 0), tolerance: 0.1)
        assertColor(lit.rgb(100 + 40, 50), is: black, "a 32 px halo")
        settings.cursorHighlight?.size = 2
        let wide = Pixels(AOMStudioRenderer.frame(frame, time: 0.5, settings: settings))
        XCTAssertGreaterThan(wide.rgb(100 + 40, 50).r, 0.8)
    }

    func testCursorSizeScalesThePointer() {
        let points = [AOMCursorPoint(time: 0, x: 0.3, y: 0.3), AOMCursorPoint(time: 1, x: 0.3, y: 0.3)]
        func whitePixels(_ size: Double) -> Int {
            let pixels = Pixels(AOMStudioRenderer.frame(frame, time: 0.5, settings: AOMStudioSettings(cursorPoints: points, cursorOverlaySize: size)))
            var count = 0
            for y in 0..<pixels.height { for x in 0..<pixels.width where pixels.rgb(x, y).g > 0.8 { count += 1 } }
            return count
        }
        let normal = whitePixels(1), double = whitePixels(2)
        XCTAssertGreaterThan(normal, 40)
        XCTAssertGreaterThan(Double(double) / Double(normal), 2.5)
        XCTAssertLessThan(Double(double) / Double(normal), 5.5)
    }

    func testKeystrokeModifierChoiceDecidesWhichShortcutsShow() {
        func label(_ flags: NSEvent.ModifierFlags, _ characters: String, keyCode: UInt16 = 7,
                   modifiers: Set<KeystrokeShortcutModifier> = KeystrokeShortcutModifier.defaultSet) -> String? {
            ScreenRecordingService.keystrokeLabel(keyCode: keyCode, flags: flags, characters: characters, allKeys: false,
                                                  shortcutModifiers: ScreenRecordingService.modifierFlags(modifiers))
        }
        XCTAssertEqual(label([.option], "x"), "⌥X")
        XCTAssertNil(label([.option], "x", modifiers: [.command]), "⌥ excluded, e.g. for layouts that type with it")
        XCTAssertEqual(label([.command, .option], "k", modifiers: [.command]), "⌥⌘K")
        XCTAssertNil(label([.shift], "a"), "Shift-typed text is not a shortcut by default")
        XCTAssertEqual(label([.shift], "a", modifiers: [.command, .shift]), "⇧A")
        XCTAssertEqual(label([], "", keyCode: 123, modifiers: []), "←", "navigation keys still show")
        XCTAssertEqual(ScreenRecordingService.keystrokeLabel(keyCode: 8, flags: [.command, .shift], characters: "c", allKeys: false), "⇧⌘C")

        XCTAssertEqual(KeystrokeShortcutModifier.parse(nil), KeystrokeShortcutModifier.defaultSet)
        XCTAssertEqual(KeystrokeShortcutModifier.parse(""), [])
        XCTAssertEqual(KeystrokeShortcutModifier.parse("shift, command,bogus"), [.shift, .command])
        XCTAssertEqual(KeystrokeShortcutModifier.serialize([.shift, .command]), "command,shift")
    }

    func testControlClickCountsAsARightClick() {
        XCTAssertEqual(ScreenRecordingService.clickButton(type: .leftMouseDown, buttonNumber: 0, flags: []), 0)
        XCTAssertEqual(ScreenRecordingService.clickButton(type: .leftMouseDown, buttonNumber: 0, flags: [.control]), 1)
        XCTAssertEqual(ScreenRecordingService.clickButton(type: .rightMouseDown, buttonNumber: 1, flags: []), 1)
        XCTAssertEqual(ScreenRecordingService.clickButton(type: .otherMouseDown, buttonNumber: 4, flags: []), 2)
    }

    private let pointerKeys = ["AOMCaptureRecordingShowsCursor", "AOMCaptureShowsCursor",
                               "AOMCaptureRecordingClickIndicators", "AOMCaptureRecordingCursorMotion"]

    func testThePointerChoiceIsIndependentOfShowMouseClicks() async {
        await preservingDefaults(pointerKeys) {
            let d = UserDefaults.standard
            d.removeObject(forKey: "AOMCaptureRecordingShowsCursor")
            d.set(false, forKey: "AOMCaptureShowsCursor")
            d.set(true, forKey: "AOMCaptureRecordingClickIndicators")
            XCTAssertNil(CaptureSettings.recordingShowsCursorChoice)
            XCTAssertTrue(CaptureSettings.recordingShowsCursor, "unset: the pre-3.3.3 rule")
            CaptureSettings.recordingShowsCursor = false
            XCTAssertFalse(CaptureSettings.recordingShowsCursor, "audit CS-38: clicks no longer force the pointer on")
            XCTAssertFalse(ScreenRecordingService.capturesSystemPointer(editableTrack: false, showsCursor: CaptureSettings.recordingShowsCursor))
            XCTAssertTrue(ScreenRecordingService.capturesSystemPointer(editableTrack: false, showsCursor: true))
            XCTAssertFalse(ScreenRecordingService.capturesSystemPointer(editableTrack: true, showsCursor: true),
                           "an editable pointer replaces the system one")
        }
    }

    private var displayKeys: [String] { CaptureSettings.recording333BackedUpKeys + pointerKeys }

    func testRecordingDefaultsCarryTheDisplayOptions() async {
        await preservingDefaults(displayKeys) {
            let style = AOMClickStyle(shape: .double, leftColor: AOMRGBAColor(hex: "#10203040")!, rightColor: AOMRGBAColor(hex: "#A0B0C0FF")!,
                                      size: 1.5, duration: 1.2)
            CaptureSettings.recordingClickStyle = style
            CaptureSettings.recordingClickIndicators = true
            CaptureSettings.recordingCursorHighlight = true
            CaptureSettings.recordingCursorSize = 2
            UserDefaults.standard.removeObject(forKey: "AOMCaptureRecordingShowsCursor")
            let clicks = [AOMClickEvent(time: 1, x: 0.5, y: 0.5)]
            let track = AOMCursorTrack(points: [AOMCursorPoint(time: 0, x: 0.1, y: 0.1)], clicks: clicks)
            let defaults = AOMStudioSettings.recordingDefaults(track: track)
            XCTAssertEqual(defaults.clickStyle, style)
            XCTAssertEqual(defaults.clicks, clicks)
            XCTAssertTrue(defaults.showClickRipples)
            XCTAssertEqual(defaults.cursorOverlaySize, 2)
            XCTAssertNotNil(defaults.cursorHighlight)
            XCTAssertEqual(defaults.cursorStyle, .arrow, "an editable pointer stays visible unless hidden on purpose")

            var baked = track
            baked.pointerInVideo = true
            XCTAssertEqual(AOMStudioSettings.recordingDefaults(track: baked).cursorStyle, .hidden, "never a second pointer")
            CaptureSettings.recordingShowsCursor = false
            XCTAssertEqual(AOMStudioSettings.recordingDefaults(track: track).cursorStyle, .hidden)
            CaptureSettings.recordingClickIndicators = false
            CaptureSettings.recordingCursorHighlight = false
            let quiet = AOMStudioSettings.recordingDefaults(track: track)
            XCTAssertTrue(quiet.clicks.isEmpty)
            XCTAssertFalse(quiet.showClickRipples)
            XCTAssertNil(quiet.cursorHighlight)
        }
    }

    func testDisplaySettingsRoundTripClampAndAreBackedUp() async {
        await preservingDefaults(displayKeys) {
            let d = UserDefaults.standard
            let highlight = AOMCursorHighlight(color: AOMRGBAColor(hex: "#FF000080")!, size: 2.5)
            CaptureSettings.recordingCursorHighlightStyle = highlight
            XCTAssertEqual(CaptureSettings.recordingCursorHighlightStyle, highlight)
            CaptureSettings.recordingKeystrokeModifiers = [.command]
            XCTAssertEqual(CaptureSettings.recordingKeystrokeModifiers, [.command])
            d.removeObject(forKey: "AOMCaptureRecordingKeystrokeModifiers")
            XCTAssertEqual(CaptureSettings.recordingKeystrokeModifiers, KeystrokeShortcutModifier.defaultSet)

            d.set(10.0, forKey: "AOMCaptureRecordingClickSize")
            d.set(-4.0, forKey: "AOMCaptureRecordingClickDuration")
            d.set("not a colour", forKey: "AOMCaptureRecordingClickColor")
            d.set("triangle", forKey: "AOMCaptureRecordingClickStyle")
            let style = CaptureSettings.recordingClickStyle
            XCTAssertEqual(style.size, 3)
            XCTAssertEqual(style.duration, 0.2)
            XCTAssertEqual(style.leftColor, AOMClickStyle.defaultLeftColor)
            XCTAssertEqual(style.shape, .ring)
            d.set(9.0, forKey: "AOMCaptureRecordingCursorSize")
            XCTAssertEqual(CaptureSettings.recordingCursorSize, 3)
            CaptureSettings.recordingCursorSize = .nan
            XCTAssertEqual(CaptureSettings.recordingCursorSize, 1)

            for key in CaptureSettings.recording333BackedUpKeys {
                XCTAssertTrue(PresetManager.isBackedUpSetting(key), "\(key) is in profile backups")
            }
        }
    }

    func testSidecarRemembersWhetherThePointerIsInTheVideo() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("take.mp4")
        try AOMCursorTrack(points: [AOMCursorPoint(time: 0, x: 0.2, y: 0.2)], pointerInVideo: true).write(for: movie)
        XCTAssertEqual(AOMCursorTrack.read(for: movie)?.pointerInVideo, true)
        try Data(#"{"points":[{"time":0,"x":0.5,"y":0.5}]}"#.utf8).write(to: AOMCursorTrack.sidecarURL(for: movie))
        let legacy = try XCTUnwrap(AOMCursorTrack.read(for: movie))
        XCTAssertNil(legacy.pointerInVideo)
    }

    /// End to end: the recorded click track plus the saved click options
    /// come out in the exported movie's pixels.
    func testExportedMovieDrawsClicksFromTheTrackWithTheChosenStyle() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("clicks.mp4")
        try await makeSyntheticMovie(at: source)
        try AOMCursorTrack(points: [], clicks: [AOMClickEvent(time: 0.5, x: 0.5, y: 0.5)]).write(for: source)
        try await preservingDefaults(displayKeys) {
            CaptureSettings.recordingClickStyle = AOMClickStyle(shape: .filled, leftColor: AOMRGBAColor(red: 0, green: 1, blue: 0),
                                                                size: 2, duration: 1)
            CaptureSettings.recordingCursorHighlight = false
            let output = try await RecordingExportService.trim(source: source, start: 0.1, end: 1.5)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            // Output 0.6 s is source 0.7 s: 20 % into a 1 s mark, a 21 px green disc.
            let pixels = Pixels(try generator.copyCGImage(at: CMTime(seconds: 0.6, preferredTimescale: 600), actualTime: nil))
            let centre = pixels.rgb(80, 60), corner = pixels.rgb(8, 8)
            XCTAssertGreaterThan(centre.g - centre.r, 0.2, "the green click mark")
            XCTAssertEqual(corner.g, corner.r, accuracy: 0.08, "untouched grey away from the click")
        }
    }
}

// MARK: - §10 CS-옵션 recording contract gaps

/// A stand-in for Finder's `CreateDesktop` preference and its restart.
@MainActor
private final class FakeFinder {
    var value: Bool?
    var restarts = 0
    var writes = 0
    init(_ value: Bool?) { self.value = value }
    var finder: RecordingDesktopIcons.Finder {
        RecordingDesktopIcons.Finder(read: { self.value },
                                     write: { self.value = $0; self.writes += 1 },
                                     restart: { self.restarts += 1 })
    }
}

@MainActor
final class CaptureRecording333ContractTests: XCTestCase {
    func testDesktopIconsAreHiddenOnlyWhenShowingAndArePutBack() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = folder.appendingPathComponent("icons.json")
        let fake = FakeFinder(nil)
        let icons = RecordingDesktopIcons(journal: journal, finder: fake.finder)

        XCTAssertTrue(icons.hide())
        XCTAssertEqual(fake.value, false)
        XCTAssertEqual(fake.restarts, 1)
        XCTAssertTrue(icons.isHidingIcons, "journaled before the change")
        XCTAssertFalse(icons.hide(), "a restarted take keeps them hidden without another Finder restart")
        XCTAssertEqual(fake.restarts, 1)
        icons.restore()
        XCTAssertNil(fake.value, "an unset preference goes back to unset")
        XCTAssertEqual(fake.restarts, 2)
        XCTAssertFalse(icons.isHidingIcons)
        icons.restore()
        XCTAssertEqual(fake.restarts, 2, "nothing to restore twice")

        fake.value = true
        XCTAssertTrue(icons.hide())
        icons.restore()
        XCTAssertEqual(fake.value, true)

        // Icons the user had hidden already are left alone and never shown.
        fake.value = false
        let restarts = fake.restarts
        XCTAssertFalse(icons.hide())
        XCTAssertFalse(icons.isHidingIcons)
        icons.restore()
        XCTAssertEqual(fake.value, false)
        XCTAssertEqual(fake.restarts, restarts)
    }

    func testDesktopIconsComeBackAtTheNextLaunchAfterACrash() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = folder.appendingPathComponent("icons.json")
        let fake = FakeFinder(true)
        XCTAssertTrue(RecordingDesktopIcons(journal: journal, finder: fake.finder).hide())
        // The process ends without stopping; a new instance reads the journal.
        let relaunched = RecordingDesktopIcons(journal: journal, finder: fake.finder)
        XCTAssertTrue(relaunched.isHidingIcons)
        relaunched.restore()
        XCTAssertEqual(fake.value, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))

        // An unreadable journal still shows the icons again.
        fake.value = false
        try Data("not json".utf8).write(to: journal)
        relaunched.restore()
        XCTAssertNil(fake.value)
        XCTAssertFalse(relaunched.isHidingIcons)

        // Shown again by hand meanwhile: no needless Finder restart.
        XCTAssertTrue(relaunched.hide())
        fake.value = true
        let restarts = fake.restarts
        relaunched.restore()
        XCTAssertEqual(fake.restarts, restarts)
        XCTAssertNil(fake.value)
    }

    func testFocusShortcutEngagedForARecordingIsUndoneAfterACrash() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalRunner = RecordingFocus.runner, originalJournal = RecordingFocus.journalURL
        defer { RecordingFocus.runner = originalRunner; RecordingFocus.journalURL = originalJournal }
        var ran: [String] = []
        RecordingFocus.runner = { ran.append($0) }
        RecordingFocus.journalURL = folder.appendingPathComponent("focus.json")
        try await preservingDefaults(["AOMCaptureRecordingFocus", "AOMCaptureRecordingFocusOn", "AOMCaptureRecordingFocusOff"]) {
            CaptureSettings.recordingFocus = true
            CaptureSettings.recordingFocusOnShortcut = "Focus On Test"
            CaptureSettings.recordingFocusOffShortcut = "Focus Off Test"
            RecordingFocus.engage()
            XCTAssertEqual(ran, ["Focus On Test"])
            XCTAssertEqual(RecordingSystemState.read(RecordingFocus.journalURL)?["offShortcut"], "Focus Off Test")
            RecordingFocus.release()
            XCTAssertEqual(ran, ["Focus On Test", "Focus Off Test"])
            XCTAssertNil(RecordingSystemState.read(RecordingFocus.journalURL))

            // A crash left the journal behind: the next launch turns Focus off.
            XCTAssertTrue(RecordingSystemState.write(["offShortcut": "Older Off"], to: RecordingFocus.journalURL))
            RecordingFocus.recoverAfterUnexpectedExit()
            XCTAssertEqual(ran.last, "Older Off")
            RecordingFocus.recoverAfterUnexpectedExit()
            XCTAssertEqual(ran.count, 3, "only once")
            CaptureSettings.recordingFocus = false
            RecordingFocus.engage()
            XCTAssertEqual(ran.count, 3, "off unless opted in")
        }
    }

    func testGIFOptionsBoundTheFrameSizeAndTheLoop() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("movie.mp4")
        try await makeSyntheticMovie(at: source)
        let big = AOMStudioSettings(aspect: .square, resolution: .hd720)
        func frameWidthAndLoop(_ gif: URL) throws -> (Int, Int?) {
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
            let properties = CGImageSourceCopyProperties(image, nil) as? [CFString: Any]
            let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (frame.width, gifProperties?[kCGImagePropertyGIFLoopCount] as? Int)
        }
        let small = try await RecordingExportService.gif(source: source, start: 0, end: 1, fps: 2, studio: big,
                                                         maxDimension: 480, loops: false)
        let (smallWidth, once) = try frameWidthAndLoop(small)
        XCTAssertEqual(smallWidth, 480)
        XCTAssertNotEqual(once, 0, "plays once instead of looping forever")
        let standard = try await RecordingExportService.gif(source: source, start: 0, end: 1, fps: 2, studio: big)
        let (standardWidth, forever) = try frameWidthAndLoop(standard)
        XCTAssertEqual(standardWidth, 960, "960 px stays the default")
        XCTAssertEqual(forever, 0)

        try await preservingDefaults(["AOMCaptureRecordingGIFSize", "AOMCaptureRecordingGIFLoop"]) {
            UserDefaults.standard.removeObject(forKey: "AOMCaptureRecordingGIFSize")
            UserDefaults.standard.removeObject(forKey: "AOMCaptureRecordingGIFLoop")
            XCTAssertEqual(CaptureSettings.recordingGIFMaxDimension, 960)
            XCTAssertTrue(CaptureSettings.recordingGIFLoops)
            CaptureSettings.recordingGIFMaxDimension = 640
            XCTAssertEqual(CaptureSettings.recordingGIFMaxDimension, 640)
            UserDefaults.standard.set(777, forKey: "AOMCaptureRecordingGIFSize")
            XCTAssertEqual(CaptureSettings.recordingGIFMaxDimension, 960)
            CaptureSettings.recordingGIFLoops = false
            XCTAssertFalse(CaptureSettings.recordingGIFLoops)
        }
    }

    func testScaleRetinaTo1xAndTheEncoderLimit() async {
        XCTAssertEqual(ScreenRecordingService.captureScale(displayScales: [2, 1], scalesTo1x: false, longestEdge: 1000), 2)
        XCTAssertEqual(ScreenRecordingService.captureScale(displayScales: [2], scalesTo1x: true, longestEdge: 1000), 1)
        XCTAssertEqual(ScreenRecordingService.captureScale(displayScales: [2], scalesTo1x: false, longestEdge: 5000), 7680.0 / 5000,
                       accuracy: 0.0001)
        XCTAssertEqual(ScreenRecordingService.captureScale(displayScales: [], scalesTo1x: false, longestEdge: 100), 1)
        await preservingDefaults(["AOMCaptureRecordingScaleTo1x", "AOMCaptureRecordingHidesDesktopIcons"]) {
            UserDefaults.standard.removeObject(forKey: "AOMCaptureRecordingScaleTo1x")
            UserDefaults.standard.removeObject(forKey: "AOMCaptureRecordingHidesDesktopIcons")
            XCTAssertFalse(CaptureSettings.recordingScalesTo1x)
            XCTAssertFalse(CaptureSettings.recordingHidesDesktopIcons, "hiding desktop icons is opt-in")
            CaptureSettings.recordingScalesTo1x = true
            XCTAssertTrue(CaptureSettings.recordingScalesTo1x)
        }
        for key in ["AOMCaptureRecordingHidesDesktopIcons", "AOMCaptureRecordingGIFSize", "AOMCaptureRecordingGIFLoop",
                    "AOMCaptureRecordingScaleTo1x"] {
            XCTAssertTrue(PresetManager.isBackedUpSetting(key), "\(key) is in profile backups")
        }
    }
}

final class CaptureRecording333DeviceTests: XCTestCase {
    /// Pure choice logic only: no device is opened or listed here.
    func testAChosenCameraOrMicrophoneIsUsedOnlyWhileConnected() {
        XCTAssertNil(RecordingInputDevice.chosen("", among: ["built-in"]), "empty is the system default")
        XCTAssertEqual(RecordingInputDevice.chosen("usb-cam", among: ["built-in", "usb-cam"]), "usb-cam")
        XCTAssertEqual(RecordingInputDevice.chosen(" usb-cam ", among: ["usb-cam"]), "usb-cam")
        XCTAssertNil(RecordingInputDevice.chosen("unplugged", among: ["built-in"]), "falls back instead of failing the take")
    }

    func testDeviceChoicesRoundTripAndStayOutOfBackups() async {
        let keys = ["AOMCaptureRecordingCameraID", "AOMCaptureRecordingMicrophoneID"]
        await preservingDefaults(keys) {
            for key in keys { UserDefaults.standard.removeObject(forKey: key) }
            XCTAssertEqual(CaptureSettings.recordingCameraID, "")
            XCTAssertEqual(CaptureSettings.recordingMicrophoneID, "")
            CaptureSettings.recordingCameraID = "cam-1"
            CaptureSettings.recordingMicrophoneID = "mic-1"
            XCTAssertEqual(CaptureSettings.recordingCameraID, "cam-1")
            XCTAssertEqual(CaptureSettings.recordingMicrophoneID, "mic-1")
        }
        for key in keys {
            XCTAssertTrue(CaptureSettings.machineSpecificKeys.contains(key))
            XCTAssertFalse(PresetManager.isBackedUpSetting(key), "\(key) describes this Mac")
            XCTAssertNotNil(PresetManager.settingsNotBackedUp[key])
        }
    }
}
