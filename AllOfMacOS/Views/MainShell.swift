import AppKit
import SwiftUI

/// The main window chrome: a fixed navigation rail, a slim page header and the
/// page canvas. Replaces the split view so navigation, page title and actions
/// stay in one predictable place instead of a titlebar + sidebar + toolbar mix.
struct AOMMainShell<Content: View>: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @Binding var showLog: Bool
    @Binding var showTouchVisualizer: Bool
    var appearance: String
    @Environment(\.openSettings) private var openSettingsAction
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

    private var isDark: Bool { appearance == "dark" }

    var body: some View {
        HStack(spacing: 0) {
            AOMMainSidebar(appearance: appearance)
                .frame(width: 236)
                .tutorialAnchor(.sidebar)

            VStack(spacing: 0) {
                AOMMainTopBar(showingCommandPalette: $showingCommandPalette,
                              showLog: $showLog,
                              showTouchVisualizer: $showTouchVisualizer)
                HStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showLog || showTouchVisualizer {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.4))
                            .frame(width: 0.5)
                        DiagnosticDrawerView(showLog: $showLog, showTouchVisualizer: $showTouchVisualizer)
                            .frame(width: 340)
                    }
                }
            }
        }
        .background(AOMWorkspaceBackground())
        .background(AOMMainWindowChrome(appearance: appearance).frame(width: 0, height: 0))
        .preferredColorScheme(appearance == "system" ? nil : (isDark ? .dark : .light))
    }
}

// MARK: - Sidebar

struct AOMMainSidebar: View {
    @EnvironmentObject var appState: AppState
    var appearance: String
    @Environment(\.openSettings) private var openSettingsAction
    @State private var hoveringTab: AOMMainTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
            statusPill
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    navSection
                    scopeSection
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .suppressScrollerReservation()

