import SwiftUI
import AppKit

/// The Capture settings tab.
///
/// Split into the same groups CleanShot uses — what is captured, what happens
/// afterwards, how the overlay behaves — because those are the three things a
/// user actually comes here to change.
struct CaptureSettingsView: View {
    @AppStorage("AOMCaptureFormat") private var formatRaw = CaptureFormat.png.rawValue
    @AppStorage("AOMCaptureQuality") private var quality = 0.9
    @AppStorage("AOMCaptureShowsCursor") private var showsCursor = false
    @AppStorage("AOMCaptureRecordingAudioSource") private var recordingAudioSourceRaw = RecordingAudioSource.off.rawValue
    @AppStorage("AOMCaptureRecordingFPS") private var recordingFPS = 30
    @AppStorage("AOMCaptureRecordingQuality") private var recordingQuality = 2
    @AppStorage("AOMCaptureRecordingClickIndicators") private var recordingClickIndicators = false
    @AppStorage("AOMCaptureWindowShadow") private var windowShadow = true
    @AppStorage("AOMCaptureHidesDesktopIcons") private var hidesDesktopIcons = false
    @AppStorage("AOMCapturePlaysSound") private var playsSound = true
    @AppStorage("AOMCaptureSelfTimer") private var selfTimer = 0
    @AppStorage("AOMCapturePixelSnap") private var pixelSnap = true
    @AppStorage("AOMCaptureFreezeScreen") private var freezeScreen = false
    @AppStorage("AOMCaptureAfterAction") private var afterActionRaw = AfterCaptureAction.showOverlay.rawValue
    @AppStorage("AOMCaptureOverlayEnabled") private var overlayEnabled = true
    @AppStorage("AOMCaptureOverlayCorner") private var overlayCornerRaw = OverlayCorner.bottomRight.rawValue
    @AppStorage("AOMCaptureOverlaySize") private var overlaySizeRaw = OverlaySize.medium.rawValue
    @AppStorage("AOMCaptureOverlayAutoClose") private var autoCloseRaw = OverlayAutoClose.never.rawValue
    @AppStorage("AOMCaptureOverlayInterval") private var overlayInterval = 5
    @AppStorage("AOMCaptureOverlayActiveDisplay") private var overlayActiveDisplay = true
    @AppStorage("AOMCaptureOverlayCloseAfterDrag") private var overlayCloseAfterDrag = true
    @AppStorage("AOMCaptureOverlayAsksForName") private var asksNameOnSave = false
    @AppStorage("AOMCaptureHistoryCapacity") private var historyCapacity = 40
    @AppStorage("AOMOCRKeepsLineBreaks") private var ocrKeepsLineBreaks = true
    @AppStorage("AOMPinnedShadow") private var pinnedShadow = true
    @AppStorage("AOMPinnedCorners") private var pinnedCorners = true
    @AppStorage("AOMPinnedBorder") private var pinnedBorder = false

    @State private var saveDirectory: String = CaptureSettings.saveDirectory.path
    @State private var permissionGranted = ScreenCaptureService.hasPermission

    private var format: CaptureFormat { CaptureFormat(rawValue: formatRaw) ?? .png }
    private var afterAction: AfterCaptureAction { AfterCaptureAction(rawValue: afterActionRaw) ?? .showOverlay }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !permissionGranted { permissionGroup }

