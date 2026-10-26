import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import XCTest
@testable import AllOfMacOS

@MainActor
final class RecordingExportTests: XCTestCase {
    func testTrimRendersClickOnlyTrackAndPreservesSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("clicks.mp4")
        try await makeSyntheticVideo(at: source)
        let before = try Data(contentsOf: source)
        try AOMCursorTrack(points: [], clicks: [AOMClickEvent(time: 0.2, x: 0.5, y: 0.5)]).write(for: source)
        let output = try await RecordingExportService.trim(source: source, start: 0.1, end: 1.1)
        XCTAssertEqual(AOMStudioSourceLink.resolve(output), source, "Click-only recordings need a rendered standalone trim")
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 0)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testCancelledGIFDoesNotPublishOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sample.mp4")
        try await makeSyntheticVideo(at: source)
        let task = Task {
            // Cancel before exporting, deterministically, without a timer race.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RecordingExportService.gif(source: source, start: 0, end: 1, fps: 30)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled export must throw")
        } catch { /* AVFoundation may also report its own cancellation error. */ }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files, ["sample.mp4"], "No completed or temporary GIF may survive cancellation")
    }

    func testTrimAndGIFExportCreateRealMediaWithoutChangingSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-video-export-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.mp4")
        try await makeSyntheticVideo(at: source)

        let originalSize = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let fullDuration = try await RecordingExportService.duration(for: source)
        XCTAssertGreaterThan(fullDuration, 1.0)

        let trimmed = try await RecordingExportService.trim(
            source: source, start: 0.25, end: 1.20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trimmed.path))
        XCTAssertNotEqual(trimmed, source)
        let trimmedDuration = try await RecordingExportService.duration(for: trimmed)
        XCTAssertGreaterThan(trimmedDuration, 0.45)
        XCTAssertLessThan(trimmedDuration, 1.40)

        let gif = try await RecordingExportService.gif(
            source: source, start: 0.25, end: 0.90, fps: 5)
        XCTAssertEqual(gif.pathExtension, "gif")
        let gifSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(gifSource), 1)
        XCTAssertEqual(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       originalSize, "Export operations must not modify their source")
    }

    func testStudioMP4RenderIsNondestructiveAndHasValidVideo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-studio-render-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("input.mp4")
        try await makeSyntheticVideo(at: original)
        let originalBytes = try Data(contentsOf: original)
        let rendered = try await RecordingExportService.render(
            source: original, start: 0.2, end: 1.1,
            muteAudio: true, quality: .compact)
        XCTAssertNotEqual(rendered, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rendered.path))
        let duration = try await RecordingExportService.duration(for: rendered)
        XCTAssertGreaterThan(duration, 0.5)
        XCTAssertLessThan(duration, 1.3)
        let asset = AVURLAsset(url: rendered)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertTrue(audioTracks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    func testStudioZoomKeyframeSamplingAndFrameComposition() throws {
        let points = [
            AOMStudioZoomKeyframe(time: 2, magnification: 2, focusX: 0.2, focusY: 0.8),
            AOMStudioZoomKeyframe(time: 4, magnification: 1.5, focusX: 0.5, focusY: 0.5)
        ]
        let atStart = AOMStudioRenderer.sampledFocus(at: 0, keyframes: points)
        XCTAssertEqual(atStart.magnification, 1, accuracy: 0.001)
        let atPoint = AOMStudioRenderer.sampledFocus(at: 2, keyframes: points)
        XCTAssertEqual(atPoint.magnification, 2, accuracy: 0.001)
        XCTAssertEqual(atPoint.x, 0.2, accuracy: 0.001)
        let middle = AOMStudioRenderer.sampledFocus(at: 1, keyframes: points)
        XCTAssertEqual(middle.magnification, 1.5, accuracy: 0.001)
        let end = AOMStudioRenderer.sampledFocus(at: 5, keyframes: points)
        XCTAssertEqual(end.magnification, 1.5, accuracy: 0.001)

        let bounds = CGRect(x: 0, y: 0, width: 80, height: 60)
        let input = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
        let style = AOMStudioSettings(keyframes: points, backdrop: .midnight,
                                      paddingFraction: 0.15, motionBlurRadius: 0)
        let result = AOMStudioRenderer.frame(input, time: 2, settings: style)
        XCTAssertEqual(result.extent, bounds)
        let renderer = CIContext(options: [.useSoftwareRenderer: true])
        guard let bitmap = renderer.createCGImage(result, from: bounds) else {
            return XCTFail("Studio composition created no image")
        }
        let rep = NSBitmapImageRep(cgImage: bitmap)
        let corner = try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(corner.redComponent, 0.2, "outside video should use background")
        let center = try XCTUnwrap(rep.colorAt(x: 40, y: 30)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.redComponent, 0.6)
    }

    func testStudioZoomRenderProducesPlayableNonDestructiveMP4() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-studio-zoom-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("sample.mp4")
        try await makeSyntheticVideo(at: original)
        let before = try Data(contentsOf: original)
        let studio = AOMStudioSettings(
            keyframes: [AOMStudioZoomKeyframe(time: 0.45, magnification: 1.6)],
            backdrop: .graphite, paddingFraction: 0.1, motionBlurRadius: 0)
        let output = try await RecordingExportService.render(
            source: original, start: 0.1, end: 1.3,
            muteAudio: true, quality: .compact, studio: studio)
        XCTAssertNotEqual(output, original)
        let outputDuration = try await RecordingExportService.duration(for: output)
        XCTAssertGreaterThan(outputDuration, 0.8)
        XCTAssertEqual(try Data(contentsOf: original), before)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty)
    }

    func testCursorSidecarRoundTripInterpolationAndVisualOverlay() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-cursor-motion-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("example.mp4")
        let points = [
            AOMCursorPoint(time: 0, x: 0.2, y: 0.2),
            AOMCursorPoint(time: 0.5, x: 0.4, y: 0.6),
            AOMCursorPoint(time: 1.0, x: 0.5, y: 0.7)
        ]
        try AOMCursorTrack(points: points).write(for: movie)
        let track = try XCTUnwrap(AOMCursorTrack.read(for: movie))
        XCTAssertEqual(track.points, points)
        let position = try XCTUnwrap(track.smoothedPosition(at: 0.5))
        XCTAssertGreaterThan(position.x, 0.2)
        XCTAssertLessThan(position.x, 0.5)
        let bounds = CGRect(x: 0, y: 0, width: 96, height: 72)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        let settings = AOMStudioSettings(cursorPoints: points, cursorOverlaySize: 1.1)
        XCTAssertTrue(settings.isActive)
        let rendered = AOMStudioRenderer.frame(black, time: 0.5, settings: settings)
        XCTAssertEqual(rendered.extent, bounds)
        let context = CIContext()
        let pixels = try XCTUnwrap(context.createCGImage(rendered, from: bounds))
        let bitmap = NSBitmapImageRep(cgImage: pixels)
        var hasLightCursor = false
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                if (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.5 {
                    hasLightCursor = true
                    break
                }
            }
            if hasLightCursor { break }
        }
        XCTAssertTrue(hasLightCursor, "The editable pointer should render on a black frame")
    }

    func testCursorHotspotFollowsZoomAndBackgroundPadding() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        let input = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        let settings = AOMStudioSettings(
            keyframes: [AOMStudioZoomKeyframe(time: 0, magnification: 2, focusX: 0.4, focusY: 0.3)],
            backdrop: .midnight, paddingFraction: 0.1,
            cursorPoints: [AOMCursorPoint(time: 0, x: 0.4, y: 0.3)])
        let output = AOMStudioRenderer.frame(input, time: 0, settings: settings)
        let cgImage = try XCTUnwrap(CIContext().createCGImage(output, from: bounds))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var lightPixels: [CGPoint] = []
        for y in 0..<120 {
            for x in 0..<200 {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent > 0.8 {
                    lightPixels.append(CGPoint(x: x, y: y))
                }
            }
        }
        XCTAssertGreaterThan(lightPixels.count, 30)
        XCTAssertTrue(lightPixels.allSatisfy { $0.x >= 98 && $0.x <= 123 },
                      "Cursor must follow the focus target to the viewport center")
        XCTAssertTrue(lightPixels.allSatisfy { $0.y >= 58 && $0.y <= 91 })
    }

    func testTrimAndGIFRenderCursorAtSourceTime() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-cursor-trim-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sample.mp4")
        try await makeSyntheticVideo(at: source)
        let before = try Data(contentsOf: source)
        let track = AOMCursorTrack(points: (0..<32).map { index in
            AOMCursorPoint(time: Double(index) * 0.05,
                           x: index < 8 ? 0.1 : 0.75, y: 0.3)
        })
        try track.write(for: source)
        let trimmed = try await RecordingExportService.trim(source: source, start: 0.65, end: 1.3)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: trimmed))
        let image = try generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        try assertCursorOnRight(image)
        let gif = try await RecordingExportService.gif(source: source, start: 0.65, end: 1.3, fps: 5,
            studio: AOMStudioSettings(cursorPoints: track.points))
        let gifSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gifSource, 0, nil))
        try assertCursorOnRight(first)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(AOMCursorTrack.read(for: source)?.points, track.points)
    }

    func testOrderedMultiCutExportPreservesSourceAndSquareResolution() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-multicut-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        try await makeSyntheticVideo(at: source)
        let before = try Data(contentsOf: source)
        let clips = [AOMStudioClip(start: 1, end: 1.4), AOMStudioClip(start: 0.1, end: 0.5)]
        let settings = AOMStudioSettings(aspect: .square, resolution: .hd720)
        let output = try await RecordingExportService.render(source: source, start: 0, end: 1.5,
            muteAudio: true, quality: .high, studio: settings, clips: clips)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.8, accuracy: 0.15)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 1280)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let first = try generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        let second = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        let firstColor = NSBitmapImageRep(cgImage: first).colorAt(x: 640, y: 640)!.usingColorSpace(.deviceRGB)!
        let secondColor = NSBitmapImageRep(cgImage: second).colorAt(x: 640, y: 640)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(firstColor.redComponent, secondColor.redComponent + 0.1)
        let gif = try await RecordingExportService.gif(source: source, start: 0, end: 1.5,
            fps: 5, studio: settings, clips: clips)
        let gifSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let gifFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gifSource, 0, nil))
        XCTAssertEqual(gifFrame.width, gifFrame.height)
        XCTAssertEqual(CGImageSourceGetCount(gifSource), 4)
        XCTAssertEqual(AOMStudioSourceLink.resolve(output), source)
        try JSONEncoder().encode("../outside.mp4").write(to: AOMStudioSourceLink.url(for: output))
        XCTAssertEqual(AOMStudioSourceLink.resolve(output), output)
        try FileManager.default.copyItem(at: source, to: AOMStudioCameraFrames.url(for: source))
        let camera = try XCTUnwrap(AOMStudioCameraFrames(source: source))
        XCTAssertNotNil(camera.frame(at: 0.2))
        XCTAssertEqual(try Data(contentsOf: source), before)
        let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try AOMStudioProject(sourceName: source.lastPathComponent, sourceBytes: bytes, sourceDuration: 1.6,
                             clips: clips, settings: settings).write(for: source)
        XCTAssertEqual(AOMStudioProject.read(for: source, duration: 1.6)?.clips, clips)
        XCTAssertNil(AOMStudioProject.read(for: source, duration: 10))
    }

    func testCameraAndInputLayersCanBeRestyledAndDisabledWithoutTouchingScreen() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 240)
        let screen = CIImage(color: .black).cropped(to: bounds)
        let camera = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        var settings = AOMStudioSettings(clicks: [AOMClickEvent(time: 1, x: 0.2, y: 0.2)],
            keystrokes: [AOMKeystrokeEvent(time: 1, label: "⌘K")], cameraSize: 0.5, cameraX: 0.7, cameraY: 0.3)
        let context = CIContext()
        func color(_ image: CIImage, x: Int, y: Int) throws -> NSColor {
            let cg = try XCTUnwrap(context.createCGImage(image, from: bounds))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: cg).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        }
        let layered = AOMStudioRenderer.frame(screen, time: 1.2, settings: settings, cameraImage: camera)
        XCTAssertGreaterThan(try color(layered, x: 280, y: 72).greenComponent, 0.8)
        settings.showCamera = false; settings.showKeystrokes = false; settings.showClickRipples = false
        let clean = AOMStudioRenderer.frame(screen, time: 1.2, settings: settings, cameraImage: camera)
        XCTAssertLessThan(try color(clean, x: 280, y: 72).greenComponent, 0.05)
        XCTAssertEqual(clean.extent, screen.extent)
        settings.showCamera = true; settings.cameraX = 0.3; settings.cameraY = 0.6
        let moved = AOMStudioRenderer.frame(screen, time: 1.2, settings: settings, cameraImage: camera)
        XCTAssertGreaterThan(try color(moved, x: 120, y: 144).greenComponent, 0.8)
        XCTAssertLessThan(try color(moved, x: 280, y: 72).greenComponent, 0.05)
    }

    private func assertCursorOnRight(_ image: CGImage) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var whiteX: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent > 0.85 && color.greenComponent > 0.85 && color.blueComponent > 0.85 {
                    whiteX.append(x)
                }
            }
        }
        XCTAssertGreaterThan(whiteX.count, 10, "Export must include the editable cursor")
        XCTAssertTrue(whiteX.allSatisfy { $0 > bitmap.pixelsWide / 2 },
                      "Trimmed frames must use cursor samples from the selected source range")
    }

    func testRecordingSettingsValidateFrameRateQualityAudioAndClicks() {
        let savedFPS = CaptureSettings.recordingFPS
        let savedQuality = CaptureSettings.recordingQuality
        let savedAudio = CaptureSettings.recordingAudioSource
        let savedClick = CaptureSettings.recordingClickIndicators
        defer {
            CaptureSettings.recordingFPS = savedFPS
            CaptureSettings.recordingQuality = savedQuality
            CaptureSettings.recordingAudioSource = savedAudio
            CaptureSettings.recordingClickIndicators = savedClick
        }

        CaptureSettings.recordingFPS = 15
        XCTAssertEqual(CaptureSettings.recordingFPS, 15)
        CaptureSettings.recordingFPS = 400
        XCTAssertEqual(CaptureSettings.recordingFPS, 30)

        CaptureSettings.recordingQuality = 3
        XCTAssertEqual(CaptureSettings.recordingQuality, 3)
        CaptureSettings.recordingQuality = 0
        XCTAssertEqual(CaptureSettings.recordingQuality, 1)

        CaptureSettings.recordingAudioSource = .computer
        XCTAssertTrue(CaptureSettings.recordSystemAudio)
        CaptureSettings.recordingAudioSource = .microphone
        XCTAssertFalse(CaptureSettings.recordSystemAudio)
        XCTAssertEqual(CaptureSettings.recordingAudioSource, .microphone)
        CaptureSettings.recordingAudioSource = .off
        XCTAssertEqual(CaptureSettings.recordingAudioSource, .off)

        CaptureSettings.recordingClickIndicators = true
        XCTAssertTrue(CaptureSettings.recordingClickIndicators)
    }

    func testRangeValidationAndCollisionFreeOutput() throws {
        XCTAssertThrowsError(try RecordingExportService.validatedRange(start: 2, end: 1, duration: 4))
        XCTAssertThrowsError(try RecordingExportService.validatedRange(start: -1, end: 1, duration: 4))
        XCTAssertThrowsError(try RecordingExportService.validatedRange(start: 4.01, end: 4.04, duration: 4))
        XCTAssertThrowsError(try RecordingExportService.validatedRange(start: 0, end: 100, duration: 4))
        XCTAssertEqual(CMTimeGetSeconds(try RecordingExportService.validatedRange(
            start: 1, end: 2.5, duration: 4).duration), 1.5, accuracy: 0.01)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-export-path-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("recording.mp4")
        let first = RecordingExportService.outputURL(for: source, suffix: "Trimmed", extension: "mp4")
        try Data("previous export".utf8).write(to: first)
        let next = RecordingExportService.outputURL(for: source, suffix: "Trimmed", extension: "mp4")
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(try Data(contentsOf: first), Data("previous export".utf8))
    }

    private func makeSyntheticVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120
        ])
        track.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: track,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 120
            ])
        writer.add(track)
        guard writer.startWriting() else {
            throw writer.error ?? RecordingExportService.ExportError.failed("Could not start the test encoder.")
        }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<16 {
            var pixel: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 160, 120,
                                             kCVPixelFormatType_32ARGB, nil, &pixel)
            guard result == kCVReturnSuccess, let pixel else {
                throw RecordingExportService.ExportError.failed("No test pixel buffer.")
            }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                memset(base, Int32(index * 11), CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            for _ in 0..<100 where !track.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
                throw writer.error ?? RecordingExportService.ExportError.failed("Could not encode test frame.")
            }
        }
        track.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RecordingExportService.ExportError.failed("Synthetic video did not finalize.")
        }
    }
}
