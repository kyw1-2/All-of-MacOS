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
    @State private var showTutorial = !UserDefaults.hasSeenTutorial
    @State private var tutorialFrames: [TutorialRegion: CGRect] = [:]
    @AppStorage("AOMAppearance") private var appearance: String = "system"

    var body: some View {
        AOMMainShell(showingCommandPalette: $showingCommandPalette,
                     showLog: $showLog,
                     showTouchVisualizer: $showTouchVisualizer,
                     appearance: appearance) {
            Group {
                switch appState.selectedMainTab {
                case .home: AOMHomeView(showingCommandPalette: $showingCommandPalette)
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
    }
}

/// Turns the main window into AOM's canvas: an opaque window painted with the
/// curated canvas colour (wallpaper never tints the UI), a transparent
/// full-size title bar whose height comes from an empty unified toolbar
/// (52 pt, traffic lights centred on the navigation row), and an AppKit
/// appearance kept in sync with the in-app appearance choice.
struct AOMMainWindowChrome: NSViewRepresentable {
    var appearance: String

    static let toolbarIdentifier = NSToolbar.Identifier("com.kyw.allofmacos.main-chrome")

    private final class Probe: NSView {
        var appearanceChoice = "system"
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            guard let window else { return }
            let selected: NSAppearance? = appearanceChoice == "dark" ? NSAppearance(named: .darkAqua)
                : appearanceChoice == "light" ? NSAppearance(named: .aqua) : nil
            if window.appearance?.name != selected?.name { window.appearance = selected }
            if !window.isOpaque { window.isOpaque = true }
            if window.backgroundColor != AOMTheme.canvasNSColor { window.backgroundColor = AOMTheme.canvasNSColor }
            // The navigation row is the title bar.
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: AOMMainWindowChrome.toolbarIdentifier)
                toolbar.displayMode = .iconOnly
                toolbar.allowsUserCustomization = false
                window.toolbar = toolbar
            }
            if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
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
