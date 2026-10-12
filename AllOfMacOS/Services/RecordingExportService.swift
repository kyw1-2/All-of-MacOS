import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Non-destructive, local video export. Never writes to or deletes the source MP4.
enum RecordingExportService {
    enum ExportError: LocalizedError {
        case invalidRange
        case unsupportedFile
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalidRange: "Choose an end time after the start time, inside the recording."
            case .unsupportedFile: "A readable MP4 recording is required."
            case .failed(let message): "Could not export recording: \(message)"
            }
        }
    }

    /// The original is never selected for output; collision suffixes preserve
    /// previous edits even if two exports occur within the same second.
    static func outputURL(for source: URL, suffix: String, extension ext: String) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent + " " + suffix
        let folder = source.deletingLastPathComponent()
        var target = folder.appendingPathComponent(stem).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) || target == source {
            target = folder.appendingPathComponent("\(stem) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return target
    }

    static func validatedRange(start: Double, end: Double, duration: Double) throws -> CMTimeRange {
        guard start.isFinite, end.isFinite, duration.isFinite,
              start >= 0, end > start, duration > 0,
              end <= duration + 0.05 else { throw ExportError.invalidRange }
        let safeEnd = min(duration, end)
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           end: CMTime(seconds: safeEnd, preferredTimescale: 600))
    }

    static func duration(for source: URL) async throws -> Double {
        guard source.isFileURL, source.pathExtension.lowercased() == "mp4",
              FileManager.default.isReadableFile(atPath: source.path) else { throw ExportError.unsupportedFile }
        let asset = AVURLAsset(url: source)
        let length = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(length)
        guard seconds.isFinite, seconds > 0 else { throw ExportError.unsupportedFile }
        return seconds
    }

    /// Trim MP4 losslessly when possible; AVFoundation preserves any audio track.
    static func trim(source: URL, start: Double, end: Double) async throws -> URL {
        let total = try await duration(for: source)
        let range = try validatedRange(start: start, end: end, duration: total)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.failed("This MP4 cannot be trimmed on this Mac.")
        }
        let url = outputURL(for: source, suffix: "Trimmed", extension: "mp4")
        session.outputFileType = .mp4
        session.outputURL = url
        session.timeRange = range

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed: continuation.resume()
                    case .failed, .cancelled:
                        continuation.resume(throwing: session.error ?? ExportError.failed("Export was cancelled or failed."))
                    default: continuation.resume(throwing: ExportError.failed("Unexpected exporter state."))
                    }
                }
            }
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
                throw ExportError.failed("The exported MP4 was empty.")
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Optional post-production rendering. Unlike passthrough trimming, this
    /// creates a fresh timeline, allows audio removal, and re-encodes using an
    /// explicit quality preset. The original file is never changed.
    enum StudioQuality: String, CaseIterable, Identifiable {
        case high, compact
        var id: String { rawValue }
        var displayName: String { self == .high ? "High Quality" : "Compact" }
        var preset: String {
            self == .high ? AVAssetExportPresetHighestQuality : AVAssetExportPresetMediumQuality
        }
    }

    static func render(source: URL, start: Double, end: Double,
                       muteAudio: Bool, quality: StudioQuality,
                       studio: AOMStudioSettings = AOMStudioSettings()) async throws -> URL {
        let total = try await duration(for: source)
        let range = try validatedRange(start: start, end: end, duration: total)
        let asset = AVURLAsset(url: source)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.unsupportedFile
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                         preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.failed("Could not create the video timeline.")
        }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)

        if !muteAudio {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            for sourceAudio in audioTracks {
                guard let audio = composition.addMutableTrack(withMediaType: .audio,
                                  preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw ExportError.failed("Could not create the audio timeline.")
                }
                try audio.insertTimeRange(range, of: sourceAudio, at: .zero)
            }
        }
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: quality.preset) else {
            throw ExportError.failed("A compatible video encoder is unavailable.")
        }
        let url = outputURL(for: source, suffix: "Edited", extension: "mp4")
        guard exporter.supportedFileTypes.contains(.mp4) else {
            throw ExportError.failed("The selected quality does not support MP4.")
        }
        exporter.outputURL = url
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        if studio.isActive {
            // AVFoundation owns the composition timeline. Core Image effects
            // execute on its render queue; no app/window capture or file I/O
            // happens within this callback.
            let effect = studio
            exporter.videoComposition = AVVideoComposition(
                asset: composition, applyingCIFiltersWithHandler: { request in
                    let t = CMTimeGetSeconds(request.compositionTime)
                    let timestamp = t.isFinite ? t : 0
                    let result = AOMStudioRenderer.frame(request.sourceImage,
                                                          time: timestamp, settings: effect)
                    request.finish(with: result, context: nil)
                })
        }
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed: continuation.resume()
                    case .failed, .cancelled:
                        continuation.resume(throwing: exporter.error ??
                            ExportError.failed("Encoding was cancelled or failed."))
                    default: continuation.resume(throwing:
                        ExportError.failed("Unexpected encoding state."))
                    }
                }
            }
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
                throw ExportError.failed("The rendered MP4 was empty.")
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Export the requested span as a GIF, capped at 30 seconds / 10 fps to keep
    /// memory and output file sizes bounded. Work runs off the main event loop.
    static func gif(source: URL, start: Double, end: Double, fps: Int = 8) async throws -> URL {
        let total = try await duration(for: source)
        _ = try validatedRange(start: start, end: end, duration: total)
        guard end - start <= 30.05, (1...10).contains(fps) else {
            throw ExportError.failed("GIFs support up to 30 seconds at 1–10 fps.")
        }
        return try await Task.detached(priority: .userInitiated) {
            try generateGIF(source: source, start: start, end: end, fps: fps)
        }.value
    }

    private static func generateGIF(source: URL, start: Double, end: Double, fps: Int) throws -> URL {
        let target = outputURL(for: source, suffix: "Animated", extension: "gif")
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let frames = min(300, max(1, Int(((end - start) * Double(fps)).rounded(.down))))
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
                                                                UTType.gif.identifier as CFString,
                                                                frames, nil) else {
            throw ExportError.failed("Could not initialize the GIF encoder.")
        }
        let loop: [CFString: Any] = [kCGImagePropertyGIFLoopCount: 0]
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: loop] as CFDictionary)
        let delay = 1 / Double(fps)
        let properties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
        ]

        for index in 0..<frames {
            let sample = min(end - 0.001, start + Double(index) / Double(fps))
            guard sample >= 0 else { continue }
            let time = CMTime(seconds: sample, preferredTimescale: 600)
            let frame = try generator.copyCGImage(at: time, actualTime: nil)
            CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.failed("Failed to finalize GIF frames.")
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}
