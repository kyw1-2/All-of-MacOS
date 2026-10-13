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

    private var validRange: Bool {
        duration > 0 && start >= 0 && end > start + 0.05 && end <= duration + 0.05
    }

    var body: some View {
        ScrollView {
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
                        Label("Save Trimmed MP4", systemImage: "scissors")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || !validRange)

                    Button {
                        export(gif: true)
                    } label: {
                        Label("Export GIF", systemImage: "photo.stack")
                    }
                    .disabled(isExporting || !validRange || end - start > 30)

                    Picker("GIF FPS", selection: $fps) {
                        Text("5").tag(5)
                        Text("8").tag(8)
                        Text("10").tag(10)
                    }
                    .frame(width: 110)
                    .disabled(isExporting)
                }

                if end - start > 30 {
                    Text("GIF exports support clips of up to 30 seconds. Trim the range first.")
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
            previewPlayer?.seek(to: CMTime(seconds: value, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onChange(of: end) { _, value in
            previewPlayer?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: value, preferredTimescale: 600)
        }
        .task(id: studioSettings) {
            // Coalesce slider events; cancelled tasks cannot install stale effects.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            updatePreview()
        }
        .onDisappear { previewPlayer?.pause() }
        .task {
            do {
                previewPlayer = AVPlayer(url: source)
                editableCursorTrack = AOMCursorTrack.read(for: source)
                let seconds = try await RecordingExportService.duration(for: source)
                duration = seconds
                start = 0
                end = seconds
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
                    zoomKeyframes.removeAll { abs($0.time - zoomAt) < 0.001 }
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
                Button("Suggest Zooms from Cursor") {
                    guard let track = editableCursorTrack else { return }
                    let suggested = AOMStudioTimeline.suggestedZooms(track: track, start: start, end: end)
                    guard !suggested.isEmpty else {
                        status = "No sustained cursor pauses found in this range. Add a keyframe manually."
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
                        zoomAt = keyframe.time
                        zoomLevel = keyframe.magnification
                        focusX = keyframe.focusX
                        focusY = keyframe.focusY
                    } label: {
                        Text("\(Self.clock(keyframe.time)) — \(String(format: "%.1f×", keyframe.magnification))")
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .help("Load this keyframe for editing; Add Keyframe replaces it at the same time")
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
            Text("Zoom suggestions follow pauses in the recorded cursor. Adjust or remove any keyframe; the preview shows the edited result.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var studioSettings: AOMStudioSettings {
        AOMStudioSettings(keyframes: zoomKeyframes, backdrop: backdrop,
                          paddingFraction: backdropPadding, motionBlurRadius: motionBlurRadius,
                          cursorPoints: includeSmoothedCursor ? (editableCursorTrack?.points ?? []) : [],
                          cursorOverlaySize: cursorSize)
    }

    private func updatePreview() {
        guard let player = previewPlayer, let item = player.currentItem else { return }
        let effect = studioSettings
        item.videoComposition = effect.isActive ? AVVideoComposition(
            asset: item.asset, applyingCIFiltersWithHandler: { request in
                let image = AOMStudioRenderer.frame(request.sourceImage,
                    time: CMTimeGetSeconds(request.compositionTime), settings: effect)
                request.finish(with: image, context: nil)
            }) : nil
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
        Task {
            do {
                let exported: URL
                if gif {
                    exported = try await RecordingExportService.gif(
                        source: source, start: begin, end: finish, fps: frames, studio: studio)
                } else if rendered {
                    exported = try await RecordingExportService.render(
                        source: source, start: begin, end: finish,
                        muteAudio: muted, quality: selectedQuality,
                        studio: studio)
                } else {
                    exported = try await RecordingExportService.trim(
                        source: source, start: begin, end: finish)
                }
                resultURL = exported
                status = "Saved \(exported.lastPathComponent). The original recording was not modified."
            } catch {
                status = "Export failed: \(error.localizedDescription)"
            }
            isExporting = false
        }
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
