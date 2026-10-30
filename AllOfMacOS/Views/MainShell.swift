import AppKit
import SwiftUI

/// The main window in the macOS arrangement (d.6–d.8): the system sidebar for
/// the eight places, the selected page in the detail column with its own
/// contextual toolbar (title, filter, one primary action), and the optional
/// diagnostics drawer.
///
/// The frame is the system's: macOS 26+ floats the sidebar as Liquid Glass and
/// the toolbar picks up the automatic scroll edge effect over the one opaque
/// page canvas, so AOM draws no window material, bar background or footer of
/// its own. Global controls live where macOS puts them: Pause AOM in the
/// Workspace hero, the menu-bar extra and Controls › Pause AOM; Settings in
/// the app menu (⌘,); Diagnostics Console and Touch Visualizer in the Window
/// menu; Show Welcome Again in Help.
struct AOMMainShell<Content: View>: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @Binding var showLog: Bool
    @Binding var showTouchVisualizer: Bool
    var appearance: String
    let content: Content
    /// The sidebar is collapsible (toolbar button, View ▸ Hide Sidebar) and
    /// remembers its state.
    @AppStorage("AOMSidebarVisible") private var sidebarVisible = true

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

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarVisible ? .all : .detailOnly },
                set: { sidebarVisible = $0 != .detailOnly })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            AOMSidebar(showingCommandPalette: $showingCommandPalette)
                .navigationSplitViewColumnWidth(min: AOMSize.sidebarMin, ideal: AOMSize.sidebarIdeal,
                                                max: AOMSize.sidebarMax)
                .tutorialAnchor(.sidebar)
        } detail: {
            GeometryReader { geometry in
                let drawerOpen = showLog || showTouchVisualizer
                // Beside the page when there is room; otherwise it floats over
                // the trailing edge (an inspector-style overlay) instead of
                // squeezing the page below its usable width.
                let sideBySide = geometry.size.width >= AOMSize.drawerSideBySideMinimum
                let drawerWidth = min(AOMSize.drawerWidth.upperBound,
                                      max(AOMSize.drawerWidth.lowerBound, geometry.size.width * 0.32))
                HStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Compact density for every page (3.3.5): 12 pt text
                        // and small controls unless a view asks for more.
                        .font(AOMFont.body)
                        .controlSize(.small)
                    if drawerOpen && sideBySide {
                        AOMDivider(axis: .vertical)
                        DiagnosticDrawerView(showLog: $showLog, showTouchVisualizer: $showTouchVisualizer)
                            .frame(width: drawerWidth)
                            .background(AOMColor.canvas)
                            .font(AOMFont.body)
                            .controlSize(.small)
                    }
                }
                .overlay(alignment: .trailing) {
                    if drawerOpen && !sideBySide {
                        DiagnosticDrawerView(showLog: $showLog, showTouchVisualizer: $showTouchVisualizer)
                            .frame(width: drawerWidth)
                            .frame(maxHeight: .infinity)
                            .font(AOMFont.body)
                            .controlSize(.small)
                            .background(AOMColor.raised)
                            .overlay(alignment: .leading) { AOMDivider(axis: .vertical) }
                            .aomElevation(.raised)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AOMWorkspaceBackground())
            .navigationTitle(appState.selectedMainTab.title)
            .modifier(AOMCompactToolbarTitle(title: appState.selectedMainTab.title))
        }
        .navigationSplitViewStyle(.balanced)
        .background(AOMMainWindowChrome(appearance: appearance).frame(width: 0, height: 0))
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    }
}

// MARK: - Sidebar

