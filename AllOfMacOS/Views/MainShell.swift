import AppKit
import SwiftUI

/// Window chrome for the app. The title bar *is* the navigation: traffic
/// lights, product mark, the tab track, the scope picker and the global
/// actions share one row over the canvas, and every page sits below it on the
/// same calm surface.
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
            // With a full-size content view the safe area's top inset is the
            // title bar's height; the navigation row occupies exactly that band.
            let barHeight = max(geometry.safeAreaInsets.top, AOMMainTopNav.minimumHeight)
            VStack(spacing: 0) {
                AOMMainTopNav(showingCommandPalette: $showingCommandPalette,
                              showLog: $showLog,
                              showTouchVisualizer: $showTouchVisualizer,
                              density: AOMMainTopNav.Density(width: geometry.size.width))
                    .frame(height: barHeight)
                    .tutorialAnchor(.sidebar)

                HStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showLog || showTouchVisualizer {
                        Rectangle().fill(AOMTheme.divider).frame(width: 1)
                        DiagnosticDrawerView(showLog: $showLog, showTouchVisualizer: $showTouchVisualizer)
                            .frame(width: 340)
                            .background(AOMTheme.paper)
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .foregroundStyle(AOMTheme.text)
        .aomHiddenWindowToolbarBackground()
        .background(AOMWindowCanvas())
        .background(AOMMainWindowChrome(appearance: appearance).frame(width: 0, height: 0))
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    }
}

