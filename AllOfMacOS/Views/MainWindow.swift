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
        .onAppear {
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
            if !sizedForPreview, let size = PresetManager.previewWindowSize {
                sizedForPreview = true
                window.setFrame(NSRect(x: 0, y: 0, width: size.width, height: size.height), display: true)
            }
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
