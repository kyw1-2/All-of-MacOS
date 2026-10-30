import SwiftUI
import AppKit

/// The Capture settings tab (Settings › Capture › All Capture Options, and
/// Capture › Capture Settings…).
///
/// Split into the same groups CleanShot uses — what is captured, what happens
/// afterwards, how the overlay behaves — because those are the three things a
/// user actually comes here to change. 3.3.3 (ui.md e.3/e.10): standard page
/// sections (title above an opaque card, at most 8 rows), ⓘ help instead of
/// caption lines, and dependent options indented and disabled under their
/// parent instead of hidden.
struct CaptureSettingsView: View {
    /// Section anchors; isolated previews can open one with
    /// `--aom-preview-capture-section <raw value>` (AudioCapturePreviewHooks).
    enum Section: String, CaseIterable {
        case format, capture, selecting, recording, pointer, clicks, camera, keystrokes, during,
             after, naming, overlay, closing, text, pinned
    }

    @AppStorage("AOMCaptureFormat") private var formatRaw = CaptureFormat.png.rawValue
    @AppStorage("AOMCaptureQuality") private var quality = 0.9
    @AppStorage("AOMCaptureShowsCursor") private var showsCursor = false
    @AppStorage("AOMCaptureRecordingAudioSource") private var recordingAudioSourceRaw = RecordingAudioSource.off.rawValue
    @AppStorage("AOMCaptureRecordingCameraOverlay") private var recordingCameraOverlay = false
    @AppStorage("AOMCaptureRecordingCameraBubble") private var recordingCameraBubble = true
    @AppStorage("AOMCaptureRecordingKeystrokeOverlay") private var recordingKeystrokeOverlay = false
    @AppStorage("AOMCaptureRecordingKeystrokeAllKeys") private var keystrokeAllKeys = false
    @AppStorage("AOMCaptureRecordingKeystrokePosition") private var keystrokePosition = KeystrokeOverlayPosition.bottom.rawValue
    @AppStorage("AOMCaptureRecordingKeystrokeSize") private var keystrokeSize = KeystrokeOverlaySize.medium.rawValue
    @AppStorage("AOMCaptureRecordingKeystrokeStyle") private var keystrokeStyle = AOMKeystrokeStyle.dark.rawValue
    @AppStorage("AOMCaptureRecordingOutputFormat") private var recordingOutputFormat = "mp4"
    @AppStorage("AOMCaptureRecordingGIFFPS") private var recordingGIFFPS = 10
    @AppStorage("AOMCaptureRecordingFPS") private var recordingFPS = 30
    @AppStorage("AOMCaptureRecordingQuality") private var recordingQuality = 2
    @AppStorage("AOMCaptureRecordingClickIndicators") private var recordingClickIndicators = false
    @AppStorage("AOMCaptureRecordingCursorMotion") private var recordingCursorMotion = false
    @AppStorage("AOMCaptureRecordingFocus") private var recordingFocus = false
    @AppStorage("AOMCaptureRecordingFocusOn") private var recordingFocusOn = CaptureSettings.defaultRecordingFocusOnShortcut
    @AppStorage("AOMCaptureRecordingFocusOff") private var recordingFocusOff = CaptureSettings.defaultRecordingFocusOffShortcut
    @State private var focusTestResult: String?
    @AppStorage("AOMCaptureWindowShadow") private var windowShadow = true
    @AppStorage("AOMCaptureHidesDesktopIcons") private var hidesDesktopIcons = false
    @AppStorage("AOMCapturePlaysSound") private var playsSound = true
    @AppStorage("AOMCaptureSelfTimer") private var selfTimer = 0
    @AppStorage("AOMCapturePixelSnap") private var pixelSnap = true
    @AppStorage("AOMCaptureSnapSelection") private var snapsSelection = true
    @AppStorage("AOMCaptureFreezeScreen") private var freezeScreen = false
    @AppStorage("AOMCaptureAfterAction") private var afterActionRaw = AfterCaptureAction.showOverlay.rawValue
    @AppStorage("AOMCaptureOverlayEnabled") private var overlayEnabled = true
    @AppStorage("AOMCaptureOverlayCorner") private var overlayCornerRaw = OverlayCorner.bottomLeft.rawValue
    @AppStorage("AOMCaptureOverlaySize") private var overlaySizeRaw = OverlaySize.small.rawValue
    @AppStorage("AOMCaptureOverlayAutoClose") private var autoCloseRaw = CaptureSettings.defaultOverlayAutoClose.rawValue
    @AppStorage("AOMCaptureOverlayInterval") private var overlayInterval = CaptureSettings.defaultOverlayIntervalSeconds
    @AppStorage("AOMCaptureOverlayAfterCopyOrSave") private var overlayAfterCopyOrSave = false
    @AppStorage("AOMCaptureOverlayActiveDisplay") private var overlayActiveDisplay = true
    @AppStorage("AOMCaptureOverlayCloseAfterDrag") private var overlayCloseAfterDrag = true
    @AppStorage("AOMCaptureOverlayAutoCloseSave") private var overlayAutoCloseSave = true
    // Must match CaptureSettings.asksForNameAfterCapture's key (was a dead key).
    @AppStorage("AOMCaptureAsksForName") private var asksNameOnSave = false
    @AppStorage("AOMCaptureCrosshairMode") private var crosshairModeRaw = CrosshairMode.always.rawValue
    @AppStorage("AOMCaptureShowsMagnifier") private var showsMagnifier = false
    @AppStorage("AOMCaptureSelfTimerInterval") private var selfTimerInterval = 2
    @AppStorage("AOMCaptureHistoryCapacity") private var historyCapacity = 40
    @AppStorage("AOMCaptureHistoryRetentionDays") private var historyRetentionDays = 30
    @AppStorage("AOMOCRKeepsLineBreaks") private var ocrKeepsLineBreaks = true
    @AppStorage("AOMPinnedShadow") private var pinnedShadow = true
    @AppStorage("AOMPinnedCorners") private var pinnedCorners = true
    @AppStorage("AOMPinnedBorder") private var pinnedBorder = false
    @AppStorage("AOMCaptureFilenameTemplate") private var filenameTemplate = ""
    @AppStorage("AOMCaptureFilenameUTC") private var filenameUTC = false
    @AppStorage("AOMCaptureColorProfile") private var colorProfile = CaptureColorProfile.display.rawValue

