import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, capture, clipboard, automation, shortcuts, permissions, data, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .clipboard: "Clipboard"
        case .automation: "Automation"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .data: "Data"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .capture: "camera.viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .automation: "hand.draw"
        case .shortcuts: "command"
        case .permissions: "checkmark.shield"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    /// The squircle colour behind the category glyph in the sidebar; the
    /// tool categories share their sidebar colour in the main window.
    var tint: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .capture: AOMMainTab.capture.accentColor
        case .clipboard: AOMMainTab.clipboard.accentColor
        case .automation: Color(nsColor: .systemBlue)
        case .shortcuts: Color(nsColor: .systemIndigo)
        case .permissions: Color(nsColor: .systemGreen)
        case .data: Color(nsColor: .systemBrown)
        case .about: Color(nsColor: .systemTeal)
        }
    }

    /// Panes that are a complete view of their own (live status, recorders)
    /// rather than a list of rows; their rows still answer search.
    var isDashboard: Bool { self == .shortcuts || self == .permissions }

    var blurb: String {
        switch self {
        case .general: "Startup, appearance and feedback"
        case .capture: "Screenshot and recording defaults"
        case .clipboard: "History and pasting behavior"
        case .automation: "Gestures, triggers and presets"
        case .shortcuts: "Keyboard shortcuts for every capture tool"
        case .permissions: "What macOS lets AOM do, and how to fix what's missing"
        case .data: "Backups, export and reset"
        case .about: "Version and help"
        }
    }
}

// MARK: - Search

enum SettingsSearch {
    /// Every whitespace-separated token must appear in the row's title,
    /// subtitle or keywords. Pure, so it is unit-tested without a window.
    static func matches(query: String, title: String, subtitle: String, keywords: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        let haystack = ([title, subtitle] + keywords).joined(separator: " ").lowercased()
        return trimmed.split(whereSeparator: { $0 == " " }).allSatisfy { haystack.contains($0) }
    }
}

extension Notification.Name {
    static let aomSettingChanged = Notification.Name("AOMSettingChanged")
}

// MARK: - Item model

struct SettingItem: Identifiable {
    let id: String
    let category: SettingsCategory
    let title: String
    let subtitle: String
    let keywords: [String]
    let content: AnyView
    /// The titled group inside the category ("Screenshots", "Recording").
    var group: String?
}

// MARK: - Bindings that write immediately

func aomSettingBool(_ key: String, _ fallback: Bool) -> Binding<Bool> {
    Binding(
        get: { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback },
        set: { UserDefaults.standard.set($0, forKey: key); NotificationCenter.default.post(name: .aomSettingChanged, object: nil) }
    )
}

func aomSettingString(_ key: String, _ fallback: String) -> Binding<String> {
    Binding(
        get: { UserDefaults.standard.string(forKey: key) ?? fallback },
        set: { UserDefaults.standard.set($0, forKey: key); NotificationCenter.default.post(name: .aomSettingChanged, object: nil) }
    )
}

func aomSettingDouble(_ key: String, _ fallback: Double) -> Binding<Double> {
    Binding(
        get: { UserDefaults.standard.object(forKey: key) as? Double ?? fallback },
        set: { UserDefaults.standard.set($0, forKey: key); NotificationCenter.default.post(name: .aomSettingChanged, object: nil) }
    )
}

func aomSettingInt(_ key: String, _ fallback: Int) -> Binding<Int> {
    Binding(
        get: { UserDefaults.standard.object(forKey: key) as? Int ?? fallback },
        set: { UserDefaults.standard.set($0, forKey: key); NotificationCenter.default.post(name: .aomSettingChanged, object: nil) }
    )
}

struct ClipboardPreferenceRow: View {
    @ObservedObject private var prefs = ClipboardPreferences.shared
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let keyPath: ReferenceWritableKeyPath<ClipboardPreferences, Bool>

    var body: some View {
        let value = Binding(
            get: { prefs[keyPath: keyPath] },
            set: { prefs[keyPath: keyPath] = $0; NotificationCenter.default.post(name: .aomSettingChanged, object: nil) }
        )
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle,
                    onLabelTap: { value.wrappedValue.toggle() }) {
            Toggle("", isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

// MARK: - Row chrome

struct HubRowShell<Control: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    /// Clicking the label side performs this (a switch row flips its switch).
    var onLabelTap: (() -> Void)?
    let control: Control

    init(icon: String, tint: Color, title: String, subtitle: String, onLabelTap: (() -> Void)? = nil,
         @ViewBuilder control: () -> Control) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.onLabelTap = onLabelTap
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: AOMSpace.s) {
            HStack(alignment: .center, spacing: AOMSpace.s) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AOMType.body)
                        .foregroundStyle(AOMTheme.text)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(AOMType.caption)
                            .foregroundStyle(AOMTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: AOMSpace.m)
            }
            .contentShape(Rectangle())
            .onTapGesture { onLabelTap?() }
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

/// Choices with a few short labels read better side by side than behind a
/// pop-up (the CleanShot 5 settings critique): up to four options of up to
/// eight characters become a segmented control.
enum HubChoiceStyle {
    static func segmented(_ labels: [String]) -> Bool {
        labels.count >= 2 && labels.count <= 4 && labels.allSatisfy { $0.count <= 8 }
    }
}

struct HubToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let key: String
    let fallback: Bool

