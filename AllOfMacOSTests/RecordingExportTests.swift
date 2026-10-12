import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import XCTest
@testable import AllOfMacOS

@MainActor
final class RecordingExportTests: XCTestCase {
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
        XCTAssertFalse(try await asset.loadTracks(withMediaType: .video).isEmpty)
        XCTAssertTrue(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
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