                formatGroup
                captureGroup
                recordingGroup
                afterCaptureGroup
                overlayGroup
                textRecognitionGroup
                pinnedGroup
            }
            .padding(20)
        }
        .onAppear { permissionGranted = ScreenCaptureService.hasPermission }
    }

    // MARK: - Permission

    private var permissionGroup: some View {
        AppleSettingsGroup("Permission") {
            AppleSettingsRow(
                icon: "exclamationmark.triangle.fill",
                iconColor: .orange,
                title: "Screen Recording Required",
                subtitle: "All of MacOS needs this to capture the screen",
                showDivider: false
            ) {
                Button("Request") {
                    ScreenCaptureService.requestPermission()
                    // The grant is applied by the system, so the state can only be
                    // re-read after the user has answered the prompt.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        permissionGranted = ScreenCaptureService.hasPermission
                    }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Format

    private var formatGroup: some View {
        AppleSettingsGroup("Format") {
            AppleSettingsRow(icon: "doc", iconColor: .blue, title: "Image Format",
                             subtitle: "PNG is lossless; JPEG and HEIC are smaller",
                             showDivider: format.isLossy) {
                Picker("", selection: $formatRaw) {
                    ForEach(CaptureFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 100)
            }
            if format.isLossy {
                AppleSettingsRow(icon: "slider.horizontal.3", iconColor: .indigo, title: "Quality",
                                 subtitle: "Higher is better looking and larger", showDivider: false) {
                    HStack(spacing: 8) {
                        Slider(value: $quality, in: 0.3...1.0, step: 0.05).frame(width: 110).controlSize(.small)
                        Text("\(Int((quality * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Capture behaviour

    private var captureGroup: some View {
        AppleSettingsGroup("Capture") {
            AppleSettingsRow(icon: "cursorarrow", iconColor: .teal, title: "Show Cursor",
                             subtitle: "Include the pointer in the capture", showDivider: true) {
                Toggle("", isOn: $showsCursor).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "macwindow", iconColor: .purple, title: "Window Shadow",
                             subtitle: "Keep the drop shadow on window captures", showDivider: true) {
                Toggle("", isOn: $windowShadow).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "square.grid.2x2", iconColor: .gray, title: "Pixel Snap",
                             subtitle: "Align selections to whole pixels to avoid a soft edge", showDivider: true) {
                Toggle("", isOn: $pixelSnap).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "snowflake", iconColor: .cyan, title: "Freeze Screen",
                             subtitle: "Hold the desktop still while you draw the selection", showDivider: true) {
                Toggle("", isOn: $freezeScreen).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "speaker.wave.2", iconColor: .green, title: "Play Sound",
                             subtitle: "Play the system capture sound", showDivider: true) {
                Toggle("", isOn: $playsSound).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "eye.slash", iconColor: .brown, title: "Hide Desktop Icons",
                             subtitle: "Temporarily restarts Finder to clear the desktop", showDivider: true) {
                Toggle("", isOn: $hidesDesktopIcons).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "timer", iconColor: .orange, title: "Self-Timer",
                             subtitle: selfTimer == 0 ? "No delay" : "\(selfTimer) second delay",
                             showDivider: false) {
                Picker("", selection: $selfTimer) {
                    Text("Off").tag(0)
                    Text("3 s").tag(3)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 90)
            }
        }
    }

    // MARK: - Recording

    private var recordingGroup: some View {
        AppleSettingsGroup("Screen Recording") {
            AppleSettingsRow(icon: "speedometer", iconColor: .indigo,
                             title: "Frame Rate",
                             subtitle: "Lower rates keep files smaller", showDivider: true) {
                Picker("", selection: $recordingFPS) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
            }
            AppleSettingsRow(icon: "slider.horizontal.3", iconColor: .purple,
                             title: "Video Quality",
                             subtitle: "Controls H.264 recording bitrate", showDivider: true) {
                Picker("", selection: $recordingQuality) {
                    Text("Compact").tag(1)
                    Text("Standard").tag(2)
                    Text("High").tag(3)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
            }
            AppleSettingsRow(icon: "cursorarrow.click.2", iconColor: .orange,
                             title: "Show Mouse Clicks",
                             subtitle: "Highlight clicks during screen recordings", showDivider: true) {
                Toggle("", isOn: $recordingClickIndicators)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "speaker.wave.2.fill", iconColor: .blue,
                             title: "Audio Source",
                             subtitle: "Optional AAC audio: computer sound or microphone",
                             showDivider: false) {
                Picker("", selection: $recordingAudioSourceRaw) {
                    ForEach(RecordingAudioSource.allCases) { source in
                        Text(source.displayName).tag(source.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }
        }
    }

    // MARK: - After capture

    private var afterCaptureGroup: some View {
        AppleSettingsGroup("After Capture") {
            AppleSettingsRow(icon: "wand.and.stars", iconColor: .pink, title: "Action",
                             subtitle: "What happens the moment a capture completes", showDivider: true) {
                Picker("", selection: $afterActionRaw) {
                    ForEach(AfterCaptureAction.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 190)
            }
            AppleSettingsRow(icon: "folder", iconColor: .blue, title: "Save Location",
                             subtitle: saveDirectory, showDivider: true) {
                Button("Choose…") { chooseDirectory() }.controlSize(.small)
            }
            AppleSettingsRow(icon: "clock.arrow.circlepath", iconColor: .gray, title: "History Size",
                             subtitle: historyCapacity == 0 ? "History disabled" : "\(historyCapacity) recent captures",
                             showDivider: false) {
                Picker("", selection: $historyCapacity) {
                    Text("Off").tag(0)
                    Text("20").tag(20)
                    Text("40").tag(40)
                    Text("100").tag(100)
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 90)
            }
        }
    }

    // MARK: - Overlay

    private var overlayGroup: some View {
        AppleSettingsGroup("Quick Access Overlay") {
            AppleSettingsRow(icon: "rectangle.on.rectangle", iconColor: .indigo,
                             title: "Show Overlay",
                             subtitle: "Floating thumbnail with copy, annotate and pin",
                             showDivider: true) {
                Toggle("", isOn: $overlayEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "arrow.up.left.and.arrow.down.right", iconColor: .teal,
                             title: "Size", subtitle: nil, showDivider: true) {
                Picker("", selection: $overlaySizeRaw) {
                    ForEach(OverlaySize.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 140)
            }
            AppleSettingsRow(icon: "square.grid.3x3.topleft.filled", iconColor: .purple,
                             title: "Corner", subtitle: nil, showDivider: true) {
                Picker("", selection: $overlayCornerRaw) {
                    ForEach(OverlayCorner.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 140)
            }
            AppleSettingsRow(icon: "display", iconColor: .blue, title: "Follow Active Display",
                             subtitle: "Appear on the screen the pointer is on", showDivider: true) {
                Toggle("", isOn: $overlayActiveDisplay).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "square.and.arrow.down", iconColor: .teal,
                             title: "Save Button Asks for Name",
                             subtitle: "Show Save As instead of instantly saving",
                             showDivider: true) {
                Toggle("", isOn: $asksNameOnSave)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "hand.draw", iconColor: .green,
                             title: "Close After Drop",
                             subtitle: "Hide only after a file is successfully dropped in another app",
                             showDivider: true) {
                Toggle("", isOn: $overlayCloseAfterDrag)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "xmark.circle", iconColor: .red, title: "Auto Close",
                             subtitle: autoCloseRaw == OverlayAutoClose.afterInterval.rawValue
                                ? "Closes \(overlayInterval) seconds after appearing" : nil,
                             showDivider: autoCloseRaw == OverlayAutoClose.afterInterval.rawValue) {
                Picker("", selection: $autoCloseRaw) {
                    ForEach(OverlayAutoClose.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 150)
            }
            if autoCloseRaw == OverlayAutoClose.afterInterval.rawValue {
                AppleSettingsRow(icon: "timer", iconColor: .orange, title: "Delay",
                                 subtitle: nil, showDivider: false) {
                    Picker("", selection: $overlayInterval) {
                        Text("3 s").tag(3)
                        Text("5 s").tag(5)
                        Text("10 s").tag(10)
                        Text("30 s").tag(30)
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 90)
                }
            }
        }
    }

    // MARK: - Text recognition

    private var textRecognitionGroup: some View {
        AppleSettingsGroup("Text Recognition") {
            AppleSettingsRow(icon: "text.viewfinder", iconColor: .green, title: "Keep Line Breaks",
                             subtitle: "Off joins every line into one paragraph",
                             showDivider: false) {
                Toggle("", isOn: $ocrKeepsLineBreaks).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    // MARK: - Pinned captures

    private var pinnedGroup: some View {
        AppleSettingsGroup("Pinned Captures") {
            AppleSettingsRow(icon: "shadow", iconColor: .gray, title: "Drop Shadow",
                             subtitle: nil, showDivider: true) {
                Toggle("", isOn: $pinnedShadow).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "square.dashed", iconColor: .blue, title: "Rounded Corners",
                             subtitle: nil, showDivider: true) {
                Toggle("", isOn: $pinnedCorners).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "rectangle.inset.filled", iconColor: .purple, title: "Border",
                             subtitle: nil, showDivider: true) {
                Toggle("", isOn: $pinnedBorder).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            AppleSettingsRow(icon: "pin.slash", iconColor: .red, title: "Unpin All",
                             subtitle: "Remove every pinned capture from the screen", showDivider: false) {
                Button("Unpin All") { PinnedScreenshotController.shared.unpinAll() }.controlSize(.small)
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
