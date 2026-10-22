import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, capture, clipboard, automation, permissions, data, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .clipboard: "Clipboard"
        case .automation: "Automation"
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
        case .permissions: "checkmark.shield"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    var blurb: String {
        switch self {
        case .general: "시작, 테마, 화면 표시"
        case .capture: "스크린샷과 녹화 기본값"
        case .clipboard: "히스토리와 붙여넣기 동작"
        case .automation: "제스처, 단축키, 프리셋"
        case .permissions: "macOS 접근 권한"
        case .data: "백업, 내보내기, 초기화"
        case .about: "버전과 안내"
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
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            Toggle("", isOn: Binding(
                get: { prefs[keyPath: keyPath] },
                set: { prefs[keyPath: keyPath] = $0; NotificationCenter.default.post(name: .aomSettingChanged, object: nil) }
            ))
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
    let control: Control

    init(icon: String, tint: Color, title: String, subtitle: String, @ViewBuilder control: () -> Control) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AOMTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(minHeight: 80)
        .contentShape(Rectangle())
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
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            Toggle("", isOn: aomSettingBool(key, fallback))
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
            Picker("", selection: aomSettingString(key, fallback)) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: width)
            .accessibilityLabel(title)
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
            Picker("", selection: aomSettingInt(key, fallback)) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: width)
            .accessibilityLabel(title)
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

    var body: some View {
        let value = aomSettingDouble(key, fallback)
        HubRowShell(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 150)
                    .controlSize(.small)
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : String(format: "%.1f", value.wrappedValue))
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
                    subtitle: "로그인하면 All of MacOS가 자동으로 시작됩니다") {
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
                    subtitle: "버튼과 선택 상태에 쓰이는 강조 색") {
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("설정 검색 (예: 커서, 백업, 단축키)", text: $text)
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
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(focused ? AOMTheme.blue : .clear, lineWidth: 1.5)
        }
    }
}

// MARK: - Catalog

