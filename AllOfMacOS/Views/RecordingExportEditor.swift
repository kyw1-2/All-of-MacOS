import AppKit
import AVKit
import CoreImage
import SwiftUI

/// Non-destructive MP4 trimming and short animated-GIF export from Capture History.
struct RecordingExportEditor: View {
    let source: URL
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var fps = 8
    @State private var muteAudio = false
    @State private var quality: RecordingExportService.StudioQuality = .high
    @State private var previewPlayer: AVPlayer?
    @State private var previousZoomKeyframes: [AOMStudioZoomKeyframe]?
    @State private var loadFailed = false
    @State private var zoomKeyframes: [AOMStudioZoomKeyframe] = []
    @State private var zoomAt = 0.0
    @State private var zoomLevel = 1.6
    @State private var focusX = 0.5
    @State private var focusY = 0.5
    @State private var backdrop: AOMStudioBackdrop = .none
    @State private var backdropPadding = 0.08
    @State private var motionBlurRadius = 0.0
    @State private var editableCursorTrack: AOMCursorTrack?
    @State private var includeSmoothedCursor = true
    @State private var cursorSize = 1.0
    @State private var isExporting = false
    @State private var status = ""
    @State private var resultURL: URL?
    @State private var clips: [AOMStudioClip] = []
    @State private var outputAspect: AOMStudioAspect = .source
    @State private var outputResolution: AOMStudioResolution = .source
    @State private var cursorStyle: AOMStudioCursorStyle = .arrow
    @State private var showRipples = true
    @State private var showKeys = true
    @State private var keyScale = 1.0
    @State private var keyY = 0.9
    @State private var showCamera = true
    @State private var cameraSize = 0.24
    @State private var cameraX = 0.84
    @State private var cameraY = 0.84
    @State private var cameraRoundness = 0.18
    @State private var keyEvents: [AOMKeystrokeEvent] = []
    @State private var editingKeyframeID: UUID?
    @State private var previewIsSequence = false

    private var exportClips: [AOMStudioClip] { clips.isEmpty ? [AOMStudioClip(start: start, end: end)] : clips }
    private var outputDuration: Double { exportClips.reduce(0) { $0 + $1.duration } }

    private var validRange: Bool {
        duration > 0 && start >= 0 && end > start + 0.05 && end <= duration + 0.05
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Edit Recording").font(.headline)
                Spacer()
                Button("Close") { if let onClose { onClose() } else { dismiss() } }.disabled(isExporting)
            }