    // 3.3.3 recording options (CaptureSettings.RecordingKey). The optional
    // ones are unset until the user picks a value, so CaptureSettings keeps
    // its own defaults and clamping; rows read through CaptureSettings, and
    // these declarations redraw the page when a value changes.
    @AppStorage(CaptureSettings.RecordingKey.showsCursor) private var recordingShowsCursorChoice: Bool?
    @AppStorage(CaptureSettings.RecordingKey.cursorSize) private var recordingCursorSize: Double?
    @AppStorage(CaptureSettings.RecordingKey.cursorHighlight) private var recordingCursorHighlight = false
    @AppStorage(CaptureSettings.RecordingKey.cursorHighlightColor) private var cursorHighlightColorHex: String?
    @AppStorage(CaptureSettings.RecordingKey.cursorHighlightSize) private var cursorHighlightSize: Double?
    @AppStorage(CaptureSettings.RecordingKey.clickStyle) private var clickStyleRaw = AOMClickRingStyle.ring.rawValue
    @AppStorage(CaptureSettings.RecordingKey.clickColor) private var clickColorHex: String?
    @AppStorage(CaptureSettings.RecordingKey.rightClickColor) private var rightClickColorHex: String?
    @AppStorage(CaptureSettings.RecordingKey.clickSize) private var clickSize: Double?
    @AppStorage(CaptureSettings.RecordingKey.clickDuration) private var clickDuration: Double?
    @AppStorage(CaptureSettings.RecordingKey.keystrokeModifiers) private var keystrokeModifiersRaw: String?
    @AppStorage(CaptureSettings.RecordingKey.hidesDesktopIcons) private var recordingHidesDesktopIcons = false
    @AppStorage(CaptureSettings.RecordingKey.gifMaxDimension) private var gifMaxDimension: Int?
    @AppStorage(CaptureSettings.RecordingKey.gifLoops) private var gifLoops = true
    @AppStorage(CaptureSettings.RecordingKey.scalesTo1x) private var scalesTo1x = false
    @AppStorage(CaptureSettings.RecordingKey.cameraID) private var recordingCameraID = ""
    @AppStorage(CaptureSettings.RecordingKey.microphoneID) private var recordingMicrophoneID = ""
    @State private var cameras: [RecordingInputDevice] = []
    @State private var microphones: [RecordingInputDevice] = []

    @State private var saveDirectory: String = CaptureSettings.saveDirectory.path
    @State private var permissionGranted = ScreenCaptureService.hasPermission

