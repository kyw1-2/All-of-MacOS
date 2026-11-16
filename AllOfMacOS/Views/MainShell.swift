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
            AOMSidebarHost(appState: appState,
                           engineOn: appState.globalEnabled,
                           snappingOn: appState.currentPreset.snappingEnabled,
                           paletteKeys: AOMPaletteShortcut.current(appState.currentPreset).displayString,
                           showingCommandPalette: $showingCommandPalette)
                .navigationSplitViewColumnWidth(min: AOMSize.sidebarMin, ideal: AOMSize.sidebarIdeal,
                                                max: AOMSize.sidebarMax)
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
                        // Body text and regular controls for every page
                        // (design-3.3.6 b.1, b.6); dense tables opt into small.
                        .font(AOMFont.body)
                    if drawerOpen && sideBySide {
                        AOMDivider(axis: .vertical)
                        DiagnosticDrawerView(showLog: $showLog, showTouchVisualizer: $showTouchVisualizer)
                            .frame(width: drawerWidth)
                            .background(AOMColor.pageBackground)
                            .font(AOMFont.body)
                    }
                }
                .overlay(alignment: .trailing) {
                    if drawerOpen && !sideBySide {
                        DiagnosticDrawerView(showLog: $showLog, showTouchVisualizer: $showTouchVisualizer)
                            .frame(width: drawerWidth)
                            .frame(maxHeight: .infinity)
                            .font(AOMFont.body)
                            .background(AOMColor.raised)
                            .overlay(alignment: .leading) { AOMDivider(axis: .vertical) }
                            .aomElevation(.raised)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AOMWorkspaceBackground())
            // 5.0: the Raycast-style action bar under every page.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AOMActionBar(appState: appState,
                             paletteKeys: AOMPaletteShortcut.current(appState.currentPreset).displayString,
                             showingCommandPalette: $showingCommandPalette)
            }
            // The system toolbar title (design-3.3.6 b.11): standard size,
            // with the page's subtitle from `aomToolbarSubtitle`.
            .modifier(AOMShellTitle())
            // Back and Forward beside the title (System Settings, Finder's Go
            // menu; design-3.4.0 b.3, #228–#229, #233).
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    AOMHistoryButtons(appState: appState)
                }
                // Search Everything lives in the sidebar and in the action
                // bar under every page (5.0), so it stays one click away
                // with the sidebar hidden, without a third toolbar copy.
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Toggle("Diagnostics Console", isOn: $showLog)
                        Toggle("Touch Visualizer", isOn: $showTouchVisualizer)
                    } label: { Label("Inspect", systemImage: "sidebar.right") }
                    .help("Diagnostics and touch visualizer")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(AOMMainWindowChrome(appearance: appearance).frame(width: 0, height: 0))
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    }
}

// MARK: - Sidebar

/// The only part of the sidebar column that observes the selected page, so a
/// page change compares the sidebar's values instead of re-rendering the shell.
private struct AOMSidebarHost: View {
    let appState: AppState
    let engineOn: Bool
    let snappingOn: Bool
    let paletteKeys: String
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var navigation = AOMNavigation.shared

    var body: some View {
        AOMSidebar(appState: appState,
                   selected: navigation.selected,
                   engineOn: engineOn,
                   snappingOn: snappingOn,
                   paletteKeys: paletteKeys,
                   showingCommandPalette: $showingCommandPalette)
            .equatable()
    }
}

/// The window title from the selected page and the subtitle the active page
/// reports through `AOMToolbarSubtitleKey`. Set once here: with several pages
/// alive, page-level titles would compete.
private struct AOMShellTitle: ViewModifier {
    @ObservedObject private var navigation = AOMNavigation.shared
    @State private var subtitle = ""

    func body(content: Content) -> some View {
        content
            .navigationTitle(navigation.selected.title)
            .navigationSubtitle(subtitle)
            .onPreferenceChange(AOMToolbarSubtitleKey.self) { value in
                let text = value ?? ""
                if text != subtitle { subtitle = text }
            }
    }
}

