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
                let seconds = try await RecordingExportService.duration(for: source)
                duration = seconds
                start = 0
                end = seconds
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func export(gif: Bool, rendered: Bool = false) {
        guard validRange, !isExporting else { return }
        isExporting = true
        status = ""
        resultURL = nil
        let begin = start, finish = end, frames = fps
        let muted = muteAudio, selectedQuality = quality
        Task {
            do {
                let exported: URL
                if gif {
                    exported = try await RecordingExportService.gif(
                        source: source, start: begin, end: finish, fps: frames)
                } else if rendered {
                    exported = try await RecordingExportService.render(
                        source: source, start: begin, end: finish,
                        muteAudio: muted, quality: selectedQuality)
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