            Spacer(minLength: 0)
            footer
        }
        .background(AOMTheme.canvas)
    }

    private var wordmark: some View {
        HStack(alignment: .center, spacing: 9) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [AOMTheme.blue, AOMTheme.blue.aomDarker(0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: AOMTheme.blue.opacity(0.3), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("All of MacOS").font(.system(size: 15, weight: .bold)).foregroundStyle(AOMTheme.text)
                Text("AOM").font(.system(size: 10, weight: .semibold)).foregroundStyle(AOMTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var statusPill: some View {
        Button { appState.toggleGlobalEnabled() } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(appState.globalEnabled ? AOMTheme.positive : AOMTheme.warning)
                    .frame(width: 7, height: 7)
                Text(appState.globalEnabled ? "자동화 실행 중" : "자동화 일시정지")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AOMTheme.text)
                Spacer(minLength: 0)
                Image(systemName: appState.globalEnabled ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AOMTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(AOMTheme.card,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(appState.globalEnabled ? "Pause automation" : "Resume automation")
    }

    private var navSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("WORKSPACE")
            ForEach(AOMMainTab.allCases) { tab in
                navRow(tab)
            }
        }
    }

    private func navRow(_ tab: AOMMainTab) -> some View {
        let selected = appState.selectedMainTab == tab
        return Button {
            withAnimation(.snappy(duration: 0.18)) { appState.selectedMainTab = tab }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? AOMTheme.blue : AOMTheme.textSecondary)
                    .frame(width: 22)
                Text(tab.title)
                    .font(.system(size: 13.5, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? AOMTheme.text : AOMTheme.textSecondary)
                Spacer(minLength: 0)
                if tab == .gestures {
                    let count = appState.currentPreset.triggers.filter(\.isEnabled).count
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hoveringTab == tab && !selected ? AOMTheme.divider.opacity(0.5) : .clear)
            }
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AOMTheme.card)
                        .shadow(color: AOMTheme.cardShadow, radius: 8, y: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hoveringTab = $0 ? tab : (hoveringTab == tab ? nil : hoveringTab) }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("SCOPE")
            Menu {
                Button {
                    selectScope(group: nil, app: .allApps)
                } label: {
                    Label("All Applications", systemImage: "globe")
                }
                if !appState.currentPreset.appTargets.filter({ !$0.isGlobal }).isEmpty {
                    Divider()
                    ForEach(appState.currentPreset.appTargets.filter { !$0.isGlobal }) { app in
                        Button {
                            selectScope(group: nil, app: app)
                        } label: {
                            Label(app.name, systemImage: "app")
                        }
                    }
                }
                if !appState.currentPreset.activationGroups.isEmpty {
                    Divider()
                    ForEach(appState.currentPreset.activationGroups) { group in
                        Button {
                            selectScope(group: group.id, app: appState.selectedAppTarget)
                        } label: {
                            Label(group.name, systemImage: group.isEnabled ? "square.stack.3d.up" : "pause")
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: scopeSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(appState.accentColorChoice.color)
                        .frame(width: 20)
                    Text(scopeName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Choose the app profile or activation group you are editing")

            if let groupID = appState.selectedActivationGroupID,
               let group = appState.currentPreset.activationGroups.first(where: { $0.id == groupID }) {
                Toggle(isOn: Binding(get: { group.isEnabled }, set: { newValue in
                    var updated = group
                    updated.isEnabled = newValue
                    appState.updateActivationGroup(updated)
                })) {
                    Text("Group enabled").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, 10)
                .padding(.top, 2)
            }
        }
    }

    private var scopeName: String {
        if appState.selectedActivationGroupID != nil { return "Activation Group" }
        if appState.selectedAppTarget.isGlobal { return "All Applications" }
        return appState.selectedAppTarget.name
    }

    private var scopeSymbol: String {
        if appState.selectedActivationGroupID != nil { return "square.stack.3d.up.fill" }
        if appState.selectedAppTarget.isGlobal { return "globe" }
        return "app.fill"
    }

    private func selectScope(group: UUID?, app: AppTarget) {
        appState.selectedActivationGroupID = group
        appState.selectedAppTarget = app
        appState.selectedTrigger = nil
        appState.selectedAction = nil
        appState.selectedMainTab = .gestures
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 0.5)
            footerRow("Settings…", symbol: "gearshape") { openSettingsAction() }
            footerRow("Onboarding tour", symbol: "sparkles") { appState.showTutorialRequested = true }
            HStack {
                Text("Version \(appVersion)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
    }

    private func footerRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium)).frame(width: 16)
                Text(title).font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(AOMTheme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
}

// MARK: - Top bar

struct AOMMainTopBar: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @Binding var showLog: Bool
    @Binding var showTouchVisualizer: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.selectedMainTab.title)
                    .font(.system(size: 23, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(AOMTheme.text)
                Text(appState.selectedMainTab.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AOMTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)

            Button {
                showingCommandPalette = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                    Text("Search").font(.system(size: 11.5))
                    Text("⌘K")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
                .foregroundStyle(AOMTheme.textSecondary)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open the command palette (⌘K)")

            quickCapture

            Menu {
                Toggle("Touch Visualizer", isOn: $showTouchVisualizer)
                Toggle("Diagnostics Console", isOn: $showLog)
            } label: {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AOMTheme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Diagnostics")
        }
        .padding(.horizontal, 28)
        .frame(height: 76)
        .background(AOMTheme.canvas)
    }

    private var quickCapture: some View {
        Menu {
            Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
            Button("Capture Full Screen") { CaptureCoordinator.shared.captureFullscreen() }
            Button("Capture Text") { CaptureCoordinator.shared.captureText() }
            Divider()
            Button("Record Screen") { ScreenRecordingService.shared.promptAndStartRecording() }
            Button("Open Clipboard") { ClipboardPanelController.shared.show() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.viewfinder").font(.system(size: 11.5, weight: .semibold))
                Text("Capture").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 34)
            .background(AOMTheme.blue, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start a capture or recording")
    }
}