private extension View {
    /// SwiftUI paints a toolbar material over the title-bar band by default;
    /// the navigation row lives there, so the band must stay clear.
    @ViewBuilder
    func aomHiddenWindowToolbarBackground() -> some View {
        if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

// MARK: - Top navigation

struct AOMMainTopNav: View {
    /// The unified title bar height on macOS 14–27; the measured inset wins.
    static let minimumHeight: CGFloat = 52
    /// Room for the traffic lights at the leading edge.
    static let trafficLightInset: CGFloat = 86

    /// How much text the row can afford at a given window width. Labels drop
    /// out from least to most important, so nothing ever wraps or squeezes.
    struct Density: Equatable {
        var showsBrandName: Bool
        var showsSearchLabel: Bool
        var showsTabTitles: Bool
        var showsScopeName: Bool

        init(width: CGFloat) {
            showsBrandName = width >= 1500
            showsSearchLabel = width >= 1380
            showsTabTitles = width >= 1080
            showsScopeName = width >= 1240
        }
    }

    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @Binding var showLog: Bool
    @Binding var showTouchVisualizer: Bool
    var density: Density
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveringTab: AOMMainTab?
    @Namespace private var selection

    private var compact: Bool { !density.showsTabTitles }

    var body: some View {
        HStack(spacing: 10) {
            brand
            tabTrack.layoutPriority(1)
            Spacer(minLength: 8)
            scopeMenu
            searchButton
            captureButton
            moreMenu
        }
        .padding(.leading, Self.trafficLightInset)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AOMWindowDragArea())
    }

    // MARK: Brand

    private var brand: some View {
        Button { appState.toggleGlobalEnabled() } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AOMTheme.heroGradient)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(appState.globalEnabled ? AOMTheme.positive : AOMTheme.warning)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(AOMTheme.canvas, lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                if density.showsBrandName {
                    Text("All of MacOS")
                        .font(.system(size: 14.5, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(AOMTheme.text)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AOMCardButtonStyle())
        .help(appState.globalEnabled ? "Automation is on — click to pause" : "Automation is paused — click to resume")
        .accessibilityLabel(appState.globalEnabled ? "All of MacOS, automation on" : "All of MacOS, automation paused")
        .padding(.trailing, 4)
    }

    // MARK: Tabs

    private var tabTrack: some View {
        HStack(spacing: 2) {
            ForEach(AOMMainTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(AOMTheme.track, in: Capsule())
    }

    private func tabButton(_ tab: AOMMainTab) -> some View {
        let selected = appState.selectedMainTab == tab
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
                appState.selectedMainTab = tab
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? tab.accentColor : AOMTheme.textTertiary)
                if !compact {
                    Text(tab.title)
                        .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? AOMTheme.text : AOMTheme.textSecondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, compact ? 11 : 14)
            .frame(height: 32)
            .background {
                if selected {
                    Capsule()
                        .fill(AOMTheme.paper)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                        .shadow(color: .black.opacity(0.04), radius: 1, y: 0.5)
                        .matchedGeometryEffect(id: "tab", in: selection)
                } else if hoveringTab == tab {
                    Capsule().fill(AOMTheme.text.opacity(0.05))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveringTab = tab } else if hoveringTab == tab { hoveringTab = nil }
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help("\(tab.title) — \(tab.subtitle)")
    }

    // MARK: Scope

    private var scopeMenu: some View {
        AOMPopupMenu(items: scopeItems) {
            HStack(spacing: 7) {
                Image(systemName: scopeSymbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AOMTheme.blue)
                if density.showsScopeName {
                    Text(scopeName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(AOMTheme.text)
                        .lineLimit(1)
                        .frame(maxWidth: 170)
                        .fixedSize()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AOMTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .navPill()
        }
        .help("App profile or activation group: \(scopeName)")
        .accessibilityLabel("Scope: \(scopeName)")
    }

    private func scopeItems() -> [AOMMenuItem] {
        var items: [AOMMenuItem] = [
            .action("All Applications", systemImage: "globe",
                    checked: appState.selectedActivationGroupID == nil && appState.selectedAppTarget.isGlobal) {
                selectScope(group: nil, app: .allApps)
            }
        ]
        let apps = appState.currentPreset.appTargets.filter { !$0.isGlobal }
        if !apps.isEmpty {
            items.append(.divider)
            for app in apps {
                items.append(.action(app.name, systemImage: "app",
                                     checked: appState.selectedActivationGroupID == nil && appState.selectedAppTarget.id == app.id) {
                    selectScope(group: nil, app: app)
                })
            }
        }
        if !appState.currentPreset.activationGroups.isEmpty {
            items.append(.divider)
            for group in appState.currentPreset.activationGroups {
                items.append(.action(group.name, systemImage: group.isEnabled ? "square.stack.3d.up" : "pause",
                                     checked: appState.selectedActivationGroupID == group.id) {
                    selectScope(group: group.id, app: appState.selectedAppTarget)
                })
            }
        }
        return items
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
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AOMTheme.textSecondary)
                if density.showsSearchLabel {
                    Text("Search").font(.system(size: 13.5, weight: .medium)).foregroundStyle(AOMTheme.textSecondary)
                }
                if !compact { AOMKeycap(text: "⌘K") }
            }
            .fixedSize()
            .padding(.leading, 12)
            .padding(.trailing, compact ? 12 : 6)
            .frame(height: 34)
            .navPill()
        }
        .buttonStyle(AOMCardButtonStyle())
        .help("Command palette (⌘K)")
        .accessibilityLabel("Search commands")
    }

    private var captureButton: some View {
        AOMPopupMenu(items: {
            [
                .action("Capture Area", systemImage: "viewfinder") { CaptureCoordinator.shared.captureArea() },
                .action("Capture Full Screen", systemImage: "display") { CaptureCoordinator.shared.captureFullscreen() },
                .action("Capture Text", systemImage: "text.viewfinder") { CaptureCoordinator.shared.captureText() },
                .divider,
                .action("Record Screen", systemImage: "record.circle") { ScreenRecordingService.shared.promptAndStartRecording() },
                .action("Open Clipboard", systemImage: "doc.on.clipboard") { ClipboardPanelController.shared.show() }
            ]
        }) {
            HStack(spacing: 7) {
                Image(systemName: "plus.viewfinder").font(.system(size: 13, weight: .bold))
                if !compact {
                    Text("Capture").font(.system(size: 13.5, weight: .semibold))
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(AOMTheme.blue, in: Capsule())
            .contentShape(Capsule())
        }
        .help("Capture, record, clipboard")
        .accessibilityLabel("Capture")
    }

    private var moreMenu: some View {
        AOMPopupMenu(items: {
            [
                .toggle("Touch Visualizer", isOn: showTouchVisualizer) { showTouchVisualizer = $0 },
                .toggle("Diagnostics Console", isOn: showLog) { showLog = $0 },
                .divider,
                .action("Settings…", systemImage: "gearshape") { openSettingsAction() },
                .action("Show Onboarding Again", systemImage: "sparkles") { appState.showTutorialRequested = true }
            ]
        }) {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AOMTheme.textSecondary)
                .frame(width: 34, height: 34)
                .navPill()
        }
        .help("More")
        .accessibilityLabel("More")
    }
}

private extension View {
    /// White capsule with a hairline used by the navigation controls.
    func navPill() -> some View {
        background(AOMTheme.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(AOMTheme.hairline, lineWidth: 0.75))
            .contentShape(Capsule())
    }
}

// MARK: - Popup menu button

/// One entry of an `AOMPopupMenu`.
struct AOMMenuItem {
    enum Kind {
        case action(() -> Void)
        case toggle(Bool, (Bool) -> Void)
        case divider
    }
    var title = ""
    var systemImage: String?
    var checked = false
    var kind: Kind

    static func action(_ title: String, systemImage: String? = nil, checked: Bool = false,
                       _ handler: @escaping () -> Void) -> AOMMenuItem {
        AOMMenuItem(title: title, systemImage: systemImage, checked: checked, kind: .action(handler))
    }
    static func toggle(_ title: String, isOn: Bool, _ handler: @escaping (Bool) -> Void) -> AOMMenuItem {
        AOMMenuItem(title: title, checked: isOn, kind: .toggle(isOn, handler))
    }
    static var divider: AOMMenuItem { AOMMenuItem(kind: .divider) }
}

/// A fully custom-styled button that opens a native menu anchored under it.
/// SwiftUI's `Menu` drops label backgrounds on macOS, so the glass/filled
/// pills in the navigation row present an `NSMenu` themselves.
struct AOMPopupMenu<Label: View>: View {
    let items: () -> [AOMMenuItem]
    @ViewBuilder var label: Label
    @State private var frame: CGRect = .zero

    init(items: @escaping () -> [AOMMenuItem], @ViewBuilder label: () -> Label) {
        self.items = items
        self.label = label()
    }

    var body: some View {
        Button(action: present) { label }
            .buttonStyle(AOMCardButtonStyle())
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { frame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, value in frame = value }
                }
            }
    }

    private final class Handler: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke() { run() }
    }

    private func present() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var handlers: [Handler] = []
        for entry in items() {
            switch entry.kind {
            case .divider:
                menu.addItem(.separator())
            case .action(let run):
                let handler = Handler(run)
                handlers.append(handler)
                let item = NSMenuItem(title: entry.title, action: #selector(Handler.invoke), keyEquivalent: "")
                item.target = handler
                item.state = entry.checked ? NSControl.StateValue.on : NSControl.StateValue.off
                if let symbol = entry.systemImage { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(item)
            case .toggle(let isOn, let set):
                let handler = Handler { set(!isOn) }
                handlers.append(handler)
                let item = NSMenuItem(title: entry.title, action: #selector(Handler.invoke), keyEquivalent: "")
                item.target = handler
                item.state = isOn ? NSControl.StateValue.on : NSControl.StateValue.off
                menu.addItem(item)
            }
        }
        // Anchor under the control's leading edge; fall back to the pointer.
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let anchor: NSPoint
        if let window, frame != .zero {
            anchor = NSPoint(x: window.frame.minX + frame.minX, y: window.frame.maxY - frame.maxY - 6)
        } else {
            anchor = NSEvent.mouseLocation
        }
        menu.popUp(positioning: nil, at: anchor, in: nil)
        withExtendedLifetime(handlers) {}
    }
}

// MARK: - Window dragging

/// Empty space in the navigation row behaves like a title bar: drag to move,
/// double-click for the user's title-bar action (zoom, minimise or nothing).
struct AOMWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
