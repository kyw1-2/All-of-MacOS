import SwiftUI

/// Shared by the sidebar, feature directory and command search. Persisted tab IDs stay stable.
enum AOMFeatureGroup: String, CaseIterable, Identifiable {
    case create = "Capture & Collect", organize = "Organize & Focus"
    case automate = "Automate & Control", system = "Mac & Activity"
    var id: String { rawValue }
    var tabs: [AOMMainTab] {
        switch self {
        case .create: [.capture, .clipboard, .textActions]
        case .organize: [.files, .folderRules, .focus]
        case .automate: [.gestures, .snapping]
        case .system: [.audio, .tools, .insights]
        }
    }
}

extension AOMMainTab {
    var discoveryKeywords: String {
        switch self {
        case .home: "home workspace overview 홈 작업공간"
        case .capture: "screenshot record video OCR ruler annotate scrolling 캡처 스크린샷 녹화 화면 텍스트 추출 자"
        case .clipboard: "copy paste history pinboard snippet 클립보드 복사 붙여넣기 기록"
        case .textActions: "selection popclip translate click hints 선택 번역 텍스트 클릭 힌트"
        case .files: "open save dialog shelf recent 파일 열기 저장 선반 최근"
        case .folderRules: "tidy downloads rename move organize 폴더 규칙 정리 다운로드 이름 변경"
        case .focus: "timer pomodoro distractions idle 집중 타이머 뽀모도로"
        case .gestures: "gesture shortcut keyboard mouse trackpad macro automation 제스처 단축키 키보드 마우스 자동화"
        case .snapping: "window snap tiling zone layout display 창 타일링 배치 영역 모니터"
        case .audio: "sound volume EQ equalizer output microphone HomePod AirPlay 소리 볼륨 오디오 마이크 홈팟"
        case .tools: "network battery fan storage cleanup VPN homebrew system 시스템 네트워크 배터리 팬 저장공간 청소"
        case .insights: "statistics usage activity stats 통계 사용 활동"
        }
    }
}

enum AOMFeatureSearch {
    static func matches(_ tab: AOMMainTab, query: String) -> Bool {
        let text = "\(tab.title) \(tab.subtitle) \(tab.discoveryKeywords)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains(String($0)) }
    }
    static func results(query: String, group: AOMFeatureGroup?) -> [AOMMainTab] {
        (group?.tabs ?? AOMFeatureGroup.allCases.flatMap(\.tabs)).filter { matches($0, query: query) }
    }
}

extension SettingsCategory {
    var discoveryKeywords: String {
        switch self {
        case .general: "appearance theme input sources language browser links router 모양 테마 입력 소스 언어 브라우저 링크"
        case .capture: "screenshot recording OCR export 스크린샷 녹화 캡처 저장"
        case .clipboard: "paste privacy history retention copy 클립보드 붙여넣기 보관 개인정보"
        case .automation: "hyper key remap caps lock keyboard mouse trackpad 하이퍼 키 리매핑 키보드 마우스 트랙패드"
        case .shortcuts: "hotkey shortcut keyboard 단축키 키보드"
        case .permissions: "accessibility screen recording input monitoring 권한 접근성 화면 기록 입력 모니터링"
        case .data: "backup restore import export profile 백업 복원 가져오기 내보내기 프로필"
        case .about: "version update release 버전 업데이트"
        }
    }
    func matchesDiscovery(_ query: String) -> Bool {
        SettingsSearch.matches(query: query, title: title, subtitle: "Settings 설정", keywords: [discoveryKeywords])
    }
}