    private var format: CaptureFormat { CaptureFormat(rawValue: formatRaw) ?? .png }
    private var afterAction: AfterCaptureAction { AfterCaptureAction(rawValue: afterActionRaw) ?? .showOverlay }
    private var recordsGIF: Bool { recordingOutputFormat == "gif" }
    private var recordsMicrophone: Bool {
        let source = RecordingAudioSource(rawValue: recordingAudioSourceRaw) ?? .off
        return !recordsGIF && (source == .microphone || source == .computerAndMicrophone)
    }

    var body: some View {
        ScrollViewReader { proxy in
            AOMPage(maxWidth: AOMSize.readableWidth) {
                if !permissionGranted { permissionNotice }
                formatGroup.id(Section.format)
                captureGroup.id(Section.capture)
                selectingGroup.id(Section.selecting)
                recordingGroup.id(Section.recording)
                pointerGroup.id(Section.pointer)
                clicksGroup.id(Section.clicks)
                cameraAudioGroup.id(Section.camera)
                keystrokesGroup.id(Section.keystrokes)
                whileRecordingGroup.id(Section.during)
                afterCaptureGroup.id(Section.after)
                namingGroup.id(Section.naming)
                overlayGroup.id(Section.overlay)
                closingGroup.id(Section.closing)
                textRecognitionGroup.id(Section.text)
                pinnedGroup.id(Section.pinned)
            }
            .onAppear {
                guard let section = AudioCapturePreviewHooks.captureSection.flatMap(Section.init(rawValue:)) else { return }
                DispatchQueue.main.async { proxy.scrollTo(section, anchor: .top) }
            }
        }
        .onAppear {
            permissionGranted = ScreenCaptureService.hasPermission
            // Listing devices opens nothing and needs no permission.
            cameras = RecordingInputDevice.cameras()
            if #available(macOS 15, *) { microphones = RecordingInputDevice.microphones() }
        }
        .onChange(of: historyCapacity) { _, _ in CaptureHistory.shared.applyRetention() }
        .onChange(of: historyRetentionDays) { _, _ in CaptureHistory.shared.applyRetention() }
    }

    // MARK: - Permission

