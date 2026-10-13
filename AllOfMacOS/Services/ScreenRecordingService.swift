import AppKit
import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SwiftUI

/// Modern ScreenCaptureKit & AVAssetWriter based video screen recording service.
///
/// Features:
/// - Records selected region to MP4 (H.264 video, optional computer/microphone AAC audio)
/// - CleanShot X-style floating HUD bar with pulsing REC dot, timer, and finish/cancel buttons
/// - Automatically generates first-frame thumbnail and integrates with Quick Access Overlay
/// - Global ESC shortcut or stop button to finish recording
@MainActor
final class ScreenRecordingService: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenRecordingService()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: Int = 0

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var recordingAudioEnabled = false
    private var outputURL: URL?
    private var firstSampleTime: CMTime?
    private var firstImage: CGImage?
    private var recordingRect: CGRect = .zero
    private var timer: Timer?
    private var isSessionStarted = false
    private var isStarting = false
    private var isStopping = false
    private var recordedScale: CGFloat = 1
    private var cursorSampler: Timer?
    private var cursorPoints: [AOMCursorPoint] = []
    private let recordingQueue = DispatchQueue(label: "com.kyw.allofmacos.screen-recording", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.kyw.allofmacos.screen-recording-audio", qos: .userInitiated)

    private override init() {
        super.init()
    }

    /// Never overwrite a prior recording, even when two saves share a second.
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
        if isRecording {
            Task { try? await stopRecording() }
        } else {
            promptAndStartRecording()
        }
    }

    /// Record the full display beneath the pointer, without opening a region picker.
    func recordFullscreenUnderPointer() {
        guard !isRecording, !isStarting, !isStopping, !SelectionOverlayController.isActive else { return }
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = ScreenCaptureService.displayUnderPointer(in: content.displays)
                        ?? content.displays.first else { throw CaptureError.noDisplays }
                try await startRecording(globalRect: display.frame)
            } catch {
                GestureHUD.shared.show(title: "Recording Failed", detail: error.localizedDescription)
            }
        }
    }

    func promptAndStartRecording() {
        guard !isRecording, !isStarting, !isStopping, !SelectionOverlayController.isActive else { return }

        // Use SelectionOverlayController (CleanShot X style) to let user drag rectangle or press Space to select a window
        SelectionOverlayController { [weak self] rect in
            guard let self else { return }
            guard let selected = rect, selected.width >= 30, selected.height >= 30 else {
                GestureHUD.shared.show(title: "Recording Cancelled", detail: "")
                return
            }
            Task {
                do {
                    try await self.startRecording(globalRect: selected)
                } catch {
                    GestureHUD.shared.show(title: "Recording Failed", detail: error.localizedDescription)
                }
            }
        }.present()
    }

    func startRecording(globalRect: CGRect) async throws {
        guard !isRecording, !isStarting, !isStopping else { return }
        isStarting = true
        defer { isStarting = false }

        let audioSource = CaptureSettings.recordingAudioSource
        if audioSource == .microphone {
            guard #available(macOS 15.0, *) else {
                throw CaptureError.captureFailed("Microphone screen recording requires macOS 15 or later.")
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw CaptureError.captureFailed("Microphone permission was denied. Enable it in Privacy & Security.")
                }
            }
        }

        let content = try await SCShareableContent.current
        guard let defaultDisplay = content.displays.first else {
            throw CaptureError.noDisplays
        }

        // Match display that intersects globalRect (in ScreenCaptureKit top-left origin coordinates)
        let display = content.displays.first { $0.frame.intersects(globalRect) } ?? defaultDisplay
        let localRect = globalRect.offsetBy(dx: -display.frame.origin.x, dy: -display.frame.origin.y)
        let sourceRect = localRect.intersection(CGRect(origin: .zero, size: display.frame.size))

        guard sourceRect.width >= 20, sourceRect.height >= 20 else {
            throw CaptureError.areaTooSmall
        }

        let scale = NSScreen.screens.first(where: { $0.displayID == display.displayID })?.backingScaleFactor ?? 2.0
        let pixelWidth = max(2, Int((sourceRect.width * scale).rounded()) & ~1)
        let pixelHeight = max(2, Int((sourceRect.height * scale).rounded()) & ~1)

        let folder = CaptureSettings.saveDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = Self.uniqueRecordingURL(in: folder)

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        let qualityMultiplier: Double
        switch CaptureSettings.recordingQuality {
        case 1: qualityMultiplier = 0.65
        case 3: qualityMultiplier = 2.0
        default: qualityMultiplier = 1.0
        }
        let configuredBitrate = Int(Double(max(2_000_000, pixelWidth * pixelHeight * 4)) * qualityMultiplier)
        let fps = CaptureSettings.recordingFPS
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuredBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CaptureError.captureFailed("Cannot configure video writer")
        }
        writer.add(input)

        // One optional AAC track for computer playback. Audio is received as
        // decoded CMSampleBuffers and muxed against the screen frame timeline.
        let wantsAudio = audioSource != .off
        let wantsMicrophone = audioSource == .microphone
        var audioInput: AVAssetWriterInput?
        if wantsAudio {
            let format: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: format)
            track.expectsMediaDataInRealTime = true
            guard writer.canAdd(track) else {
                throw CaptureError.captureFailed("Cannot configure the system audio encoder")
            }
            writer.add(track)
            audioInput = track
        }

        // Exclude our own recording bar & overlay windows
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter {
            $0.owningApplication?.processID == ownPID
        })

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = pixelWidth
        config.height = pixelHeight
        // Opt-in editing records cursor motion separately and hides the baked
        // pointer to avoid two overlapping cursors in Studio exports.
        let recordsEditableCursor = CaptureSettings.recordingCursorMotion
        config.showsCursor = !recordsEditableCursor &&
            (CaptureSettings.showsCursor || CaptureSettings.recordingClickIndicators)
        if #available(macOS 15.0, *) {
            config.showMouseClicks = CaptureSettings.recordingClickIndicators
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .best
        config.capturesAudio = wantsAudio && !wantsMicrophone
        if wantsAudio {
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        if wantsMicrophone {
            if #available(macOS 15.0, *) { config.captureMicrophone = true }
        }

        // Start AVAssetWriter writing session in advance
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: fileURL)
            throw CaptureError.captureFailed("Failed to initialize video writer: \(writer.error?.localizedDescription ?? "unknown")")
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: recordingQueue)
            if wantsMicrophone {
                if #available(macOS 15.0, *) {
                    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
                }
            } else if wantsAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        self.writer = writer
        self.videoInput = input
        self.audioInput = audioInput
        self.recordingAudioEnabled = wantsAudio
        self.outputURL = fileURL
        self.recordingRect = sourceRect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        self.cursorPoints.removeAll(keepingCapacity: true)
        self.recordedScale = scale
        self.firstSampleTime = nil
        self.firstImage = nil
        self.isSessionStarted = false
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            try? stream.removeStreamOutput(self, type: .screen)
            if wantsMicrophone {
                if #available(macOS 15.0, *) { try? stream.removeStreamOutput(self, type: .microphone) }
            } else if wantsAudio {
                try? stream.removeStreamOutput(self, type: .audio)
            }
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.recordingAudioEnabled = false
            self.outputURL = nil
            self.stream = nil
            throw error
        }

        self.isRecording = true
        self.elapsedSeconds = 0
        if recordsEditableCursor {
            startCursorSampling()
        }

        startTimer()
        ScreenRecordingBarController.shared.show()
        GestureHUD.shared.show(title: "Recording Started", detail: "\(Int(sourceRect.width)) × \(Int(sourceRect.height))")
    }

    func stopRecording() async throws -> URL? {
        guard isRecording, !isStopping else { return nil }
        isStopping = true
        defer { isStopping = false }
        isRecording = false
        stopTimer()
        stopCursorSampling()

        ScreenRecordingBarController.shared.hide()

        try? await stream?.stopCapture()
        stream = nil

        let activeWriter = self.writer
        let activeInput = self.videoInput
        let activeAudioInput = self.audioInput
        let url = self.outputURL
        let rect = self.recordingRect
        let thumb = self.firstImage ?? Self.makeFallbackThumbnail(size: rect.size)

        let hasFrames = self.isSessionStarted
        activeInput?.markAsFinished()
        activeAudioInput?.markAsFinished()
        if let activeWriter, activeWriter.status == .writing {
            await activeWriter.finishWriting()
        }

        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.recordingAudioEnabled = false
        self.outputURL = nil
        self.isSessionStarted = false

        guard hasFrames, activeWriter?.status == .completed,
              let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0 else {
            // A file's existence is not evidence that an MP4 was finalized.
            if let url { try? FileManager.default.removeItem(at: url) }
            GestureHUD.shared.show(title: "Recording Failed",
                                   detail: "The video did not finalize. No valid MP4 was saved.")
            throw CaptureError.captureFailed("Recording did not finalize correctly. No valid video was saved.")
        }

        if FileManager.default.fileExists(atPath: url.path) {
            if !cursorPoints.isEmpty {
                do {
                    try AOMCursorTrack(points: cursorPoints).write(for: url)
                } catch {
                    GestureHUD.shared.show(title: "Cursor Metadata Warning",
                                           detail: "The movie was saved, but editable pointer data could not be written.")
                }
            }
            cursorPoints.removeAll()
            let result = CaptureResult(
                image: thumb,
                globalRect: rect,
                scale: recordedScale,
                kind: .videoRecording,
                windowTitle: "Screen Recording"
            )

            let entry = CaptureHistory.shared.add(result, url: url)
            CaptureCoordinator.shared.showRecordingOverlay(for: entry)
            GestureHUD.shared.show(title: "Recording Saved", detail: url.lastPathComponent)
            NSSound(named: "Glass")?.play()
            return url
        }
        return nil
    }

    func cancelRecording() {
        guard isRecording, !isStopping else { return }
        isStopping = true
        isRecording = false
        stopTimer()
        stopCursorSampling()
        cursorPoints.removeAll()

        ScreenRecordingBarController.shared.hide()

        let activeStream = self.stream
        let activeWriter = self.writer
        let url = self.outputURL
        self.stream = nil
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.recordingAudioEnabled = false
        self.isSessionStarted = false

        Task {
            defer { self.isStopping = false }
            try? await activeStream?.stopCapture()
            activeWriter?.cancelWriting()
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
        }
        GestureHUD.shared.show(title: "Recording Discarded", detail: "")
    }

    // MARK: - SCStreamOutput (Synchronous Frame Encoding on recordingQueue)

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type != .screen {
            // The recorder registers only one sound source at a time.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stream === stream, self.isRecording, self.recordingAudioEnabled,
                      self.isSessionStarted,
                      let audioInput = self.audioInput,
                      audioInput.isReadyForMoreMediaData,
                      let start = self.firstSampleTime,
                      CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
                if !audioInput.append(sampleBuffer) {
                    NSLog("[ScreenRecording] Audio encode error: %@", self.writer?.error?.localizedDescription ?? "Unknown")
                }
            }
            return
        }
        guard type == .screen else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let attachment = attachments.first else { return }

        if let statusRaw = attachment[SCStreamFrameInfo.status.rawValue as CFString] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw), status != .complete {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Process directly on recordingQueue for maximum throughput & zero-latency encoding
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream, self.isRecording || self.isStarting else { return }
            if !self.isSessionStarted, let writer = self.writer, writer.status == .writing {
                writer.startSession(atSourceTime: pts)
                self.isSessionStarted = true
                self.firstSampleTime = pts

                // Generate clean first-frame thumbnail for Quick Access Overlay
                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let ci = CIImage(cvImageBuffer: imageBuffer)
                    let ctx = CIContext()
                    if let cg = ctx.createCGImage(ci, from: ci.extent) {
                        self.firstImage = cg
                    }
                }
            }

            if self.isSessionStarted, let input = self.videoInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    private func startCursorSampling() {
        stopCursorSampling()
        cursorPoints.removeAll(keepingCapacity: true)
        cursorSampler = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleCursor() }
        }
    }

    private func sampleCursor() {
        guard isRecording, let start = firstSampleTime, cursorPoints.count < 60_000,
              recordingRect.width > 0, recordingRect.height > 0 else { return }
        let screenY = NSScreen.screens.first?.frame.maxY ?? 0
        let mouse = NSEvent.mouseLocation
        let sx = (mouse.x - recordingRect.minX) / recordingRect.width
        let sy = (screenY - mouse.y - recordingRect.minY) / recordingRect.height
        let seconds = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), start))
        guard sx.isFinite, sy.isFinite, seconds.isFinite, seconds >= 0 else { return }
        let visible = (0...1).contains(sx) && (0...1).contains(sy)
        cursorPoints.append(AOMCursorPoint(time: seconds,
                                          x: Double(min(1, max(0, sx))),
                                          y: Double(min(1, max(0, sy))), visible: visible))
    }

    private func stopCursorSampling() {
        cursorSampler?.invalidate()
        cursorSampler = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func makeFallbackThumbnail(size: CGSize) -> CGImage {
        let width = max(200, Int(size.width.isFinite ? size.width : 400))
        let height = max(150, Int(size.height.isFinite ? size.height : 300))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return rep.cgImage!
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
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
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
            x: screen.visibleFrame.midX - 110,
            y: screen.visibleFrame.maxY - 56,
            width: 220,
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
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                Text("REC")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.red)
            }
            .onAppear { isPulsing = true }

            Text(formattedTime)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

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
        .background(VisualEffectBackground(material: .hudWindow, state: .active))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }
}
