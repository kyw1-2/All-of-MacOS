import AppKit
import SwiftUI

private struct AOMTriggerPaneHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var gestureLog = GestureLog.shared
    @AppStorage("AOMShowLog") private var showLog = false
    @AppStorage("AOMShowTouchVisualizer") private var showTouchVisualizer = false
    @State private var showingCommandPalette = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var showTutorial = !UserDefaults.hasSeenTutorial
    @State private var tutorialFrames: [TutorialRegion: CGRect] = [:]
    @AppStorage("AOMAppearance") private var appearance: String = "system"
    @Environment(\.openSettings) private var openSettingsAction

    private var isDark: Bool { appearance == "dark" }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ModernSidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
                .tutorialAnchor(.sidebar)
        } detail: {
            HStack(spacing: 0) {
                Group {
                    switch appState.selectedMainTab {
                    case .home: HomeDashboardView()
                    case .gestures:
                        ModernGesturesWorkspace()
                            .tutorialAnchor(.triggers)
                            .tutorialAnchor(.actions)
                    case .snapping: ModernWindowSnappingView()
                    case .capture: CaptureStudioView()
                    case .clipboard: ClipboardStudioView()
                    case .insights: StatisticsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showLog || showTouchVisualizer {
                    Divider()
                    DiagnosticDrawerView(showLog: $showLog, showTouchVisualizer: $showTouchVisualizer)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(appState.selectedMainTab.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showingCommandPalette.toggle() } label: {
                        Label("Commands", systemImage: "command")
                    }
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Commands (⌘K)")
                    Menu {
                        Toggle("Touch Visualizer", isOn: $showTouchVisualizer)
                        Toggle("Console", isOn: $showLog)
                        Divider()
                        Picker("Appearance", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        Divider()
                        Button("Settings…") { openSettingsAction() }
                    } label: {
                        Label("View Options", systemImage: "ellipsis.circle")
                    }
                    .help("View options")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .scrollIndicators(.hidden)
        .onPreferenceChange(AOMTriggerPaneHeightKey.self) { paneHeight in
            // Opt-in, single-value layout probe for diagnosing split view regressions.
            if UserDefaults.standard.bool(forKey: "AOMLayoutProbeEnabled") {
                UserDefaults.standard.set(Double(paneHeight), forKey: "AOMMeasuredTriggerPaneHeight")
            }
        }
        .coordinateSpace(name: "tutorialOverlay")
        .onPreferenceChange(TutorialFramePreferenceKey.self) { tutorialFrames = $0 }
        .overlay {
            if showTutorial {
                TutorialOverlayView(isPresented: $showTutorial, frames: tutorialFrames)
                    .environmentObject(appState)
            }
        }
        .overlay {
            if showingCommandPalette {
                QuickCommandPalette(isPresented: $showingCommandPalette)
                    .environmentObject(appState)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .onChange(of: appState.showTutorialRequested) { _, requested in
            if requested {
                showTutorial = true
                appState.showTutorialRequested = false
            }
        }

        .preferredColorScheme(appearance == "system" ? nil : (isDark ? .dark : .light))
    }

    private func openSettings() {
        openSettingsAction()
    }
}
