import AppKit
import AVKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// Non-destructive MP4 trimming and short animated-GIF export from Capture History.
///
/// Laid out as a standard page: the preview, then one section per job (trim,
/// cut sequence, zoom, background, cursor, clicks, shortcut and camera layers,
/// output, export), each a card of rows, so every option sits with the ones
/// it works with.
struct RecordingExportEditor: View {
    let source: URL
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var fps = 8
    /// GIF options (3.3.3); shared with the recording settings.
    @AppStorage("AOMCaptureRecordingGIFSize") private var gifSize = 960
    @AppStorage("AOMCaptureRecordingGIFLoop") private var gifLoops = true
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
    @State private var background = AOMVideoBackground()
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
    @State private var clickStyle = AOMClickStyle.legacy
    @State private var highlightOn = false
    @State private var highlight = AOMCursorHighlight()
    @State private var showKeys = true
    @State private var keyScale = 1.0
    @State private var keyY = 0.9
    @State private var keyStyle: AOMKeystrokeStyle = .dark
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

    /// The window height for this screen (the controller sizes the window the same way).
    static var preferredHeight: CGFloat {
        min(AOMFeatureSize.recordingEditorHeight.upperBound,
            max(AOMFeatureSize.recordingEditorHeight.lowerBound,
                (NSScreen.main?.visibleFrame.height ?? 940) - AOMFeatureSize.recordingEditorScreenMargin))
    }

