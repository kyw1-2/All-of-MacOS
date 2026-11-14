import SwiftUI

/// The Screen Ruler on the Capture page: Measure Now with its shortcut, then
/// the measuring options. Every value is the setting the next session reads.
struct ScreenRulerSection: View {
    @ObservedObject private var shortcuts = CaptureShortcuts.shared
    @AppStorage(ScreenRulerSettings.unitKey) private var unitRaw = ScreenRulerUnit.points.rawValue
    @AppStorage(ScreenRulerSettings.showsBothUnitsKey) private var showsBothUnits = false
    @AppStorage(ScreenRulerSettings.copyFormatKey) private var copyFormatRaw = ScreenRulerCopyFormat.times.rawValue
    @AppStorage(ScreenRulerSettings.toleranceKey) private var tolerance = ScreenRulerSettings.defaultTolerance
    @AppStorage(ScreenRulerSettings.snapsAreaKey) private var snapsArea = true
    @AppStorage(ScreenRulerSettings.guideColorKey) private var guideColorHex: String?
    @AppStorage(ScreenRulerSettings.showsColorKey) private var showsColor = false
    @AppStorage(ScreenRulerSettings.hidesCursorKey) private var hidesCursor = false
    @State private var permissionGranted: Bool
    @Environment(\.openSettings) private var openSettings
    /// Fixed by the visual review; nil reads the real permission.
    private let permissionOverride: Bool?

    init(permissionOverride: Bool? = nil) {
        self.permissionOverride = permissionOverride
        _permissionGranted = State(initialValue: permissionOverride ?? AOMPermissionCache.screenRecordingGranted)
    }

    private var shortcut: KeyboardShortcut? { shortcuts.shortcut(for: .measureScreen) }
    private var copyFormat: ScreenRulerCopyFormat { ScreenRulerCopyFormat(rawValue: copyFormatRaw) ?? .times }

    /// Two cards side by side where the page is wide enough (two related
    /// sections, design-340 b.2), one above the other otherwise. The ideal
    /// width is pinned so the choice depends on the page, not on text length.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: AOMSpace.sectionGap) {
                rulerSection.frame(minWidth: Self.columnMinimum, idealWidth: Self.columnMinimum, maxWidth: .infinity)
                measuringSection.frame(minWidth: Self.columnMinimum, idealWidth: Self.columnMinimum, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
                rulerSection
                measuringSection
            }
        }
        .onAppear(perform: refreshPermission)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermission()
        }
    }

    private func refreshPermission() {
        permissionGranted = permissionOverride ?? AOMPermissionCache.screenRecordingGranted
    }

    /// Each card's width when the two sit side by side (wider pages give them more).
    private static let columnMinimum: CGFloat = AOMSize.editorMinimum + AOMSpace.x5

    private var rulerSection: some View {
        AOMSection("Screen ruler", help: Self.help,
                   footer: "⇧ keeps a measurement · ⌘C copies it · Space switches pt and px · arrow keys move one pixel · Esc or right-click ends") {
            if !permissionGranted {
                AOMNotice(.warning, "Screen Recording is off",
                          detail: "The ruler reads the screen to find edges.") {
                    Button("Open System Settings…") {
                        if !ScreenCaptureService.requestPermission() {
                            _ = AOMPermission.screenRecording.openSettings()
                        }
                    }
                }
                .padding(AOMSpace.x3)
            }
            AOMSettingRow("Measure screen", detail: "Freeze every display and measure on it", symbol: "ruler") {
                Button("Measure Now") { ScreenRulerModule.measure() }
                    .help(shortcut.map { "Measure the screen (\($0.displayString))" } ?? "Measure the screen")
            }
            AOMSettingRow("Shortcut", detail: "Change it in Settings › Shortcuts") {
                HStack(spacing: AOMSpace.x2) {
                    if let shortcut {
                        AOMShortcutKeys(shortcut: shortcut)
                    } else {
                        Text("None")
                            .font(AOMFont.callout)
                            .foregroundStyle(AOMColor.textSecondary)
                    }
                    Button("Change…") { showShortcutSettings() }
                        .accessibilityLabel("Change the Measure Screen shortcut")
                }
            }
            AOMSettingRow("Units", detail: "Space switches them while measuring") {
                Picker("Units", selection: $unitRaw) {
                    ForEach(ScreenRulerUnit.allCases) { unit in
                        Text(unit.title).tag(unit.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            AOMToggleRow("Show pixels with points", detail: "On Retina displays, as 120 pt · 240 px", isOn: $showsBothUnits)
            AOMSettingRow("Copy format", detail: copyFormat == .css ? "⌘C copies CSS sizes, in points"
                                                                    : "⌘C copies \(copyFormat.example)") {
                Picker("Copy format", selection: $copyFormatRaw) {
                    ForEach(ScreenRulerCopyFormat.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var measuringSection: some View {
        AOMSection("Measuring") {
            AOMSettingRow("Edge tolerance", detail: "Color change that counts as an edge",
                          help: "The ruler compares each pixel with the one under the pointer. A higher tolerance looks past gradients, shadows and noise; a lower one finds faint borders.") {
                AOMRowSlider("Edge tolerance", value: $tolerance, in: ScreenRulerSettings.toleranceRange, step: 0.01,
                             format: AOMRowSlider.percent)
            }
            AOMToggleRow("Snap areas to content", detail: "A box shrinks to its content; hold ⌥ to keep it",
                         isOn: $snapsArea)
            AOMSettingRow("Guide color", detail: "Lines and labels; the label text keeps its contrast") {
                AOMHexColorWell("Guide color", hex: $guideColorHex, fallback: ScreenRulerSettings.defaultGuideColor,
                                supportsOpacity: false)
            }
            AOMToggleRow("Show color under pointer", detail: "Its hex value, in sRGB", isOn: $showsColor)
            AOMToggleRow("Hide cursor while measuring", detail: "Only the guides mark the pointer", isOn: $hidesCursor)
        }
    }

    private static let help = "The shortcut freezes every display and measures on it. Move the pointer to see the distance to the nearest edges around it; drag a box to measure an area, which shrinks to the object inside. The numbers are points (what layouts and CSS use) or the display's pixels."

    /// Opens Settings on the Shortcuts pane, where Measure Screen is listed under Productivity.
    private func showShortcutSettings() {
        openSettings()
        // The pane switch reaches the Settings window once it is on screen.
        for delay in [0.0, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.shortcuts.rawValue)
            }
        }
    }
}
