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
                .toggleStyle(AOMRowSwitchStyle())
                .accessibilityLabel(title)
        }
    }
}

/// Link cards fetch page titles and images only while private web previews
/// are on (clipboard P03), so the row is disabled and says why until then.
struct ClipboardLinkCardsRow: View {
    @ObservedObject private var prefs = ClipboardPreferences.shared

    var body: some View {
        ClipboardPreferenceRow(icon: "link.badge.plus", tint: .teal, title: "Link cards",
                               subtitle: prefs.networkPreviews ? "Show page titles and images on link cards"
                                                               : "Turn on Link previews to show page titles and images",
                               keyPath: \.linkCards)
            .dependentSetting(on: prefs.networkPreviews)
    }
}

// MARK: - Row chrome

struct HubRowShell<Control: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    /// A dependent option, indented under the row it depends on (e.3).
    var indent = false
    /// Clicking the label side performs this (a switch row flips its switch).
    var onLabelTap: (() -> Void)?
    let control: Control

    init(icon: String, tint: Color, title: String, subtitle: String, indent: Bool = false,
         onLabelTap: (() -> Void)? = nil, @ViewBuilder control: () -> Control) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.indent = indent
        self.onLabelTap = onLabelTap
        self.control = control()
    }

    /// e.3, the `AOMSettingRow` geometry, so Settings rows line up with the
    /// Shortcuts and Permissions panes and every other page: a 20 pt
    /// monochrome symbol (the tint stays in the API but colour has no job
    /// here), Body title, an optional Caption line, the control at the
    /// trailing edge; 12 pt insets, 32 pt tall, 44 with a description.
    var body: some View {
        HStack(alignment: .center, spacing: AOMSpace.x2) {
            HStack(alignment: .center, spacing: AOMSpace.x2) {
                Image(systemName: icon)
                    .font(AOMFont.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.row, height: AOMIcon.row)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text(title)
                        .font(AOMFont.body)
                        .foregroundStyle(AOMColor.text)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(AOMFont.caption)
                            .foregroundStyle(AOMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: AOMSpace.x3)
            }
            .contentShape(Rectangle())
            .onTapGesture { onLabelTap?() }
            control
        }
        .padding(.leading, AOMSpace.rowInset + (indent ? AOMSpace.x5 : 0))
        .padding(.trailing, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1)
        .frame(minHeight: subtitle.isEmpty ? AOMSize.rowStandard : AOMSize.rowDetail)
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
                .toggleStyle(AOMRowSwitchStyle())
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
    /// Digits after the point when not a percentage (3.3.3: 2 for 0.25 s and
    /// the 0.02–0.3 hysteresis, which one digit would round).
    var decimals = 1

    @State private var liveValue: Double?

    /// A stepped slider draws one tick per step. Past this many ticks they
    /// read as a dotted rule under the track (HUD background had 31), so those
    /// sliders slide freely and the binding rounds to the same steps.
    private static let maximumTickMarks = 11

    private var drawsTickMarks: Bool {
        step > 0 && (range.upperBound - range.lowerBound) / step + 1 <= Double(Self.maximumTickMarks)
    }

    /// The nearest step from the lower bound, as a stepped slider rounds.
    private func stepped(_ value: Double) -> Double {
        guard step > 0 else { return value }
        let steps = ((value - range.lowerBound) / step).rounded()
        return min(range.upperBound, max(range.lowerBound, range.lowerBound + steps * step))
    }

    private func label(_ value: Double) -> String {
        percent ? AOMRowSlider.percent(value) : String(format: "%.\(decimals)f", value)
    }

    /// The shared row slider (`AOMRowSlider`: 160 pt track, 48 pt value in
    /// Caption digits), so these line up with the Audio and Capture pages.
    var body: some View {
        let value = liveValue ?? aomSettingDouble(key, fallback).wrappedValue
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            AOMRowSlider(title, value: Binding(
                get: { value },
                set: { newValue in
                    let snapped = stepped(newValue)
                    // A free slider reports every pixel; write once per step.
                    guard snapped != (liveValue ?? value) else { return }
                    liveValue = snapped
                    // Persist on the fly so other surfaces observe it too;
                    // the label updates from liveValue without waiting.
                    UserDefaults.standard.set(snapped, forKey: key)
                    NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
                }), in: range, step: drawsTickMarks ? step : nil, format: { label($0) })
                .labelsHidden()
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
        HubRowShell(icon: "power", tint: .blue, title: "Launch at login",
                    subtitle: "", onLabelTap: { enabled.toggle() }) {
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(AOMRowSwitchStyle())
                .accessibilityLabel("Launch at login")
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

/// The accent swatches: the palette-row dot size, the shared selection ring.
struct AccentColorRow: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HubRowShell(icon: "paintpalette.fill", tint: .pink, title: "Highlight color", subtitle: "") {
            HStack(spacing: AOMSpace.x2) {
                ForEach(AccentColorChoice.allCases) { choice in
                    let selected = appState.accentColorChoice == choice
                    Button {
                        appState.accentColorChoice = choice
                        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
                    } label: {
                        Circle()
                            .fill(choice.color)
                            .frame(width: AOMFeatureSize.swatchSmall, height: AOMFeatureSize.swatchSmall)
                            .overlay {
                                Circle().strokeBorder(Color.primary.opacity(selected ? 0.55 : 0.12),
                                                      lineWidth: selected ? AOMFeatureSize.swatchRing : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(choice.rawValue.capitalized)
                    .accessibilityLabel(choice.rawValue.capitalized)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
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
    /// Titles are sentence case like every section title (c.2).
    private static let groups: [String: String] = [
        "launchAtLogin": "Startup", "showMenuBarIcon": "Startup",
        "appearance": "Appearance", "accentColor": "Appearance",
        "hud": "Feedback", "hudOpacity": "Feedback",
        // The window-tiling rows mirror the Window Tiling page and use its
        // row names, in boxes of 8 rows or fewer (e.2).
        "titleBarSnap": "Window tiling", "titleBarSnapGrid": "Window tiling", "titleBarSnapAlmost": "Window tiling",
        "titleBarSnapNativeTiling": "Window tiling", "titleBarSnapHotkeys": "Window tiling",
        "titleBarSnapTooltip": "Window tiling",
        "titleBarSnapHoldCancel": "Title-bar gestures", "titleBarSnapSensitivity": "Title-bar gestures",
        "titleBarSnapMotionPause": "Title-bar gestures", "titleBarSnapTabs": "Title-bar gestures",
        "titleBarSnapSuperAnywhere": "Title-bar gestures",
        "spaceSwipe": "Dock & menu bar", "dockPinchQuit": "Dock & menu bar", "dockGestures": "Dock & menu bar",
        "dockDoublePinch": "Dock & menu bar", "appMenuGestures": "Dock & menu bar",
        "menuBarGestures": "Dock & menu bar", "menuBarScrollToTop": "Dock & menu bar",
        "mcButtons": "Mission Control", "missionControlGestures": "Mission Control",
        "groupByFolder": "Automation list",
        "captureFormat": "Screenshots", "captureQuality": "Screenshots", "showsCursor": "Screenshots",
        "windowShadow": "Screenshots", "playsSound": "Screenshots", "selfTimer": "Screenshots",
        "pixelSnap": "Selecting", "snapSelection": "Selecting", "freezeScreen": "Selecting",
        "crosshair": "Selecting", "magnifier": "Selecting",
        "overlay": "After capture", "ocrLineBreaks": "After capture", "captureDetail": "After capture",
        "historyCapacity": "History", "historyRetention": "History",
        "recordingFPS": "Recording", "recordingFormat": "Recording", "recordingAudio": "Recording",
        "recordingScaleTo1x": "Recording", "recordingHidesDesktopIcons": "Recording",
        "clickIndicators": "Recording overlays", "recordingCursorHighlight": "Recording overlays",
        "cameraOverlay": "Recording overlays", "keystrokeOverlay": "Recording overlays",
        "clipboardCompact": "Shelf", "clipboardCapture": "Shelf", "clipboardPreviews": "Shelf",
        "clipboardLinkCards": "Shelf",
        "clipboardQuickModifier": "Pasting", "clipboardPlainModifier": "Pasting",
        "clipboardStorage": "History",
        "gestures": "Automations", "bttPreset": "Import", "forceTouchStageHysteresis": "Force Touch",
        "hyperKey": "Keyboard & mouse", "keyRemaps": "Keyboard & mouse", "reverseWheel": "Keyboard & mouse",
        "permissions": "Access", "privacySettings": "Access",
        "backups": "Your data", "reset": "Your data", "tutorial": "Help",
    ]

    private static func generalItems() -> [SettingItem] {
        [
            item("launchAtLogin", .general, "Launch at login", "Start automatically at login", ["Start", "로그인", "부팅", "startup"], AnyView(LaunchAtLoginRow())),
            item("showMenuBarIcon", .general, "Menu bar icon", "Keep quick controls in the menu bar", ["메뉴바", "menubar", "아이콘"], AnyView(HubToggleRow(icon: "menubar.rectangle", tint: .purple, title: "Menu bar icon", subtitle: "", key: "showMenuBarIcon", fallback: true))),
            item("appearance", .general, "Appearance", "Match the system or choose a theme", ["테마", "다크", "라이트", "theme"], AnyView(HubChoiceRow(icon: "circle.lefthalf.filled", tint: .indigo, title: "Appearance", subtitle: "", key: "AOMAppearance", fallback: "system", options: [("System", "system"), ("Light", "light"), ("Dark", "dark")], width: 150))),
            item("accentColor", .general, "Highlight color", "Accent for buttons and selections", ["색", "컬러", "accent"], AnyView(AccentColorRow())),
            item("hud", .general, "On-screen HUD", "Show feedback when actions run", ["hud", "오버레이", "알림"], AnyView(HubToggleRow(icon: "rectangle.on.rectangle", tint: .teal, title: "On-screen HUD", subtitle: "Show feedback when actions run", key: "AOMHUDEnabled", fallback: true))),
            item("hudOpacity", .general, "HUD background", "Background opacity", ["투명도", "opacity"], AnyView(HubSliderRow(icon: "circle.dashed", tint: .teal, title: "HUD background", subtitle: "", key: "AOMHUDBackgroundOpacity", fallback: 0.06, range: 0...0.3, step: 0.01, percent: true))),
            // Window tiling: the Window Tiling page's row names. Words of the
            // old titles stay searchable as keywords ("title-bar", "snap").
            item("titleBarSnap", .general, "Swipe to snap", "Swipe two fingers on a title bar to snap the window", ["snap", "swish", "스냅", "창", "트랙패드", "trackpad", "title-bar"], AnyView(HubToggleRow(icon: "hand.draw", tint: .indigo, title: "Swipe to snap", subtitle: "Swipe two fingers on a title bar to snap the window", key: TitleBarWindowSnap.enabledKey, fallback: false))),
            item("titleBarSnapGrid", .general, "Grid", "2 × 2 halves and quarters, 3 × 2 thirds and sixths, or 3 × 3 ninths", ["grid", "thirds", "sixths", "ninths", "3분할", "삼분할", "6분할", "9분할", "격자", "그리드", "swish", "스냅", "title-bar", "snap"], AnyView(HubChoiceRow(icon: "square.grid.3x3", tint: .indigo, title: "Grid", subtitle: "2 × 2 keeps halves and quarters only", key: TitleBarWindowSnap.gridKey, fallback: TitleBarWindowSnap.grid().rawValue, options: SwishSnap.Grid.allCases.map { (label: $0.rawValue.replacingOccurrences(of: "x", with: " × "), value: $0.rawValue) }))),
            item("titleBarSnapAlmost", .general, "Almost maximize", "Swipe up to fill almost the whole screen; swipe up again to maximize", ["almost", "maximize", "최대화", "거의", "여백", "swish", "스냅"], AnyView(HubToggleRow(icon: "arrow.up.left.and.arrow.down.right", tint: .indigo, title: "Almost maximize", subtitle: "Swipe up again to maximize", key: TitleBarWindowSnap.almostKey, fallback: false))),
            item("titleBarSnapNativeTiling", .general, "Native window tiling", "Halves, quarters and Fill use macOS's own tiling where the app offers Window › Move & Resize (macOS 15 or later); other places use AOM's engine", ["native", "tiling", "타일링", "창 타일링", "네이티브", "기본", "macos", "move & resize", "이동 및 크기 조절", "fill", "채우기", "swish", "스냅"], AnyView(HubToggleRow(icon: "rectangle.split.2x2", tint: .indigo, title: "Native window tiling", subtitle: "Use macOS tiling for halves, quarters and Fill", key: TitleBarWindowSnap.nativeTilingKey, fallback: false))),
            item("titleBarSnapHotkeys", .general, "Keyboard shortcuts", "⌃⌥ with the arrows, WASD, IJKL, HJKL or ,AOE moves the front window like a swipe; add ⌘ for the display that way or ⇧ for the 3 × 2 grid", ["hotkey", "keyboard", "shortcut", "단축키", "키보드", "arrows", "화살표", "wasd", "ijkl", "hjkl", ",aoe", "aoe", "dvorak", "드보락", "swish", "스냅", "snap"], AnyView(HubChoiceRow(icon: "keyboard", tint: .indigo, title: "Keyboard shortcuts", subtitle: "⌃⌥ and four keys swipe the front window", key: TitleBarWindowSnap.hotkeysKey, fallback: SwishSnap.HotkeyScheme.off.rawValue, options: [("Off", "off"), ("⌃⌥ Arrows", "arrows"), ("⌃⌥ WASD", "wasd"), ("⌃⌥ IJKL", "ijkl"), ("⌃⌥ HJKL", "hjkl"), ("⌃⌥ ,AOE", SwishSnap.HotkeyScheme.dvorak.rawValue)]))),
            item("titleBarSnapTooltip", .general, "Gesture tooltip", "Name where the window goes beside the pointer while you swipe", ["tooltip", "툴팁", "label", "이름", "pointer", "포인터", "preview", "미리보기", "swish", "스냅"], AnyView(HubToggleRow(icon: "text.bubble", tint: .indigo, title: "Gesture tooltip", subtitle: "Name where the window goes beside the pointer", key: TitleBarWindowSnap.tooltipKey, fallback: true))),
            item("titleBarSnapHoldCancel", .general, "Hold still to cancel", "Seconds of resting fingers that cancel a title-bar, top-bar or Dock gesture (0 = off)", ["cancel", "취소", "hold", "가만히", "swish", "2초"], AnyView(HubSliderRow(icon: "hand.raised", tint: .indigo, title: "Hold still to cancel", subtitle: "Seconds of resting fingers (0 = off)", key: TitleBarWindowSnap.holdCancelKey, fallback: TitleBarWindowSnap.holdCancelDefault, range: 0...3, step: 0.5, percent: false))),
            item("titleBarSnapSensitivity", .general, "Swipe sensitivity", "How little travel starts a title-bar swipe (1 = 3.3.1, higher reacts sooner)", ["sensitivity", "민감도", "반응", "속도", "swish", "스냅", "snap"], AnyView(HubSliderRow(icon: "speedometer", tint: .indigo, title: "Swipe sensitivity", subtitle: "Higher reacts after less travel", key: TitleBarWindowSnap.sensitivityKey, fallback: TitleBarWindowSnap.sensitivityDefault, range: 0.5...2, step: 0.05, percent: false, decimals: 2))),
            item("titleBarSnapMotionPause", .general, "Multi-motion pause", "Rest briefly on a swipe or pinch, then move again to start another gesture without lifting (0 = off)", ["multi", "motion", "pause", "chain", "멀티", "연속", "제스처", "멈춤", "쉬기", "swish", "스냅"], AnyView(HubSliderRow(icon: "pause.circle", tint: .indigo, title: "Multi-motion pause", subtitle: "Seconds of rest before the next gesture (0 = off)", key: TitleBarWindowSnap.motionPauseKey, fallback: TitleBarWindowSnap.motionPauseDefault, range: 0...1, step: 0.25, percent: false, decimals: 2))),
            item("titleBarSnapTabs", .general, "Tab gestures", "Pinch in on a tab to close it; tap and hold a native or Safari tab, then lift, to move it to a new window", ["tab", "tabs", "탭", "탭 닫기", "close tab", "detach", "분리", "새 윈도우", "새 창", "new window", "safari", "finder", "swish", "스냅"], AnyView(HubToggleRow(icon: "square.on.square", tint: .indigo, title: "Tab gestures", subtitle: "Pinch in to close a tab; tap and hold to move it to a new window", key: TitleBarWindowSnap.tabGesturesKey, fallback: true))),
            item("titleBarSnapSuperAnywhere", .general, "Super key: whole window", "Hold the Super key to start window gestures anywhere on a window, not only its title bar", ["super", "modifier", "보조 키", "수정자", "fn", "globe", "지구본", "anywhere", "어디서나", "창 전체", "swish", "스냅"], AnyView(HubToggleRow(icon: "macwindow", tint: .indigo, title: "Super key: whole window", subtitle: "Hold Super to start gestures anywhere on a window", key: TitleBarWindowSnap.superAnywhereKey, fallback: false))),
            item("spaceSwipe", .general, "Top-bar Space swipe", "Two fingers at the top of the screen switch Spaces", ["space", "스페이스", "화면"], AnyView(HubToggleRow(icon: "rectangle.split.2x1", tint: .blue, title: "Top-bar Space swipe", subtitle: "Two fingers at the top of the screen switch Spaces", key: "AOMTopBarSpaceSwipe", fallback: true))),
            item("dockPinchQuit", .general, "Dock pinch to quit", "Pinch in on a Dock icon to quit that app", ["dock", "독", "핀치"], AnyView(HubToggleRow(icon: "dock.rectangle", tint: .pink, title: "Dock pinch to quit", subtitle: "Pinch in on a Dock icon to quit that app", key: "AOMDockPinchQuit", fallback: true))),
            item("dockGestures", .general, "Dock gestures", "Two fingers on a Dock icon: tap and hold to activate, swipe sideways through windows, down to minimize, up to unminimize, double tap to hide, pinch out for a new window", ["dock", "독", "swish", "minimize", "최소화", "hide", "숨기기", "window", "창"], AnyView(HubToggleRow(icon: "dock.arrow.up.rectangle", tint: .pink, title: "Dock gestures", subtitle: "Swipe, tap and hold, double tap or pinch out on a Dock icon", key: TrackpadUtilityGestures.dockGesturesKey, fallback: true))),
            item("dockDoublePinch", .general, "Dock: pinch twice", "Pinch in twice on a Dock icon to minimize all of its windows, out twice to bring them back", ["dock", "독", "pinch", "핀치", "twice", "두 번", "minimize", "최소화", "swish"], AnyView(HubToggleRow(icon: "dock.arrow.down.rectangle", tint: .pink, title: "Dock: pinch twice", subtitle: "Pinch in twice to minimize an app's windows, out twice to bring them back", key: TrackpadUtilityGestures.dockDoublePinchKey, fallback: true))),
            item("appMenuGestures", .general, "Dock gestures on the app's menu", "The Dock gestures also work on the front app's own menu, its name next to the Apple menu", ["dock", "독", "app menu", "앱 메뉴", "menu bar", "메뉴 막대", "메뉴바", "swish"], AnyView(HubToggleRow(icon: "menubar.arrow.up.rectangle", tint: .pink, title: "Dock gestures on the app's menu", subtitle: "Use the Dock gestures on the front app's name in the menu bar", key: TrackpadUtilityGestures.appMenuGesturesKey, fallback: false))),
            item("menuBarGestures", .general, "Menu-bar gestures", "Two fingers at the top of the screen: tap and hold for the window switcher or to switch apps, double tap to unsnap, swipe down to minimize all, up to bring them back, ⌘ swipe to move snapped windows to another display", ["menu bar", "메뉴 막대", "메뉴바", "swish", "minimize", "최소화", "unsnap", "앱 전환", "app switch"], AnyView(HubToggleRow(icon: "menubar.rectangle", tint: .blue, title: "Menu-bar gestures", subtitle: "Tap and hold, double tap, swipe up or down at the top of the screen", key: TrackpadUtilityGestures.menuBarGesturesKey, fallback: true))),
            item("menuBarScrollToTop", .general, "Menu bar: tap to scroll to the top", "A two-finger tap on the empty part of the menu bar scrolls the front window to the top", ["scroll", "스크롤", "top", "맨 위", "위로", "menu bar", "메뉴 막대", "메뉴바", "tap", "탭", "swish"], AnyView(HubToggleRow(icon: "arrow.up.to.line", tint: .blue, title: "Menu bar: tap to scroll to the top", subtitle: "A two-finger tap on the empty menu bar scrolls the front window up", key: TrackpadUtilityGestures.menuBarScrollToTopKey, fallback: false))),
            item("mcButtons", .general, "Mission Control ✕ buttons", "✕ buttons on Mission Control tiles", ["mission", "미션컨트롤", "미션 컨트롤"], AnyView(HubToggleRow(icon: "rectangle.on.rectangle", tint: .teal, title: "Mission Control ✕ buttons", subtitle: "Close windows straight from Mission Control", key: "AOMMissionControlButtons", fallback: true))),
            item("missionControlGestures", .general, "Mission Control gestures", "In Mission Control and App Exposé, pinch in on a window to close it (twice: quit its app), swipe down to minimize it", ["mission", "미션 컨트롤", "미션컨트롤", "exposé", "expose", "앱 엑스포제", "close", "닫기", "minimize", "최소화", "swish"], AnyView(HubToggleRow(icon: "rectangle.3.group", tint: .teal, title: "Mission Control gestures", subtitle: "Pinch in on a window to close it, swipe down to minimize it", key: TrackpadUtilityGestures.missionControlGesturesKey, fallback: false))),
            item("groupByFolder", .general, "Group triggers by folder", "Organize gestures into folders", ["폴더", "그룹", "정렬"], AnyView(HubToggleRow(icon: "folder", tint: .orange, title: "Group triggers by folder", subtitle: "Organize gestures into folders", key: "AOMGroupTriggersByFolder", fallback: false))),
        ]
    }

    private static func captureItems() -> [SettingItem] {
        let formats = CaptureFormat.allCases.map { (label: $0.displayName, value: $0.rawValue) }
        let crosshairs = CrosshairMode.allCases.map { (label: $0.displayName, value: $0.rawValue) }
        let audio = RecordingAudioSource.allCases.map { (label: $0.displayName, value: $0.rawValue) }
        return [
            item("captureFormat", .capture, "Image format", "PNG is lossless; JPEG and HEIC use less space", ["포맷", "png", "jpeg", "heic"], AnyView(HubChoiceRow(icon: "doc", tint: .blue, title: "Image format", subtitle: "PNG is lossless; JPEG and HEIC use less space", key: "AOMCaptureFormat", fallback: CaptureFormat.png.rawValue, options: formats, width: 120))),
            item("captureQuality", .capture, "Image quality", "Higher quality produces larger files", ["품질", "quality", "압축"], AnyView(HubSliderRow(icon: "slider.horizontal.3", tint: .indigo, title: "Image quality", subtitle: "Higher quality produces larger files", key: "AOMCaptureQuality", fallback: 0.9, range: 0.3...1.0, step: 0.05, percent: true))),
            item("showsCursor", .capture, "Show cursor", "Include the pointer in captures", ["커서", "포인터"], AnyView(HubToggleRow(icon: "cursorarrow", tint: .teal, title: "Show cursor", subtitle: "", key: "AOMCaptureShowsCursor", fallback: false))),
            item("windowShadow", .capture, "Window shadow", "Keep window shadows", ["그림자", "shadow"], AnyView(HubToggleRow(icon: "macwindow", tint: .purple, title: "Window shadow", subtitle: "", key: "AOMCaptureWindowShadow", fallback: true))),
            item("pixelSnap", .capture, "Pixel snap", "Align selections to pixels", ["픽셀", "정렬"], AnyView(HubToggleRow(icon: "square.grid.2x2", tint: .gray, title: "Pixel snap", subtitle: "Align selections to pixels", key: "AOMCapturePixelSnap", fallback: true))),
            item("snapSelection", .capture, "Snap selection to windows", "Edges stick to window and screen edges; hold ⌃ to place freely", ["스냅", "창", "가장자리", "snap"], AnyView(HubToggleRow(icon: "rectangle.dashed", tint: .blue, title: "Snap selection to windows", subtitle: "Edges stick to window and screen edges; hold ⌃ to place freely", key: "AOMCaptureSnapSelection", fallback: true))),
            item("freezeScreen", .capture, "Freeze screen", "Freeze the screen while selecting", ["고정", "freeze"], AnyView(HubToggleRow(icon: "snowflake", tint: .cyan, title: "Freeze screen", subtitle: "", key: "AOMCaptureFreezeScreen", fallback: false))),
            item("crosshair", .capture, "Crosshair mode", "Guides for selecting a region", ["십자", "가이드"], AnyView(HubChoiceRow(icon: "plus.viewfinder", tint: .indigo, title: "Crosshair mode", subtitle: "Guides for selecting a region", key: "AOMCaptureCrosshairMode", fallback: CrosshairMode.always.rawValue, options: crosshairs, width: 200))),
            item("magnifier", .capture, "Show magnifier", "Show a magnifier beside the pointer", ["돋보기", "확대"], AnyView(HubToggleRow(icon: "magnifyingglass", tint: .teal, title: "Show magnifier", subtitle: "Hold Shift to show the pixel magnifier", key: "AOMCaptureShowsMagnifier", fallback: false))),
            item("playsSound", .capture, "Play sound", "Play a sound when capturing", ["소리", "사운드"], AnyView(HubToggleRow(icon: "speaker.wave.2", tint: .green, title: "Play sound", subtitle: "", key: "AOMCapturePlaysSound", fallback: true))),
            item("selfTimer", .capture, "Delay every capture", "Delay before each capture", ["타이머", "지연", "딜레이"], AnyView(HubIntChoiceRow(icon: "timer.circle", tint: .orange, title: "Delay every capture", subtitle: "", key: "AOMCaptureSelfTimer", fallback: 0, options: [("Off", 0), ("3 s", 3), ("5 s", 5), ("10 s", 10)], width: 100))),
            item("historyCapacity", .capture, "History capacity", "Maximum number of saved captures", ["히스토리", "개수"], AnyView(HubIntChoiceRow(icon: "tray.full", tint: .brown, title: "History capacity", subtitle: "Maximum number of saved captures", key: "AOMCaptureHistoryCapacity", fallback: 40, options: [("20", 20), ("40", 40), ("100", 100), ("200", 200)], width: 110))),
            item("historyRetention", .capture, "Keep history for", "How long to keep captures", ["보관", "기간"], AnyView(HubIntChoiceRow(icon: "calendar", tint: .brown, title: "Keep history for", subtitle: "", key: "AOMCaptureHistoryRetentionDays", fallback: 30, options: [("7 days", 7), ("30 days", 30), ("90 days", 90), ("Forever", 0)], width: 130))),
            item("recordingFPS", .capture, "Recording frame rate", "Lower frame rates use less space", ["녹화", "fps"], AnyView(HubIntChoiceRow(icon: "speedometer", tint: .indigo, title: "Recording frame rate", subtitle: "Lower frame rates use less space", key: "AOMCaptureRecordingFPS", fallback: 30, options: [("15 fps", 15), ("30 fps", 30), ("60 fps", 60)], width: 110))),
            item("recordingFormat", .capture, "Recording format", "GIF does not include audio", ["녹화", "gif", "mp4"], AnyView(HubChoiceRow(icon: "film", tint: .blue, title: "Recording format", subtitle: "GIF does not include audio", key: "AOMCaptureRecordingOutputFormat", fallback: "mp4", options: [("MP4", "mp4"), ("GIF", "gif")], width: 110))),
            item("recordingAudio", .capture, "Audio source", "System audio, microphone, or both", ["오디오", "마이크", "소리"], AnyView(HubChoiceRow(icon: "speaker.wave.2.fill", tint: .blue, title: "Audio source", subtitle: "", key: "AOMCaptureRecordingAudioSource", fallback: RecordingAudioSource.off.rawValue, options: audio, width: 190))),
            item("recordingScaleTo1x", .capture, "Scale Retina videos to 1x", "Half the width and height on Retina displays; smaller files", ["retina", "레티나", "1x", "scale", "크기", "해상도", "resolution", "파일 크기", "녹화", "recording"], AnyView(HubToggleRow(icon: "arrow.down.right.and.arrow.up.left", tint: .blue, title: "Scale Retina videos to 1x", subtitle: "Half the width and height on Retina displays; smaller files", key: CaptureSettings.RecordingKey.scalesTo1x, fallback: false))),
            item("recordingHidesDesktopIcons", .capture, "Hide desktop icons while recording", "Restarts Finder when a recording starts and ends; if AOM quits unexpectedly, the icons come back at the next launch", ["desktop", "데스크탑", "바탕화면", "icons", "아이콘", "hide", "숨기기", "finder", "녹화", "recording"], AnyView(HubToggleRow(icon: "eye.slash", tint: .gray, title: "Hide desktop icons while recording", subtitle: "Restarts Finder when a recording starts and ends", key: CaptureSettings.RecordingKey.hidesDesktopIcons, fallback: false))),
            item("clickIndicators", .capture, "Show mouse clicks", "Highlight clicks in recordings", ["클릭", "마우스"], AnyView(HubToggleRow(icon: "cursorarrow.click.2", tint: .orange, title: "Show mouse clicks", subtitle: "Highlight clicks in recordings", key: "AOMCaptureRecordingClickIndicators", fallback: false))),
            item("recordingCursorHighlight", .capture, "Highlight cursor", "A soft circle around the pointer in the saved video", ["cursor", "커서", "highlight", "강조", "하이라이트", "pointer", "포인터", "녹화", "recording"], AnyView(HubToggleRow(icon: "cursorarrow.rays", tint: .yellow, title: "Highlight cursor", subtitle: "A soft circle around the pointer in the saved video", key: CaptureSettings.RecordingKey.cursorHighlight, fallback: false))),
            item("cameraOverlay", .capture, "Camera overlay", "Save an editable camera layer", ["카메라", "얼굴"], AnyView(HubToggleRow(icon: "video.fill", tint: .green, title: "Camera overlay", subtitle: "Save an editable camera layer", key: "AOMCaptureRecordingCameraOverlay", fallback: false))),
            item("keystrokeOverlay", .capture, "Show keystrokes", "Display keystrokes in recordings", ["키보드", "단축키", "녹화", "키스트로크"], AnyView(HubToggleRow(icon: "keyboard", tint: .purple, title: "Show keystrokes", subtitle: "", key: "AOMCaptureRecordingKeystrokeOverlay", fallback: false))),
            item("overlay", .capture, "Floating overlay", "Show a preview after capturing", ["오버레이", "미리보기"], AnyView(HubToggleRow(icon: "rectangle.on.rectangle.angled", tint: .purple, title: "Floating overlay", subtitle: "Show a preview after capturing", key: "AOMCaptureOverlayEnabled", fallback: true))),
            item("ocrLineBreaks", .capture, "Keep OCR line breaks", "Preserve line breaks in recognized text", ["ocr", "텍스트"], AnyView(HubToggleRow(icon: "text.viewfinder", tint: .teal, title: "Keep OCR line breaks", subtitle: "", key: "AOMOCRKeepsLineBreaks", fallback: true))),
            item("captureDetail", .capture, "All capture options", "Quick Access, save location, file names, text recognition and shortcuts",
                 ["quick access", "저장", "위치", "파일", "이름", "ocr", "언어", "after capture", "단축키", "오버레이"],
                 AnyView(HubActionRow(icon: "ellipsis.circle", tint: .gray, title: "All capture options",
                                      subtitle: "Quick Access, save location, file names, text recognition and shortcuts") {
                Button("Open…") { NotificationCenter.default.post(name: .aomOpenCaptureOptions, object: nil) }.controlSize(.small)
            })),
        ]
    }

    private static func clipboardItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        let modifiers = ClipboardPreferences.Modifier.allCases.map { (label: $0.symbol + " " + $0.rawValue.capitalized, value: $0.rawValue) }
        return [
            item("clipboardCompact", .clipboard, "Compact shelf", "Use a smaller clipboard shelf", ["컴팩트", "선반", "shelf"], AnyView(ClipboardPreferenceRow(icon: "rectangle.compress.vertical", tint: .blue, title: "Compact shelf", subtitle: "", keyPath: \.compact))),
            item("clipboardCapture", .clipboard, "Visible in screen capture", "Include clipboard windows in screen sharing", ["캡처", "공유", "녹화"], AnyView(ClipboardPreferenceRow(icon: "eye", tint: .purple, title: "Visible in screen capture", subtitle: "Include clipboard windows in screen sharing", keyPath: \.showInScreenCapture))),
            item("clipboardPreviews", .clipboard, "Link previews", "Private web previews on link cards", ["링크", "미리보기"], AnyView(ClipboardPreferenceRow(icon: "link", tint: .teal, title: "Link previews", subtitle: "Private link previews, off by default", keyPath: \.networkPreviews))),
            item("clipboardLinkCards", .clipboard, "Link cards", "Show page titles and images on link cards; needs Link previews", ["link", "링크", "card", "카드", "title", "제목", "image", "이미지", "preview", "미리보기", "web", "웹"], AnyView(ClipboardLinkCardsRow())),
            item("clipboardQuickModifier", .clipboard, "Quick paste modifier", "Modifier for quick paste with keys 1–9", ["붙여넣기", "단축키"], AnyView(HubChoiceRow(icon: "command", tint: .indigo, title: "Quick paste modifier", subtitle: "Modifier for quick paste with keys 1–9", key: "AOMClipboardQuickModifier", fallback: "command", options: modifiers, width: 150))),
            item("clipboardPlainModifier", .clipboard, "Plain text modifier", "Modifier for pasting without formatting", ["텍스트", "서식"], AnyView(HubChoiceRow(icon: "textformat", tint: .gray, title: "Plain text modifier", subtitle: "Modifier for pasting without formatting", key: "AOMClipboardPlainModifier", fallback: "shift", options: modifiers, width: 150))),
            item("clipboardStorage", .clipboard, "Storage & retention", "Retention, storage limits and excluded apps", ["저장", "용량", "보관", "히스토리", "shortcut", "hotkey", "단축키"], AnyView(HubActionRow(icon: "externaldrive", tint: .brown, title: "Storage & retention", subtitle: "Retention, storage limits and excluded apps") {
                Button("Open…") { sheet.wrappedValue = .clipboardDetail }
                    .controlSize(.small)
            })),
        ]
    }

    private static func automationItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        [
            item("gestures", .automation, "Gestures & triggers", "Edit gestures, actions and profiles", ["제스처", "트리거", "동작"], AnyView(HubActionRow(icon: "hand.draw", tint: .orange, title: "Gestures & triggers", subtitle: "Edit gestures, actions and profiles") {
                Button("Edit…") { sheet.wrappedValue = .gestures }.controlSize(.small)
            })),
            item("shortcutRecorder", .shortcuts, "Capture shortcuts", "Record and change the keys for every capture tool", ["단축키", "키보드", "hotkey", "shortcut"], AnyView(HubActionRow(icon: "command", tint: .indigo, title: "Capture shortcuts", subtitle: "Record and change the keys for every capture tool") {
                Button("Show") { NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.shortcuts.rawValue) }.controlSize(.small)
            })),
            item("bttPreset", .automation, "Import BTT preset", "Import BetterTouchTool presets: .bttpreset files or copied JSON triggers", ["btt", "프리셋", "Import", "bttpreset", "bettertouchtool", "가져오기"], AnyView(HubActionRow(icon: "square.and.arrow.down", tint: .green, title: "Import BTT preset", subtitle: "Import BetterTouchTool .bttpreset files or copied JSON triggers") {
                Button("Import…") { NotificationCenter.default.post(name: .aomImportBTTPreset, object: nil) }.controlSize(.small)
            })),
            item("forceTouchStageHysteresis", .automation, "Force Touch stage hysteresis", "How far the pressure must ease off before a Force Touch stage can fire again", ["force touch", "포스 터치", "pressure", "압력", "stage", "단계", "hysteresis", "히스테리시스", "deep press", "강한 클릭"], AnyView(HubSliderRow(icon: "hand.tap", tint: .orange, title: "Force Touch stage hysteresis", subtitle: "How far pressure eases off before a stage fires again", key: PressureStageTracker.hysteresisKey, fallback: PressureStageTracker.defaultHysteresis, range: PressureStageTracker.hysteresisRange, step: 0.01, percent: false, decimals: 2))),
            item("hyperKey", .automation, "Hyper key", "Hold Caps Lock or another key for ⌃⌥⇧⌘", ["hyper", "caps lock", "캡스락", "하이퍼", "modifier"], AnyView(HyperKeyRow())),
            item("keyRemaps", .automation, "Remap keys", "Turn one key into another", ["remap", "리맵", "키 변경", "karabiner", "키보드"], AnyView(KeyRemapRow())),
            item("reverseWheel", .automation, "Reverse mouse wheel", "Flip a wheel mouse, keep the trackpad natural", ["scroll", "스크롤", "휠", "마우스", "reverse", "natural"], AnyView(ReverseWheelRow())),
        ]
    }

    private static func permissionItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        [
            item("permissions", .permissions, "Permission dashboard", "Accessibility, Screen Recording and Input Monitoring", ["권한", "개인정보", "접근성"], AnyView(HubActionRow(icon: "checkmark.shield", tint: .green, title: "Permission dashboard", subtitle: "Accessibility, Screen Recording and Input Monitoring") {
                PermissionSummaryBadge()
                Button("Show") { NotificationCenter.default.post(name: .aomShowSettingsCategory, object: SettingsCategory.permissions.rawValue) }.controlSize(.small)
            })),
            item("privacySettings", .permissions, "Open System Settings", "Open macOS privacy settings", ["시스템 설정", "개인정보"], AnyView(HubActionRow(icon: "gearshape.2", tint: .gray, title: "Open System Settings", subtitle: "Privacy & Security") {
                Button("Open…") {
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
                Button("Manage…") { sheet.wrappedValue = .backups }.controlSize(.small)
            })),
            item("tutorial", .data, "Onboarding Tour", "Show the introduction again", ["튜토리얼", "안내", "온보딩"], AnyView(HubActionRow(icon: "sparkles", tint: .pink, title: "Onboarding Tour", subtitle: "Show the introduction again") {
                Button("Start") { NotificationCenter.default.post(name: .aomRestartTutorial, object: nil) }.controlSize(.small)
            })),
            item("reset", .data, "Reset Preferences", "Restore default preferences", ["Reset", "리셋"], AnyView(HubActionRow(icon: "arrow.counterclockwise", tint: .red, title: "Reset Preferences", subtitle: "Restore default preferences; keep automations and data") {
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
                            .font(AOMFont.caption.weight(.semibold))
                            .foregroundStyle(onAccent ? Color.white : AOMTheme.warning)
                            .help("\(AOMPermission.required.count - granted) permission(s) need attention")
                            .accessibilityLabel("Permissions need attention")
                    }
                } else {
                    // A text style rather than a fixed 10.5 pt, so it stays
                    // readable and follows the system text size.
                    Label(complete ? "All allowed" : "\(granted) of \(AOMPermission.required.count) allowed",
                          systemImage: complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(AOMFont.badge)
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
                    HStack(spacing: AOMSpace.x2) {
                        // The shared badge (hue, white 12 pt glyph, control
                        // radius) at row-icon size, as System Settings draws it.
                        Label { Text(cat.title) } icon: {
                            AOMModuleBadge(symbol: cat.symbol, hue: cat.tint, size: AOMIcon.row)
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
        .frame(minWidth: SettingsHubMetrics.windowMinWidth, idealWidth: SettingsHubMetrics.windowIdealWidth,
               maxWidth: .infinity, minHeight: SettingsHubMetrics.windowMinHeight,
               idealHeight: SettingsHubMetrics.windowIdealHeight, maxHeight: .infinity)
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
                .frame(minWidth: AOMSize.readableWidth, idealWidth: AOMSize.readableWidth, maxWidth: .infinity,
                       minHeight: SettingsHubMetrics.sheetMinHeight, idealHeight: SettingsHubMetrics.sheetIdealHeight,
                       maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isSearching && category.isDashboard {
            // The panes bring their own 16 pt margins and column, like the rest.
            Group {
                switch category {
                case .shortcuts: ShortcutsSettingsView(showsBanner: false)
                default: PermissionsSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if visibleSections.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AOMSpace.sectionGap) {
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
                // One leading-aligned column, as the Shortcuts and Permissions
                // panes, so switching panes never moves the cards.
                .frame(maxWidth: SettingsHubMetrics.column, alignment: .leading)
                .padding(.horizontal, AOMSpace.pageMargin)
                .padding(.top, AOMSpace.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                footer
                    .frame(maxWidth: SettingsHubMetrics.column, alignment: .leading)
                    .padding(.horizontal, AOMSpace.pageMargin)
                    .padding(.bottom, AOMSpace.x6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            // Isolated previews only: `--aom-preview-scroll-bottom` or
            // `--aom-preview-scroll-fraction` open a long pane part-way down.
            .defaultScrollAnchor(PreviewScrollAnchor.current)
            .id(isSearching ? "search" : category.id)
        }
    }

    /// e.2: the title above the card in the Section style every main-window
    /// page uses, the rows inside with dividers inset to the title text.
    private func groupView(_ title: String?, rows: [SettingItem]) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            if let title {
                AOMSectionTitle(title)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    row.content
                    if index < rows.count - 1 {
                        // Inset to the title text, as `AOMSettingRow` draws it.
                        AOMDivider().padding(.leading, AOMSpace.rowSymbolInset)
                    }
                }
            }
            .aomCard(padding: 0, elevated: false)
        }
    }

    private var footer: some View {
        Label("Changes are applied and saved automatically.", systemImage: "checkmark.circle")
            .font(AOMFont.caption)
            .foregroundStyle(AOMColor.textSecondary)
            .padding(.leading, AOMSpace.x1)
            .padding(.top, AOMSpace.x4)
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
        // `.bttpreset` files as well as copied BTT trigger JSON
        // (BTTPresetImport.openPanelContentTypes), then the reviewed import.
        appState.presentBTTPresetImportPanel()
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

    /// Settings › Data › Reset Preferences (3.3.3, N333-07): every preference
    /// `PreferenceResetRegistry` names, not nine fixed keys; the alert says
    /// what is kept before anything changes. The title-bar snap and the Dock
    /// and menu-bar gestures read their settings when they act, and the
    /// change notice refreshes the rest that listens; the parts that read
    /// their settings at launch need a reopen, as after a restore.
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset Preferences?"
        alert.informativeText = "Every preference goes back to its default: general, gestures (title bar, Dock and menu bar), "
            + "capture and recording, clipboard, audio and shortcuts.\n\n"
            + "Kept: automations and presets; clipboard history, pinboards and the apps it ignores; captures, "
            + "recordings and how long their history keeps them; saved window layouts, floating menus, key remaps, "
            + "EQ curves and annotation styles; access granted to AI tools; backups; and whether AOM is paused."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = PreferenceResetRegistry.reset(.standard)
        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
        appState.presetOperationReporter("Preferences Reset", removed.isEmpty
            ? "Every preference was already at its default."
            : "\(removed.count) preference\(removed.count == 1 ? "" : "s") went back to the default. "
                + "Quit and reopen All of MacOS so every part uses the defaults.", .actionNeeded)
    }
}

struct SettingsSectionGroup: Identifiable {
    let category: SettingsCategory
    let items: [SettingItem]
    var id: String { category.id }
}

/// Settings window sizes the shared scale does not name.
private enum SettingsHubMetrics {
    /// The readable column every pane uses (the Shortcuts and Permissions
    /// panes compute the same width).
    static let column = AOMSize.readableWidth - AOMSpace.pageMargin * 2
    static let windowMinWidth: CGFloat = 780
    static let windowIdealWidth: CGFloat = 920
    static let windowMinHeight: CGFloat = 560
    static let windowIdealHeight: CGFloat = 700
    static let sheetMinHeight: CGFloat = 560
    static let sheetIdealHeight: CGFloat = 620
}

struct SettingsSheetHost: View {
    let sheet: AdvancedSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheet.title).font(AOMFont.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AOMSpace.x4)
            .padding(.vertical, AOMSpace.x3)
            AOMDivider()
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