    var body: some View {
        let value = aomSettingBool(key, fallback)
        // The label is part of the control: clicking it flips the switch.
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle,
                    onLabelTap: { value.wrappedValue.toggle() }) {
            Toggle("", isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

struct HubChoiceRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let key: String
    let fallback: String
    let options: [(label: String, value: String)]
    var width: CGFloat = 176

    var body: some View {
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            let picker = Picker("", selection: aomSettingString(key, fallback)) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(title)
            if HubChoiceStyle.segmented(options.map(\.label)) {
                picker.pickerStyle(.segmented).fixedSize()
            } else {
                // Menus size to their content: a fixed width truncates long or
                // localized labels ("Microphone + System Audio").
                picker.pickerStyle(.menu).frame(minWidth: width, alignment: .trailing).fixedSize()
            }
        }
    }
}

struct HubIntChoiceRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let key: String
    let fallback: Int
    let options: [(label: String, value: Int)]
    var width: CGFloat = 130

    var body: some View {
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            let picker = Picker("", selection: aomSettingInt(key, fallback)) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(title)
            if HubChoiceStyle.segmented(options.map(\.label)) {
                picker.pickerStyle(.segmented).fixedSize()
            } else {
                picker.pickerStyle(.menu).frame(minWidth: width, alignment: .trailing).fixedSize()
            }
        }
    }
}

struct HubSliderRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let key: String
    let fallback: Double
    let range: ClosedRange<Double>
    let step: Double
    let percent: Bool

    @State private var liveValue: Double?

    var body: some View {
        let value = liveValue ?? aomSettingDouble(key, fallback).wrappedValue
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { value },
                    set: { newValue in
                        liveValue = newValue
                        // Persist on the fly so other surfaces observe it too;
                        // the label updates from liveValue without waiting.
                        UserDefaults.standard.set(newValue, forKey: key)
                        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
                    }), in: range, step: step)
                    .frame(width: 150)
                    .controlSize(.small)
                Text(percent ? "\(Int((value * 100).rounded()))%" : String(format: "%.1f", value))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

struct HubActionRow<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let actions: Actions

    init(icon: String, tint: Color, title: String, subtitle: String, @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle) { actions }
    }
}

// MARK: - Special rows

struct LaunchAtLoginRow: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        HubRowShell(icon: "power", tint: .blue, title: "Launch at Login",
                    subtitle: "Start All of MacOS when you sign in", onLabelTap: { enabled.toggle() }) {
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: enabled) { _, newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
                    } catch {
                        NSLog("[AOM] Failed to update login item: %@", error.localizedDescription)
                        enabled = SMAppService.mainApp.status == .enabled
                    }
                }
        }
    }
}

struct AccentColorRow: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HubRowShell(icon: "paintpalette.fill", tint: .pink, title: "Highlight Color",
                    subtitle: "Accent for buttons and selections") {
            HStack(spacing: 7) {
                ForEach(AccentColorChoice.allCases) { choice in
                    Button {
                        appState.accentColorChoice = choice
                        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
                    } label: {
                        Circle()
                            .fill(choice.color)
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().strokeBorder(Color.primary.opacity(appState.accentColorChoice == choice ? 0.55 : 0.12), lineWidth: appState.accentColorChoice == choice ? 2 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.rawValue)
                }
            }
        }
    }
}

struct SettingsSearchField: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(onSubmit)
                .onAppear { focused = true }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            // Increase Contrast gets a visible edge; the standard 0.06 rim
            // was nearly invisible on both appearances.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.8)
                                      : (contrast == .increased ? Color(nsColor: .secondaryLabelColor) : Color.primary.opacity(0.12)),
                              lineWidth: focused || contrast == .increased ? 1.5 : 0.5)
        }
    }

    @Environment(\.colorSchemeContrast) private var contrast
}

// MARK: - Catalog

enum AdvancedSheet: String, Identifiable {
    case gestures, shortcuts, permissions, backups, clipboardDetail, captureDetail
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gestures: "Gestures & Triggers"
        case .shortcuts: "Shortcut Recorder"
        case .permissions: "Permissions"
        case .backups: "Backups"
        case .clipboardDetail: "Clipboard Storage"
        case .captureDetail: "Capture Options"
        }
    }
}

enum SettingsCatalog {
    static func items(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        generalItems() + captureItems() + clipboardItems(sheet: sheet)
            + automationItems(sheet: sheet) + permissionItems(sheet: sheet)
            + dataItems(sheet: sheet) + aboutItems()
    }

    private static func item(_ id: String, _ category: SettingsCategory, _ title: String,
                             _ subtitle: String, _ keywords: [String], _ content: AnyView) -> SettingItem {
        SettingItem(id: id, category: category, title: title, subtitle: subtitle, keywords: keywords, content: content,
                    group: groups[id])
    }

