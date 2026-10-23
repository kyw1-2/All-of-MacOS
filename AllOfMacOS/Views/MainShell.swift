import AppKit
import SwiftUI

/// Window chrome for the app: a single compact top bar with the product mark,
/// a pill tab group, the scope picker and the global actions. The left rail is
/// gone — navigation recedes into one slim row so the page owns the window.
struct AOMMainShell<Content: View>: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @Binding var showLog: Bool
    @Binding var showTouchVisualizer: Bool
    var appearance: String
    let content: Content

    init(showingCommandPalette: Binding<Bool>,
         showLog: Binding<Bool>,
         showTouchVisualizer: Binding<Bool>,
         appearance: String,
         @ViewBuilder content: () -> Content) {
        self._showingCommandPalette = showingCommandPalette
        self._showLog = showLog
        self._showTouchVisualizer = showTouchVisualizer
        self.appearance = appearance
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                AOMMainTopNav(showingCommandPalette: $showingCommandPalette,
                              showLog: $showLog,
                              showTouchVisualizer: $showTouchVisualizer,
                              compact: geometry.size.width < 1120)
                    .tutorialAnchor(.sidebar)

                Rectangle()
                    .fill(AOMTheme.divider)
                    .frame(height: 0.6)

                HStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showLog || showTouchVisualizer {
                        Rectangle().fill(AOMTheme.divider).frame(width: 0.6)
                        DiagnosticDrawerView(showLog: $showLog, showTouchVisualizer: $showTouchVisualizer)
                            .frame(width: 340)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .controlSize(.small)
        .background(AOMWorkspaceBackground())
        .background(AOMMainWindowChrome(appearance: appearance).frame(width: 0, height: 0))
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    }
}

// MARK: - Top navigation

struct AOMMainTopNav: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @Binding var showLog: Bool
    @Binding var showTouchVisualizer: Bool
    var compact: Bool
    @Environment(\.openSettings) private var openSettingsAction
    @State private var hoveringTab: AOMMainTab?

    var body: some View {
        HStack(spacing: 14) {
            brand

            tabGroup

            Spacer(minLength: 8)

            scopeMenu
            searchButton
            captureButton
            diagnosticsMenu
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(AOMTheme.canvas)
    }

    // MARK: Brand

    private var brand: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AOMTheme.heroGradient)
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(appState.globalEnabled ? AOMTheme.positive : AOMTheme.warning)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(AOMTheme.canvas, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            if !compact {
                Text("All of MacOS")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(AOMTheme.text)
                    .fixedSize()
            }
        }
        .help(appState.globalEnabled ? "자동화 실행 중" : "자동화 일시정지")
        .onTapGesture { appState.toggleGlobalEnabled() }
    }

    // MARK: Tabs

    private var tabGroup: some View {
        HStack(spacing: 2) {
            ForEach(AOMMainTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func tabButton(_ tab: AOMMainTab) -> some View {
        let selected = appState.selectedMainTab == tab
        return Button {
            withAnimation(AOMDesign.animation()) { appState.selectedMainTab = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 12, weight: .semibold))
                if !compact {
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .fixedSize()
                }
            }
            .foregroundStyle(selected ? AOMTheme.text : AOMTheme.textSecondary)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AOMTheme.card)
                        .shadow(color: AOMTheme.cardShadow, radius: 6, y: 2)
                } else if hoveringTab == tab {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AOMTheme.divider.opacity(0.45))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveringTab = tab } else if hoveringTab == tab { hoveringTab = nil }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(tab.subtitle)
    }

    // MARK: Scope

    private var scopeMenu: some View {
        Menu {
            Button {
                selectScope(group: nil, app: .allApps)
            } label: {
                Label("All Applications", systemImage: "globe")
            }
            let apps = appState.currentPreset.appTargets.filter { !$0.isGlobal }
            if !apps.isEmpty {
                Divider()
                ForEach(apps) { app in
                    Button { selectScope(group: nil, app: app) } label: {
                        Label(app.name, systemImage: "app")
                    }
                }
            }
            if !appState.currentPreset.activationGroups.isEmpty {
                Divider()
                ForEach(appState.currentPreset.activationGroups) { group in
                    Button { selectScope(group: group.id, app: appState.selectedAppTarget) } label: {
                        Label(group.name, systemImage: group.isEnabled ? "square.stack.3d.up" : "pause")
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: scopeSymbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AOMTheme.blue)
                if !compact {
                    Text(scopeName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AOMTheme.text)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AOMTheme.textTertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("편집할 앱 프로필 또는 활성화 그룹")
    }

    private var scopeName: String {
        if let id = appState.selectedActivationGroupID,
           let group = appState.currentPreset.activationGroups.first(where: { $0.id == id }) {
            return group.name
        }
        return appState.selectedAppTarget.isGlobal ? "All Applications" : appState.selectedAppTarget.name
    }

    private var scopeSymbol: String {
        if appState.selectedActivationGroupID != nil { return "square.stack.3d.up.fill" }
        return appState.selectedAppTarget.isGlobal ? "globe" : "app.fill"
    }

    private func selectScope(group: UUID?, app: AppTarget) {
        appState.selectedActivationGroupID = group
        appState.selectedAppTarget = app
        appState.selectedTrigger = nil
        appState.selectedAction = nil
        appState.selectedMainTab = .gestures
    }

    // MARK: Actions

    private var searchButton: some View {
        Button { showingCommandPalette = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .semibold))
                if !compact {
                    Text("⌘K").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AOMTheme.textTertiary)
                }
            }
            .foregroundStyle(AOMTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("명령 팔레트 (⌘K)")
    }

    private var captureButton: some View {
        Menu {
            Button("영역 캡처") { CaptureCoordinator.shared.captureArea() }
            Button("전체 화면 캡처") { CaptureCoordinator.shared.captureFullscreen() }
            Button("텍스트 추출") { CaptureCoordinator.shared.captureText() }
            Divider()
            Button("화면 녹화") { ScreenRecordingService.shared.promptAndStartRecording() }
            Button("클립보드 열기") { ClipboardPanelController.shared.show() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.viewfinder").font(.system(size: 12, weight: .bold))
                if !compact {
                    Text("캡처").font(.system(size: 12.5, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(AOMTheme.heroGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: AOMTheme.blue.opacity(0.28), radius: 8, y: 3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("캡처 · 녹화 · 클립보드")
    }

    private var diagnosticsMenu: some View {
        Menu {
            Toggle("터치 시각화", isOn: $showTouchVisualizer)
            Toggle("진단 콘솔", isOn: $showLog)
            Divider()
            Button("설정…") { openSettingsAction() }
            Button("온보딩 다시 보기") { appState.showTutorialRequested = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AOMTheme.textSecondary)
                .frame(width: 32, height: 32)
                .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32)
        .help("더 보기")
    }
}