/// Navigation only (d.6): the search field at the top (the visible way into
/// ⌘K), then Workspace, Tools and Activity. Badges appear only for states that
/// aren't normal ("Paused", "Rec", "Off", a count of problems to fix), in the
/// one status pill. Icons stay the system accent; module hues never appear
/// here. No footer: global controls moved to the hero and the menus.
struct AOMSidebar: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool

    private var selection: Binding<AOMMainTab?> {
        Binding(get: { appState.selectedMainTab },
                set: { if let tab = $0, tab != appState.selectedMainTab { appState.selectedMainTab = tab } })
    }

    var body: some View {
        List(selection: selection) {
            navigationItem(.home)
            Section("Tools") {
                navigationItem(.gestures)
                navigationItem(.snapping)
                navigationItem(.capture)
                navigationItem(.clipboard)
                navigationItem(.audio)
                navigationItem(.tools)
            }
            Section("Activity") {
                navigationItem(.insights)
            }
        }
        .listStyle(.sidebar)
        // Small rows (about 24 pt) like Finder's small sidebar setting.
        .environment(\.sidebarRowSize, .small)
        .safeAreaInset(edge: .top, spacing: 0) {
            AOMSidebarSearchButton(showingCommandPalette: $showingCommandPalette)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusBadge(for tab: AOMMainTab) -> some View {
        switch tab {
        case .home: AOMWorkspaceSidebarBadge()
        case .gestures:
            if !appState.globalEnabled { AOMSidebarStatusBadge(text: "Paused", tone: .neutral) }
        case .capture: AOMRecordingSidebarBadge()
        case .clipboard: AOMClipboardSidebarBadge()
        case .audio: AOMAudioSidebarBadge()
        default: EmptyView()
        }
    }

    /// System sidebar rows: the platform's font, row height and selection,
    /// so the floating Liquid Glass sidebar matches Finder, Mail and Notes.
    private func navigationItem(_ tab: AOMMainTab) -> some View {
        HStack(spacing: 0) {
            Label {
                Text(tab.title).font(AOMFont.body)
            } icon: {
                Image(systemName: tab.sidebarSymbol).font(.system(size: 12))
            }
            Spacer(minLength: AOMSpace.x1)
            statusBadge(for: tab)
        }
        .tag(tab)
        .help("\(tab.title) — ⌘\(tab.shortcutKey.character)")
    }
}

/// The way into ⌘K, drawn like the system's sidebar search field: one
/// standard 28 pt capsule whose fill and label deepen under the pointer,
/// aligned with the selection inset of the rows below. Its own view, so
/// hovering never re-evaluates the sidebar list.
private struct AOMSidebarSearchButton: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        Button { showingCommandPalette = true } label: {
            HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Text("Search").font(AOMFont.body)
                Spacer(minLength: AOMSpace.x1)
                AOMKeycap(text: AOMPaletteShortcut.current(appState.currentPreset).displayString)
            }
            .foregroundStyle(hovering ? AOMColor.text : AOMColor.textSecondary)
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: AOMIcon.hitArea + AOMSpace.x0_5)
            .background(hovering ? AOMColor.sunken : AOMColor.track, in: Capsule())
            .overlay {
                Capsule().strokeBorder(contrast == .increased ? AOMColor.strongLine : AOMColor.hairline,
                                       lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .aomAnimation(.quick, value: hovering)
        .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5)
        .padding(.top, AOMSpace.x1)
        .padding(.bottom, AOMSpace.x1)
        .help("Search pages, settings and actions")
        .accessibilityLabel("Search")
    }
}

/// The page title in the toolbar at 13 pt semibold instead of the system's
/// larger title (macOS 26+, where the default title item can be replaced). The window
/// title stays `navigationTitle`, so Mission Control and the Window menu
/// still name the page.
/// A page's one-line context beside the toolbar title ("All Apps · 3 of 5
/// on"). Pages set it with `aomToolbarSubtitle(_:)`; the shell draws it.
struct AOMToolbarSubtitleKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) { value = nextValue() ?? value }
}

extension View {
    /// The page's context line in the compact toolbar title. Also sets the
    /// window subtitle, so macOS 14 (system title) shows it too.
    func aomToolbarSubtitle(_ subtitle: String) -> some View {
        navigationSubtitle(subtitle)
            .preference(key: AOMToolbarSubtitleKey.self, value: subtitle.isEmpty ? nil : subtitle)
    }
}

private struct AOMCompactToolbarTitle: ViewModifier {
    let title: String
    @State private var subtitle: String?

    func body(content: Content) -> some View {
        titled(content)
            .onPreferenceChange(AOMToolbarSubtitleKey.self) { value in
                if value != subtitle { subtitle = value }
            }
    }

    @ViewBuilder
    private func titled(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // A plain label, not a glass capsule: a title is not a control.
            // The flexible space stands in for the one the system title
            // brought, so each page's actions stay at the trailing edge.
            content
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .navigation) { label }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible)
                }
        } else {
            // macOS 14–15: the system title (no toolbar spacer before 26).
            content
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
            Text(title)
                .font(AOMFont.pageStatus)
                .foregroundStyle(AOMColor.text)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, AOMSpace.x1)
    }
}

// MARK: - Menu commands for the shell

/// What the main window offers to the menu bar: the master switch and the
/// diagnostics drawer. Published by `MainWindow` as a focused scene value and
/// read by `AOMShellCommandMenus` (inside `TriggerEditorCommands`, which the
/// app already installs).
struct AOMShellCommandActions {
    var engineOn: Bool
    var toggleEngine: () -> Void
    var showLog: Bool
    var setShowLog: (Bool) -> Void
    var showTouchVisualizer: Bool
    var setShowTouchVisualizer: (Bool) -> Void
}

private struct AOMShellCommandsKey: FocusedValueKey { typealias Value = AOMShellCommandActions }

extension FocusedValues {
    var aomShellCommands: AOMShellCommandActions? {
        get { self[AOMShellCommandsKey.self] }
        set { self[AOMShellCommandsKey.self] = newValue }
    }
}

/// Controls › Pause AOM / Resume AOM, and Window › Diagnostics Console and
/// Touch Visualizer (these moved out of the sidebar footer).
struct AOMShellCommandMenus: Commands {
    @FocusedValue(\.aomShellCommands) private var shell