    private var permissionNotice: some View {
        AOMNotice(.warning, "Screen Recording is off", detail: "All of MacOS needs it to capture the screen.") {
            Button("Request Access") {
                ScreenCaptureService.requestPermission()
                // The grant is applied by the system, so the state can only be
                // re-read after the user has answered the prompt.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    permissionGranted = ScreenCaptureService.hasPermission
                }
            }
        }
    }

    // MARK: - Format

    private var formatGroup: some View {
        AOMSection("Format") {
            AOMSettingRow("Image format", help: "PNG is lossless; JPEG and HEIC are smaller.") {
                Picker("Image Format", selection: $formatRaw) {
                    ForEach(CaptureFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
            }
            AOMSettingRow("Quality", indent: true,
                          help: "For the lossy formats. Higher looks better and makes larger files.") {
                AOMRowSlider("Quality", value: $quality, in: 0.3...1.0, step: 0.05, format: AOMRowSlider.percent)
            }
            .aomDependentRows(enabled: format.isLossy)
            AOMSettingRow("Color profile",
                          help: format == .webp ? "WebP output always uses standard sRGB."
                                                : "Preserve wide gamut or convert pixels to standard sRGB.") {
                if format == .webp {
                    Text("sRGB (WebP)").foregroundStyle(AOMColor.textSecondary)
                } else {
                    Picker("Color Profile", selection: $colorProfile) {
                        ForEach(CaptureColorProfile.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    // MARK: - Capture behaviour

    private var captureGroup: some View {
        // Named like Settings › Capture's own group, so the two read alike.
        AOMSection("Screenshots") {
            AOMToggleRow("Show cursor",
                         help: "Include the pointer in screenshots. Recordings have their own Show cursor under Pointer in recordings.",
                         isOn: $showsCursor)
            AOMToggleRow("Window shadow", help: "Keep the drop shadow on window captures.",
                         isOn: $windowShadow)
            AOMToggleRow("Play sound", isOn: $playsSound)
            AOMToggleRow("Hide desktop icons",
                         help: "Temporarily restarts Finder to clear the desktop.", isOn: $hidesDesktopIcons)
            AOMSettingRow("Self-Timer interval", help: "The countdown the Self-Timer capture mode uses.") {
                Picker("Self-Timer Interval", selection: $selfTimerInterval) {
                    // Seconds as "3 s", like Delay every capture below.
                    ForEach(SelfTimerInterval.choices, id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.menu)
            }
            AOMSettingRow("Delay every capture",
                          help: "Wait before every capture, not only Self-Timer ones.") {
                Picker("Delay Every Capture", selection: $selfTimer) {
                    Text("Off").tag(0)
                    Text("3 s").tag(3)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var selectingGroup: some View {
        AOMSection("Selecting") {
            AOMToggleRow("Pixel snap",
                         help: "Align selections to whole pixels to avoid a soft edge.", isOn: $pixelSnap)
            AOMToggleRow("Snap selection to windows",
                         help: "Edges stick to nearby window and screen edges. Hold ⌃ while dragging to place freely.",
                         isOn: $snapsSelection)
            AOMToggleRow("Freeze screen",
                         help: "Hold the desktop still while you draw the selection.", isOn: $freezeScreen)
            AOMSettingRow("Crosshair mode", help: "Guides while selecting an area.") {
                Picker("Crosshair Mode", selection: $crosshairModeRaw) {
                    ForEach(CrosshairMode.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
            }
            AOMToggleRow("Show magnifier",
                         help: "A pixel loupe next to the pointer. Hold ⇧ to show it on demand.", isOn: $showsMagnifier)
        }
    }

    // MARK: - Recording

    private var recordingGroup: some View {
        AOMSection("Screen recording") {
            AOMSettingRow("Recording format",
                          help: "GIF records up to 120 seconds without audio and keeps its MP4 source.") {
                Picker("Recording Format", selection: $recordingOutputFormat) {
                    Text("MP4").tag("mp4")
                    Text("GIF").tag("gif")
                }
                .pickerStyle(.menu)
            }
            Group {
                AOMSettingRow("GIF frame rate", indent: true) {
                    Picker("GIF Frame Rate", selection: $recordingGIFFPS) {
                        ForEach([5, 8, 10, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                AOMSettingRow("GIF size", indent: true, help: "The longest edge of GIF frames.") {
                    Picker("GIF Size", selection: gifSize) {
                        ForEach(CaptureSettings.recordingGIFSizeChoices, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                AOMToggleRow("Loop GIF", help: "Off plays the GIF once.", indent: true, isOn: $gifLoops)
            }
            .aomDependentRows(enabled: recordsGIF)
            AOMSettingRow("Frame rate", help: "Lower rates keep files smaller.") {
                Picker("Frame Rate", selection: $recordingFPS) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.menu)
            }
            AOMSettingRow("Video quality", help: "Sets the H.264 recording bitrate.") {
                Picker("Video Quality", selection: $recordingQuality) {
                    Text("Compact").tag(1)
                    Text("Standard").tag(2)
                    Text("High").tag(3)
                }
                .pickerStyle(.menu)
            }
            AOMToggleRow("Scale Retina videos to 1x",
                         help: "Half the width and height on Retina displays, for smaller files.", isOn: $scalesTo1x)
        }
    }

    private var pointerGroup: some View {
        AOMSection("Pointer in recordings") {
            AOMToggleRow("Show cursor",
                         help: "Show the pointer in recordings. Separate from Show mouse clicks.", isOn: recordingShowsCursor)
            AOMToggleRow("Editable cursor track",
                         help: "Keeps local cursor positions with the recording and hides the video cursor, so the pointer can be edited later.",
                         isOn: $recordingCursorMotion)
            AOMSettingRow("Cursor size", indent: true,
                          help: "Size of the editable pointer drawn from the cursor track.") {
                AOMRowSlider("Cursor Size", value: cursorSizeValue, in: 0.5...3, step: 0.1, format: AOMRowSlider.multiple)
            }
            .aomDependentRows(enabled: recordingCursorMotion && recordingShowsCursor.wrappedValue)
            AOMToggleRow("Highlight cursor",
                         help: "A soft circle around the pointer in the saved video.", isOn: $recordingCursorHighlight)
            Group {
                AOMSettingRow("Highlight color", indent: true) {
                    AOMHexColorWell("Highlight Color", hex: $cursorHighlightColorHex, fallback: AOMCursorHighlight.defaultColor)
                }
                AOMSettingRow("Highlight size", indent: true) {
                    AOMRowSlider("Highlight Size", value: highlightSizeValue, in: AOMCursorHighlight.sizeRange, step: 0.1,
                                 format: AOMRowSlider.multiple)
                }
            }
            .aomDependentRows(enabled: recordingCursorHighlight)
        }
    }

    private var clicksGroup: some View {
        AOMSection("Clicks in recordings") {
            AOMToggleRow("Show mouse clicks",
                         help: "Highlight clicks during screen recordings.", isOn: $recordingClickIndicators)
            Group {
                AOMSettingRow("Click style", indent: true) {
                    Picker("Click Style", selection: clickShape) {
                        ForEach(AOMClickRingStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                AOMSettingRow("Left click color", indent: true) {
                    AOMHexColorWell("Left Click Color", hex: $clickColorHex, fallback: AOMClickStyle.defaultLeftColor)
                }
                AOMSettingRow("Right click color", indent: true,
                              help: "Right clicks and ⌃-clicks.") {
                    AOMHexColorWell("Right Click Color", hex: $rightClickColorHex, fallback: AOMClickStyle.defaultRightColor)
                }
                AOMSettingRow("Click size", indent: true) {
                    AOMRowSlider("Click Size", value: clickSizeValue, in: AOMClickStyle.sizeRange, step: 0.1,
                                 format: AOMRowSlider.multiple)
                }
                AOMSettingRow("Click duration", indent: true, help: "How long each click stays visible.") {
                    AOMRowSlider("Click Duration", value: clickDurationValue, in: AOMClickStyle.durationRange, step: 0.05,
                                 format: AOMRowSlider.seconds)
                }
            }
            .aomDependentRows(enabled: recordingClickIndicators)
        }
    }

    private var cameraAudioGroup: some View {
        AOMSection("Camera & audio") {
            AOMToggleRow("Camera overlay",
                         help: "An editable camera layer; the original and a standalone camera video are saved.",
                         isOn: $recordingCameraOverlay)
            Group {
                AOMSettingRow("Camera", indent: true,
                              help: "A chosen camera that isn't connected falls back to the system default.") {
                    devicePicker("Camera", selection: $recordingCameraID, devices: cameras)
                }
                AOMToggleRow("Camera bubble while recording",
                             help: "A round preview you can drag. It is not baked into the video, and the camera layer starts where you leave it.",
                             indent: true, isOn: $recordingCameraBubble)
            }
            .aomDependentRows(enabled: recordingCameraOverlay)
            AOMSettingRow("Audio source", detail: recordsGIF ? "GIF has no audio" : nil,
                          help: "Record computer sound, microphone, or both.") {
                Picker("Audio Source", selection: $recordingAudioSourceRaw) {
                    ForEach(RecordingAudioSource.allCases) { source in
                        Text(source.displayName).tag(source.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .disabled(recordsGIF)
            }
            if #available(macOS 15, *) {
                AOMSettingRow("Microphone", indent: true,
                              help: "A chosen microphone that isn't connected falls back to the system default.") {
                    devicePicker("Microphone", selection: $recordingMicrophoneID, devices: microphones)
                }
                .aomDependentRows(enabled: recordsMicrophone)
            }
        }
    }

    private var keystrokesGroup: some View {
        AOMSection("Keystrokes") {
            AOMToggleRow("Show keystrokes",
                         help: keystrokeAllKeys ? "Every key except in password fields; editable afterwards."
                                                : "Shortcuts and navigation keys; ordinary typed text is not collected.",
                         isOn: $recordingKeystrokeOverlay)
            Group {
                AOMSettingRow("Keys to show", indent: true) {
                    Picker("Keys to Show", selection: $keystrokeAllKeys) {
                        Text("Shortcuts Only").tag(false)
                        Text("All Keys").tag(true)
                    }
                    .pickerStyle(.menu)
                }
                AOMSettingRow("Shortcut modifiers", indent: true,
                              help: "Keys pressed with these count as shortcuts. ⇧ also shows capitals and symbols typed with Shift.") {
                    modifiersMenu
                }
                // "Keystroke" is the section's title already.
                AOMSettingRow("Position, size and style", indent: true) {
                    HStack(spacing: AOMSpace.x2) {
                        Picker("Keystroke position", selection: $keystrokePosition) {
                            ForEach(KeystrokeOverlayPosition.allCases) { Text($0.displayName).tag($0.rawValue) }
                        }
                        Picker("Keystroke size", selection: $keystrokeSize) {
                            ForEach(KeystrokeOverlaySize.allCases) { Text($0.displayName).tag($0.rawValue) }
                        }
                        Picker("Keystroke style", selection: $keystrokeStyle) {
                            ForEach(AOMKeystrokeStyle.allCases) { Text($0.displayName).tag($0.rawValue) }
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .aomDependentRows(enabled: recordingKeystrokeOverlay)
        }
    }

    private var whileRecordingGroup: some View {
        AOMSection("While recording", footer: recordingFocus ? focusTestResult : nil) {
            AOMToggleRow("Hide desktop icons while recording",
                         help: "Restarts Finder when a recording starts and ends. If AOM quits unexpectedly, the icons come back at the next launch.",
                         isOn: $recordingHidesDesktopIcons)
            AOMToggleRow("Do Not Disturb while recording",
                         help: "Runs your Focus Shortcuts when recording starts and ends. Create two Shortcuts with a single “Set Focus” action, Do Not Disturb On and Off, and enter their names below. macOS offers no other supported way to change Focus.",
                         isOn: $recordingFocus)
            Group {
                focusShortcutRow(title: "Start shortcut", name: $recordingFocusOn)
                focusShortcutRow(title: "End shortcut", name: $recordingFocusOff)
            }
            .aomDependentRows(enabled: recordingFocus)
        }
    }

    private func focusShortcutRow(title: String, name: Binding<String>) -> some View {
        AOMSettingRow(title, indent: true) {
            HStack(spacing: AOMSpace.x2) {
                TextField("Shortcut name", text: name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: AOMRowControlMetrics.fieldWidth)
                    .accessibilityLabel(title)
                // Regular size, like the field beside it and every other row control.
                Button("Test") {
                    focusTestResult = "Running “\(name.wrappedValue)”…"
                    RecordingFocus.run(name.wrappedValue) { ok, message in
                        focusTestResult = ok ? "“\(name.wrappedValue)” ran successfully." : "“\(name.wrappedValue)” failed: \(message)"
                    }
                }
                .disabled(name.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Recording bindings (3.3.3)

    /// Show Cursor for recordings goes through CaptureSettings: while unset,
    /// it reads the pre-3.3.3 rule (Show Cursor or Show Mouse Clicks).
    private var recordingShowsCursor: Binding<Bool> {
        Binding(get: { CaptureSettings.recordingShowsCursor },
                set: { CaptureSettings.recordingShowsCursor = $0 })
    }

    private var cursorSizeValue: Binding<Double> {
        Binding(get: { CaptureSettings.recordingCursorSize },
                set: { CaptureSettings.recordingCursorSize = $0 })
    }

    private var highlightSizeValue: Binding<Double> {
        Binding(get: { CaptureSettings.recordingCursorHighlightStyle.clampedSize },
                set: { cursorHighlightSize = $0 })
    }

    private var clickShape: Binding<AOMClickRingStyle> {
        Binding(get: { AOMClickRingStyle(rawValue: clickStyleRaw) ?? .ring },
                set: { clickStyleRaw = $0.rawValue })
    }

    private var clickSizeValue: Binding<Double> {
        Binding(get: { CaptureSettings.recordingClickStyle.clampedSize },
                set: { clickSize = $0 })
    }

    private var clickDurationValue: Binding<Double> {
        Binding(get: { CaptureSettings.recordingClickStyle.clampedDuration },
                set: { clickDuration = $0 })
    }

    /// GIF size reads through CaptureSettings, which keeps it to the offered sizes.
    private var gifSize: Binding<Int> {
        Binding(get: { CaptureSettings.recordingGIFMaxDimension },
                set: { CaptureSettings.recordingGIFMaxDimension = $0 })
    }

    /// System Default first; a chosen device that is not connected stays
    /// listed, so the menu shows what will happen (the default is used).
    private func devicePicker(_ title: String, selection: Binding<String>, devices: [RecordingInputDevice]) -> some View {
        Picker(title, selection: selection) {
            Text("System Default").tag("")
            if !selection.wrappedValue.isEmpty, !devices.contains(where: { $0.id == selection.wrappedValue }) {
                Text("Disconnected — using default").tag(selection.wrappedValue)
            }
            if !devices.isEmpty { Divider() }
            ForEach(devices) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: AOMSize.tileMin)
    }

    /// ⌘ ⌃ ⌥ ⇧ as menu toggles; the label lists the chosen symbols.
    private var modifiersMenu: some View {
        let chosen = KeystrokeShortcutModifier.allCases.filter(CaptureSettings.recordingKeystrokeModifiers.contains)
        return Menu {
            ForEach(KeystrokeShortcutModifier.allCases) { modifier in
                Toggle(modifier.displayName, isOn: Binding(
                    get: { CaptureSettings.recordingKeystrokeModifiers.contains(modifier) },
                    set: { on in
                        var set = CaptureSettings.recordingKeystrokeModifiers
                        if on { set.insert(modifier) } else { set.remove(modifier) }
                        CaptureSettings.recordingKeystrokeModifiers = set
                    }))
            }
        } label: {
            Text(chosen.isEmpty ? "None" : chosen.map(\.symbol).joined(separator: " "))
        }
        .fixedSize()
        .accessibilityLabel("Shortcut modifiers")
        .accessibilityValue(chosen.isEmpty ? "None" : chosen.map { $0.rawValue.capitalized }.joined(separator: ", "))
    }

    // MARK: - After capture

    private var afterCaptureGroup: some View {
        AOMSection("After capture") {
            AOMSettingRow("Action", help: "What happens the moment a capture completes.") {
                Picker("Action", selection: $afterActionRaw) {
                    ForEach(AfterCaptureAction.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
            }
            AOMSettingRow("Save location", detail: (saveDirectory as NSString).abbreviatingWithTildeInPath) {
                Button("Choose…") { chooseDirectory() }
                    .help(saveDirectory)
            }
            AOMSettingRow("History size",
                          help: historyCapacity == 0 ? "Unpinned history is off; pinned captures are kept."
                                                     : "Up to \(historyCapacity) unpinned captures; pins are kept separately.") {
                Picker("History Size", selection: $historyCapacity) {
                    Text("Off").tag(0)
                    Text("20").tag(20)
                    Text("40").tag(40)
                    Text("100").tag(100)
                    Text("250").tag(250)
                    Text("500").tag(500)
                }
                .pickerStyle(.menu)
            }
            AOMSettingRow("Keep unpinned captures",
                          help: "The age and count limits both apply. Pinned captures are kept.") {
                Picker("Keep Unpinned Captures", selection: $historyRetentionDays) {
                    Text("1 Day").tag(1)
                    Text("3 Days").tag(3)
                    Text("7 Days").tag(7)
                    Text("14 Days").tag(14)
                    Text("30 Days").tag(30)
                    Text("Until Capacity Limit").tag(0)
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - File Naming

    private var namingGroup: some View {
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSection("File naming") {
                AOMSettingRow("File name",
                              help: "Leave blank to use the current Screenshot timestamp format. Tokens: {prefix} {date} {time} {datetime} {kind} {window} {width} {height} {year} {month} {day} {hour} {minute} {second} {millisecond} {weekday} {timezone} {unix}") {
                    TextField("Name template", text: $filenameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: AOMRowControlMetrics.fieldWidth)
                        .accessibilityLabel("Capture filename template")
                }
                AOMToggleRow("Use UTC",
                             help: "Apply UTC instead of your Mac's local time to filename tokens.", isOn: $filenameUTC)
            }
            // The section footer, selectable so a preview can be copied.
            Text("Preview: " + namingPreview)
                .font(AOMFont.caption.monospaced())
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .padding(.horizontal, AOMSpace.x1)
        }
    }

    private var namingPreview: String {
        let result = CaptureNaming.templateName(
            filenameTemplate, date: Date(), kind: "Area",
            windowTitle: nil, width: 1280, height: 720, utc: filenameUTC)
        return result.isEmpty ? "Screenshot yyyy-MM-dd at HH.mm.ss" : result
    }

    // MARK: - Overlay

    private var overlaySize: OverlaySize { OverlaySize(rawValue: overlaySizeRaw) ?? .small }

    private var overlayGroup: some View {
        AOMSection("Quick Access overlay") {
            AOMToggleRow("Show overlay",
                         help: "A floating thumbnail with copy, save, annotate and pin.", isOn: $overlayEnabled)
            if afterAction == .copyToClipboard || afterAction == .saveToDisk {
                AOMToggleRow("Also show after \(afterAction == .copyToClipboard ? "copy" : "save")",
                             help: overlayAfterCopyOrSave
                                ? "The card appears too, after the capture is \(afterAction == .copyToClipboard ? "copied" : "saved")."
                                : "Off: the capture is \(afterAction == .copyToClipboard ? "copied" : "saved") without a card. A card still appears if that fails.",
                             indent: true, isOn: $overlayAfterCopyOrSave)
                    .aomDependentRows(enabled: overlayEnabled)
            }
            AOMSettingRow("Position on screen") {
                Picker("Position on Screen", selection: $overlayCornerRaw) {
                    ForEach(OverlayCorner.pickerOrder.prefix(2)) { Text($0.positionName).tag($0.rawValue) }
                    Divider()
                    ForEach(OverlayCorner.pickerOrder.dropFirst(2)) { Text($0.positionName).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
            }
            AOMToggleRow("Move to active screen",
                         help: "The active screen is the one your pointer is on.", isOn: $overlayActiveDisplay)
            // The small and large glyphs mark the ends; the size's name is
            // the slider's tooltip and VoiceOver value, not a second line.
            AOMSettingRow("Overlay size") {
                Slider(value: Binding(
                    get: { Double(overlaySize.sliderIndex) },
                    set: { overlaySizeRaw = OverlaySize.fromSliderIndex(Int($0.rounded())).rawValue }),
                       in: 0...4, step: 1) {
                    Text("Overlay size")
                } minimumValueLabel: {
                    Image(systemName: "rectangle.fill").imageScale(.small).foregroundStyle(AOMColor.textSecondary)
                } maximumValueLabel: {
                    Image(systemName: "rectangle.fill").imageScale(.large).foregroundStyle(AOMColor.textSecondary)
                }
                .frame(width: AOMRowControlMetrics.sliderWidth)
                .controlSize(.small)
                .help(overlaySize.displayName)
                .accessibilityValue(overlaySize.displayName)
            }
        }
    }

    private var closingGroup: some View {
        AOMSection("Closing & saving") {
            AOMToggleRow("Auto-close",
                         help: "Close each overlay after an interval. Off, overlays stay until you close them.",
                         isOn: autoCloseEnabled)
            Group {
                AOMSettingRow("Action", indent: true,
                              help: "If saving fails, the overlay stays so you can retry.") {
                    Picker("Auto-Close Action", selection: $overlayAutoCloseSave) {
                        Text("Save and Close").tag(true)
                        Text("Close").tag(false)
                    }
                    .pickerStyle(.menu)
                }
                AOMSettingRow("Interval", indent: true) {
                    Picker("Auto-Close Interval", selection: $overlayInterval) {
                        ForEach(OverlayAutoCloseInterval.choices, id: \.self) {
                            Text(OverlayAutoCloseInterval.label($0)).tag($0)
                        }
                        if !OverlayAutoCloseInterval.choices.contains(overlayInterval) {
                            Text(OverlayAutoCloseInterval.label(overlayInterval)).tag(overlayInterval)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .aomDependentRows(enabled: autoCloseEnabled.wrappedValue)
            AOMToggleRow("Close after dragging",
                         help: closeAfterDrag.wrappedValue ? "Hold ⌥ (Option) while dropping to keep the overlay."
                                                           : "Hold ⌥ (Option) while dropping to close the overlay.",
                         isOn: closeAfterDrag)
            AOMSettingRow("Save button behavior",
                          help: asksNameOnSave ? "Press with ⌥ (Option) to use the export location without asking."
                                               : "Press with ⌥ (Option) to choose the destination.") {
                Picker("Save Button Behavior", selection: $asksNameOnSave) {
                    Text("Save to Export Location").tag(false)
                    Text("Ask for Destination").tag(true)
                }
                .pickerStyle(.menu)
            }
        }
    }

    /// CleanShot's "Auto-close: Enable". Maps onto the stored mode; a legacy
    /// "After Dragging" mode is surfaced through Close after dragging instead.
    private var autoCloseEnabled: Binding<Bool> {
        Binding(get: { autoCloseRaw == OverlayAutoClose.afterInterval.rawValue },
                set: { enabled in
                    if autoCloseRaw == OverlayAutoClose.afterDrag.rawValue { overlayCloseAfterDrag = true }
                    autoCloseRaw = (enabled ? OverlayAutoClose.afterInterval : .never).rawValue
                })
    }

    private var closeAfterDrag: Binding<Bool> {
        Binding(get: { overlayCloseAfterDrag || autoCloseRaw == OverlayAutoClose.afterDrag.rawValue },
                set: { value in
                    overlayCloseAfterDrag = value
                    if !value, autoCloseRaw == OverlayAutoClose.afterDrag.rawValue {
                        autoCloseRaw = OverlayAutoClose.never.rawValue
                    }
                })
    }

    // MARK: - Text recognition

    /// TextSniper-style Capture Text settings (TextCaptureSettingsView.swift).
    private var textRecognitionGroup: some View {
        TextCaptureSettingsSection()
    }

    // MARK: - Pinned captures

    private var pinnedGroup: some View {
        AOMSection("Pinned captures") {
            AOMToggleRow("Drop shadow", isOn: $pinnedShadow)
            AOMToggleRow("Rounded corners", isOn: $pinnedCorners)
            AOMToggleRow("Border", isOn: $pinnedBorder)
            AOMSettingRow("Unpin all", help: "Remove every pinned capture from the screen.") {
                Button("Unpin All") { PinnedScreenshotController.shared.unpinAll() }
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = CaptureSettings.saveDirectory
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        CaptureSettings.saveDirectory = url
        saveDirectory = url.path
    }
}
