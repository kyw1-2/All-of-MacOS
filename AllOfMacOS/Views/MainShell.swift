import AppKit
import SwiftUI

/// The main window in the macOS arrangement: a system sidebar for the six
/// places, the selected page in the detail column with its own contextual
/// toolbar (title, view switch, search, create), and the optional diagnostics
/// drawer. Global navigation and page tools no longer share one row.
///
/// AOM 3: the shell is the system's. macOS 26+ floats the sidebar as Liquid
/// Glass over the page and the toolbar picks up the scroll edge effect, so
/// AOM draws no window material of its own (HIG Sidebars/Toolbars, WWDC25
/// "Build a SwiftUI app with the new design"). Each page paints its canvas
/// edge to edge, under the toolbar.
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
            AOMSidebar(showingCommandPalette: $showingCommandPalette,
                       showLog: $showLog,
                       showTouchVisualizer: $showTouchVisualizer)
                .navigationSplitViewColumnWidth(min: AOMSize.sidebarMin, ideal: AOMSize.sidebarIdeal,
                                                max: AOMSize.sidebarMax)
                .tutorialAnchor(.sidebar)
        } detail: {
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showLog || showTouchVisualizer {
                    AOMDivider(axis: .vertical)
                    DiagnosticDrawerView(showLog: $showLog, showTouchVisualizer: $showTouchVisualizer)
                        .frame(width: 340)
                        .background(AOMTheme.pane)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AOMTheme.workspace)
            .navigationTitle(appState.selectedMainTab.title)
        }
        .navigationSplitViewStyle(.balanced)
        .background(AOMMainWindowChrome(appearance: appearance).frame(width: 0, height: 0))
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    }
}

// MARK: - Sidebar

/// Navigation only: search at the top, the six places with live state where
/// it needs attention (a paused engine, a running recording, paused clipboard
/// history), and the engine switch with Settings and Help at the bottom.
/// Scopes, filters and pinboards live inside the page they filter. No brand
/// block: the window title and toolbar say where you are (HIG Sidebars).
struct AOMSidebar: View {
    @EnvironmentObject var appState: AppState
    @Binding var showingCommandPalette: Bool
    @Binding var showLog: Bool
    @Binding var showTouchVisualizer: Bool
    @Environment(\.openSettings) private var openSettings

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
        .safeAreaInset(edge: .top, spacing: 0) { searchButton }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusBadge(for tab: AOMMainTab) -> some View {
        switch tab {
        case .gestures:
            if !appState.globalEnabled { AOMSidebarStatusBadge(text: "Paused", tint: AOMTheme.warning) }
        case .capture: AOMRecordingSidebarBadge()
        case .clipboard: AOMClipboardSidebarBadge()
        case .audio: AOMAudioSidebarBadge()
        default: EmptyView()
        }
    }

    private func navigationItem(_ tab: AOMMainTab) -> some View {
        HStack(spacing: 0) {
            Label {
                Text(tab.title).font(.system(size: 13, weight: .medium))
                    .padding(.leading, 2)
            } icon: {
                Image(systemName: tab.sidebarSymbol)
                    .font(.system(size: 14, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
            }
            Spacer(minLength: 4)
            statusBadge(for: tab)
        }
        .frame(minHeight: 26)
        .tag(tab)
        .help("\(tab.title) — ⌘\(tab.shortcutKey.character)")
    }

    private var searchButton: some View {
        Button { showingCommandPalette = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                Text("Search").font(AOMType.body)
                Spacer(minLength: 4)
                AOMKeycap(text: AOMPaletteShortcut.current(appState.currentPreset).displayString)
            }
            .foregroundStyle(AOMTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .help("Search commands, automations, clipboard and captures")
        .accessibilityLabel("Search")
    }

    private var footer: some View {
        let on = appState.globalEnabled
        return HStack(spacing: AOMSpace.xs) {
            Circle()
                .fill(on ? AOMTheme.positive : AOMTheme.warning)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(on ? "Automation On" : "Automation Paused")
                .font(AOMType.caption.weight(.medium))
                .foregroundStyle(AOMTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Toggle("Automation", isOn: Binding(get: { appState.globalEnabled },
                                               set: { if $0 != appState.globalEnabled { appState.toggleGlobalEnabled() } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Automation engine")
                .help(on ? "Pause every gesture and shortcut" : "Resume automation")
            Menu {
                Button("Settings…") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Toggle("Diagnostics Console", isOn: $showLog)
                Toggle("Touch Visualizer", isOn: $showTouchVisualizer)
                Divider()
                Button("Show Welcome Again") { appState.showTutorialRequested = true }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings, diagnostics and help")
            .accessibilityLabel("Settings and Help")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

// Only the small status badge observes recording ticks/clipboard updates.
// Navigation selection and the full List no longer redraw for these events.
private struct AOMSidebarStatusBadge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(AOMType.micro.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).frame(height: 17)
            .background(tint.opacity(0.14), in: Capsule()).accessibilityLabel(text)
    }
}
private struct AOMRecordingSidebarBadge: View {
    @ObservedObject private var recording = ScreenRecordingService.shared
    var body: some View {
        if recording.isRecording {
            AOMSidebarStatusBadge(text: recording.isPaused ? "Paused" : "REC", tint: AOMTheme.danger)
        }
    }
}
private struct AOMClipboardSidebarBadge: View {
    @ObservedObject private var clipboard = ClipboardStore.shared
    var body: some View {
        if clipboard.paused { AOMSidebarStatusBadge(text: "Paused", tint: AOMTheme.warning) }
    }
}
private struct AOMAudioSidebarBadge: View {
    @ObservedObject private var audio = AppAudioMixerService.shared
    var body: some View {
        if !audio.soundEnabled { AOMSidebarStatusBadge(text: "Off", tint: AOMTheme.textSecondary) }
        else if audio.airPlayBypassed { AOMSidebarStatusBadge(text: "Direct", tint: AOMTheme.textSecondary) }
        else if audio.airPlayProcessingActive { AOMSidebarStatusBadge(text: "AirPlay FX", tint: AOMTheme.positive) }
        else if audio.eqEnabled || audio.allAppsBoostEnabled {
            AOMSidebarStatusBadge(text: "FX", tint: AOMTheme.positive)
        }
    }
}