/// Navigation only, the way Finder, Mail and Notes draw it: the search field
/// at the top (the visible way into ⌘K), then outline symbols the system
/// tints with the accent. Badges are plain trailing text and appear only for
/// states that aren't normal ("Paused", "Rec", "Off", a count to fix). No
/// footer: Pause lives in the Workspace header, the menu-bar extra and
/// Controls › Pause AOM; the drawers in the Window menu; Settings at ⌘,.
///
/// It takes the few values it draws instead of observing AppState, and
/// `==` compares them, so selecting an automation, typing a search or any
/// other app-state change no longer reconfigures every sidebar row.
struct AOMSidebar: View, Equatable {
    /// Not observed: only written to (selection, menu toggles).
    let appState: AppState
    let selected: AOMMainTab
    let engineOn: Bool
    let snappingOn: Bool
    let paletteKeys: String
    @Binding var showingCommandPalette: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selected == rhs.selected && lhs.engineOn == rhs.engineOn
            && lhs.snappingOn == rhs.snappingOn && lhs.paletteKeys == rhs.paletteKeys
    }

    private var selection: Binding<AOMMainTab?> {
        Binding(get: { selected },
                set: { if let tab = $0, tab != appState.selectedMainTab { appState.selectedMainTab = tab } })
    }

    @ObservedObject private var layout = AOMWorkspaceLayout.shared
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        List(selection: selection) {
            navigationItem(.home)
            ForEach(AOMFeatureGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.tabs) { tab in navigationItem(tab) }
                }
            }
        }
        .listStyle(.sidebar)
        // Row height, text and glyph size follow the sidebar size chosen in
        // System Settings › Appearance (HIG Sidebars), so no override here.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                AOMSidebarHeader(engineOn: engineOn) { appState.toggleGlobalEnabled() }
                AOMSidebarSearchButton(keys: paletteKeys, showingCommandPalette: $showingCommandPalette)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: AOMSpace.x1) {
                Divider()
                Button { openSettings() } label: {
                    HStack(spacing: AOMSpace.x2) {
                        AOMAppIcon(.neutral("gearshape.fill"), size: AOMIcon.identityRow)
                        Text("Settings")
                        Spacer()
                        AOMKeycap(text: "⌘,")
                    }.padding(.horizontal, AOMSpace.x2).padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
                        .contentShape(Rectangle())
                }.buttonStyle(AOMRowButtonStyle())
            }.padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5).padding(.bottom, AOMSpace.x2)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusBadge(for tab: AOMMainTab) -> some View {
        switch tab {
        case .home: AOMWorkspaceSidebarBadge()
        case .gestures:
            if !engineOn { AOMSidebarStatusBadge(text: "Paused", tone: .neutral) }
        case .capture: AOMRecordingSidebarBadge()
        case .clipboard: AOMClipboardSidebarBadge()
        case .audio: AOMAudioSidebarBadge()
        case .folderRules, .textActions, .files, .focus:
            if let module = AOMModule(tab: tab), let status = AOMModuleStatusBoard.status(for: module) {
                AOMModuleSidebarBadge(status: status)
            }
        default: EmptyView()
        }
    }

    /// The row's context menu (design-3.4.0 b.4): open, the module's own
    /// switch as a checked item, and whether Workspace shows its tile.
    @ViewBuilder
    private func rowMenu(_ tab: AOMMainTab) -> some View {
        Button("Open \(tab.title)") { appState.selectedMainTab = tab }
        switch tab {
        case .gestures:
            Toggle("Automation", isOn: Binding(get: { engineOn },
                                               set: { if $0 != appState.globalEnabled { appState.toggleGlobalEnabled() } }))
        case .snapping:
            Toggle("Drag to Snap", isOn: Binding(get: { snappingOn },
                                                 set: { appState.setSnappingEnabled($0) }))
                .disabled(!engineOn)
        case .clipboard:
            Toggle("Clipboard History", isOn: Binding(get: { !ClipboardStore.shared.paused },
                                                      set: { $0 ? ClipboardStore.shared.resume() : ClipboardStore.shared.pause() }))
        case .audio:
            if AppAudioMixerService.shared.isSupported {
                Toggle("App Audio", isOn: Binding(get: { AppAudioMixerService.shared.soundEnabled },
                                                  set: { AppAudioMixerService.shared.soundEnabled = $0 }))
            }
        case .folderRules, .textActions, .files, .focus:
            if let module = AOMModule(tab: tab), let status = AOMModuleStatusBoard.status(for: module),
               status.isOn != nil, let setOn = status.setOn {
                Toggle(module.title, isOn: Binding(get: { status.isOn ?? false }, set: { setOn($0) }))
            }
        default:
            EmptyView()
        }
        if let module = AOMModule(tab: tab) {
            let id = AOMWorkspaceLayout.tileID(module)
            let hidden = layout.hidden.contains(id)
            Divider()
            Button(hidden ? "Show on Workspace" : "Hide from Workspace") {
                layout.change(hidden ? "Show Tile" : "Hide Tile", undoManager: undoManager) { $0.setHidden(id, !hidden) }
            }
        }
    }

    /// A system sidebar row: the outline symbol (accent-tinted by the list),
    /// the page title and, only when something is off-normal, a trailing
    /// status word.
    private func navigationItem(_ tab: AOMMainTab) -> some View {
        Label {
            HStack(spacing: AOMSpace.x2) {
                Text(tab.title).lineLimit(1)
                Spacer(minLength: AOMSpace.x1)
                statusBadge(for: tab)
            }
        } icon: {
            // 5.0: the tool's identity mark (System Settings, Loop), so a
            // destination is found by colour and shape before its name.
            AOMAppIcon(tab, size: AOMIcon.identityRow,
                       active: tab == .gestures ? engineOn : true)
        }
        .tag(tab)
        .help(tab.shortcutKey.map { "\(tab.title) — ⌘\($0.character)" } ?? tab.title)
        .contextMenu { rowMenu(tab) }
    }
}

