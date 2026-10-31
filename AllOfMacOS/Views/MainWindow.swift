import AppKit
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("AOMShowLog") private var showLog = false
    @AppStorage("AOMShowTouchVisualizer") private var showTouchVisualizer = false
    @State private var showTutorial = !UserDefaults.hasSeenTutorial
    @State private var tutorialFrames: [TutorialRegion: CGRect] = [:]
    @AppStorage("AOMAppearance") private var appearance: String = "system"
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var history = AOMNavigationHistory.shared

    /// The last page, restored at launch (HIG Launching: restore the previous
    /// state). Isolated previews and tests share no state with the app, so
    /// they neither read nor write it.
    static let lastPageKey = "AOMLastPage"
    static var persistsLastPage: Bool { !PresetManager.isUIPreview && !PresetManager.isRunningTests }
    private static var restoredLastPage = false

    var body: some View {
        AOMMainShell(showingCommandPalette: $appState.showingCommandPalette,
                     showLog: $showLog,
                     showTouchVisualizer: $showTouchVisualizer,
                     appearance: appearance) {
            Group {
                switch appState.selectedMainTab {
                case .home: AOMHomeView(showingCommandPalette: $appState.showingCommandPalette)
                case .gestures:
                    ModernGesturesWorkspace()
                        .tutorialAnchor(.triggers)
                        .tutorialAnchor(.actions)
                case .snapping: ModernWindowSnappingView()
                case .capture: CaptureStudioView()
                case .clipboard: ClipboardStudioView()
                case .audio: AudioWorkspaceView()
                case .tools: SystemToolsView()
                case .insights: StatisticsView()
                case .folderRules: FolderRulesPage()
                case .textActions: TextActionsPage()
                case .files: FilesPage()
                case .focus: FocusPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .coordinateSpace(name: "tutorialOverlay")
        .onPreferenceChange(TutorialFramePreferenceKey.self) { if tutorialFrames != $0 { tutorialFrames = $0 } }
        .overlay {
            if showTutorial {
                TutorialOverlayView(isPresented: $showTutorial, frames: tutorialFrames)
                    .environmentObject(appState)
            }
        }
        .overlay {
            if appState.showingCommandPalette {
                QuickCommandPalette(isPresented: $appState.showingCommandPalette)
                    .environmentObject(appState)
                    .transition(.opacity)
            }
        }
        .animation(AOMMotion.quick, value: appState.showingCommandPalette)
        // The master switch and the diagnostics drawer, for Controls › Pause
        // AOM and the Window menu (they left the sidebar footer in 3.3.3).
        .focusedSceneValue(\.aomShellCommands, AOMShellCommandActions(
            engineOn: appState.globalEnabled,
            toggleEngine: { appState.toggleGlobalEnabled() },
            showLog: showLog,
            setShowLog: { showLog = $0 },
            showTouchVisualizer: showTouchVisualizer,
            setShowTouchVisualizer: { showTouchVisualizer = $0 }))
        .onChange(of: appState.selectedMainTab) { old, new in
            history.record(from: old, to: new)
            if Self.persistsLastPage { UserDefaults.standard.set(new.rawValue, forKey: Self.lastPageKey) }
        }
        .onAppear {
            restoreLastPage()
            // Isolated previews can open Settings for review (`--aom-preview-settings`),
            // once the main window is on screen — the way a person would.
            if PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openSettings() }
            }
        }
        .onChange(of: appState.showTutorialRequested) { _, requested in
            if requested {
                showTutorial = true
                appState.showTutorialRequested = false
            }
        }
    }
}

extension MainWindow {
    /// Once per launch, and only if nothing else (a link, the menu bar) has
    /// picked a page yet.
    private func restoreLastPage() {
        guard Self.persistsLastPage, !Self.restoredLastPage else { return }
        Self.restoredLastPage = true
        guard appState.selectedMainTab == .home,
              let raw = UserDefaults.standard.string(forKey: Self.lastPageKey),
              let tab = AOMMainTab(rawValue: raw), tab != .home else { return }
        history.skipRecording(tab)
        appState.selectedMainTab = tab
    }
}

/// Keeps the main window's AppKit appearance in sync with the in-app
/// appearance choice. The window, title bar and toolbar are otherwise the
/// system's: SwiftUI owns the toolbar and the sidebar draws its own material.
struct AOMMainWindowChrome: NSViewRepresentable {
    var appearance: String

    private final class Probe: NSView {
        var appearanceChoice = "system"
        private var sizedForPreview = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            guard let window else { return }
            let selected: NSAppearance? = appearanceChoice == "dark" ? NSAppearance(named: .darkAqua)
                : appearanceChoice == "light" ? NSAppearance(named: .aqua) : nil
            if window.appearance?.name != selected?.name { window.appearance = selected }
            // The titlebar, toolbar and window background stay the system's:
            // macOS 26 draws the toolbar as Liquid Glass with a scroll-edge
            // effect over the system canvas. Painting a custom background or
            // a transparent titlebar here hid both (3.0.x).
            if !sizedForPreview, let size = AOMMainWindowChrome.previewSize {
                sizedForPreview = true
                window.setFrame(NSRect(x: 0, y: 0, width: size.width, height: size.height), display: true)
            }
        }
    }
    /// The isolated preview's window size. The last `--aom-preview-size`
    /// wins, so a size added after the kit's default 1320x820 (the 1000x680
    /// review) takes effect.
    static var previewSize: CGSize? {
        guard PresetManager.isUIPreview else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.lastIndex(of: "--aom-preview-size"), args.indices.contains(index + 1) else {
            return PresetManager.previewWindowSize
        }
        let parts = args[index + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 >= 400 && $0 <= 4000 }) else { return PresetManager.previewWindowSize }
        return CGSize(width: parts[0], height: parts[1])
    }

    func makeNSView(context: Context) -> NSView {
        let view = Probe(frame: .zero); view.appearanceChoice = appearance; return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard let probe = view as? Probe else { return }
        probe.appearanceChoice = appearance; probe.configure()
    }
}