    var body: some View {
        AOMPage(maxWidth: AOMFeatureSize.recordingEditorWidth, spacing: AOMSpace.x5) {
            AOMPageHeader("Edit Recording", symbol: "film.stack.fill", subtitle: source.lastPathComponent,
                          help: "Edits are saved as a Studio project beside the movie, and the original recording is never changed. Ranges, zooms and layers stay anchored to the recording's own time, so reordering never moves them.") {
                Button("Close") { if let onClose { onClose() } else { dismiss() } }.disabled(isExporting)
            }

            if duration > 0 {
                if let previewPlayer {
                    VideoPlayer(player: previewPlayer)
                        .frame(height: AOMFeatureSize.videoPreviewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
                            .strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                        .accessibilityLabel("Recording preview")
                }
                trimSection
                timelineControls.disabled(isExporting)
                studioControls.disabled(isExporting)
                outputSection
                exportSection
            } else if loadFailed {
                AOMNotice(.error, "Could not open this recording.")
            } else {
                ProgressView("Reading recording…")
                    .frame(maxWidth: .infinity)
            }

            if isExporting || !status.isEmpty || resultURL != nil {
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    if isExporting {
                        ProgressView("Exporting…")
                            .controlSize(.small)
                    }
                    if !status.isEmpty {
                        Text(status)
                            .font(AOMFont.caption)
                            .foregroundStyle(resultURL == nil ? AOMColor.textSecondary : AOMColor.successText)
                            .lineLimit(3)
                    }
                    if let resultURL {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([resultURL])
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.horizontal, AOMSpace.x1)
            }
        }
        .frame(width: AOMFeatureSize.recordingEditorWidth, height: Self.preferredHeight)
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
                } else {
                    // Start from what the recording's Presentation showed.
                    restore(AOMStudioSettings.recordingDefaults(track: editableCursorTrack))
                }
                updatePreview()
            } catch {
                loadFailed = true
                status = error.localizedDescription
            }
        }
    }

    // MARK: - Rows

    /// A row inside a section card with the `AOMSettingRow` metrics, for
    /// content that needs its own layout (lists, sliders, number fields).
    private func cardRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: AOMSpace.x3) { content() }
            .padding(.horizontal, AOMSpace.rowInset)
            .padding(.vertical, AOMSpace.x1)
            .frame(maxWidth: .infinity, minHeight: AOMSize.rowStandard, alignment: .leading)
            .overlay(alignment: .top) { AOMRowDivider() }
            .accessibilityElement(children: .contain)
    }

    /// A slider row: its title, a slider that takes the free width and,
    /// when it helps, the value it sets.
    private func sliderRow<V: BinaryFloatingPoint>(_ title: String, value: Binding<V>, in range: ClosedRange<V>,
                                                   step: V.Stride? = nil, label: String? = nil) -> some View
        where V.Stride: BinaryFloatingPoint {
        cardRow {
            Text(title).font(AOMFont.body).foregroundStyle(AOMColor.text)
                .frame(width: AOMFeatureSize.editorRowTitle, alignment: .leading)
            Group {
                if let step { Slider(value: value, in: range, step: step) } else { Slider(value: value, in: range) }
            }
            .accessibilityLabel(title)
            if let label {
                Text(label).font(AOMFont.body).monospacedDigit().foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMFeatureSize.editorRowValue, alignment: .trailing)
            }
        }
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    // MARK: - Trim

    private var trimSection: some View {
        AOMSection("Trim", footer: "Selected: \(Self.clock(max(0, end - start))) of \(Self.clock(duration))") {
            sliderRow("Start", value: $start, in: 0...max(0.1, duration), step: 0.1, label: Self.clock(start))
                .onChange(of: start) { _, next in
                    if next >= end { end = min(duration, next + 0.1) }
                }
            sliderRow("End", value: $end, in: 0...max(0.1, duration), step: 0.1, label: Self.clock(end))
                .onChange(of: end) { _, next in
                    if next <= start { start = max(0, next - 0.1) }
                }
        }
    }

    // MARK: - Cut sequence

    private var timelineControls: some View {
        AOMSection("Cut sequence", detail: Self.clock(outputDuration),
                   footer: "Ranges export in this order; split and remove a middle range to cut it. Preview uses source time so edits remain anchored after reordering.") {
            AOMSettingRow("Selected range") {
                HStack(spacing: AOMSpace.x2) {
                    Button("Append Selected Range") { if validRange { clips.append(AOMStudioClip(start: start, end: end)); saveProject() } }
                    Button("Use Only Selected Range") { clips = [AOMStudioClip(start: start, end: end)]; saveProject() }.disabled(!validRange)
                }
            }
            AOMSettingRow("Preview") {
                HStack(spacing: AOMSpace.x2) {
                    Button("Preview Sequence") { previewSequence() }
                    Button("Source") { restoreSourcePreview() }
                }
            }
            AOMSettingRow("Project", detail: "Saved beside the original movie") {
                Button("Save Project") { saveProject() }
            }
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                cardRow {
                    Text("\(index + 1). \(Self.clock(clip.start)) → \(Self.clock(clip.end))")
                        .font(AOMFont.body.monospacedDigit()).foregroundStyle(AOMColor.text)
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
        }
    }

    // MARK: - Studio (zoom, background, cursor, clicks, layers)

    /// All edits remain anchored to source time, including after changing trim bounds.
    @ViewBuilder private var studioControls: some View {
        zoomSection
        if !zoomKeyframes.isEmpty { keyframesSection }
        backgroundControls
        cursorSection
        clickAndHighlightControls
        if !keyEvents.isEmpty { shortcutSection }
        if FileManager.default.fileExists(atPath: AOMStudioCameraFrames.url(for: source).path) { cameraSection }
    }

    private var zoomSection: some View {
        AOMSection("Zoom", detail: zoomKeyframes.isEmpty ? nil : "\(zoomKeyframes.count) keyframe\(zoomKeyframes.count == 1 ? "" : "s")",
                   help: "Set the time, zoom and focus, then Add Keyframe. Suggest Smart Zooms uses recorded clicks, with pointer dwell as a fallback. Load a keyframe from the list to move or replace it.") {
            sliderRow("At", value: $zoomAt, in: 0...max(0.1, duration), step: 0.1, label: Self.clock(zoomAt))
                .onChange(of: zoomAt) { _, value in
                    restoreSourcePreview()
                    previewPlayer?.pause()
                    previewPlayer?.seek(to: CMTime(seconds: value, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero)
                }
            sliderRow("Zoom", value: $zoomLevel, in: 1...3, step: 0.1, label: String(format: "%.1f×", zoomLevel))
            sliderRow("Focus X", value: $focusX, in: 0...1, label: Self.percent(focusX))
            sliderRow("Focus Y", value: $focusY, in: 0...1, label: Self.percent(focusY))
            sliderRow("Zoom-transition blur", value: $motionBlurRadius, in: 0...8, label: String(format: "%.1f", motionBlurRadius))
                .disabled(isExporting)
            AOMSettingRow("Keyframes") {
                HStack(spacing: AOMSpace.x2) {
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
            }
        }
    }

    private var keyframesSection: some View {
        AOMSection("Zoom keyframes") {
            ForEach(zoomKeyframes) { keyframe in
                cardRow {
                    Button {
                        editingKeyframeID = keyframe.id
                        zoomAt = keyframe.time
                        zoomLevel = keyframe.magnification
                        focusX = keyframe.focusX
                        focusY = keyframe.focusY
                    } label: {
                        Label("\(Self.clock(keyframe.time)) — \(String(format: "%.1f×", keyframe.magnification))",
                              systemImage: editingKeyframeID == keyframe.id ? "diamond.fill" : "diamond")
                            .font(AOMFont.body.monospacedDigit())
                            .foregroundStyle(AOMColor.text)
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
        }
    }

    private var cursorSection: some View {
        AOMSection("Cursor",
                   footer: editableCursorTrack == nil
                   ? "Editable cursor motion requires a new recording with Cursor Track enabled in Capture Settings."
                   : (editableCursorTrack?.pointerInVideo == true
                      ? "The system pointer is already in this video; the cursor track adds only the highlight." : nil)) {
            if let track = editableCursorTrack {
                AOMToggleRow("Smooth editable cursor", detail: "\(track.points.count) cursor samples", isOn: $includeSmoothedCursor)
                sliderRow("Cursor size", value: $cursorSize, in: 0.5...2, step: 0.1, label: String(format: "%.1f×", cursorSize))
            }
            AOMSettingRow("Cursor") {
                Picker("Cursor", selection: $cursorStyle) { ForEach(AOMStudioCursorStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    .pickerStyle(.menu)
            }
            AOMToggleRow("Click ripples", isOn: $showRipples)
        }
    }

    private var studioSettings: AOMStudioSettings {
        AOMStudioSettings(keyframes: zoomKeyframes, backdrop: .none,
                          paddingFraction: 0, motionBlurRadius: motionBlurRadius,
                          cursorPoints: includeSmoothedCursor ? (editableCursorTrack?.points ?? []) : [],
                          cursorOverlaySize: cursorSize, clicks: editableCursorTrack?.clicks ?? [],
                          showClickRipples: showRipples, cursorStyle: cursorStyle,
                          keystrokes: keyEvents.filter { $0.isValid }.sorted { $0.time < $1.time }, showKeystrokes: showKeys,
                          keystrokeScale: keyScale, keystrokeY: keyY, showCamera: showCamera,
                          cameraSize: cameraSize, cameraX: cameraX, cameraY: cameraY, cameraRoundness: cameraRoundness,
                          aspect: outputAspect, resolution: outputResolution, keystrokeStyle: keyStyle,
                          background: background, clickStyle: clickStyle,
                          cursorHighlight: highlightOn ? highlight : nil)
    }

    // MARK: - Click marks and cursor highlight (3.3.3, C06)

    private var clickAndHighlightControls: some View {
        AOMSection("Clicks & highlight") {
            AOMSettingRow("Click style") {
                Picker("Click style", selection: $clickStyle.shape) {
                    ForEach(AOMClickRingStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
            }
            AOMSettingRow("Click colours", detail: "Left and right clicks") {
                HStack(spacing: AOMSpace.x3) {
                    ColorPicker("Left click", selection: Self.cgColor($clickStyle.leftColor))
                    ColorPicker("Right click", selection: Self.cgColor($clickStyle.rightColor))
                }
            }
            sliderRow("Click size", value: $clickStyle.size, in: AOMClickStyle.sizeRange)
            sliderRow("Duration", value: $clickStyle.duration, in: AOMClickStyle.durationRange,
                      label: String(format: "%.2f s", clickStyle.duration))
            Group {
                AOMToggleRow("Cursor highlight", isOn: $highlightOn)
                Group {
                    AOMSettingRow("Highlight colour", indent: true) {
                        ColorPicker("Color", selection: Self.cgColor($highlight.color))
                    }
                    sliderRow("Highlight size", value: $highlight.size, in: AOMCursorHighlight.sizeRange)
                }
                .disabled(!highlightOn)
                .opacity(highlightOn ? 1 : 0.55)
            }
            .disabled(editableCursorTrack?.points.isEmpty ?? true)
        }
        .disabled(isExporting)
    }

    // MARK: - Shortcut and camera layers

    private var shortcutSection: some View {
        AOMSection("Shortcut layer") {
            AOMToggleRow("Shortcut layer", isOn: $showKeys)
            Group {
                sliderRow("Size", value: $keyScale, in: 0.5...2, label: String(format: "%.1f×", keyScale))
                sliderRow("Vertical position", value: $keyY, in: 0...1, label: Self.percent(keyY))
                AOMSettingRow("Badge style") {
                    Picker("Badge style", selection: $keyStyle) {
                        ForEach(AOMKeystrokeStyle.allCases) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)
                }
            }
            .disabled(!showKeys)
            .opacity(showKeys ? 1 : 0.55)
            ForEach($keyEvents) { $key in
                cardRow {
                    Text(key.label).font(AOMFont.body).foregroundStyle(AOMColor.text)
                        .frame(width: AOMFeatureSize.editorRowTitle, alignment: .leading)
                    TextField("Time", value: $key.time, format: .number).frame(width: AOMFeatureSize.numberField)
                    TextField("Duration", value: $key.duration, format: .number).frame(width: AOMFeatureSize.numberField)
                    Spacer()
                    Button("Delete") { keyEvents.removeAll { $0.id == key.id } }
                }
            }
        }
    }

    private var cameraSection: some View {
        AOMSection("Camera layer") {
            AOMToggleRow("Camera layer", isOn: $showCamera)
            Group {
                sliderRow("Size", value: $cameraSize, in: 0.1...0.6, label: Self.percent(cameraSize))
                sliderRow("Roundness", value: $cameraRoundness, in: 0...0.5, label: Self.percent(cameraRoundness))
                sliderRow("Camera X", value: $cameraX, in: 0...1, label: Self.percent(cameraX))
                sliderRow("Camera Y", value: $cameraY, in: 0...1, label: Self.percent(cameraY))
            }
            .disabled(!showCamera)
            .opacity(showCamera ? 1 : 0.55)
        }
    }

    // MARK: - Output and export

    private var outputSection: some View {
        AOMSection("Output",
                   footer: "Shortcut and camera layers require a new AOM recording; older videos retain their baked overlays.") {
            AOMSettingRow("Aspect") {
                Picker("Aspect", selection: $outputAspect) { ForEach(AOMStudioAspect.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    .pickerStyle(.menu)
            }
            AOMSettingRow("Resolution") {
                Picker("Resolution", selection: $outputResolution) { ForEach(AOMStudioResolution.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    .pickerStyle(.menu)
            }
            AOMSettingRow("MP4 quality") {
                Picker("MP4 Quality", selection: $quality) {
                    ForEach(RecordingExportService.StudioQuality.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
            }
            AOMToggleRow("Mute Audio", isOn: $muteAudio)
        }
        .disabled(isExporting)
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            if outputDuration > 120 {
                AOMNotice(.warning, "GIF exports support clips of up to 120 seconds.", detail: "Trim the range first.")
            }
            AOMSection("Export", footer: "Exports are new files; the original recording is not modified.") {
                AOMSettingRow("Edited movie", detail: "MP4 with every Studio layer") {
                    Button {
                        export(gif: false, rendered: true)
                    } label: {
                        Label("Render Edited MP4", systemImage: "film.stack")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || !validRange)
                }
                AOMSettingRow("Cut sequence", detail: "The ranges above, in order") {
                    Button {
                        export(gif: false)
                    } label: {
                        Label("Export Cut Sequence", systemImage: "scissors")
                    }
                    .disabled(isExporting || !validRange)
                }
                AOMSettingRow("Animated GIF", detail: "Up to 120 seconds") {
                    Button {
                        export(gif: true)
                    } label: {
                        Label("Export GIF", systemImage: "photo.stack")
                    }
                    .disabled(isExporting || !validRange || outputDuration > 120)
                }
                Group {
                    AOMSettingRow("GIF frame rate", indent: true) {
                        Picker("GIF FPS", selection: $fps) {
                            Text("5").tag(5)
                            Text("8").tag(8)
                            Text("10").tag(10)
                            Text("15").tag(15)
                            Text("20").tag(20)
                            Text("30").tag(30)
                        }
                        .pickerStyle(.menu)
                    }
                    AOMSettingRow("GIF size", indent: true, help: "Longest edge of the GIF frames") {
                        Picker("Size", selection: $gifSize) {
                            ForEach(CaptureSettings.recordingGIFSizeChoices, id: \.self) { Text("\($0) px").tag($0) }
                        }
                        .pickerStyle(.menu)
                        .help("Longest edge of the GIF frames")
                    }
                    AOMSettingRow("Loop", indent: true) {
                        Toggle("Loop", isOn: $gifLoops)
                            .help("Off plays the GIF once")
                    }
                }
                .disabled(isExporting)
            }
        }
    }

    // MARK: - Background (3.3.3, C05)

    /// Colour, gradient, picture or desktop picture behind the video, with
    /// padding, corners and shadow. The preview above updates as they change.
    private var backgroundControls: some View {
        AOMSection("Background") {
            AOMSettingRow("Background") {
                Picker("Background", selection: Binding(get: { background.kind }, set: { selectBackground($0) })) {
                    ForEach(AOMVideoBackgroundKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
            }
            switch background.kind {
            case .solid:
                AOMSettingRow("Color", indent: true) {
                    ColorPicker("Color", selection: Self.cgColor($background.color, opaque: true), supportsOpacity: false)
                }
            case .gradient:
                AOMSettingRow("Gradient", indent: true) {
                    Picker("Gradient", selection: $background.gradient) {
                        ForEach(AOMGradientPreset.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            case .image:
                AOMSettingRow("Picture", detail: background.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No image chosen",
                              indent: true) {
                    Button("Choose Image…") { chooseBackgroundImage() }
                }
            case .wallpaper:
                AOMSettingRow("Desktop picture",
                              detail: background.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Gradient (desktop picture unreadable)",
                              indent: true) {
                    Button("Use Current Desktop Picture") { selectBackground(.wallpaper) }
                }
            case .none:
                EmptyView()
            }
            Group {
                sliderRow("Padding", value: $background.padding, in: AOMVideoBackground.paddingRange)
                sliderRow("Corners", value: $background.cornerRadius, in: AOMVideoBackground.cornerRange)
                sliderRow("Shadow", value: $background.shadow, in: AOMVideoBackground.shadowRange)
            }
            .disabled(isExporting || !background.isActive)
            .opacity(background.isActive ? 1 : 0.55)
        }
        .disabled(isExporting)
    }

    private func selectBackground(_ kind: AOMVideoBackgroundKind) {
        switch kind {
        case .image:
            // Reuse a picture chosen earlier; otherwise ask for one.
            if background.kind != .wallpaper, let path = background.imagePath, FileManager.default.isReadableFile(atPath: path) {
                background.kind = .image
            } else {
                chooseBackgroundImage()
            }
        case .wallpaper:
            let path = AOMVideoBackground.currentWallpaperPath()
            AOMStudioBackgroundImages.invalidate(path)
            background.imagePath = path
            background.kind = .wallpaper
            if path == nil { status = "The desktop picture is not a readable image file; the \(background.gradient.displayName) gradient is used instead." }
        default:
            background.kind = kind
        }
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture to place behind the recording"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AOMStudioBackgroundImages.invalidate(url.path)
        background.imagePath = url.path
        background.kind = .image
    }

    /// A ColorPicker binding over a stored sRGB colour.
    private static func cgColor(_ color: Binding<AOMRGBAColor>, opaque: Bool = false) -> Binding<CGColor> {
        Binding(get: { color.wrappedValue.cgColor }, set: { picked in
            guard var converted = AOMRGBAColor(cgColor: picked) else { return }
            if opaque { converted.alpha = 1 }
            color.wrappedValue = converted
        })
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
        let gifSide = gifSize, gifRepeats = gifLoops
        let muted = muteAudio, selectedQuality = quality
        let studio = studioSettings
        let selected = exportClips
        saveProject()
        Task {
            do {
                let exported: URL
                if gif {
                    exported = try await RecordingExportService.gif(
                        source: source, start: begin, end: finish, fps: frames, studio: studio, clips: selected,
                        maxDimension: gifSide, loops: gifRepeats)
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
        zoomKeyframes = settings.keyframes
        // Projects saved before 3.3.3 carry a single-colour backdrop instead.
        background = settings.background ?? AOMVideoBackground(legacy: settings.backdrop, padding: settings.paddingFraction)
        if background.kind == .wallpaper, background.imagePath.map({ !FileManager.default.isReadableFile(atPath: $0) }) ?? true {
            background.imagePath = AOMVideoBackground.currentWallpaperPath()
        }
        motionBlurRadius = settings.motionBlurRadius; cursorSize = settings.cursorOverlaySize
        includeSmoothedCursor = !settings.cursorPoints.isEmpty; cursorStyle = settings.cursorStyle
        clickStyle = settings.clickStyle ?? .legacy
        highlightOn = settings.cursorHighlight != nil
        highlight = settings.cursorHighlight ?? AOMCursorHighlight()
        showRipples = settings.showClickRipples; keyEvents = settings.keystrokes; showKeys = settings.showKeystrokes
        keyScale = settings.keystrokeScale; keyY = settings.keystrokeY; showCamera = settings.showCamera
        keyStyle = settings.keystrokeStyle ?? .dark
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
        let height = RecordingExportEditor.preferredHeight
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: AOMFeatureSize.recordingEditorWidth, height: height),
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
