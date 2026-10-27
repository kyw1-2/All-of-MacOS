import AppKit
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreImage
import Carbon
import Foundation
import ScreenCaptureKit
import SwiftUI

/// Captures each intersecting display into a shared, pause-aware movie timeline.
@MainActor
final class ScreenRecordingService: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenRecordingService()
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedSeconds = 0
    private var streams: [SCStream] = []
    private var displayRects: [ObjectIdentifier: CGRect] = [:]
    private var frames: [ObjectIdentifier: CIImage] = [:]
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var firstSampleTime: CMTime?
    private var lastVideoTime: CMTime?
    private var firstImage: CGImage?
    private var recordingRect = CGRect.zero
    private var timer: Timer?
    private var isSessionStarted = false
    private var isStarting = false
    private var isStopping = false
    private var recordedScale: CGFloat = 1
    private var outputGIF = false
    private var recordsEditableCursor = false
    private var gifFPS = 10
    private var outputSize = CGSize.zero
    private var cursorSampler: Timer?
    private var cursorPoints: [AOMCursorPoint] = []
    private var pauseStarted: CMTime?
    private var pausedDuration = CMTime.zero
    private var acceptAudioAfter = CMTime.zero
    private var camera: RecordingCameraSource?
    private var cameraImage: CIImage?
    private var cameraWriter: AVAssetWriter?
    private var cameraInput: AVAssetWriterInput?
    private var cameraAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var cameraStarted = false
    private var clickEvents: [AOMClickEvent] = []
    private var keyEvents: [AOMKeystrokeEvent] = []
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var keyImage: CIImage?
    private var keyExpires = Date.distantPast
    private let ciContext = CIContext()
    private let recordingQueue = DispatchQueue(label: "com.kyw.allofmacos.screen-recording", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.kyw.allofmacos.screen-recording-audio", qos: .userInitiated)

    private override init() { super.init() }

    static func uniqueRecordingURL(in directory: URL, at date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Screen Recording \(formatter.string(from: date))"
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension("mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension("mp4")
            suffix += 1
        }
        return candidate
    }

    func toggleRecording() {
        if isRecording { Task { try? await stopRecording() } }
        else { promptAndStartRecording() }
    }

    func recordFullscreenUnderPointer() {
        guard !isRecording, !isStarting, !isStopping, !SelectionOverlayController.isActive else { return }
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = ScreenCaptureService.displayUnderPointer(in: content.displays)
                        ?? content.displays.first else { throw CaptureError.noDisplays }
                try await startRecording(globalRect: display.frame)
            } catch { GestureHUD.shared.show(title: "Recording Failed", detail: error.localizedDescription) }
        }
    }

    func promptAndStartRecording() {
        guard !isRecording, !isStarting, !isStopping, !SelectionOverlayController.isActive else { return }
        SelectionOverlayController { [weak self] rect in
            guard let self, let selected = rect, selected.width >= 30, selected.height >= 30 else { return }
            Task {
                do { try await self.startRecording(globalRect: selected) }
                catch { GestureHUD.shared.show(title: "Recording Failed", detail: error.localizedDescription) }
            }
        }.present()
    }

    func startRecording(globalRect: CGRect) async throws {
        guard !isRecording, !isStarting, !isStopping else { return }
        isStarting = true
        defer {
            isStarting = false
            // Any failed start, wherever it threw, takes the camera bubble down.
            if !isRecording { RecordingCameraBubble.shared.hide() }
        }
        recordsEditableCursor = CaptureSettings.recordingCursorMotion
        outputGIF = UserDefaults.standard.string(forKey: "AOMCaptureRecordingOutputFormat") == "gif"
        gifFPS = max(1, min(30, UserDefaults.standard.integer(forKey: "AOMCaptureRecordingGIFFPS") == 0 ? 10 : UserDefaults.standard.integer(forKey: "AOMCaptureRecordingGIFFPS")))
        let source = outputGIF ? RecordingAudioSource.off : CaptureSettings.recordingAudioSource
        let wantsMic = source == .microphone || source == .computerAndMicrophone
        let wantsComputer = source == .computer || source == .computerAndMicrophone
        if wantsMic {
            guard #available(macOS 15.0, *) else {
                throw CaptureError.captureFailed("Microphone screen recording requires macOS 15 or later.")
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw CaptureError.captureFailed("Enable microphone access in Privacy & Security.")
                }
            }
        }
        if CaptureSettings.recordingCameraOverlay {
            if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    throw CaptureError.captureFailed("Enable camera access in Privacy & Security, or disable the camera overlay.")
                }
            }
        }
        // The bubble must exist before ScreenCaptureKit lists AOM's windows,
        // so the own-window exclusion below keeps it out of the video.
        if CaptureSettings.recordingCameraOverlay && CaptureSettings.recordingCameraBubble {
            RecordingCameraBubble.shared.show(recording: globalRect)
        }
        let content = try await SCShareableContent.current
        let displays = content.displays.filter { !$0.frame.intersection(globalRect).isEmpty }
        guard !displays.isEmpty else { throw CaptureError.noDisplays }
        guard globalRect.width >= 20, globalRect.height >= 20 else { throw CaptureError.areaTooSmall }
        let scale = displays.map { display in
            NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 1
        }.max() ?? 1
        // H.264 hardware encoders have finite dimensions. Keep the entire selection
        // while scaling oversized multi-display canvases down proportionally.
        let effectiveScale = min(scale, 7680 / max(globalRect.width, globalRect.height))
        let width = max(2, Int(globalRect.width * effectiveScale) & ~1)
        let height = max(2, Int(globalRect.height * effectiveScale) & ~1)
        let folder = CaptureSettings.saveDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = Self.uniqueRecordingURL(in: folder)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let multiplier = CaptureSettings.recordingQuality == 1 ? 0.65 : (CaptureSettings.recordingQuality == 3 ? 2.0 : 1.0)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(max(2_000_000, width * height * 4)) * multiplier),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: CaptureSettings.recordingFPS
            ]
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw CaptureError.captureFailed("Cannot configure the video encoder.") }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        func audioTrack() throws -> AVAssetWriterInput {
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
            ])
            track.expectsMediaDataInRealTime = true
            guard writer.canAdd(track) else { throw CaptureError.captureFailed("Cannot configure the audio encoder.") }
            writer.add(track)
            return track
        }
        var systemTrack: AVAssetWriterInput?
        var micTrack: AVAssetWriterInput?
        if wantsComputer { systemTrack = try audioTrack() }
        if wantsMic { micTrack = try audioTrack() }
        guard writer.startWriting() else { throw writer.error ?? CaptureError.captureFailed("Could not start recording.") }
        self.writer = writer
        videoInput = video; pixelAdaptor = adaptor
        audioInput = systemTrack; microphoneInput = micTrack
        outputURL = url; recordingRect = globalRect; recordedScale = effectiveScale
        outputSize = CGSize(width: width, height: height)
        firstSampleTime = nil; lastVideoTime = nil; firstImage = nil
        pausedDuration = .zero; pauseStarted = nil; isPaused = false; acceptAudioAfter = .zero
        isSessionStarted = false; elapsedSeconds = 0
        frames.removeAll(); displayRects.removeAll(); cursorPoints.removeAll(); clickEvents.removeAll(); keyEvents.removeAll()
        do {
            try RecordingRecovery.add(url)
            if CaptureSettings.recordingCameraOverlay {
                let cameraURL = AOMStudioCameraFrames.url(for: url)
                let cameraWriter = try AVAssetWriter(outputURL: cameraURL, fileType: .mp4)
                cameraWriter.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
                let cameraInput = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 640])
                cameraInput.expectsMediaDataInRealTime = true
                guard cameraWriter.canAdd(cameraInput) else { throw CaptureError.captureFailed("Cannot save editable camera track.") }
                cameraWriter.add(cameraInput)
                self.cameraAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: cameraInput, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 640, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
                guard cameraWriter.startWriting() else { throw cameraWriter.error ?? CaptureError.captureFailed("Cannot start camera track.") }
                self.cameraWriter = cameraWriter; self.cameraInput = cameraInput; cameraStarted = false
                let camera = RecordingCameraSource()
                camera.onFrame = { [weak self] image in self?.cameraImage = image }
                try await camera.start()
                self.camera = camera
                if RecordingCameraBubble.shared.isVisible { RecordingCameraBubble.shared.attach(camera.captureSession) }
            }
            if CaptureSettings.recordingKeystrokeOverlay { startKeyOverlay() }
            for (index, display) in displays.enumerated() {
                let piece = globalRect.intersection(display.frame)
                let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter {
                    $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                })
                let config = SCStreamConfiguration()
                config.sourceRect = piece.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                config.width = max(2, Int(piece.width * effectiveScale))
                config.height = max(2, Int(piece.height * effectiveScale))
                config.showsCursor = !recordsEditableCursor && (CaptureSettings.showsCursor || CaptureSettings.recordingClickIndicators)
                if #available(macOS 15.0, *) {
                    config.showMouseClicks = false // Editable local click events are rendered in Studio.
                    config.captureMicrophone = wantsMic && index == 0
                }
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(CaptureSettings.recordingFPS))
                config.queueDepth = 6; config.pixelFormat = kCVPixelFormatType_32BGRA
                config.captureResolution = .best
                config.capturesAudio = wantsComputer && index == 0
                config.sampleRate = 48_000; config.channelCount = 2
                config.excludesCurrentProcessAudio = true
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: recordingQueue)
                if index == 0 {
                    if wantsComputer { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
                    if wantsMic, #available(macOS 15.0, *) {
                        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
                    }
                }
                streams.append(stream); displayRects[ObjectIdentifier(stream)] = piece
                try await stream.startCapture()
            }
            isRecording = true
            RecordingFocus.engage()
            startCursorSampling()
            startClickMonitoring()
            startTimer(); ScreenRecordingBarController.shared.show()
            GestureHUD.shared.show(title: "Recording Started", detail: "\(Int(globalRect.width)) × \(Int(globalRect.height))")
        } catch {
            for stream in streams { try? await stream.stopCapture() }
            writer.cancelWriting(); cameraWriter?.cancelWriting(); try? FileManager.default.removeItem(at: AOMStudioCameraFrames.url(for: url)); try? FileManager.default.removeItem(at: AOMCursorTrack.sidecarURL(for: url)); try? FileManager.default.removeItem(at: url)
            RecordingRecovery.remove(url); clearSession()
            throw error
        }
    }

    func pauseRecording() {
        if isRecording && !isPaused { togglePause() }
    }

    func resumeRecording() {
        if isRecording && isPaused { togglePause() }
    }

    func togglePause() {
        guard isRecording, !isStopping else { return }
        if isPaused {
            if let start = pauseStarted {
                pausedDuration = CMTimeAdd(pausedDuration, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), start))
            }
            pauseStarted = nil; isPaused = false; acceptAudioAfter = CMClockGetTime(CMClockGetHostTimeClock())
        } else {
            pauseStarted = CMClockGetTime(CMClockGetHostTimeClock()); isPaused = true
            keyImage = nil
        }
    }

    func stopRecording() async throws -> URL? {
        guard isRecording, !isStopping else { return nil }
        isStopping = true
        defer { isStopping = false }
        isRecording = false; stopTimer(); stopCursorSampling(); stopOverlays()
        RecordingFocus.release()
        let bubblePlacement = RecordingCameraBubble.shared.placement(recording: recordingRect)
        RecordingCameraBubble.shared.hide()
        ScreenRecordingBarController.shared.hide()
        for stream in streams { try? await stream.stopCapture() }
        streams.removeAll()
        guard let writer, let url = outputURL else { clearSession(); return nil }
        videoInput?.markAsFinished(); audioInput?.markAsFinished(); microphoneInput?.markAsFinished()
        let hasFrames = isSessionStarted
        let needsMix = audioInput != nil && microphoneInput != nil
        let thumb = firstImage ?? Self.makeFallbackThumbnail(size: recordingRect.size)
        let rect = recordingRect; let scale = recordedScale; let points = cursorPoints
        let telemetry = AOMCursorTrack(points: recordsEditableCursor ? points : [], clicks: clickEvents, keystrokes: keyEvents)
        let cameraWriter = cameraWriter
        cameraInput?.markAsFinished()
        if cameraWriter?.status == .writing { await cameraWriter?.finishWriting() }
        let wantsGIF = outputGIF; let animationFPS = gifFPS
        let wantsRipples = CaptureSettings.recordingClickIndicators
        if writer.status == .writing { await writer.finishWriting() }
        clearSession()
        guard hasFrames, writer.status == .completed else {
            // Preserve fragments and the journal for the recovery flow.
            GestureHUD.shared.show(title: "Recording Interrupted", detail: "Saved fragments are available for recovery when AOM next opens.")
            throw writer.error ?? CaptureError.captureFailed("The recording could not finalize. Its fragments have been retained.")
        }
        if needsMix {
            do { try await RecordingExportService.mixRecordedAudio(in: url) }
            catch {
                GestureHUD.shared.show(title: "Audio Mix Warning", detail: "Both audio tracks were saved, but could not be mixed: \(error.localizedDescription)")
            }
        }
        RecordingRecovery.remove(url)
        var finishingWarning: String?
        do { try telemetry.write(for: url) }
        catch { finishingWarning = "Editable input track could not be saved: \(error.localizedDescription)" }
        var defaultStyle = AOMStudioSettings(cursorPoints: telemetry.points, clicks: wantsRipples ? (telemetry.clicks ?? []) : [], keystrokes: telemetry.keystrokes ?? [])
        defaultStyle.keystrokeScale = CaptureSettings.recordingKeystrokeSize.studioScale
        defaultStyle.keystrokeY = CaptureSettings.recordingKeystrokePosition.studioY
        defaultStyle.keystrokeStyle = CaptureSettings.recordingKeystrokeStyle
        // The camera layer starts where the live bubble was left, round like it.
        if let bubblePlacement, cameraWriter != nil {
            defaultStyle.cameraX = bubblePlacement.x
            defaultStyle.cameraY = bubblePlacement.y
            defaultStyle.cameraSize = bubblePlacement.size
            defaultStyle.cameraRoundness = 0.5
        }
        var presentation = url
        if !telemetry.points.isEmpty || !(telemetry.keystrokes ?? []).isEmpty || cameraWriter?.status == .completed || (wantsRipples && !(telemetry.clicks ?? []).isEmpty) {
            GestureHUD.shared.show(title: "Finishing Recording", detail: "Rendering editable layers. The original screen and camera tracks are kept.")
            do {
                let length = try await RecordingExportService.duration(for: url)
                let rendered = try await RecordingExportService.render(source: url, start: 0, end: length,
                    muteAudio: false, quality: .high, studio: defaultStyle, outputSuffix: "Presentation")
                try AOMStudioSourceLink.write(presentation: rendered, source: url)
                presentation = rendered
            } catch {
                finishingWarning = "Layer export failed; raw recording and editable tracks were kept: \(error.localizedDescription). Open Edit Recording to retry."
            }
        }
        if let cameraWriter, cameraWriter.status != .completed {
            finishingWarning = "The screen recording was saved. Camera fragments were retained: \(cameraWriter.error?.localizedDescription ?? "Camera track could not finalize.")"
        }
        let result = CaptureResult(image: thumb, globalRect: rect, scale: scale, kind: .videoRecording, windowTitle: "Screen Recording")
        let entry = CaptureHistory.shared.add(result, url: presentation)
        CaptureCoordinator.shared.showRecordingOverlay(for: entry)
        if wantsGIF {
            GestureHUD.shared.show(title: "Creating GIF", detail: "The MP4 source has been saved.")
            do {
                let duration = try await RecordingExportService.duration(for: url)
                let gif = try await RecordingExportService.gif(source: url, start: 0, end: duration, fps: animationFPS,
                    studio: defaultStyle)
                NSWorkspace.shared.activateFileViewerSelecting([gif])
                GestureHUD.shared.show(title: "GIF Saved", detail: gif.lastPathComponent)
            } catch {
                GestureHUD.shared.show(title: "GIF Export Failed", detail: "MP4 retained. \(error.localizedDescription)")
            }
        } else if let finishingWarning {
            GestureHUD.shared.show(title: "Recording Saved with Warning", detail: finishingWarning)
        } else {
            GestureHUD.shared.show(title: "Recording Saved", detail: presentation.lastPathComponent)
        }
        AOMSystemSound.play("Glass")
        return presentation
    }

    /// CleanShot's Restart: throw the take away and record the same area again
    /// with the same options, without re-selecting it.
    func restartRecording() {
        guard isRecording, !isStopping else { return }
        let rect = recordingRect
        cancelRecording(announce: false, releasesFocus: false)
        Task { @MainActor in
            for _ in 0..<80 where isStopping { try? await Task.sleep(for: .milliseconds(50)) }
            do {
                try await startRecording(globalRect: rect)
                GestureHUD.shared.show(title: "Recording Restarted", detail: "")
            } catch {
                RecordingFocus.release()
                GestureHUD.shared.show(title: "Recording could not restart", detail: error.localizedDescription)
            }
        }
    }

    func cancelRecording(announce: Bool = true, releasesFocus: Bool = true) {
        guard isRecording, !isStopping else { return }
        isStopping = true; isRecording = false
        if releasesFocus { RecordingFocus.release() }
        RecordingCameraBubble.shared.hide()
        stopTimer(); stopCursorSampling(); stopOverlays(); ScreenRecordingBarController.shared.hide()
        let activeStreams = streams; let writer = writer; let cameraWriter = cameraWriter; let url = outputURL
        clearSession()
        Task {
            defer { isStopping = false }
            for stream in activeStreams { try? await stream.stopCapture() }
            writer?.cancelWriting(); cameraWriter?.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: AOMStudioCameraFrames.url(for: url)); try? FileManager.default.removeItem(at: AOMCursorTrack.sidecarURL(for: url)); RecordingRecovery.remove(url) }
        }
        if announce { GestureHUD.shared.show(title: "Recording Discarded", detail: "") }
    }

    private func clearSession() {
        stopOverlays(); stopTimer(); stopCursorSampling()
        streams.removeAll(); frames.removeAll(); displayRects.removeAll()
        cameraWriter = nil; cameraInput = nil; cameraAdaptor = nil; cameraStarted = false
        writer = nil; videoInput = nil; pixelAdaptor = nil; audioInput = nil; microphoneInput = nil
        outputURL = nil; isSessionStarted = false; isPaused = false
        firstSampleTime = nil; lastVideoTime = nil; cursorPoints.removeAll()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.streams.contains(where: { $0 === stream }), self.isRecording, !self.isStopping else { return }
            do { _ = try await self.stopRecording() }
            catch { GestureHUD.shared.show(title: "Recording Interrupted", detail: error.localizedDescription) }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]],
                  let raw = attachments.first?[SCStreamFrameInfo.status.rawValue as CFString] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.streams.contains(where: { $0 === stream }),
                  self.isRecording || self.isStarting, !self.isStopping else { return }
            let sourcePTS = CMSampleBufferGetPresentationTimeStamp(buffer)
            let pts = CMTimeSubtract(sourcePTS, self.pausedDuration)
            if type == .screen {
                guard let pixel = CMSampleBufferGetImageBuffer(buffer) else { return }
                self.frames[ObjectIdentifier(stream)] = CIImage(cvImageBuffer: pixel)
            } else {
                guard !self.isPaused, sourcePTS >= self.acceptAudioAfter, self.isSessionStarted, let start = self.firstSampleTime, pts >= start else { return }
                let input: AVAssetWriterInput?
                if #available(macOS 15.0, *), type == .microphone { input = self.microphoneInput }
                else { input = self.audioInput }
                guard let input, input.isReadyForMoreMediaData,
                      let adjusted = Self.adjustedAudio(buffer, subtracting: self.pausedDuration) else { return }
                if !input.append(adjusted) { NSLog("[Recording] Audio error: %@", self.writer?.error?.localizedDescription ?? "unknown") }
            }
        }
    }

    private func appendVideoFrame(at hostTime: CMTime) {
        guard isRecording, !isPaused, !isStopping, frames.count == displayRects.count,
              !frames.isEmpty, let writer, writer.status == .writing else { return }
        let pts = CMTimeSubtract(hostTime, pausedDuration)
        if !isSessionStarted {
            writer.startSession(atSourceTime: pts)
            firstSampleTime = pts; isSessionStarted = true
            if let cameraWriter, cameraWriter.status == .writing {
                cameraWriter.startSession(atSourceTime: pts); cameraStarted = true
            }
        }
        guard videoInput?.isReadyForMoreMediaData == true,
              let adaptor = pixelAdaptor, let pool = adaptor.pixelBufferPool else { return }
        if let previous = lastVideoTime, pts <= previous { return }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return }
        let canvas = compositedFrame()
        ciContext.render(canvas, to: destination)
        if let image = cameraImage, let cameraWriter, cameraWriter.status == .writing {
            if !cameraStarted { cameraWriter.startSession(atSourceTime: pts); cameraStarted = true }
            if cameraInput?.isReadyForMoreMediaData == true, let adaptor = cameraAdaptor, let pool = adaptor.pixelBufferPool {
                var cameraPixel: CVPixelBuffer?
                if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &cameraPixel) == kCVReturnSuccess, let cameraPixel {
                    let factor = max(640 / image.extent.width, 640 / image.extent.height)
                    let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                    let centered = scaled.transformed(by: CGAffineTransform(translationX: 320 - scaled.extent.midX, y: 320 - scaled.extent.midY)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
                    ciContext.render(centered, to: cameraPixel)
                    _ = adaptor.append(cameraPixel, withPresentationTime: pts)
                }
            }
        }
        if adaptor.append(destination, withPresentationTime: pts) {
            lastVideoTime = pts
            if firstImage == nil { firstImage = ciContext.createCGImage(canvas, from: canvas.extent) }
        }
    }

    private static func adjustedAudio(_ buffer: CMSampleBuffer, subtracting offset: CMTime) -> CMSampleBuffer? {
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr else { return nil }
        var timing = Array(repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else { return nil }
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, offset)
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, offset) }
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }

    private func compositedFrame() -> CIImage {
        let bounds = CGRect(origin: .zero, size: outputSize)
        var canvas = CIImage(color: .black).cropped(to: bounds)
        for (id, image) in frames {
            guard let rect = displayRects[id] else { continue }
            let target = CGRect(x: (rect.minX - recordingRect.minX) * recordedScale,
                                y: (recordingRect.maxY - rect.maxY) * recordedScale,
                                width: rect.width * recordedScale, height: rect.height * recordedScale)
            let fitted = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: target.width / image.extent.width, y: target.height / image.extent.height))
                .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            canvas = fitted.cropped(to: target).composited(over: canvas)
        }
        // Camera and shortcuts remain independent editable tracks.
        return canvas.cropped(to: bounds)
    }

    private func startKeyOverlay() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.showKey(event) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.showKey(event); return event
        }
    }

    private func showKey(_ event: NSEvent) {
        guard isRecording, !isPaused else { return }
        guard !IsSecureEventInputEnabled() else { keyImage = nil; return }
        // By default only shortcuts and navigation keys are shown, so ordinary
        // typed text is not copied into the overlay; "All Keys" opts in.
        // Password fields (Secure Input) are always excluded above.
        guard let label = Self.keystrokeLabel(keyCode: event.keyCode, flags: event.modifierFlags,
                                              characters: event.charactersIgnoringModifiers,
                                              allKeys: CaptureSettings.recordingKeystrokesAllKeys) else { return }
        guard let time = recordingTime(), keyEvents.count < 60_000 else { return }
        keyEvents.append(AOMKeystrokeEvent(time: time, label: label))
    }

    /// The badge text for a key press, or nil when it is not shown.
    nonisolated static func keystrokeLabel(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?,
                                           allKeys: Bool) -> String? {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let shortcut = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        guard shortcut || special[keyCode] != nil || allKeys else { return nil }
        let modifiers = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) && shortcut ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        let key = special[keyCode] ?? (shortcut ? characters?.uppercased() : characters) ?? ""
        let label = modifiers + key
        return label.trimmingCharacters(in: .whitespaces).isEmpty ? nil : label
    }

    private func recordingTime() -> Double? {
        guard isRecording, !isPaused, let start = firstSampleTime else { return nil }
        let time = CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), pausedDuration), start))
        return time.isFinite && time >= 0 ? time : nil
    }

    private func startClickMonitoring() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.recordClick(event) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.recordClick(event); return event }
    }

    private func recordClick(_ event: NSEvent) {
        guard let time = recordingTime(), clickEvents.count < 60_000 else { return }
        let mouse = NSEvent.mouseLocation
        let x = (mouse.x - recordingRect.minX) / recordingRect.width
        let y = ((NSScreen.screens.first?.frame.maxY ?? 0) - mouse.y - recordingRect.minY) / recordingRect.height
        guard (0...1).contains(x), (0...1).contains(y) else { return }
        clickEvents.append(AOMClickEvent(time: time, x: x, y: y, button: min(2, event.buttonNumber)))
    }

    private func stopOverlays() {
        camera?.stop(); camera = nil; cameraImage = nil; keyImage = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
    }

    private func startCursorSampling() {
        stopCursorSampling()
        cursorSampler = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleCursor() }
        }
    }
    private func sampleCursor() {
        guard isRecording, !isPaused, let start = firstSampleTime, cursorPoints.count < 60_000 else { return }
        let mouse = NSEvent.mouseLocation
        let sx = (mouse.x - recordingRect.minX) / recordingRect.width
        let sy = ((NSScreen.screens.first?.frame.maxY ?? 0) - mouse.y - recordingRect.minY) / recordingRect.height
        let seconds = CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), pausedDuration), start))
        guard sx.isFinite, sy.isFinite, seconds.isFinite, seconds >= 0 else { return }
        cursorPoints.append(AOMCursorPoint(time: seconds, x: Double(min(1, max(0, sx))), y: Double(min(1, max(0, sy))), visible: (0...1).contains(sx) && (0...1).contains(sy)))
        if cursorPoints.count % 40 == 0, let url = outputURL {
            try? AOMCursorTrack(points: recordsEditableCursor ? cursorPoints : [], clicks: clickEvents, keystrokes: keyEvents).write(for: url)
        }
    }
    private func stopCursorSampling() { cursorSampler?.invalidate(); cursorSampler = nil }
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(CaptureSettings.recordingFPS), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                self.appendVideoFrame(at: CMClockGetTime(CMClockGetHostTimeClock()))
                guard let start = self.firstSampleTime else { return }
                let seconds = CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), self.pausedDuration), start))
                if self.outputGIF && seconds >= 120 && !self.isStopping {
                    Task { @MainActor in _ = try? await self.stopRecording() }
                }
                if seconds.isFinite { self.elapsedSeconds = max(0, Int(seconds)) }
            }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private static func makeFallbackThumbnail(size: CGSize) -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func offerInterruptedRecordingRecovery() {
        let recordings = RecordingRecovery.pending()
        guard !recordings.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Recover interrupted recordings?"
        alert.informativeText = "AOM found \(recordings.count) interrupted recording(s). Recover the saved video fragments, keep them for later, or discard them. The last few seconds may be unavailable."
        alert.addButton(withTitle: "Recover"); alert.addButton(withTitle: "Later"); alert.addButton(withTitle: "Discard")
        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            for url in recordings { try? FileManager.default.removeItem(at: url); RecordingRecovery.remove(url) }
        } else if response == .alertFirstButtonReturn {
            Task {
                for url in recordings {
                    do {
                        let recovered = try await RecordingExportService.recoverInterrupted(source: url)
                        RecordingRecovery.remove(url)
                        NSWorkspace.shared.activateFileViewerSelecting([recovered])
                    } catch { GestureHUD.shared.show(title: "Recovery Unavailable", detail: "\(url.lastPathComponent): \(error.localizedDescription). Original fragments were kept.") }
                }
            }
        }
    }
}