    /// Groups inside each category, in display order of first appearance.
    private static let groups: [String: String] = [
        "launchAtLogin": "Startup", "showMenuBarIcon": "Startup",
        "appearance": "Appearance", "accentColor": "Appearance",
        "hud": "Feedback", "hudOpacity": "Feedback",
        "groupByFolder": "Automation List",
        "captureFormat": "Screenshots", "captureQuality": "Screenshots", "showsCursor": "Screenshots",
        "windowShadow": "Screenshots", "playsSound": "Screenshots", "selfTimer": "Screenshots",
        "pixelSnap": "Selecting", "snapSelection": "Selecting", "freezeScreen": "Selecting",
        "crosshair": "Selecting", "magnifier": "Selecting",
        "overlay": "After Capture", "ocrLineBreaks": "After Capture", "captureDetail": "After Capture",
        "historyCapacity": "History", "historyRetention": "History",
        "recordingFPS": "Recording", "recordingFormat": "Recording", "recordingAudio": "Recording",
        "clickIndicators": "Recording", "cameraOverlay": "Recording", "keystrokeOverlay": "Recording",
        "clipboardCompact": "Shelf", "clipboardCapture": "Shelf", "clipboardPreviews": "Shelf",
        "clipboardQuickModifier": "Pasting", "clipboardPlainModifier": "Pasting",
        "clipboardStorage": "History",
        "gestures": "Automations", "bttPreset": "Import",
        "hyperKey": "Keyboard & Mouse", "keyRemaps": "Keyboard & Mouse", "reverseWheel": "Keyboard & Mouse",
        "permissions": "Access", "privacySettings": "Access",
        "backups": "Your Data", "reset": "Your Data", "tutorial": "Help",
    ]

    private static func generalItems() -> [SettingItem] {
        [
            item("launchAtLogin", .general, "Launch at Login", "Start automatically at login", ["Start", "로그인", "부팅", "startup"], AnyView(LaunchAtLoginRow())),
            item("showMenuBarIcon", .general, "Menu Bar Icon", "Keep quick controls in the menu bar", ["메뉴바", "menubar", "아이콘"], AnyView(HubToggleRow(icon: "menubar.rectangle", tint: .purple, title: "Menu Bar Icon", subtitle: "Keep quick controls in the menu bar", key: "showMenuBarIcon", fallback: true))),
            item("appearance", .general, "Appearance", "Match the system or choose a theme", ["테마", "다크", "라이트", "theme"], AnyView(HubChoiceRow(icon: "circle.lefthalf.filled", tint: .indigo, title: "Appearance", subtitle: "Match the system or choose a theme", key: "AOMAppearance", fallback: "system", options: [("System", "system"), ("Light", "light"), ("Dark", "dark")], width: 150))),
            item("accentColor", .general, "Highlight Color", "Accent for buttons and selections", ["색", "컬러", "accent"], AnyView(AccentColorRow())),
            item("hud", .general, "On-screen HUD", "Show feedback when actions run", ["hud", "오버레이", "알림"], AnyView(HubToggleRow(icon: "rectangle.on.rectangle", tint: .teal, title: "On-screen HUD", subtitle: "Show feedback when actions run", key: "AOMHUDEnabled", fallback: true))),
            item("hudOpacity", .general, "HUD Background", "Background opacity", ["투명도", "opacity"], AnyView(HubSliderRow(icon: "circle.dashed", tint: .teal, title: "HUD Background", subtitle: "Background opacity", key: "AOMHUDBackgroundOpacity", fallback: 0.06, range: 0...0.3, step: 0.01, percent: true))),
            item("mcButtons", .general, "Mission Control Buttons", "✕ buttons on Mission Control tiles", ["mission", "미션컨트롬"], AnyView(HubToggleRow(icon: "rectangle.on.rectangle", tint: .teal, title: "Mission Control ✕ Buttons", subtitle: "Close windows straight from Mission Control", key: "AOMMissionControlButtons", fallback: true))),
            item("titleBarSnap", .general, "Trackpad Title-Bar Snap", "Swipe two fingers on a title bar to snap the window", ["snap", "swish", "스냅", "창", "트랙패드", "trackpad"], AnyView(HubToggleRow(icon: "hand.draw", tint: .indigo, title: "Trackpad Title-Bar Snap", subtitle: "Swipe two fingers on a title bar to snap the window", key: TitleBarWindowSnap.enabledKey, fallback: false))),
            item("spaceSwipe", .general, "Top-Bar Space Swipe", "Two fingers at the top of the screen switch Spaces", ["space", "스페이스", "화면"], AnyView(HubToggleRow(icon: "rectangle.split.2x1", tint: .blue, title: "Top-Bar Space Swipe", subtitle: "Two fingers at the top of the screen switch Spaces", key: "AOMTopBarSpaceSwipe", fallback: true))),
            item("dockPinchQuit", .general, "Dock Pinch to Quit", "Pinch in on a Dock icon to quit that app", ["dock", "독", "핀치"], AnyView(HubToggleRow(icon: "dock.rectangle", tint: .pink, title: "Dock Pinch to Quit", subtitle: "Pinch in on a Dock icon to quit that app", key: "AOMDockPinchQuit", fallback: true))),
            item("groupByFolder", .general, "Group Triggers by Folder", "Organize gestures into folders", ["폴더", "그룹", "정렬"], AnyView(HubToggleRow(icon: "folder", tint: .orange, title: "Group Triggers by Folder", subtitle: "Organize gestures into folders", key: "AOMGroupTriggersByFolder", fallback: false))),
        ]
    }