    var body: some Commands {
        CommandMenu("Controls") {
            Button(shell?.engineOn == false ? "Resume AOM" : "Pause AOM") { shell?.toggleEngine() }
                .disabled(shell == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            Toggle("Diagnostics Console", isOn: Binding(get: { shell?.showLog ?? false },
                                                        set: { shell?.setShowLog($0) }))
                .disabled(shell == nil)
            Toggle("Touch Visualizer", isOn: Binding(get: { shell?.showTouchVisualizer ?? false },
                                                     set: { shell?.setShowTouchVisualizer($0) }))
                .disabled(shell == nil)
        }
    }
}

// MARK: - Command palette shortcut

/// The palette's key equivalent. ⌘K unless an enabled automation or a global
/// capture/clipboard shortcut already owns it — those fire before the menu
/// bar sees the key — then the first free alternative.
enum AOMPaletteShortcut {
    static let candidates: [KeyboardShortcut] = [
        KeyboardShortcut(keyCode: 40, modifiers: [.command]),
        KeyboardShortcut(keyCode: 40, modifiers: [.command, .shift]),
        KeyboardShortcut(keyCode: 40, modifiers: [.command, .option]),
        KeyboardShortcut(keyCode: 35, modifiers: [.command, .shift])
    ]

    static func resolve(taken: Set<KeyboardShortcut>) -> KeyboardShortcut {
        candidates.first { !taken.contains($0) } ?? candidates[0]
    }

    @MainActor
    static func current(_ preset: Preset) -> KeyboardShortcut {
        var taken = Set(preset.triggers.compactMap { trigger -> KeyboardShortcut? in
            guard trigger.isEnabled, case .keyboardShortcut(let shortcut) = trigger.input else { return nil }
            return shortcut
        })
        for command in ClipboardShortcuts.Command.allCases {
            if let shortcut = ClipboardShortcuts.shared.shortcut(for: command) { taken.insert(shortcut) }
        }
        for action in CaptureShortcutAction.allCases {
            if let shortcut = CaptureShortcuts.shared.shortcut(for: action) { taken.insert(shortcut) }
        }
        return resolve(taken: taken)
    }

    /// The SwiftUI key equivalent for a candidate (letters only).
    static func keyEquivalent(_ shortcut: KeyboardShortcut) -> (KeyEquivalent, EventModifiers) {
        let key: KeyEquivalent = shortcut.keyCode == 35 ? "p" : "k"
        var modifiers: EventModifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        return (key, modifiers)
    }
}

// MARK: - Sidebar badges

// Only the small status badge observes recording ticks/clipboard updates.
// Navigation selection and the full List no longer redraw for these events.

/// A sidebar badge: the one status pill.
private struct AOMSidebarStatusBadge: View {
    let text: String
    var tone: AOMTone = .neutral
    var symbol: String?

    var body: some View {
        AOMStatusPill(text, tone: tone, symbol: symbol)
    }
}

/// Workspace: the number of problems that need fixing now (missing
/// permissions), polled like the Workspace hero does.
private struct AOMWorkspaceSidebarBadge: View {
    @State private var missing = 0

    var body: some View {
        HStack(spacing: 0) {
            if missing > 0 {
                AOMSidebarStatusBadge(text: "\(missing)", tone: .warning, symbol: "exclamationmark.triangle.fill")
                    .accessibilityLabel("\(missing) to fix")
                    .help(missing == 1 ? "1 permission needs your attention" : "\(missing) permissions need your attention")
            }
        }
        .task {
            while !Task.isCancelled {
                let count = AOMPermission.required.filter { [.denied, .notDetermined].contains($0.status) }.count
                if count != missing { missing = count }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct AOMRecordingSidebarBadge: View {
    @ObservedObject private var recording = ScreenRecordingService.shared
    var body: some View {
        if recording.isRecording {
            AOMSidebarStatusBadge(text: recording.isPaused ? "Paused" : "Rec", tone: .recording)
        }
    }
}

private struct AOMClipboardSidebarBadge: View {
    @ObservedObject private var clipboard = ClipboardStore.shared
    var body: some View {
        if clipboard.paused { AOMSidebarStatusBadge(text: "Paused", tone: .neutral) }
    }
}

private struct AOMAudioSidebarBadge: View {
    @ObservedObject private var audio = AppAudioMixerService.shared
    var body: some View {
        if !audio.soundEnabled { AOMSidebarStatusBadge(text: "Off", tone: .neutral) }
        else if audio.airPlayBypassed { AOMSidebarStatusBadge(text: "Direct", tone: .neutral) }
        else if audio.airPlayProcessingActive { AOMSidebarStatusBadge(text: "AirPlay", tone: .success) }
        else if audio.eqEnabled || audio.allAppsBoostEnabled {
            AOMSidebarStatusBadge(text: "Effects", tone: .success)
        }
    }
}