            Text(source.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if duration > 0 {
                if let previewPlayer {
                    VideoPlayer(player: previewPlayer)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Recording preview")
                }
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 16) {
                        Text("Start")
                            .frame(width: 40, alignment: .leading)
                        Slider(value: $start, in: 0...max(0.1, duration), step: 0.1)
                            .onChange(of: start) { _, next in
                                if next >= end { end = min(duration, next + 0.1) }
                            }
                        Text(Self.clock(start))
                            .monospacedDigit()
                            .frame(width: 55)
                    }
                    HStack(spacing: 16) {
                        Text("End")
                            .frame(width: 40, alignment: .leading)
                        Slider(value: $end, in: 0...max(0.1, duration), step: 0.1)
                            .onChange(of: end) { _, next in
                                if next <= start { start = max(0, next - 0.1) }
                            }
                        Text(Self.clock(end))
                            .monospacedDigit()
                            .frame(width: 55)
                    }
                    Text("Selected: \(Self.clock(max(0, end - start))) of \(Self.clock(duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                timelineControls.disabled(isExporting)
                studioControls.disabled(isExporting)

                Divider()

                HStack(spacing: 16) {
                    Toggle("Mute Audio", isOn: $muteAudio)
                        .disabled(isExporting)
                    Picker("MP4 Quality", selection: $quality) {
                        ForEach(RecordingExportService.StudioQuality.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .frame(width: 215)
                    .disabled(isExporting)
                    Spacer(minLength: 0)
                    Button {
                        export(gif: false, rendered: true)
                    } label: {
                        Label("Render Edited MP4", systemImage: "film.stack")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || !validRange)
                }

                HStack(spacing: 12) {
                    Button {
                        export(gif: false)
                    } label: {
                        Label("Export Cut Sequence", systemImage: "scissors")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || !validRange)

                    Button {
                        export(gif: true)
                    } label: {
                        Label("Export GIF", systemImage: "photo.stack")
                    }
                    .disabled(isExporting || !validRange || outputDuration > 120)

                    Picker("GIF FPS", selection: $fps) {
                        Text("5").tag(5)
                        Text("8").tag(8)
                        Text("10").tag(10)
                        Text("15").tag(15)
                        Text("20").tag(20)
                        Text("30").tag(30)
                    }
                    .frame(width: 110)
                    .disabled(isExporting)
                }

                if outputDuration > 120 {
                    Text("GIF exports support clips of up to 120 seconds. Trim the range first.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if loadFailed {
                Label("Could not open this recording.", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("Reading recording…")
            }

            if isExporting {
                ProgressView("Exporting…")
                    .controlSize(.small)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(resultURL == nil ? Color.secondary : Color.green)
                    .lineLimit(3)
            }
            if let resultURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([resultURL])
                }
                .buttonStyle(.link)
            }
        }
        .padding(24)
        }
        .frame(width: 720, height: min(820, max(480, (NSScreen.main?.visibleFrame.height ?? 940) - 120)))
        .onChange(of: start) { _, value in
            restoreSourcePreview()
            saveProject()
            previewPlayer?.seek(to: CMTime(seconds: value, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onChange(of: end) { _, value in
            saveProject()
            previewPlayer?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: value, preferredTimescale: 600)
        }
        .onChange(of: muteAudio) { _, value in previewPlayer?.isMuted = value; saveProject() }
        .task(id: studioSettings) {
            // Coalesce slider events; cancelled tasks cannot install stale effects.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            updatePreview()
            saveProject()
        }
        .onDisappear { previewPlayer?.pause(); saveProject() }
        .task {
            do {
                previewPlayer = AVPlayer(url: source)
                editableCursorTrack = AOMCursorTrack.read(for: source)
                let seconds = try await RecordingExportService.duration(for: source)
                duration = seconds
                start = 0
                end = seconds
                keyEvents = editableCursorTrack?.keystrokes ?? []
                if let project = AOMStudioProject.read(for: source, duration: seconds) {
                    clips = project.clips
                    restore(project.settings)
                    muteAudio = project.muteAudio
                    status = "Recovered saved Studio project."
                }
                updatePreview()
            } catch {
                loadFailed = true
                status = error.localizedDescription
            }
        }
    }

    /// All edits remain anchored to source time, including after changing trim bounds.
    private var studioControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Studio Mode — Zoom Timeline", systemImage: "viewfinder")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Text("At")
                Slider(value: $zoomAt, in: 0...max(0.1, duration), step: 0.1)
                    .onChange(of: zoomAt) { _, value in
                        restoreSourcePreview()
                        previewPlayer?.pause()
                        previewPlayer?.seek(to: CMTime(seconds: value, preferredTimescale: 600),
                                            toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                Text(Self.clock(zoomAt)).monospacedDigit().frame(width: 60)
            }
            HStack(spacing: 12) {
                Text("Zoom")
                Slider(value: $zoomLevel, in: 1...3, step: 0.1)
                Text(String(format: "%.1f×", zoomLevel)).monospacedDigit().frame(width: 42)
                Button("Add Keyframe") {
                    guard zoomAt >= start, zoomAt <= end else {
                        status = "Select a zoom time inside the trim range."
                        return
                    }
                    previousZoomKeyframes = zoomKeyframes
                    zoomKeyframes.removeAll { $0.id == editingKeyframeID || abs($0.time - zoomAt) < 0.001 }
                    editingKeyframeID = nil
                    zoomKeyframes.append(AOMStudioZoomKeyframe(
                        time: zoomAt, magnification: zoomLevel,
                        focusX: focusX, focusY: focusY))
                    zoomKeyframes.sort { $0.time < $1.time }
                }
                .disabled(isExporting || !validRange)
            }
            HStack(spacing: 10) {
                Text("Focus X")
                Slider(value: $focusX, in: 0...1)
                Text("Y")
                Slider(value: $focusY, in: 0...1)
            }
            .font(.caption)
            HStack {
                Button("Suggest Smart Zooms") {
                    guard let track = editableCursorTrack else { return }
                    let suggested = AOMStudioTimeline.suggestedZooms(track: track, start: start, end: end)
                    guard !suggested.isEmpty else {
                        status = "No recorded interactions or sustained cursor pauses found. Add a keyframe manually."
                        return
                    }
                    previousZoomKeyframes = zoomKeyframes
                    zoomKeyframes = suggested
                    status = "Added \(suggested.count / 4) editable zoom suggestions."
                }
                .disabled(editableCursorTrack == nil || !validRange)
                Button("Undo Zoom Edit") {
                    guard let previous = previousZoomKeyframes else { return }
                    zoomKeyframes = previous
                    previousZoomKeyframes = nil
                }
                .disabled(previousZoomKeyframes == nil)
            }
            ForEach(zoomKeyframes) { keyframe in
                HStack {
                    Button {
                        editingKeyframeID = keyframe.id
                        zoomAt = keyframe.time
                        zoomLevel = keyframe.magnification
                        focusX = keyframe.focusX
                        focusY = keyframe.focusY
                    } label: {
                        Text("\(Self.clock(keyframe.time)) — \(String(format: "%.1f×", keyframe.magnification))")
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .help("Load this keyframe, change its time/focus/zoom and Add Keyframe to move or replace it")
                    Spacer()
                    Button(role: .destructive) {
                        previousZoomKeyframes = zoomKeyframes
                        zoomKeyframes.removeAll { $0.id == keyframe.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isExporting)
                    .accessibilityLabel("Remove zoom keyframe")
                }
            }
            HStack(spacing: 12) {
                Picker("Background", selection: $backdrop) {
                    ForEach(AOMStudioBackdrop.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .frame(width: 205)
                .disabled(isExporting)
                Text("Padding")
                Slider(value: $backdropPadding, in: 0...0.20)
                    .disabled(isExporting || backdrop == .none)
                Text("\(Int(backdropPadding * 100))%")
                    .monospacedDigit().frame(width: 35)
            }
            HStack(spacing: 10) {
                Text("Zoom-transition blur").font(.caption)
                Slider(value: $motionBlurRadius, in: 0...8)
                    .disabled(isExporting)
                Text(String(format: "%.1f", motionBlurRadius))
                    .monospacedDigit().frame(width: 34)
            }
            if let track = editableCursorTrack {
                HStack(spacing: 12) {
                    Toggle("Smooth editable cursor", isOn: $includeSmoothedCursor)
                    Text("\(track.points.count) cursor samples").font(.caption2)
                    Text("Cursor size")
                    Slider(value: $cursorSize, in: 0.5...2, step: 0.1)
                    Text(String(format: "%.1f×", cursorSize))
                        .monospacedDigit().frame(width: 42)
                }
            } else {
                Text("Editable cursor motion requires a new recording with Cursor Track enabled in Capture Settings.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Cursor", selection: $cursorStyle) { ForEach(AOMStudioCursorStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Toggle("Click ripples", isOn: $showRipples)
            }
            if !keyEvents.isEmpty {
                Toggle("Shortcut layer", isOn: $showKeys)
                HStack { Text("Size"); Slider(value: $keyScale, in: 0.5...2); Text("Vertical position"); Slider(value: $keyY, in: 0...1) }
                ForEach($keyEvents) { $key in
                    HStack {
                        Text(key.label).frame(width: 100)
                        TextField("Time", value: $key.time, format: .number).frame(width: 70)
                        TextField("Duration", value: $key.duration, format: .number).frame(width: 70)
                        Button("Delete") { keyEvents.removeAll { $0.id == key.id } }
                    }.font(.caption)
                }
            }
            if FileManager.default.fileExists(atPath: AOMStudioCameraFrames.url(for: source).path) {
                Toggle("Camera layer", isOn: $showCamera)
                HStack { Text("Size"); Slider(value: $cameraSize, in: 0.1...0.6); Text("Roundness"); Slider(value: $cameraRoundness, in: 0...0.5) }
                HStack { Text("Camera X"); Slider(value: $cameraX, in: 0...1); Text("Y"); Slider(value: $cameraY, in: 0...1) }
            }
            HStack {
                Picker("Aspect", selection: $outputAspect) { ForEach(AOMStudioAspect.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                Picker("Resolution", selection: $outputResolution) { ForEach(AOMStudioResolution.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            }
            Text("Smart Zoom uses recorded clicks, with pointer dwell as a fallback. Shortcut and camera layers require a new AOM recording; older videos retain their baked overlays.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var studioSettings: AOMStudioSettings {
        AOMStudioSettings(keyframes: zoomKeyframes, backdrop: backdrop,
                          paddingFraction: backdropPadding, motionBlurRadius: motionBlurRadius,
                          cursorPoints: includeSmoothedCursor ? (editableCursorTrack?.points ?? []) : [],
                          cursorOverlaySize: cursorSize, clicks: editableCursorTrack?.clicks ?? [],
                          showClickRipples: showRipples, cursorStyle: cursorStyle,
                          keystrokes: keyEvents.filter { $0.isValid }.sorted { $0.time < $1.time }, showKeystrokes: showKeys,
                          keystrokeScale: keyScale, keystrokeY: keyY, showCamera: showCamera,
                          cameraSize: cameraSize, cameraX: cameraX, cameraY: cameraY, cameraRoundness: cameraRoundness,
                          aspect: outputAspect, resolution: outputResolution)
    }

    private func updatePreview() {
        guard let player = previewPlayer, let item = player.currentItem else { return }
        let effect = studioSettings
        let sequence = previewIsSequence ? exportClips : []
        let camera = effect.showCamera ? AOMStudioCameraFrames(source: source) : nil
        let filters = AVMutableVideoComposition(
            asset: item.asset, applyingCIFiltersWithHandler: { request in
                let outputTime = CMTimeGetSeconds(request.compositionTime)
                let sourceTime = sequence.isEmpty ? outputTime : (AOMStudioClip.sourceTime(at: outputTime, clips: sequence) ?? sequence.last!.end)
                let image = AOMStudioRenderer.frame(request.sourceImage,
                    time: sourceTime, settings: effect, cameraImage: camera?.frame(at: sourceTime))
                request.finish(with: image, context: nil)
            })
        filters.renderSize = effect.outputSize(source: filters.renderSize)
        item.videoComposition = filters
        // Refresh even while paused so changing a slider changes the image.
        let time = player.currentTime()
        if time.isNumeric {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func export(gif: Bool, rendered: Bool = false) {
        guard validRange, !isExporting else { return }
        isExporting = true
        status = ""
        resultURL = nil
        let begin = start, finish = end, frames = fps
        let muted = muteAudio, selectedQuality = quality
        let studio = studioSettings
        let selected = exportClips
        saveProject()
        Task {
            do {
                let exported: URL
                if gif {
                    exported = try await RecordingExportService.gif(
                        source: source, start: begin, end: finish, fps: frames, studio: studio, clips: selected)
                } else if rendered {
                    exported = try await RecordingExportService.render(
                        source: source, start: begin, end: finish,
                        muteAudio: muted, quality: selectedQuality,
                        studio: studio, clips: selected)
                } else {
                    exported = try await RecordingExportService.render(
                        source: source, start: begin, end: finish,
                        muteAudio: muted, quality: selectedQuality, studio: studio, clips: selected)
                }
                resultURL = exported
                status = "Saved \(exported.lastPathComponent). The original recording was not modified."
            } catch {
                status = "Export failed: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    private var timelineControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cut Sequence · \(Self.clock(outputDuration))").font(.subheadline.weight(.semibold))
            HStack {
                Button("Append Selected Range") { if validRange { clips.append(AOMStudioClip(start: start, end: end)); saveProject() } }
                Button("Use Only Selected Range") { clips = [AOMStudioClip(start: start, end: end)]; saveProject() }.disabled(!validRange)
            }
            HStack {
                Button("Save Project") { saveProject() }
                Button("Preview Sequence") { previewSequence() }
                Button("Source") { restoreSourcePreview() }
            }
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                HStack {
                    Text("\(index + 1). \(Self.clock(clip.start)) → \(Self.clock(clip.end))").font(.caption.monospacedDigit())
                    Spacer()
                    Button("↑") { clips.swapAt(index, index - 1); saveProject() }.disabled(index == 0)
                    Button("↓") { clips.swapAt(index, index + 1); saveProject() }.disabled(index + 1 == clips.count)
                    Button("Split at Playhead") {
                        guard zoomAt > clip.start + 0.05, zoomAt < clip.end - 0.05 else { return }
                        clips.replaceSubrange(index...index, with: [AOMStudioClip(start: clip.start, end: zoomAt), AOMStudioClip(start: zoomAt, end: clip.end)])
                        saveProject()
                    }.disabled(zoomAt <= clip.start + 0.05 || zoomAt >= clip.end - 0.05)
                    Button("Remove") { clips.remove(at: index); saveProject() }
                }
            }
            Text("Ranges export in this order; split and remove a middle range to cut it. Preview uses source time so edits remain anchored after reordering.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func restoreSourcePreview() {
        guard previewIsSequence else { return }
        previewIsSequence = false
        previewPlayer?.replaceCurrentItem(with: AVPlayerItem(url: source))
        updatePreview()
    }

    private func previewSequence() {
        let selected = exportClips
        Task {
            do {
                let asset = AVURLAsset(url: source)
                let composition = AVMutableComposition()
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let tracks = videoTracks + audioTracks
                for original in tracks {
                    guard let track = composition.addMutableTrack(withMediaType: original.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    track.preferredTransform = try await original.load(.preferredTransform)
                    let available = try await original.load(.timeRange)
                    var offset = CMTime.zero
                    for clip in selected {
                        let range = try RecordingExportService.validatedRange(start: clip.start, end: clip.end, duration: duration)
                        let segment = CMTimeRangeGetIntersection(range, otherRange: available)
                        if segment.duration > .zero { try track.insertTimeRange(segment, of: original, at: CMTimeAdd(offset, CMTimeSubtract(segment.start, range.start))) }
                        offset = CMTimeAdd(offset, range.duration)
                    }
                }
                previewIsSequence = true
                previewPlayer?.replaceCurrentItem(with: AVPlayerItem(asset: composition))
                updatePreview()
                previewPlayer?.isMuted = muteAudio
                previewPlayer?.play()
            } catch { status = "Sequence preview failed: \(error.localizedDescription)" }
        }
    }

    private func saveProject() {
        guard duration > 0 else { return }
        do {
            let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try AOMStudioProject(sourceName: source.lastPathComponent, sourceBytes: bytes, sourceDuration: duration,
                                 clips: exportClips, settings: studioSettings, muteAudio: muteAudio).write(for: source)
            status = "Studio project saved beside the original movie."
        } catch { status = "Project could not be saved: \(error.localizedDescription)" }
    }

    private func restore(_ settings: AOMStudioSettings) {
        zoomKeyframes = settings.keyframes; backdrop = settings.backdrop; backdropPadding = settings.paddingFraction
        motionBlurRadius = settings.motionBlurRadius; cursorSize = settings.cursorOverlaySize
        includeSmoothedCursor = !settings.cursorPoints.isEmpty; cursorStyle = settings.cursorStyle
        showRipples = settings.showClickRipples; keyEvents = settings.keystrokes; showKeys = settings.showKeystrokes
        keyScale = settings.keystrokeScale; keyY = settings.keystrokeY; showCamera = settings.showCamera
        cameraSize = settings.cameraSize; cameraX = settings.cameraX; cameraY = settings.cameraY; cameraRoundness = settings.cameraRoundness
        outputAspect = settings.aspect; outputResolution = settings.resolution
    }

    private static func clock(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "00:00.0" }
        let minutes = Int(time) / 60
        let seconds = time.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }
}

/// Direct Quick Access entry point; each movie keeps its own editing window.
@MainActor
final class RecordingExportEditorController: NSObject, NSWindowDelegate {
    static let shared = RecordingExportEditorController()
    private var windows: [URL: NSWindow] = [:]

    func open(source: URL) {
        let source = AOMStudioSourceLink.resolve(source)
        if let existing = windows[source] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let height = min(820, max(480, (NSScreen.main?.visibleFrame.height ?? 940) - 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: height),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Edit Recording — \(source.lastPathComponent)"
        window.applyCaptureVisibilityPreference()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: RecordingExportEditor(source: source,
            onClose: { [weak window] in window?.close() }))
        windows[source] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let source = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: source)
    }
}