    private static func captureItems() -> [SettingItem] {
        let formats = CaptureFormat.allCases.map { (label: $0.displayName, value: $0.rawValue) }
        let crosshairs = CrosshairMode.allCases.map { (label: $0.displayName, value: $0.rawValue) }
        let audio = RecordingAudioSource.allCases.map { (label: $0.displayName, value: $0.rawValue) }
        return [
            item("captureFormat", .capture, "Image Format", "PNG is lossless; JPEG and HEIC use less space", ["포맷", "png", "jpeg", "heic"], AnyView(HubChoiceRow(icon: "doc", tint: .blue, title: "Image Format", subtitle: "PNG is lossless; JPEG and HEIC use less space", key: "AOMCaptureFormat", fallback: CaptureFormat.png.rawValue, options: formats, width: 120))),
            item("captureQuality", .capture, "Image Quality", "Higher quality produces larger files", ["품질", "quality", "압축"], AnyView(HubSliderRow(icon: "slider.horizontal.3", tint: .indigo, title: "Image Quality", subtitle: "Higher quality produces larger files", key: "AOMCaptureQuality", fallback: 0.9, range: 0.3...1.0, step: 0.05, percent: true))),
            item("showsCursor", .capture, "Show Cursor", "Include the pointer in captures", ["커서", "포인터"], AnyView(HubToggleRow(icon: "cursorarrow", tint: .teal, title: "Show Cursor", subtitle: "Include the pointer in captures", key: "AOMCaptureShowsCursor", fallback: false))),
            item("windowShadow", .capture, "Window Shadow", "Keep window shadows", ["그림자", "shadow"], AnyView(HubToggleRow(icon: "macwindow", tint: .purple, title: "Window Shadow", subtitle: "Keep window shadows", key: "AOMCaptureWindowShadow", fallback: true))),
            item("pixelSnap", .capture, "Pixel Snap", "Align selections to pixels", ["픽셀", "정렬"], AnyView(HubToggleRow(icon: "square.grid.2x2", tint: .gray, title: "Pixel Snap", subtitle: "Align selections to pixels", key: "AOMCapturePixelSnap", fallback: true))),
            item("snapSelection", .capture, "Snap Selection to Windows", "Edges stick to window and screen edges; hold ⌃ to place freely", ["스냅", "창", "가장자리", "snap"], AnyView(HubToggleRow(icon: "rectangle.dashed", tint: .blue, title: "Snap Selection to Windows", subtitle: "Edges stick to window and screen edges; hold ⌃ to place freely", key: "AOMCaptureSnapSelection", fallback: true))),
            item("freezeScreen", .capture, "Freeze Screen", "Freeze the screen while selecting", ["고정", "freeze"], AnyView(HubToggleRow(icon: "snowflake", tint: .cyan, title: "Freeze Screen", subtitle: "Freeze the screen while selecting", key: "AOMCaptureFreezeScreen", fallback: false))),
            item("crosshair", .capture, "Crosshair Mode", "Guides for selecting a region", ["십자", "가이드"], AnyView(HubChoiceRow(icon: "plus.viewfinder", tint: .indigo, title: "Crosshair Mode", subtitle: "Guides for selecting a region", key: "AOMCaptureCrosshairMode", fallback: CrosshairMode.always.rawValue, options: crosshairs, width: 200))),
            item("magnifier", .capture, "Show Magnifier", "Show a magnifier beside the pointer", ["돋보기", "확대"], AnyView(HubToggleRow(icon: "magnifyingglass", tint: .teal, title: "Show Magnifier", subtitle: "Hold Shift to show the pixel magnifier", key: "AOMCaptureShowsMagnifier", fallback: false))),
            item("playsSound", .capture, "Play Sound", "Play a sound when capturing", ["소리", "사운드"], AnyView(HubToggleRow(icon: "speaker.wave.2", tint: .green, title: "Play Sound", subtitle: "Play a sound when capturing", key: "AOMCapturePlaysSound", fallback: true))),
            item("selfTimer", .capture, "Delay Every Capture", "Delay before each capture", ["타이머", "지연", "딜레이"], AnyView(HubIntChoiceRow(icon: "timer.circle", tint: .orange, title: "Delay Every Capture", subtitle: "Delay before each capture", key: "AOMCaptureSelfTimer", fallback: 0, options: [("Off", 0), ("3 s", 3), ("5 s", 5), ("10 s", 10)], width: 100))),
            item("historyCapacity", .capture, "History Capacity", "Maximum number of saved captures", ["히스토리", "개수"], AnyView(HubIntChoiceRow(icon: "tray.full", tint: .brown, title: "History Capacity", subtitle: "Maximum number of saved captures", key: "AOMCaptureHistoryCapacity", fallback: 40, options: [("20", 20), ("40", 40), ("100", 100), ("200", 200)], width: 110))),
            item("historyRetention", .capture, "Keep History For", "How long to keep captures", ["보관", "기간"], AnyView(HubIntChoiceRow(icon: "calendar", tint: .brown, title: "Keep History For", subtitle: "How long to keep captures", key: "AOMCaptureHistoryRetentionDays", fallback: 30, options: [("7 days", 7), ("30 days", 30), ("90 days", 90), ("Forever", 0)], width: 130))),
            item("recordingFPS", .capture, "Recording Frame Rate", "Lower frame rates use less space", ["녹화", "fps"], AnyView(HubIntChoiceRow(icon: "speedometer", tint: .indigo, title: "Recording Frame Rate", subtitle: "Lower frame rates use less space", key: "AOMCaptureRecordingFPS", fallback: 30, options: [("15 fps", 15), ("30 fps", 30), ("60 fps", 60)], width: 110))),
            item("recordingFormat", .capture, "Recording Format", "GIF does not include audio", ["녹화", "gif", "mp4"], AnyView(HubChoiceRow(icon: "film", tint: .blue, title: "Recording Format", subtitle: "GIF does not include audio", key: "AOMCaptureRecordingOutputFormat", fallback: "mp4", options: [("MP4", "mp4"), ("GIF", "gif")], width: 110))),
            item("recordingAudio", .capture, "Audio Source", "System audio, microphone, or both", ["오디오", "마이크", "소리"], AnyView(HubChoiceRow(icon: "speaker.wave.2.fill", tint: .blue, title: "Audio Source", subtitle: "System audio, microphone, or both", key: "AOMCaptureRecordingAudioSource", fallback: RecordingAudioSource.off.rawValue, options: audio, width: 190))),
            item("clickIndicators", .capture, "Show Mouse Clicks", "Highlight clicks in recordings", ["클릭", "마우스"], AnyView(HubToggleRow(icon: "cursorarrow.click.2", tint: .orange, title: "Show Mouse Clicks", subtitle: "Highlight clicks in recordings", key: "AOMCaptureRecordingClickIndicators", fallback: false))),
            item("cameraOverlay", .capture, "Camera Overlay", "Save an editable camera layer", ["카메라", "얼굴"], AnyView(HubToggleRow(icon: "video.fill", tint: .green, title: "Camera Overlay", subtitle: "Save an editable camera layer", key: "AOMCaptureRecordingCameraOverlay", fallback: false))),
            item("keystrokeOverlay", .capture, "Show Keystrokes", "Display keystrokes in recordings", ["키보드", "단축키", "녹화", "키스트로크"], AnyView(HubToggleRow(icon: "keyboard", tint: .purple, title: "Show Keystrokes", subtitle: "Display keystrokes in recordings", key: "AOMCaptureRecordingKeystrokeOverlay", fallback: false))),
            item("overlay", .capture, "Floating Overlay", "Show a preview after capturing", ["오버레이", "미리보기"], AnyView(HubToggleRow(icon: "rectangle.on.rectangle.angled", tint: .purple, title: "Floating Overlay", subtitle: "Show a preview after capturing", key: "AOMCaptureOverlayEnabled", fallback: true))),
            item("ocrLineBreaks", .capture, "Keep OCR Line Breaks", "Preserve line breaks in recognized text", ["ocr", "텍스트"], AnyView(HubToggleRow(icon: "text.viewfinder", tint: .teal, title: "Keep OCR Line Breaks", subtitle: "Preserve line breaks in recognized text", key: "AOMOCRKeepsLineBreaks", fallback: true))),
            item("captureDetail", .capture, "All Capture Options", "Quick Access, save location, file names, text recognition and shortcuts",
                 ["quick access", "저장", "위치", "파일", "이름", "ocr", "언어", "after capture", "단축키", "오버레이"],
                 AnyView(HubActionRow(icon: "ellipsis.circle", tint: .gray, title: "All Capture Options",
                                      subtitle: "Quick Access, save location, file names, text recognition and shortcuts") {
                Button("Open…") { NotificationCenter.default.post(name: .aomOpenCaptureOptions, object: nil) }.controlSize(.small)
            })),
        ]
    }