// MARK: - Navigation history

/// Back and Forward in the toolbar. Only these two buttons observe the
/// history, so recording a page change redraws them, not the shell. They
/// also follow the selected page, which keeps the Back/Forward help current.
private struct AOMHistoryButtons: View {
    let appState: AppState
    @ObservedObject private var history = AOMNavigationHistory.shared
    @ObservedObject private var navigation = AOMNavigation.shared

    var body: some View {
        Button { history.goBack(appState) } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .disabled(!history.canGoBack)
        .help(history.backTarget.map { "Back to \($0.title) (⌘[)" } ?? "Back (⌘[)")
        Button { history.goForward(appState) } label: {
            Label("Forward", systemImage: "chevron.right")
        }
        .disabled(!history.canGoForward)
        .help(history.forwardTarget.map { "Forward to \($0.title) (⌘])" } ?? "Forward (⌘])")
    }
}

/// Back and Forward through the pages (Finder's Go menu, System Settings'
/// View menu): every page change is recorded, at most 50, and ⌘[ / ⌘] and
/// the toolbar chevrons walk it. A change made by Back or Forward itself is
/// not recorded again.
///
/// Only `canGoBack` and `canGoForward` are published, and only when they
/// change, so recording an ordinary page change publishes nothing.
@MainActor
final class AOMNavigationHistory: ObservableObject {
    static let shared = AOMNavigationHistory()
    static let limit = 50

    private(set) var backStack: [AOMMainTab] = [] { didSet { publishAvailability() } }
    private(set) var forwardStack: [AOMMainTab] = [] { didSet { publishAvailability() } }
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The page Back or Forward is about to select.
    private var pending: AOMMainTab?

    var backTarget: AOMMainTab? { backStack.last }
    var forwardTarget: AOMMainTab? { forwardStack.last }

    private func publishAvailability() {
        if canGoBack == backStack.isEmpty { canGoBack = !backStack.isEmpty }
        if canGoForward == forwardStack.isEmpty { canGoForward = !forwardStack.isEmpty }
    }

    /// Called for every page change.
    func record(from old: AOMMainTab, to new: AOMMainTab) {
        guard old != new else { return }
        if pending == new {
            pending = nil
            return
        }
        pending = nil
        var back = backStack
        back.append(old)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        backStack = back
        if !forwardStack.isEmpty { forwardStack.removeAll() }
    }

    /// The next page change to `tab` is not a visit (launch restore).
    func skipRecording(_ tab: AOMMainTab) { pending = tab }

    /// Pops the page Back goes to; the caller selects it.
    func back(from current: AOMMainTab) -> AOMMainTab? {
        guard let target = backStack.popLast() else { return nil }
        forwardStack.append(current)
        pending = target
        return target
    }

    func forward(from current: AOMMainTab) -> AOMMainTab? {
        guard let target = forwardStack.popLast() else { return nil }
        backStack.append(current)
        pending = target
        return target
    }

    func goBack(_ appState: AppState) {
        if let target = back(from: appState.selectedMainTab) { appState.selectedMainTab = target }
    }

    func goForward(_ appState: AppState) {
        if let target = forward(from: appState.selectedMainTab) { appState.selectedMainTab = target }
    }
}

/// View ▸ Back and Forward. Its own view, so the App's scene body does not
/// observe the history.
struct AOMHistoryMenuItems: View {
    let appState: AppState
    let showMainWindow: () -> Void
    @ObservedObject private var history = AOMNavigationHistory.shared

    var body: some View {
        Button("Back") {
            showMainWindow()
            history.goBack(appState)
        }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!history.canGoBack)
        Button("Forward") {
            showMainWindow()
            history.goForward(appState)
        }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!history.canGoForward)
    }
}

/// The top of the sidebar (5.0): the app's brand mark, its name, whether AOM
/// is running, and the master switch — the control-centre header of
/// Bartender, Ice and CleanShot's menus, so Pause is one click from every page.
private struct AOMSidebarHeader: View {
    let engineOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: AOMSpace.x2 + AOMSpace.x0_5) {
            AOMAppIcon(AOMMainTab.home.identity, size: 30, active: engineOn)
            VStack(alignment: .leading, spacing: 0) {
                Text("All of MacOS")
                    .font(AOMFont.bodyEmphasis)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                HStack(spacing: AOMSpace.x1) {
                    Circle()
                        .fill(engineOn ? AOMColor.success : AOMColor.paused)
                        .frame(width: AOMIcon.dot, height: AOMIcon.dot)
                    Text(engineOn ? "Running" : "Paused")
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                }
            }
            Spacer(minLength: AOMSpace.x1)
            Toggle("AOM", isOn: Binding(get: { engineOn }, set: { if $0 != engineOn { toggle() } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(engineOn ? "Pause AOM — gestures, shortcuts and automations stop" : "Resume AOM")
                .accessibilityLabel("AOM running")
        }
        .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5 + AOMSpace.x1)
        .padding(.top, AOMSpace.x1)
        .accessibilityElement(children: .contain)
    }
}