struct AOMFeatureDirectory: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Binding var query: String
    @Binding var focusSearch: Bool
    @State private var group: AOMFeatureGroup?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x4) {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "magnifyingglass").foregroundStyle(AOMColor.textSecondary)
                TextField("Find a tool or task — try OCR, volume, or 창 배치", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Find a tool or task")
                    .onSubmit {
                        let results = AOMFeatureSearch.results(query: query, group: group)
                        if results.count == 1, let tab = results.first { appState.selectedMainTab = tab }
                    }
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear tool search")
                } else { AOMKeycap(text: "⌘F") }
            }
            .padding(.horizontal, AOMSpace.x3)
            .frame(height: 34)
            .background(AOMColor.surface, in: RoundedRectangle(cornerRadius: AOMRadius.well + 2, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AOMRadius.well + 2, style: .continuous)
                    .strokeBorder(searchFocused ? AOMColor.accent : AOMColor.hairline, lineWidth: searchFocused ? 1.5 : 0.5)
            }
            ScrollView(.horizontal) {
                HStack(spacing: AOMSpace.x2) {
                    scopeButton("All Tools", value: nil)
                    ForEach(AOMFeatureGroup.allCases) { item in scopeButton(item.rawValue, value: item) }
                }
            }.scrollIndicators(.never)
            let results = AOMFeatureSearch.results(query: query, group: group)
            let settings = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : SettingsCategory.allCases.filter { $0.matchesDiscovery(query) }
            if results.isEmpty && settings.isEmpty {
                AOMEmptyState("No matching tools", systemImage: "magnifyingglass",
                              message: "Try a task like screenshot, clipboard or audio, or browse all tools.") {
                    Button("Show All Tools") { query = ""; group = nil }
                }
            } else {
                // 6.0: one grouped list in two columns (System Settings,
                // Raycast Store) instead of a grid of hue-washed cards.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: AOMSpace.x1),
                                    GridItem(.flexible(), spacing: AOMSpace.x1)],
                          alignment: .leading, spacing: AOMSpace.x1) {
                    ForEach(results) { tab in AOMFeatureCard(tab: tab) { appState.selectedMainTab = tab } }
                }
                .padding(AOMSpace.x1 + AOMSpace.x0_5)
                .aomCard(padding: 0)
                if !settings.isEmpty {
                    AOMSection("Matching settings") {
                        ForEach(settings) { category in
                            Button {
                                openSettings()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    NotificationCenter.default.post(name: .aomShowSettingsCategory, object: category.rawValue)
                                }
                            } label: {
                                HStack {
                                    Label { Text("\(category.title) Settings") } icon: {
                                        AOMAppIcon(category.identity, size: AOMIcon.identityRow)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .padding(AOMSpace.x3).contentShape(Rectangle())
                            }.buttonStyle(AOMRowButtonStyle())
                        }
                    }
                }
            }
        }
        .onChange(of: focusSearch, initial: true) { _, requested in
            if requested { searchFocused = true; focusSearch = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: AOMToolbarSearchField.previewSearch)) { note in
            if PresetManager.isUIPreview, let text = note.object as? String { query = text }
        }
        .onChange(of: query) { _, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { group = nil }
        }
    }
    private func scopeButton(_ title: String, value: AOMFeatureGroup?) -> some View {
        // 6.0: a segmented row of words — the selected one on a raised
        // plate, the rest plain (Linear's view tabs).
        Button { group = value } label: {
            Text(title).font(AOMFont.callout.weight(group == value ? .semibold : .regular))
                .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5).frame(height: 26)
                .foregroundStyle(group == value ? AOMColor.text : AOMColor.textSecondary)
                .background(group == value ? AOMColor.surface : Color.clear,
                            in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
                .overlay {
                    if group == value {
                        RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous)
                            .strokeBorder(AOMColor.hairline, lineWidth: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(group == value ? .isSelected : [])
    }
}

private struct AOMFeatureCard: View {
    let tab: AOMMainTab
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x3) {
                AOMAppIcon(tab, size: AOMIcon.identityCard)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title).font(AOMFont.headline).foregroundStyle(AOMColor.text).lineLimit(1)
                    Text(tab.subtitle).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: AOMSpace.x2)
                if let key = tab.shortcutKey {
                    Text("⌘\(String(key.character))")
                        .font(AOMFont.caption.monospacedDigit())
                        .foregroundStyle(AOMColor.textTertiary)
                        .opacity(hovering ? 1 : 0)
                }
                Image(systemName: "chevron.right")
                    .font(AOMFont.caption.weight(.semibold))
                    .foregroundStyle(hovering ? AOMColor.textSecondary : AOMColor.textTertiary)
            }
            .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5)
            .frame(height: 50)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? AOMColor.rowHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: AOMRadius.well + 2, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AOMRadius.well + 2, style: .continuous))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.aomAnimation(.quick, value: hovering)
        .accessibilityLabel("Open \(tab.title)").accessibilityHint(tab.subtitle).help(tab.subtitle)
    }
}
