import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
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
        guard start < safeEnd else { throw ExportError.invalidRange }
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
        // Cursor-track recordings intentionally omit the baked pointer. Render
        // it into standalone trims so playback never depends on a missing sidecar.
        let track = AOMCursorTrack.read(for: source)
        let hasOverlays = track.map { !$0.points.isEmpty || !($0.clicks ?? []).isEmpty || !($0.keystrokes ?? []).isEmpty } ?? false
        if hasOverlays || FileManager.default.fileExists(atPath: AOMStudioCameraFrames.url(for: source).path) {
            return try await render(source: source, start: start, end: end,
                                    muteAudio: false, quality: .high,
                                    studio: AOMStudioSettings(cursorPoints: track?.points ?? [], clicks: track?.clicks ?? [], keystrokes: track?.keystrokes ?? []),
                                    outputSuffix: "Trimmed")
        }
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
                       studio: AOMStudioSettings = AOMStudioSettings(),
                       outputSuffix: String = "Edited",
                       clips: [AOMStudioClip]? = nil) async throws -> URL {
        let total = try await duration(for: source)
        let selected = clips ?? [AOMStudioClip(start: start, end: end)]
        guard !selected.isEmpty, selected.count <= 1000 else { throw ExportError.invalidRange }
        let ranges = try selected.map { try validatedRange(start: $0.start, end: $0.end, duration: total) }
        let asset = AVURLAsset(url: source)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.unsupportedFile
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                         preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.failed("Could not create the video timeline.")
        }
        var outputTime = CMTime.zero
        for range in ranges {
            try video.insertTimeRange(range, of: sourceVideo, at: outputTime)
            outputTime = CMTimeAdd(outputTime, range.duration)
        }
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)

        if !muteAudio {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            for sourceAudio in audioTracks {
                guard let audio = composition.addMutableTrack(withMediaType: .audio,
                                  preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw ExportError.failed("Could not create the audio timeline.")
                }
                var outputTime = CMTime.zero
                let available = try await sourceAudio.load(.timeRange)
                for range in ranges {
                    let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
                    if intersection.duration > .zero {
                        try audio.insertTimeRange(intersection, of: sourceAudio, at: CMTimeAdd(outputTime, CMTimeSubtract(intersection.start, range.start)))
                    }
                    outputTime = CMTimeAdd(outputTime, range.duration)
                }
            }
        }
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: quality.preset) else {
            throw ExportError.failed("A compatible video encoder is unavailable.")
        }
        let url = outputURL(for: source, suffix: outputSuffix, extension: "mp4")
        guard exporter.supportedFileTypes.contains(.mp4) else {
            throw ExportError.failed("The selected quality does not support MP4.")
        }
        exporter.outputURL = url
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        let camera = studio.showCamera ? AOMStudioCameraFrames(source: source) : nil
        let effect = studio
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let transform = try await sourceVideo.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform).size
        let sourceSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let filters = AVMutableVideoComposition(asset: composition, applyingCIFiltersWithHandler: { request in
            let outputTime = CMTimeGetSeconds(request.compositionTime)
            let sourceTime = AOMStudioClip.sourceTime(at: outputTime, clips: selected) ?? selected.last!.end
            let result = AOMStudioRenderer.frame(request.sourceImage, time: sourceTime, settings: effect,
                cameraImage: camera?.frame(at: sourceTime))
            request.finish(with: result, context: nil)
        })
        filters.renderSize = studio.outputSize(source: sourceSize)
        exporter.videoComposition = filters
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
            try AOMStudioSourceLink.write(presentation: url, source: source)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Mix separately captured microphone/system tracks into one universally
    /// playable AAC track. Replace only after the full export has completed.
    static func mixRecordedAudio(in source: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count > 1 else { return }
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        for original in try await asset.loadTracks(withMediaType: .video) {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ExportError.failed("Could not create the video track.")
            }
            try track.insertTimeRange(range, of: original, at: .zero)
            track.preferredTransform = try await original.load(.preferredTransform)
        }
        var parameters: [AVMutableAudioMixInputParameters] = []
        for original in tracks {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ExportError.failed("Could not create the mixed audio track.")
            }
            // A sound source may begin a little after the first screen frame.
            let available = try await original.load(.timeRange)
            let segment = CMTimeRangeGetIntersection(range, otherRange: available)
            if segment.duration > .zero { try track.insertTimeRange(segment, of: original, at: segment.start) }
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(0.75, at: .zero)
            parameters.append(parameter)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failed("Audio mixing is unavailable.")
        }
        let temporary = source.deletingLastPathComponent().appendingPathComponent(".mixed-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        exporter.outputURL = temporary; exporter.outputFileType = .mp4
        exporter.audioMix = mix
        try await complete(exporter)
        _ = try FileManager.default.replaceItemAt(source, withItemAt: temporary)
    }

    /// Fragmented MP4 files keep completed fragments usable after a stream or
    /// process interruption. Export a new movie; retain the original fragments.
    static func recoverInterrupted(source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let length = try await asset.load(.duration)
        guard CMTimeGetSeconds(length).isFinite, length > .zero,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw ExportError.failed("No complete movie fragment was saved.")
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.failed("These fragments cannot be recovered.")
        }
        let target = outputURL(for: source, suffix: "Recovered", extension: "mp4")
        exporter.outputURL = target; exporter.outputFileType = .mp4
        do {
            try await complete(exporter)
            try await mixRecordedAudio(in: target)
            if let track = AOMCursorTrack.read(for: source) { try track.write(for: target) }
            let camera = AOMStudioCameraFrames.url(for: source)
            if FileManager.default.fileExists(atPath: camera.path) {
                try FileManager.default.copyItem(at: camera, to: AOMStudioCameraFrames.url(for: target))
            }
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    private static func complete(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: exporter.error ?? ExportError.failed("The export did not complete.")) }
            }
        }
    }

    /// Export the requested span as a GIF, capped at 120 seconds / 30 fps to keep
    /// memory and output file sizes bounded. Work runs off the main event loop.
    static func gif(source: URL, start: Double, end: Double, fps: Int = 8,
                    studio: AOMStudioSettings = AOMStudioSettings(), clips: [AOMStudioClip]? = nil) async throws -> URL {
        let total = try await duration(for: source)
        let range = try validatedRange(start: start, end: end, duration: total)
        let safeEnd = CMTimeGetSeconds(range.end)
        let selected = clips ?? [AOMStudioClip(start: start, end: safeEnd)]
        guard !selected.isEmpty, selected.count <= 1000, selected.allSatisfy({ $0.isValid(duration: total) }) else { throw ExportError.invalidRange }
        guard selected.reduce(0, { $0 + $1.duration }) <= 120.5, (1...30).contains(fps) else {
            throw ExportError.failed("GIFs support up to 120 seconds at 1–30 fps.")
        }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try generateGIF(source: source, clips: selected, fps: fps, studio: studio)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func generateGIF(source: URL, clips: [AOMStudioClip], fps: Int,
                                    studio: AOMStudioSettings) throws -> URL {
        let target = outputURL(for: source, suffix: "Animated", extension: "gif")
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let camera = studio.showCamera ? AOMStudioCameraFrames(source: source) : nil
        if studio.isActive || camera != nil {
            let filters = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
                let result = AOMStudioRenderer.frame(request.sourceImage,
                    time: CMTimeGetSeconds(request.compositionTime), settings: studio, cameraImage: camera?.frame(at: CMTimeGetSeconds(request.compositionTime)))
                request.finish(with: result, context: nil)
            })
            filters.renderSize = studio.outputSize(source: filters.renderSize)
            generator.videoComposition = filters
        }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / Double(fps), preferredTimescale: 600)
        let length = clips.reduce(0) { $0 + $1.duration }
        let frames = max(1, Int((length * Double(fps)).rounded(.up)))
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
            let sample = AOMStudioClip.sourceTime(at: min(length - 0.001, Double(index) / Double(fps)), clips: clips) ?? clips[0].start
            guard sample >= 0 else { continue }
            let time = CMTime(seconds: sample, preferredTimescale: 600)
            try Task.checkCancellation()
            try autoreleasepool {
                let frame = try generator.copyCGImage(at: time, actualTime: nil)
                CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
            }
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.failed("Failed to finalize GIF frames.")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}