/// The way into ⌘K, drawn like the system's sidebar search field: one
/// standard 28 pt capsule whose fill and label deepen under the pointer,
/// aligned with the selection inset of the rows below. Its own view, so
/// hovering never re-evaluates the sidebar list.
private struct AOMSidebarSearchButton: View {
    let keys: String
    @Binding var showingCommandPalette: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        VStack(spacing: AOMSpace.x2) {
            Button { showingCommandPalette = true } label: {
                HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                    Image(systemName: "magnifyingglass")
                        .imageScale(.medium)
                    Text("Search Everything").font(AOMFont.callout)
                    Spacer(minLength: AOMSpace.x1)
                    AOMKeycap(text: keys)
                }
                .foregroundStyle(hovering ? AOMColor.text : AOMColor.textSecondary)
                .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5)
                .frame(height: AOMSize.rowStandard)
                .background(hovering ? AOMColor.surfaceHover : AOMColor.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(contrast == .increased ? AOMColor.strongLine : AOMColor.hairline,
                                           lineWidth: contrast == .increased ? 1 : 0.5)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .aomAnimation(.quick, value: hovering)
            .help("Search pages, settings and actions")
            .accessibilityLabel("Search Everything")
        }
        .padding(.horizontal, AOMSpace.x2 + AOMSpace.x0_5)
        .padding(.top, AOMSpace.x2)
        .padding(.bottom, AOMSpace.x2)
    }
}

/// A page's one-line context under the toolbar title ("All Apps · 3 of 5
/// on"). Pages set it with `aomToolbarSubtitle(_:)`; the shell
/// (`AOMShellTitle`) draws it as the window subtitle.
struct AOMToolbarSubtitleKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) { value = nextValue() ?? value }
}

extension View {
    /// The page's context line: the window subtitle under the system title.
    /// A page kept alive behind the selected one reports none.
    func aomToolbarSubtitle(_ subtitle: String) -> some View {
        modifier(AOMToolbarSubtitle(subtitle: subtitle))
    }
}

private struct AOMToolbarSubtitle: ViewModifier {
    let subtitle: String
    @Environment(\.aomPageActivity) private var activity

    func body(content: Content) -> some View {
        content.modifier(AOMToolbarSubtitleValue(subtitle: subtitle, activity: activity))
    }
}

/// Observes the page's activity, so only this modifier re-renders on a switch.
private struct AOMToolbarSubtitleValue: ViewModifier {
    let subtitle: String
    @ObservedObject var activity: AOMPageActivity

    func body(content: Content) -> some View {
        content.preference(key: AOMToolbarSubtitleKey.self,
                           value: activity.isActive && !subtitle.isEmpty ? subtitle : nil)
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

/// A sidebar badge: a few words of trailing secondary text, like Mail's
/// counts. Only warnings and recording take their tone's colour (with a
/// glyph for warnings, so colour is never the only signal). On the accent
/// selection of the key window everything turns white.
private struct AOMSidebarStatusBadge: View {
    let text: String
    var tone: AOMTone = .neutral
    var symbol: String?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onSelection = prominence == .increased
        let colour: Color = onSelection ? .white
            : (tone == .warning || tone == .recording || tone == .danger ? tone.textColor : AOMColor.textSecondary)
        HStack(spacing: AOMSpace.x0_5) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).monospacedDigit()
        }
        .font(AOMFont.caption.weight(.medium))
        .foregroundStyle(colour)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
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
                let count = AOMPermission.required.filter { [.denied, .notDetermined].contains(AOMPermissionCache.status($0)) }.count
                if count != missing { missing = count }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// A Productivity module: ⚠ while it needs something (its `attention`),
/// On while a Focus session runs; nothing in the normal state.
private struct AOMModuleSidebarBadge: View {
    @ObservedObject var status: AOMModuleStatus

    var body: some View {
        if let attention = status.attention, !attention.isEmpty {
            AOMSidebarStatusBadge(text: "1", tone: .warning, symbol: "exclamationmark.triangle.fill")
                .help(attention)
                .accessibilityLabel("Needs attention: \(attention)")
        } else if status.module == .focus, FocusModule.isSessionActive {
            AOMSidebarStatusBadge(text: "On", tone: .success)
                .help(status.detail)
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
