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
            HStack(alignment: .firstTextBaseline) {
                Text("Explore your tools").font(AOMFont.pageTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("11 tools · one workspace").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            }
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
            .padding(AOMSpace.x3)
            .background(AOMColor.surface, in: RoundedRectangle(cornerRadius: AOMRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: AOMRadius.card)
                    .strokeBorder(searchFocused ? AOMColor.accent : AOMColor.hairline, lineWidth: 1)
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: AOMSize.directoryTileMin), spacing: AOMSpace.x3)],
                          alignment: .leading, spacing: AOMSpace.x3) {
                    ForEach(results) { tab in AOMFeatureCard(tab: tab) { appState.selectedMainTab = tab } }
                }
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
                                    Label("\(category.title) Settings", systemImage: category.symbol)
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
        Button { group = value } label: {
            Text(title).font(AOMFont.callout)
                .padding(.horizontal, AOMSpace.x3).padding(.vertical, AOMSpace.x2)
                .foregroundStyle(group == value ? AOMColor.accent : AOMColor.textSecondary)
                .background(group == value ? AOMColor.accent.opacity(0.12) : AOMColor.surface, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(group == value ? .isSelected : [])
    }
}

private struct AOMFeatureCard: View {
    let tab: AOMMainTab
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AOMSpace.x2) {
                HStack(spacing: AOMSpace.x2) {
                    Image(systemName: tab.sidebarSymbol).font(AOMFont.title).foregroundStyle(AOMColor.accent)
                        .frame(width: AOMSize.directoryIcon, height: AOMSize.directoryIcon)
                        .background(AOMColor.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: AOMRadius.well))
                    Text(tab.title).font(AOMFont.headline).foregroundStyle(AOMColor.text)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
                Text(tab.subtitle).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: AOMSize.rowStandard, alignment: .top)
            }
            .padding(AOMSpace.x4).frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? AOMColor.surfaceHover : AOMColor.surface, in: RoundedRectangle(cornerRadius: AOMRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: AOMRadius.card)
                    .strokeBorder(hovering ? AOMColor.accent : (contrast == .increased ? AOMColor.strongLine : AOMColor.hairline), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AOMRadius.card))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.aomAnimation(.quick, value: hovering)
        .accessibilityLabel("Open \(tab.title)").accessibilityHint(tab.subtitle).help(tab.subtitle)
    }
}


/// A visible bridge between tools that belong to the same task family.
private struct AOMRelatedToolsContent: View {
    let tabs: [AOMMainTab]
    let open: (AOMMainTab) -> Void
    var body: some View {
        HStack(spacing: AOMSpace.x3) {
            Text("Related tools").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            ForEach(tabs) { tab in
                Button { open(tab) } label: { Label(tab.title, systemImage: tab.sidebarSymbol) }
                    .buttonStyle(.borderless).font(AOMFont.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AOMSpace.pageMargin).padding(.vertical, AOMSpace.x2)
        .background(AOMColor.surface)
        .overlay(alignment: .top) { AOMDivider() }
    }
}

struct AOMRelatedTools: View {
    let appState: AppState
    @ObservedObject private var navigation = AOMNavigation.shared
    var body: some View {
        if let group = AOMFeatureGroup.allCases.first(where: { $0.tabs.contains(navigation.selected) }) {
            AOMRelatedToolsContent(tabs: group.tabs.filter { $0 != navigation.selected }) {
                appState.selectedMainTab = $0
            }
        }
    }
}