/// Dedicated capture queue avoids blocking the main actor while the camera starts.
private final class RecordingCameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.kyw.allofmacos.recording-camera")
    /// For the live preview bubble only; frames still arrive through `onFrame`.
    var captureSession: AVCaptureSession { session }
    var onFrame: (@MainActor (CIImage) -> Void)?
    func start() async throws {
        guard let device = AVCaptureDevice.default(for: .video) else { throw CaptureError.captureFailed("No camera is available.") }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .medium
        guard session.canAddInput(input) else { session.commitConfiguration(); throw CaptureError.captureFailed("The camera is in use or unavailable.") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw CaptureError.captureFailed("Cannot receive camera frames.") }
        session.addOutput(output); output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        await withCheckedContinuation { continuation in queue.async { self.session.startRunning(); continuation.resume() } }
        guard session.isRunning else { throw CaptureError.captureFailed("The camera did not start.") }
    }
    func stop() { queue.async { self.session.stopRunning() } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvImageBuffer: pixel)
        Task { @MainActor [weak self] in self?.onFrame?(image) }
    }
}

@MainActor
private enum RecordingRecovery {
    private static var journalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllOfMacOS", isDirectory: true).appendingPathComponent("interrupted-recordings.json")
    }
    static func pending() -> [URL] {
        guard let data = try? Data(contentsOf: journalURL), let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func add(_ url: URL) throws {
        var urls = pending(); urls.append(url)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(urls.map(\.path)).write(to: journalURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
    static func remove(_ url: URL) {
        try? JSONEncoder().encode(pending().filter { $0 != url }.map(\.path)).write(to: journalURL, options: .atomic)
    }
}

// MARK: - Floating CleanShot X-style Recording Control Bar

@MainActor
final class ScreenRecordingBarController: NSObject {
    static let shared = ScreenRecordingBarController()

    private var panel: NSPanel?
    private var keyMonitor: Any?

    func show() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ScreenRecordingBarView())
            panel = p
        }

        guard let panel, let screen = NSScreen.main else { return }

        let frame = NSRect(
            x: screen.visibleFrame.midX - 150,
            y: screen.visibleFrame.maxY - 56,
            width: 300,
            height: 44
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // ESC to stop
                Task { @MainActor in
                    try? await ScreenRecordingService.shared.stopRecording()
                }
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private struct ScreenRecordingBarView: View {
    @ObservedObject var service = ScreenRecordingService.shared
    @State private var isPulsing = false

    private var formattedTime: String {
        let mins = service.elapsedSeconds / 60
        let secs = service.elapsedSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing Red REC indicator
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .opacity(isPulsing ? 1.0 : 0.3)
                    .animation(AOMDesign.animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)), value: isPulsing)
                Text(service.isPaused ? "PAUSED" : "REC")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.red)
            }
            .onAppear { isPulsing = true }

            Text(formattedTime)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Button { service.restartRecording() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restart — discard this take and record the same area again")
            .accessibilityLabel("Restart recording")
            Button { service.togglePause() } label: {
                Image(systemName: service.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(service.isPaused ? "Resume Recording" : "Pause Recording")

            // Finish Recording button
            Button {
                Task { try? await service.stopRecording() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                    Text("Stop")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Stop Recording (Esc)")

            // Cancel button
            Button {
                service.cancelRecording()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Discard Recording")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .aomFloatingSurface(.hud, radius: 22)
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }
}

/// Runs the user's Focus Shortcuts around a recording (CleanShot's "Do Not
/// Disturb while recording"). The Shortcuts CLI is launched directly, without a
/// shell, so a Shortcut name never needs quoting. A failure is reported once and
/// never blocks or stops the recording.
@MainActor
enum RecordingFocus {
    private static var engaged = false

    static func engage() {
        guard CaptureSettings.recordingFocus, !engaged else { return }
        engaged = true
        run(CaptureSettings.recordingFocusOnShortcut)
    }

    static func release() {
        guard engaged else { return }
        engaged = false
        run(CaptureSettings.recordingFocusOffShortcut)
    }

    /// Also used by the settings "Test" buttons.
    static func run(_ name: String, completion: ((Bool, String) -> Void)? = nil) {
        let shortcut = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcut.isEmpty else { completion?(false, "No Shortcut name"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.launch(shortcut)
            DispatchQueue.main.async {
                if !result.ok {
                    GestureHUD.shared.show(title: "Focus Shortcut Failed",
                                           detail: "“\(shortcut)”: \(result.message)")
                }
                completion?(result.ok, result.message)
            }
        }
    }

    nonisolated private static func launch(_ shortcut: String) -> (ok: Bool, message: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["run", shortcut]
        let errors = Pipe()
        task.standardError = errors
        task.standardOutput = FileHandle.nullDevice
        do { try task.run() } catch { return (false, error.localizedDescription) }
        // A Shortcut that waits on UI must not leave Focus in limbo forever.
        let deadline = Date().addingTimeInterval(10)
        while task.isRunning, Date() < deadline { usleep(50_000) }
        if task.isRunning { task.terminate(); return (false, "Timed out after 10 seconds") }
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if task.terminationStatus == 0 { return (true, "") }
        return (false, detail.isEmpty ? "Exit status \(task.terminationStatus)" : String(detail.prefix(200)))
    }
}