    private static func clipboardItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        let modifiers = ClipboardPreferences.Modifier.allCases.map { (label: $0.symbol + " " + $0.rawValue.capitalized, value: $0.rawValue) }
        return [
            item("clipboardCompact", .clipboard, "Compact Shelf", "Use a smaller clipboard shelf", ["컴팩트", "선반", "shelf"], AnyView(ClipboardPreferenceRow(icon: "rectangle.compress.vertical", tint: .blue, title: "Compact Shelf", subtitle: "Use a smaller clipboard shelf", keyPath: \.compact))),
            item("clipboardCapture", .clipboard, "Visible in Screen Capture", "Include clipboard windows in screen sharing", ["캡처", "공유", "녹화"], AnyView(ClipboardPreferenceRow(icon: "eye", tint: .purple, title: "Visible in Screen Capture", subtitle: "Include clipboard windows in screen sharing", keyPath: \.showInScreenCapture))),
            item("clipboardPreviews", .clipboard, "Link Previews", "Private web previews on link cards", ["링크", "미리보기"], AnyView(ClipboardPreferenceRow(icon: "link", tint: .teal, title: "Link Previews", subtitle: "Private link previews, off by default", keyPath: \.networkPreviews))),
            item("clipboardQuickModifier", .clipboard, "Quick Paste Modifier", "Modifier for quick paste with keys 1–9", ["붙여넣기", "단축키"], AnyView(HubChoiceRow(icon: "command", tint: .indigo, title: "Quick Paste Modifier", subtitle: "Modifier for quick paste with keys 1–9", key: "AOMClipboardQuickModifier", fallback: "command", options: modifiers, width: 150))),
            item("clipboardPlainModifier", .clipboard, "Plain Text Modifier", "Modifier for pasting without formatting", ["텍스트", "서식"], AnyView(HubChoiceRow(icon: "textformat", tint: .gray, title: "Plain Text Modifier", subtitle: "Modifier for pasting without formatting", key: "AOMClipboardPlainModifier", fallback: "shift", options: modifiers, width: 150))),
            item("clipboardStorage", .clipboard, "Storage & Retention", "Retention, storage limits and excluded apps", ["저장", "용량", "보관", "히스토리", "shortcut", "hotkey", "단축키"], AnyView(HubActionRow(icon: "externaldrive", tint: .brown, title: "Storage & Retention", subtitle: "Retention, storage limits and excluded apps") {
                Button("Open") { sheet.wrappedValue = .clipboardDetail }
                    .controlSize(.small)
            })),
        ]
    }

    private static func automationItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        [
            item("gestures", .automation, "Gestures & Triggers", "Edit gestures, actions and profiles", ["제스처", "트리거", "동작"], AnyView(HubActionRow(icon: "hand.draw", tint: .orange, title: "Gestures & Triggers", subtitle: "Edit gestures, actions and profiles") {
                Button("Edit") { sheet.wrappedValue = .gestures }.controlSize(.small)
            })),
            item("shortcutRecorder", .shortcuts, "Capture Shortcuts", "Record and change the keys for every capture tool", ["단축키", "키보드", "hotkey", "shortcut"], AnyView(HubActionRow(icon: "command", tint: .indigo, title: "Capture Shortcuts", subtitle: "Record and change the keys for every capture tool") {
                Button("Show") { NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.shortcuts.rawValue) }.controlSize(.small)
            })),
            item("bttPreset", .automation, "Import BTT Preset", "Import BetterTouchTool JSON presets", ["btt", "프리셋", "Import"], AnyView(HubActionRow(icon: "square.and.arrow.down", tint: .green, title: "Import BTT Preset", subtitle: "Import BetterTouchTool JSON presets") {
                Button("Import") { NotificationCenter.default.post(name: .aomImportBTTPreset, object: nil) }.controlSize(.small)
            })),
            item("hyperKey", .automation, "Hyper Key", "Hold Caps Lock or another key for ⌃⌥⇧⌘", ["hyper", "caps lock", "캡스락", "하이퍼", "modifier"], AnyView(HyperKeyRow())),
            item("keyRemaps", .automation, "Remap Keys", "Turn one key into another", ["remap", "리맵", "키 변경", "karabiner", "키보드"], AnyView(KeyRemapRow())),
            item("reverseWheel", .automation, "Reverse Mouse Wheel", "Flip a wheel mouse, keep the trackpad natural", ["scroll", "스크롤", "휠", "마우스", "reverse", "natural"], AnyView(ReverseWheelRow())),
        ]
    }

    private static func permissionItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        [
            item("permissions", .permissions, "Permission Dashboard", "Accessibility, Screen Recording and Input Monitoring", ["권한", "개인정보", "접근성"], AnyView(HubActionRow(icon: "checkmark.shield", tint: .green, title: "Permission Dashboard", subtitle: "Accessibility, Screen Recording and Input Monitoring") {
                PermissionSummaryBadge()
                Button("Show") { NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.permissions.rawValue) }.controlSize(.small)
            })),
            item("privacySettings", .permissions, "Open System Settings", "Open macOS privacy settings", ["시스템 설정", "개인정보"], AnyView(HubActionRow(icon: "gearshape.2", tint: .gray, title: "Open System Settings", subtitle: "Open macOS privacy settings") {
                Button("Open") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }.controlSize(.small)
            })),
        ]
    }

    private static func dataItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        [
            item("backups", .data, "Backups", "Automatic backups, retention and restore", ["백업", "복원", "스냅샷"], AnyView(HubActionRow(icon: "clock.arrow.circlepath", tint: .orange, title: "Backups", subtitle: "Automatic backups, retention and restore") {
                Button("Manage") { sheet.wrappedValue = .backups }.controlSize(.small)
            })),
            item("tutorial", .data, "Onboarding Tour", "Show the introduction again", ["튜토리얼", "안내", "온보딩"], AnyView(HubActionRow(icon: "sparkles", tint: .pink, title: "Onboarding Tour", subtitle: "Show the introduction again") {
                Button("Start") { NotificationCenter.default.post(name: .aomRestartTutorial, object: nil) }.controlSize(.small)
            })),
            item("reset", .data, "Reset Preferences", "Restore default preferences", ["Reset", "리셋"], AnyView(HubActionRow(icon: "arrow.counterclockwise", tint: .red, title: "Reset Preferences", subtitle: "Restore preferences; keep gestures and actions") {
                Button("Reset", role: .destructive) { NotificationCenter.default.post(name: .aomResetPreferences, object: nil) }.controlSize(.small)
            })),
        ]
    }

    private static func aboutItems() -> [SettingItem] {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
        return [
            item("version", .about, "Version", "\(version) (build \(build))", ["버전", "빌드"], AnyView(HubActionRow(icon: "app.badge", tint: .blue, title: "Version", subtitle: "\(version) (build \(build))") {
                Button("Release Notes") { NotificationCenter.default.post(name: .aomOpenReleaseNotes, object: nil) }.controlSize(.small)
            })),
        ]
    }
}

