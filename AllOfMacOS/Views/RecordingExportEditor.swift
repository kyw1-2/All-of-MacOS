import AppKit
import AVKit
import SwiftUI

/// Non-destructive MP4 trimming and short animated-GIF export from Capture History.
struct RecordingExportEditor: View {
    let source: URL
    @Environment(\.dismiss) private var dismiss

    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var fps = 8
    @State private var muteAudio = false
    @State private var quality: RecordingExportService.StudioQuality = .high
    @State private var previewPlayer: AVPlayer?
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Edit Recording").font(.headline)
                Spacer()
                Button("Close") { dismiss() }.disabled(isExporting)
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

                studioControls

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
        .frame(width: 680)
        .onDisappear { previewPlayer?.pause() }
        .task {
            do {
                previewPlayer = AVPlayer(url: source)
                editableCursorTrack = AOMCursorTrack.read(for: source)
                let seconds = try await RecordingExportService.duration(for: source)
                duration = seconds
                start = 0
                end = seconds
            } catch {
                status = error.localizedDescription
            }
        }
    }

    /// Time coordinates are converted to local trimmed video time on export.
    /// The renderer never mutates the original MP4 or captures cursor events.
    private var studioControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Studio Mode — Zoom Timeline", systemImage: "viewfinder")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Text("At")
                Slider(value: $zoomAt, in: 0...max(0.1, duration), step: 0.1)
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
                    zoomKeyframes.append(AOMStudioZoomKeyframe(
                        time: zoomAt - start, magnification: zoomLevel,
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
            ForEach(zoomKeyframes) { keyframe in
                HStack {
                    Text("\(Self.clock(keyframe.time + start)) — \(String(format: "%.1f×", keyframe.magnification))")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button(role: .destructive) {
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
            Text("Zoom keyframes are manually positioned. Automatic scene analysis and camera-track editing are not available.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func export(gif: Bool, rendered: Bool = false) {
        guard validRange, !isExporting else { return }
        isExporting = true
        status = ""
        resultURL = nil
        let begin = start, finish = end, frames = fps
        let muted = muteAudio, selectedQuality = quality
        let studio = AOMStudioSettings(keyframes: zoomKeyframes,
                                       backdrop: backdrop,
                                       paddingFraction: backdropPadding,
                                       motionBlurRadius: motionBlurRadius,
                                       cursorPoints: includeSmoothedCursor ?
                                           (editableCursorTrack?.points ?? []) : [],
                                       cursorOverlaySize: cursorSize)
        Task {
            do {
                let exported: URL
                if gif {
                    exported = try await RecordingExportService.gif(
                        source: source, start: begin, end: finish, fps: frames)
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
