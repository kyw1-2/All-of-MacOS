import AppKit
import SwiftUI

/// The main window in the macOS arrangement: a system sidebar for the six
/// places, the selected page in the detail column with its own contextual
/// toolbar (title, view switch, search, create), and the optional diagnostics
/// drawer. Global navigation and page tools no longer share one row.
///
/// 2.2: the window itself is glass — a behind-window sidebar blur shows the
/// desktop through the chrome (sidebar, toolbar) while the page floats as an
/// inset opaque card, the System Settings / Things arrangement. Transparency
/// and contrast accessibility settings restore the opaque window.
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

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

    /// Glass chrome needs the window non-opaque; accessibility settings
    /// substitute the plain opaque window.
    private var wantsGlass: Bool { !reduceTransparency && contrast != .increased }

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
            .background(AOMTheme.pane)
            // The page floats as an inset card on the glass: rounded, edged
            // and softly lifted, with the toolbar left on the material above.
            .clipShape(RoundedRectangle(cornerRadius: AOMTheme.windowContentRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AOMTheme.windowContentRadius, style: .continuous)
                    .strokeBorder(AOMTheme.hairline, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.06), radius: 16, y: 4)
            .padding([.leading, .bottom, .trailing], AOMSpace.xs + 2)
            .navigationTitle(appState.selectedMainTab.title)
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            if wantsGlass {
                // Behind-window blur under the whole window: the sidebar and
                // the toolbar pick it up; the opaque page card sits on top.
                VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                TranslucentWindow().frame(width: 0, height: 0)
            } else {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            }
        }
        .background(AOMMainWindowChrome(appearance: appearance).frame(width: 0, height: 0))
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
    }
}

// MARK: - Sidebar

/// Navigation only: search at the top, the six places, and the engine switch
/// with Settings and Help at the bottom. Scopes, filters and pinboards live
/// inside the page they filter.
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
            }
            Section("Activity") {
                navigationItem(.insights)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 19, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(AOMTheme.text)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AOM").font(.system(size: 18, weight: .semibold)).tracking(-0.6)
                        Text("All of MacOS").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                searchButton
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .accessibilityElement(children: .contain)
    }

    private func navigationItem(_ tab: AOMMainTab) -> some View {
        Label {
            Text(tab.title).font(.system(size: 13, weight: .medium))
                .padding(.leading, 3)
        } icon: {
            Image(systemName: tab.sidebarSymbol)
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.hierarchical)
        }
        .frame(minHeight: 28)
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
            .frame(height: 30)
            .background(AOMTheme.track.opacity(0.7), in: RoundedRectangle(cornerRadius: AOMTheme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AOMTheme.controlRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
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
                .controlSize(.small)
                .accessibilityLabel("Automation engine")
                .help(on ? "Pause every gesture and shortcut" : "Resume automation")
            Menu {
                Button("Settings…") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Toggle("Diagnostics Console", isOn: $showLog)
                Toggle("Touch Visualizer", isOn: $showTouchVisualizer)
                Divider()
                Button("Show Onboarding Again") { appState.showTutorialRequested = true }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings, diagnostics and help")
            .accessibilityLabel("Settings and Help")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