extension Notification.Name {
    static let aomOpenCaptureOptions = Notification.Name("AOMSettingsOpenCaptureOptions")
    static let aomShowSettingsCategory = Notification.Name("AOMSettingsShowCategory")
    static let aomImportBTTPreset = Notification.Name("AOMSettingsImportBTTPreset")
    static let aomRestartTutorial = Notification.Name("AOMSettingsRestartTutorial")
    static let aomResetPreferences = Notification.Name("AOMSettingsResetPreferences")
    static let aomOpenReleaseNotes = Notification.Name("AOMSettingsOpenReleaseNotes")
}

/// Quiet live summary beside the permission dashboard's Review action, so a
/// search hit shows the state without opening the sheet.
struct PermissionSummaryBadge: View {
    /// The sidebar form: only a warning dot while something is missing.
    var compact = false
    /// Drawn on the selected (accent) sidebar row.
    var onAccent = false
    @State private var granted: Int?

    var body: some View {
        Group {
            if let granted {
                let complete = granted == AOMPermission.required.count
                if compact {
                    if !complete {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(onAccent ? Color.white : AOMTheme.warning)
                            .help("\(AOMPermission.required.count - granted) permission(s) need attention")
                            .accessibilityLabel("Permissions need attention")
                    }
                } else {
                    // A text style rather than a fixed 10.5 pt, so it stays
                    // readable and follows the system text size.
                    Label(complete ? "All granted" : "\(granted) of \(AOMPermission.required.count)",
                          systemImage: complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(AOMType.micro.weight(.medium))
                        .foregroundStyle(complete ? AOMTheme.positive : AOMTheme.warning)
                        .fixedSize()
                }
            }
        }
        // Read-only status queries, deferred off the catalog build; the
        // dashboard sheet owns the periodic re-check.
        .task {
            if granted == nil {
                granted = AOMPermission.required.filter { $0.status == .granted }.count
            }
        }
    }
}

// MARK: - Hub

struct SettingsHubView: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var category: SettingsCategory = .general
    @State private var sheet: AdvancedSheet?
    @State private var savedFlash = false
    @State private var flashTask: Task<Void, Never>?
    @AppStorage("AOMAppearance") private var appearance = "system"

