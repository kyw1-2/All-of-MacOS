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
