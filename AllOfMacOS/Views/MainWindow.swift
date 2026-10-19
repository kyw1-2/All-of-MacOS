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
                .navigationSplitViewColumnWidth(min: 210, ideal: 244, max: 300)
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
            .background(AOMWorkspaceBackground())
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
        .background(AOMMainWindowChrome(appearance: appearance).frame(width: 0, height: 0))
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

/// Keep the system toolbar's own material visible. A clear transparent titlebar
/// without content beneath it can become a white strip in an explicitly dark
/// SwiftUI window. Synchronize AppKit appearance rather than painting a toolbar.
struct AOMMainWindowChrome: NSViewRepresentable {
    var appearance: String

    private final class Probe: NSView {
        var appearanceChoice = "system"
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            guard let window else { return }
            let selected: NSAppearance? = appearanceChoice == "dark" ? NSAppearance(named: .darkAqua)
                : appearanceChoice == "light" ? NSAppearance(named: .aqua) : nil
            if window.appearance?.name != selected?.name { window.appearance = selected }
            if window.isOpaque { window.isOpaque = false }
            if window.backgroundColor != .clear { window.backgroundColor = .clear }
            if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        }
    }
    func makeNSView(context: Context) -> NSView {
        let view = Probe(frame: .zero); view.appearanceChoice = appearance; return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard let probe = view as? Probe else { return }
        probe.appearanceChoice = appearance; probe.configure()
    }
}