enum AdvancedSheet: String, Identifiable {
    case gestures, shortcuts, permissions, backups, clipboardDetail
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gestures: "Gestures & Triggers"
        case .shortcuts: "Shortcut Recorder"
        case .permissions: "Permissions"
        case .backups: "Backups"
        case .clipboardDetail: "Clipboard Storage"
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
        SettingItem(id: id, category: category, title: title, subtitle: subtitle, keywords: keywords, content: content)
    }

    private static func generalItems() -> [SettingItem] {
        [
            item("launchAtLogin", .general, "Launch at Login", "로그인 시 자동 시작", ["시작", "로그인", "부팅", "startup"], AnyView(LaunchAtLoginRow())),
            item("showMenuBarIcon", .general, "Menu Bar Icon", "메뉴 막대에 빠른 제어 유지", ["메뉴바", "menubar", "아이콘"], AnyView(HubToggleRow(icon: "menubar.rectangle", tint: .purple, title: "Menu Bar Icon", subtitle: "메뉴 막대에 빠른 제어 유지", key: "showMenuBarIcon", fallback: true))),
            item("appearance", .general, "Appearance", "시스템 설정을 따르거나 직접 선택", ["테마", "다크", "라이트", "theme"], AnyView(HubChoiceRow(icon: "circle.lefthalf.filled", tint: .indigo, title: "Appearance", subtitle: "시스템 설정을 따르거나 직접 선택", key: "AOMAppearance", fallback: "system", options: [("System", "system"), ("Light", "light"), ("Dark", "dark")], width: 150))),
            item("accentColor", .general, "Highlight Color", "버튼과 선택 상태의 강조 색", ["색", "컬러", "accent"], AnyView(AccentColorRow())),
            item("hud", .general, "On-screen HUD", "동작 피드백을 화면에 표시", ["hud", "오버레이", "알림"], AnyView(HubToggleRow(icon: "rectangle.on.rectangle", tint: .teal, title: "On-screen HUD", subtitle: "동작 피드백을 화면에 표시", key: "AOMHUDEnabled", fallback: true))),
            item("hudOpacity", .general, "HUD Background", "HUD 배경 불투명도", ["투명도", "opacity"], AnyView(HubSliderRow(icon: "circle.dashed", tint: .teal, title: "HUD Background", subtitle: "HUD 배경 불투명도", key: "AOMHUDBackgroundOpacity", fallback: 0.06, range: 0...0.3, step: 0.01, percent: true))),
            item("groupByFolder", .general, "Group Triggers by Folder", "제스처 목록을 폴더로 묶기", ["폴더", "그룹", "정렬"], AnyView(HubToggleRow(icon: "folder", tint: .orange, title: "Group Triggers by Folder", subtitle: "제스처 목록을 폴더로 묶기", key: "AOMGroupTriggersByFolder", fallback: false))),
        ]
    }

    private static func captureItems() -> [SettingItem] {
        let formats = CaptureFormat.allCases.map { (label: $0.displayName, value: $0.rawValue) }
        let crosshairs = CrosshairMode.allCases.map { (label: $0.displayName, value: $0.rawValue) }
        let audio = RecordingAudioSource.allCases.map { (label: $0.displayName, value: $0.rawValue) }
        return [
            item("captureFormat", .capture, "Image Format", "PNG는 무손실, JPEG/HEIC는 더 작음", ["포맷", "png", "jpeg", "heic"], AnyView(HubChoiceRow(icon: "doc", tint: .blue, title: "Image Format", subtitle: "PNG는 무손실, JPEG/HEIC는 더 작음", key: "AOMCaptureFormat", fallback: CaptureFormat.png.rawValue, options: formats, width: 120))),
            item("captureQuality", .capture, "Image Quality", "높을수록 선명하고 파일이 커짐", ["품질", "quality", "압축"], AnyView(HubSliderRow(icon: "slider.horizontal.3", tint: .indigo, title: "Image Quality", subtitle: "높을수록 선명하고 파일이 커짐", key: "AOMCaptureQuality", fallback: 0.9, range: 0.3...1.0, step: 0.05, percent: true))),
            item("showsCursor", .capture, "Show Cursor", "캡처에 포인터 포함", ["커서", "포인터"], AnyView(HubToggleRow(icon: "cursorarrow", tint: .teal, title: "Show Cursor", subtitle: "캡처에 포인터 포함", key: "AOMCaptureShowsCursor", fallback: false))),
            item("windowShadow", .capture, "Window Shadow", "창 캡처에 그림자 유지", ["그림자", "shadow"], AnyView(HubToggleRow(icon: "macwindow", tint: .purple, title: "Window Shadow", subtitle: "창 캡처에 그림자 유지", key: "AOMCaptureWindowShadow", fallback: true))),
            item("pixelSnap", .capture, "Pixel Snap", "선택 영역을 픽셀에 정렬", ["픽셀", "정렬"], AnyView(HubToggleRow(icon: "square.grid.2x2", tint: .gray, title: "Pixel Snap", subtitle: "선택 영역을 픽셀에 정렬", key: "AOMCapturePixelSnap", fallback: true))),
            item("freezeScreen", .capture, "Freeze Screen", "선택하는 동안 화면 고정", ["고정", "freeze"], AnyView(HubToggleRow(icon: "snowflake", tint: .cyan, title: "Freeze Screen", subtitle: "선택하는 동안 화면 고정", key: "AOMCaptureFreezeScreen", fallback: false))),
            item("crosshair", .capture, "Crosshair Mode", "영역 선택 가이드", ["십자", "가이드"], AnyView(HubChoiceRow(icon: "plus.viewfinder", tint: .indigo, title: "Crosshair Mode", subtitle: "영역 선택 가이드", key: "AOMCaptureCrosshairMode", fallback: CrosshairMode.always.rawValue, options: crosshairs, width: 200))),
            item("magnifier", .capture, "Show Magnifier", "포인터 옆 픽셀 돋보기", ["돋보기", "확대"], AnyView(HubToggleRow(icon: "magnifyingglass", tint: .teal, title: "Show Magnifier", subtitle: "포인터 옆 픽셀 돋보기 (⇧ 길게 눌러 표시)", key: "AOMCaptureShowsMagnifier", fallback: false))),
            item("playsSound", .capture, "Play Sound", "캡처할 때 시스템 소리 재생", ["소리", "사운드"], AnyView(HubToggleRow(icon: "speaker.wave.2", tint: .green, title: "Play Sound", subtitle: "캡처할 때 시스템 소리 재생", key: "AOMCapturePlaysSound", fallback: true))),
            item("selfTimer", .capture, "Delay Every Capture", "모든 캡처 전 지연", ["타이머", "지연", "딜레이"], AnyView(HubIntChoiceRow(icon: "timer.circle", tint: .orange, title: "Delay Every Capture", subtitle: "모든 캡처 전 지연", key: "AOMCaptureSelfTimer", fallback: 0, options: [("Off", 0), ("3 s", 3), ("5 s", 5), ("10 s", 10)], width: 100))),
            item("historyCapacity", .capture, "History Capacity", "보관할 캡처 개수", ["히스토리", "개수"], AnyView(HubIntChoiceRow(icon: "tray.full", tint: .brown, title: "History Capacity", subtitle: "보관할 캡처 개수", key: "AOMCaptureHistoryCapacity", fallback: 40, options: [("20", 20), ("40", 40), ("100", 100), ("200", 200)], width: 110))),
            item("historyRetention", .capture, "Keep History For", "캡처 보관 기간", ["보관", "기간"], AnyView(HubIntChoiceRow(icon: "calendar", tint: .brown, title: "Keep History For", subtitle: "캡처 보관 기간", key: "AOMCaptureHistoryRetentionDays", fallback: 30, options: [("7 days", 7), ("30 days", 30), ("90 days", 90), ("Forever", 0)], width: 130))),
            item("recordingFPS", .capture, "Recording Frame Rate", "낮을수록 파일이 작음", ["녹화", "fps"], AnyView(HubIntChoiceRow(icon: "speedometer", tint: .indigo, title: "Recording Frame Rate", subtitle: "낮을수록 파일이 작음", key: "AOMCaptureRecordingFPS", fallback: 30, options: [("15 fps", 15), ("30 fps", 30), ("60 fps", 60)], width: 110))),
            item("recordingFormat", .capture, "Recording Format", "GIF는 오디오가 없음", ["녹화", "gif", "mp4"], AnyView(HubChoiceRow(icon: "film", tint: .blue, title: "Recording Format", subtitle: "GIF는 오디오가 없음", key: "AOMCaptureRecordingOutputFormat", fallback: "mp4", options: [("MP4", "mp4"), ("GIF", "gif")], width: 110))),
            item("recordingAudio", .capture, "Audio Source", "컴퓨터 소리, 마이크 또는 둘 다", ["오디오", "마이크", "소리"], AnyView(HubChoiceRow(icon: "speaker.wave.2.fill", tint: .blue, title: "Audio Source", subtitle: "컴퓨터 소리, 마이크 또는 둘 다", key: "AOMCaptureRecordingAudioSource", fallback: RecordingAudioSource.off.rawValue, options: audio, width: 190))),
            item("clickIndicators", .capture, "Show Mouse Clicks", "녹화 중 클릭 강조", ["클릭", "마우스"], AnyView(HubToggleRow(icon: "cursorarrow.click.2", tint: .orange, title: "Show Mouse Clicks", subtitle: "녹화 중 클릭 강조", key: "AOMCaptureRecordingClickIndicators", fallback: false))),
            item("cameraOverlay", .capture, "Camera Overlay", "카메라 레이어를 편집 가능하게 저장", ["카메라", "얼굴"], AnyView(HubToggleRow(icon: "video.fill", tint: .green, title: "Camera Overlay", subtitle: "카메라 레이어를 편집 가능하게 저장", key: "AOMCaptureRecordingCameraOverlay", fallback: false))),
            item("keystrokeOverlay", .capture, "Show Keyboard Shortcuts", "녹화에 단축키 표시", ["키보드", "단축키", "녹화"], AnyView(HubToggleRow(icon: "keyboard", tint: .purple, title: "Show Keyboard Shortcuts", subtitle: "녹화에 단축키 표시", key: "AOMCaptureRecordingKeystrokeOverlay", fallback: false))),
            item("overlay", .capture, "Floating Overlay", "캡처 후 미리보기 패널", ["오버레이", "미리보기"], AnyView(HubToggleRow(icon: "rectangle.on.rectangle.angled", tint: .purple, title: "Floating Overlay", subtitle: "캡처 후 미리보기 패널", key: "AOMCaptureOverlayEnabled", fallback: true))),
            item("ocrLineBreaks", .capture, "Keep OCR Line Breaks", "텍스트 인식 시 줄바꿈 유지", ["ocr", "텍스트"], AnyView(HubToggleRow(icon: "text.viewfinder", tint: .teal, title: "Keep OCR Line Breaks", subtitle: "텍스트 인식 시 줄바꿈 유지", key: "AOMOCRKeepsLineBreaks", fallback: true))),
        ]
    }

    private static func clipboardItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        let modifiers = ClipboardPreferences.Modifier.allCases.map { (label: $0.symbol + " " + $0.rawValue.capitalized, value: $0.rawValue) }
        return [
            item("clipboardCompact", .clipboard, "Compact Shelf", "클립보드 선반을 작게 표시", ["컴팩트", "선반", "shelf"], AnyView(ClipboardPreferenceRow(icon: "rectangle.compress.vertical", tint: .blue, title: "Compact Shelf", subtitle: "클립보드 선반을 작게 표시", keyPath: \.compact))),
            item("clipboardCapture", .clipboard, "Visible in Screen Capture", "화면 공유·녹화에 클립보드 창 포함", ["캡처", "공유", "녹화"], AnyView(ClipboardPreferenceRow(icon: "eye", tint: .purple, title: "Visible in Screen Capture", subtitle: "화면 공유·녹화에 클립보드 창 포함", keyPath: \.showInScreenCapture))),
            item("clipboardPreviews", .clipboard, "Link Previews", "링크 카드의 비공개 웹 미리보기", ["링크", "미리보기"], AnyView(ClipboardPreferenceRow(icon: "link", tint: .teal, title: "Link Previews", subtitle: "링크 카드의 비공개 웹 미리보기 (기본 꺼짐)", keyPath: \.networkPreviews))),
            item("clipboardQuickModifier", .clipboard, "Quick Paste Modifier", "1–9 빠른 붙여넣기 보조키", ["붙여넣기", "단축키"], AnyView(HubChoiceRow(icon: "command", tint: .indigo, title: "Quick Paste Modifier", subtitle: "1–9 빠른 붙여넣기 보조키", key: "AOMClipboardQuickModifier", fallback: "command", options: modifiers, width: 150))),
            item("clipboardPlainModifier", .clipboard, "Plain Text Modifier", "서식 없이 붙여넣는 보조키", ["텍스트", "서식"], AnyView(HubChoiceRow(icon: "textformat", tint: .gray, title: "Plain Text Modifier", subtitle: "서식 없이 붙여넣는 보조키", key: "AOMClipboardPlainModifier", fallback: "shift", options: modifiers, width: 150))),
            item("clipboardStorage", .clipboard, "Storage & Retention", "보관 기간, 용량, 제외 앱 관리", ["저장", "용량", "보관", "히스토리"], AnyView(HubActionRow(icon: "externaldrive", tint: .brown, title: "Storage & Retention", subtitle: "보관 기간, 용량, 제외 앱 관리") {
                Button("열기") { sheet.wrappedValue = .clipboardDetail }
                    .controlSize(.small)
            })),
        ]
    }

    private static func automationItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        [
            item("gestures", .automation, "Gestures & Triggers", "제스처, 액션, 프로필 편집", ["제스처", "트리거", "동작"], AnyView(HubActionRow(icon: "hand.draw", tint: .orange, title: "Gestures & Triggers", subtitle: "제스처, 액션, 프로필 편집") {
                Button("편집") { sheet.wrappedValue = .gestures }.controlSize(.small)
            })),
            item("shortcutRecorder", .automation, "Keyboard Shortcuts", "전역 단축키 기록 및 변경", ["단축키", "키보드"], AnyView(HubActionRow(icon: "command", tint: .indigo, title: "Keyboard Shortcuts", subtitle: "전역 단축키 기록 및 변경") {
                Button("편집") { sheet.wrappedValue = .shortcuts }.controlSize(.small)
            })),
            item("bttPreset", .automation, "Import BTT Preset", "BetterTouchTool JSON 프리셋 가져오기", ["btt", "프리셋", "가져오기"], AnyView(HubActionRow(icon: "square.and.arrow.down", tint: .green, title: "Import BTT Preset", subtitle: "BetterTouchTool JSON 프리셋 가져오기") {
                Button("가져오기") { NotificationCenter.default.post(name: .aomImportBTTPreset, object: nil) }.controlSize(.small)
            })),
        ]
    }

    private static func permissionItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        [
            item("permissions", .permissions, "Permission Dashboard", "손쉬운 사용, 화면 기록, 입력 모니터링 상태", ["권한", "개인정보", "접근성"], AnyView(HubActionRow(icon: "checkmark.shield", tint: .green, title: "Permission Dashboard", subtitle: "손쉬운 사용, 화면 기록, 입력 모니터링 상태") {
                Button("확인") { sheet.wrappedValue = .permissions }.controlSize(.small)
            })),
            item("privacySettings", .permissions, "Open System Settings", "macOS 개인정보 보호 설정 열기", ["시스템 설정", "개인정보"], AnyView(HubActionRow(icon: "gearshape.2", tint: .gray, title: "Open System Settings", subtitle: "macOS 개인정보 보호 설정 열기") {
                Button("열기") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }.controlSize(.small)
            })),
        ]
    }

    private static func dataItems(sheet: Binding<AdvancedSheet?>) -> [SettingItem] {
        [
            item("backups", .data, "Backups", "자동 백업, 보관 개수, 복원", ["백업", "복원", "스냅샷"], AnyView(HubActionRow(icon: "clock.arrow.circlepath", tint: .orange, title: "Backups", subtitle: "자동 백업, 보관 개수, 복원") {
                Button("관리") { sheet.wrappedValue = .backups }.controlSize(.small)
            })),
            item("tutorial", .data, "Onboarding Tour", "주요 기능 안내를 다시 표시", ["튜토리얼", "안내", "온보딩"], AnyView(HubActionRow(icon: "sparkles", tint: .pink, title: "Onboarding Tour", subtitle: "주요 기능 안내를 다시 표시") {
                Button("시작") { NotificationCenter.default.post(name: .aomRestartTutorial, object: nil) }.controlSize(.small)
            })),
            item("reset", .data, "Reset Preferences", "모든 환경설정을 기본값으로 복원", ["초기화", "리셋"], AnyView(HubActionRow(icon: "arrow.counterclockwise", tint: .red, title: "Reset Preferences", subtitle: "모든 환경설정을 기본값으로 복원 (제스처는 유지)") {
                Button("초기화", role: .destructive) { NotificationCenter.default.post(name: .aomResetPreferences, object: nil) }.controlSize(.small)
            })),
        ]
    }

    private static func aboutItems() -> [SettingItem] {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
        return [
            item("version", .about, "Version", "\(version) (build \(build))", ["버전", "빌드"], AnyView(HubActionRow(icon: "app.badge", tint: .blue, title: "Version", subtitle: "\(version) (build \(build))") {
                Button("릴리스 노트") { NotificationCenter.default.post(name: .aomOpenReleaseNotes, object: nil) }.controlSize(.small)
            })),
        ]
    }
}