    private var allItems: [SettingItem] {
        SettingsCatalog.items(sheet: $sheet)
    }

    private var filtered: [SettingItem] {
        allItems.filter {
            SettingsSearch.matches(query: query, title: $0.title, subtitle: $0.subtitle, keywords: $0.keywords)
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleSections: [SettingsSectionGroup] {
        let pool = isSearching ? filtered : filtered.filter { $0.category == category }
        return SettingsCategory.allCases.compactMap { cat in
            let rows = pool.filter { $0.category == cat }
            return rows.isEmpty ? nil : SettingsSectionGroup(category: cat, items: rows)
        }
    }

    /// The category's rows in their groups, in catalog order.
    private func groups(_ rows: [SettingItem]) -> [(title: String?, rows: [SettingItem])] {
        var result: [(title: String?, rows: [SettingItem])] = []
        for row in rows {
            if let index = result.firstIndex(where: { $0.title == row.group }) {
                result[index].rows.append(row)
            } else {
                result.append((row.group, [row]))
            }
        }
        return result
    }

    private var sidebarSelection: Binding<SettingsCategory?> {
        Binding(get: { isSearching ? nil : category },
                set: { if let next = $0 { query = ""; category = next } })
    }

    /// System Settings arrangement: a system sidebar (Liquid Glass on
    /// macOS 26) with search at its top, the selected pane titled in the
    /// window toolbar, grouped boxes on the system canvas.
    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(SettingsCategory.allCases) { cat in
                    HStack(spacing: 8) {
                        Label { Text(cat.title) } icon: {
                            Image(systemName: cat.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(cat.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        Spacer(minLength: 0)
                        if cat == .permissions { PermissionSummaryBadge(compact: true, onAccent: false) }
                    }
                    .tag(cat)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: AOMSize.sidebarMin, ideal: AOMSize.sidebarIdeal, max: AOMSize.sidebarMax)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AOMTheme.workspace)
                .navigationTitle(isSearching ? "Search Results" : category.title)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        if savedFlash {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(AOMType.caption.weight(.medium))
                                .foregroundStyle(AOMTheme.positive)
                                .transition(.opacity)
                                .accessibilityLabel("Settings saved")
                        }
                    }
                }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search Settings")
        .frame(minWidth: 780, idealWidth: 920, maxWidth: .infinity, minHeight: 560, idealHeight: 700, maxHeight: .infinity)
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
        .onReceive(NotificationCenter.default.publisher(for: .aomSettingChanged)) { _ in flashSaved() }
        .onReceive(NotificationCenter.default.publisher(for: .aomImportBTTPreset)) { _ in importBTTPreset() }
        .onReceive(NotificationCenter.default.publisher(for: .aomRestartTutorial)) { _ in startTutorial() }
        .onReceive(NotificationCenter.default.publisher(for: .aomResetPreferences)) { _ in confirmReset() }
        .onReceive(NotificationCenter.default.publisher(for: .aomOpenReleaseNotes)) { _ in openReleaseNotes() }
        .onReceive(NotificationCenter.default.publisher(for: .aomOpenCaptureOptions)) { _ in sheet = .captureDetail }
        .onReceive(NotificationCenter.default.publisher(for: .aomShowSettingsCategory)) { note in
            if let raw = note.object as? String, let target = SettingsCategory(rawValue: raw) {
                query = ""
                category = target
            }
        }
        .onAppear {
            // Isolated previews can open one pane for review (`--aom-preview-settings-pane permissions`).
            let args = ProcessInfo.processInfo.arguments
            if PresetManager.isUIPreview, let index = args.firstIndex(of: "--aom-preview-settings-pane"),
               args.indices.contains(index + 1), let pane = SettingsCategory(rawValue: args[index + 1]) {
                category = pane
            }
        }
        .sheet(item: $sheet) { sheet in
            // Resizable from a sensible minimum, so long lists and editors
            // (shortcuts, presets) can use a larger Settings window.
            SettingsSheetHost(sheet: sheet)
                .environmentObject(appState)
                .frame(minWidth: 760, idealWidth: 760, maxWidth: .infinity,
                       minHeight: 560, idealHeight: 620, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isSearching && category.isDashboard {
            Group {
                switch category {
                case .shortcuts: ShortcutsSettingsView(showsBanner: false)
                default: PermissionsSettingsView()
                }
            }
            .padding(.horizontal, AOMSpace.xxs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if visibleSections.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AOMSpace.m) {
                    ForEach(visibleSections) { section in
                        if isSearching {
                            groupView(section.category.title, rows: section.items)
                        } else {
                            ForEach(Array(groups(section.items).enumerated()), id: \.offset) { _, group in
                                groupView(group.title, rows: group.rows)
                            }
                        }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, AOMSpace.l)
                .padding(.top, AOMSpace.xs)
                footer
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, AOMSpace.l)
                    .padding(.bottom, AOMSpace.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .id(isSearching ? "search" : category.id)
        }
    }

    private func groupView(_ title: String?, rows: [SettingItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AOMTheme.textSecondary)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    row.content
                    if index < rows.count - 1 {
                        AOMDivider().padding(.leading, 44)
                    }
                }
            }
            .aomCardStyle(.paper, radius: AOMRadius.card, padding: 0, elevated: false)
        }
    }

    private var footer: some View {
        Label("Changes are applied and saved automatically.", systemImage: "checkmark.circle")
            .font(AOMType.caption)
            .foregroundStyle(AOMTheme.textTertiary)
            .padding(.leading, 4)
            .padding(.top, AOMSpace.xs)
    }

    private func flashSaved() {
        flashTask?.cancel()
        withAnimation(AOMDesign.animation(.easeOut(duration: 0.15))) { savedFlash = true }
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation(AOMDesign.animation(.easeIn(duration: 0.2))) { savedFlash = false } }
        }
    }

    private func importBTTPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a BetterTouchTool JSON preset"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in appState.reviewCompatiblePresetImport(from: url) }
        }
    }

    private func startTutorial() {
        let window = NSApp.keyWindow
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
        window?.close()
        appState.showTutorialRequested = true
    }

    private func openReleaseNotes() {
        if let url = URL(string: "https://github.com/kyw1-2/All-of-MacOS/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset Preferences?"
        alert.informativeText = "Only preferences will be reset. Gestures and actions are preserved."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let keys = ["AOMGlobalEnabled", "AOMAccentColor", "AOMAppearance",
                    "AOMPressDragThreshold", "AOMTipTapMinRestTime",
                    "AOMSuppressMouseDuringDrawing", "showMenuBarIcon", "AOMHasSeenTutorial", "AOMHUDBackgroundOpacity"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        flashSaved()
    }
}

struct SettingsSectionGroup: Identifiable {
    let category: SettingsCategory
    let items: [SettingItem]
    var id: String { category.id }
}

struct SettingsSheetHost: View {
    let sheet: AdvancedSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheet.title).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .gestures: GestureSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .permissions: PermissionsSettingsView()
        case .backups: BackupSettingsView()
        case .clipboardDetail: ClipboardSettingsView()
        case .captureDetail: CaptureSettingsView()
        }
    }
}