extension Notification.Name {
    static let aomImportBTTPreset = Notification.Name("AOMSettingsImportBTTPreset")
    static let aomRestartTutorial = Notification.Name("AOMSettingsRestartTutorial")
    static let aomResetPreferences = Notification.Name("AOMSettingsResetPreferences")
    static let aomOpenReleaseNotes = Notification.Name("AOMSettingsOpenReleaseNotes")
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

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text("설정").font(.aomDisplay(28)).tracking(-0.7).padding(.horizontal, 12)
                Text("내 Mac에 맞게").font(.aomBody(13)).foregroundStyle(AOMTheme.textSecondary)
                    .padding(.horizontal, 12)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(SettingsCategory.allCases) { cat in categoryChip(cat) }
                    }
                }.scrollIndicators(.hidden)
            }
            .padding(20).padding(.top, 12)
            .frame(width: 206)
            .background(AOMTheme.card)
            VStack(spacing: 0) {
                header
                content
                footer
            }
        }
        .frame(minWidth: 780, idealWidth: 900, maxWidth: .infinity, minHeight: 560, idealHeight: 700, maxHeight: .infinity)
        .background(AOMTheme.canvas)
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
        .onReceive(NotificationCenter.default.publisher(for: .aomSettingChanged)) { _ in flashSaved() }
        .onReceive(NotificationCenter.default.publisher(for: .aomImportBTTPreset)) { _ in importBTTPreset() }
        .onReceive(NotificationCenter.default.publisher(for: .aomRestartTutorial)) { _ in startTutorial() }
        .onReceive(NotificationCenter.default.publisher(for: .aomResetPreferences)) { _ in confirmReset() }
        .onReceive(NotificationCenter.default.publisher(for: .aomOpenReleaseNotes)) { _ in openReleaseNotes() }
        .sheet(item: $sheet) { sheet in
            SettingsSheetHost(sheet: sheet)
                .environmentObject(appState)
                .frame(width: 760, height: 620)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isSearching ? "검색 결과" : category.title)
                        .font(.aomDisplay(28)).tracking(-0.7).foregroundStyle(AOMTheme.text)
                    Text(isSearching ? "찾고 있는 설정을 빠르게 바꿔보세요." : category.blurb)
                        .font(.aomBody(13)).foregroundStyle(AOMTheme.textSecondary)
                }
                Spacer()
                if savedFlash {
                    AOMChip(text: "저장됨", tint: AOMTheme.positive, symbol: "checkmark")
                }
            }
            SettingsSearchField(text: $query)
        }
        .padding(28)
        .padding(.bottom, -10)
    }

    private func categoryChip(_ cat: SettingsCategory) -> some View {
        let selected = !isSearching && category == cat
        return Button {
            query = ""
            category = cat
        } label: {
            HStack(spacing: 12) {
                Image(systemName: cat.symbol).font(.system(size: 16, weight: .medium)).frame(width: 20)
                Text(cat.title).font(.aomLabel(13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 48)
            .foregroundStyle(selected ? AOMTheme.blue : AOMTheme.textSecondary)
            .background(selected ? AOMTheme.blue.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var content: some View {
        if visibleSections.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("‘\(query)’에 해당하는 설정이 없습니다")
                    .font(.system(size: 13, weight: .medium))
                Text("다른 단어로 검색하거나 전체 카테고리를 둘러보세요.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Button("검색 지우기") { query = "" }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(visibleSections) { section in
                            sectionView(section.category, rows: section.items)
                                .id(section.category.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
                .onChange(of: category) { _, newValue in
                    withAnimation(AOMDesign.animation()) { proxy.scrollTo(newValue.id, anchor: .top) }
                }
            }
        }
    }

    private func sectionView(_ cat: SettingsCategory, rows: [SettingItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cat.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AOMTheme.text)
                Text(cat.blurb)
                    .font(.system(size: 12))
                    .foregroundStyle(AOMTheme.textTertiary)
                Spacer()
                Text("\(rows.count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    row.content
                    if index < rows.count - 1 {
                        Rectangle().fill(AOMTheme.divider.opacity(0.5)).frame(height: 0.5).padding(.leading, 76)
                    }
                }
            }
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: AOMTheme.cardRadius, style: .continuous))
            .shadow(color: AOMTheme.cardShadow, radius: 12, y: 5)
            .clipShape(RoundedRectangle(cornerRadius: AOMTheme.cardRadius, style: .continuous))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 11))
                .foregroundStyle(AOMTheme.textTertiary)
            Text("모든 변경은 즉시 적용되고 자동 저장됩니다.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text("⌘F 검색")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(AOMTheme.canvas)
    }

    private func flashSaved() {
        flashTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { savedFlash = true }
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation(.easeIn(duration: 0.2)) { savedFlash = false } }
        }
    }

    private func importBTTPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "BetterTouchTool JSON 프리셋을 선택하세요"
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
        alert.informativeText = "환경설정만 기본값으로 돌립니다. 제스처와 액션은 유지됩니다."
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
                Text(sheet.title).font(.system(size: 14, weight: .semibold))
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
        }
    }
}
