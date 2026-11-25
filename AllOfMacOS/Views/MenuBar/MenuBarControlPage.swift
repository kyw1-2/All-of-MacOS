import AppKit
import ApplicationServices
import SwiftUI

/// The Menu Bar page's panes, in Bartender 7's sidebar order.
enum MenuBarSettingsTab: String, CaseIterable, Identifiable {
    case general, layout, items, bar, hotkeys, advanced, weather, aomMenu
    static let key = "AOMMenuBarSettingsTab"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .layout: return "Menu Bar Items"
        case .items: return "Item Settings"
        case .bar: return "Bar"
        case .hotkeys: return "Hotkeys"
        case .advanced: return "Advanced"
        case .weather: return "Weather"
        case .aomMenu: return "AOM Menu"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .layout: return "menubar.rectangle"
        case .items: return "list.bullet.rectangle"
        case .bar: return "menubar.dock.rectangle"
        case .hotkeys: return "keyboard"
        case .advanced: return "slider.horizontal.3"
        case .weather: return "cloud.sun"
        case .aomMenu: return "slider.horizontal.below.rectangle"
        }
    }
}

/// 7.10: the Menu Bar page after Bartender 7's settings window — a pane per
/// sidebar entry (General, Menu Bar Items, the item list, Bar, Hotkeys,
/// Advanced) plus AOM's own Weather and menu, and the Setup guide the first
/// time it opens.
struct MenuBarControlPage: View {
    @ObservedObject private var modules = AOMModuleSwitches.shared
    @ObservedObject private var layout = MenuBarLayoutModel.shared
    @AppStorage(MenuBarSettingsTab.key) private var tabRaw = MenuBarSettingsTab.layout.rawValue
    @State private var setup = false
    /// 7.18: the first visit shows a banner, not a sheet over the page.
    @AppStorage(MenuBarPrefs.setupKey) private var setupDone = false
    @State private var bannerDismissed = false

    private var tab: MenuBarSettingsTab { MenuBarSettingsTab(rawValue: tabRaw) ?? .layout }
    @State private var sideBySide = true

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .general: MenuBarGeneralPane()
        case .layout:
            AOMSection(padding: 16) { MenuBarLayoutEditor() }
        case .items:
            AOMSection("Menu Bar Items", detail: "What each app's icons do", padding: 14) { MenuBarItemSettingsList() }
        case .bar: MenuBarBarPane()
        case .hotkeys: MenuBarHotkeysPane()
        case .advanced: MenuBarAdvancedPane()
        case .weather: MenuBarWeatherPane()
        case .aomMenu: MenuBarAOMMenuPane()
        }
    }

    var body: some View {
        AOMPage {
            // 7.15 (M01): a state, not the page's name again.
            AOMPageHeader(headline, subtitle: summary, active: modules.isOn(.menuBarHider) || layout.isSample) {
                Button { setup = true } label: { Label("Setup Guide", systemImage: "questionmark.circle") }
                    .controlSize(.small)
            }
            if !setupDone && !bannerDismissed && !PresetManager.isUIPreview {
                AOMNotice(.info, "Set up the menu bar", detail: "A short guide shows Shown, Hidden and Always Hidden and how to move icons.") {
                    Button("Set Up…") { setup = true }.controlSize(.small)
                    AOMIconButton("xmark", label: "Not Now") { bannerDismissed = true }
                }
            }
            // 7.15 (50refs §1, Bartender 7 / Ice preferences): the eight
            // panes as a list beside the pane when the page is wide, a
            // pop-up above it when narrow — not eight squeezed icon tabs.
            let selection = Binding(get: { tab }, set: { tabRaw = $0.rawValue })
            // 7.16 (GPT V06): one layout that changes direction, so the pane
            // keeps its identity (drafts, selection, focus) when the window
            // crosses the width; 16 pt of hysteresis stops flicker at the edge.
            let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: AOMSpace.x4))
                                    : AnyLayout(VStackLayout(alignment: .leading, spacing: AOMSpace.sectionGap))
            layout {
                if sideBySide {
                    MenuBarPaneNavigation(selection: selection)
                        .frame(width: MenuBarPaneNavigation.width)
                } else {
                    MenuBarPaneNavigation.Compact(selection: selection)
                }
                VStack(alignment: .leading, spacing: AOMSpace.sectionGap) { pane }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { sideBySide = MenuBarPaneNavigation.sideBySide(width: geometry.size.width, current: sideBySide) }
                    .onChange(of: geometry.size.width) { _, width in
                        let next = MenuBarPaneNavigation.sideBySide(width: width, current: sideBySide)
                        if next != sideBySide { sideBySide = next }
                    }
            })
        }
        .aomPage("Menu Bar")
        .sheet(isPresented: $setup) { MenuBarSetupGuide { setup = false } }
        .onReceive(NotificationCenter.default.publisher(for: .aomMenuBarSetup)) { _ in setup = true }
        .onAppear {
            if let raw = MenuBarPreviewFlags.tab { tabRaw = raw }
            if MenuBarPreviewFlags.setup { setup = true }
        }
        .aomPageLifecycle(minimumInterval: 20, onActivate: {
            if AXIsProcessTrusted() { layout.refresh(quietly: true) }
        })
    }

    /// One line under the title: is hiding on, and how many apps are where.
    /// 7.16 (GPT V07): off, no Accessibility, not read yet and "nothing
    /// hidden" are different states; apps are counted once across lanes and
    /// items without an owner aren't counted as an app.
    private var headline: String {
        MenuBarHeadline.text(hidingOn: modules.isOn(.menuBarHider) || layout.isSample,
                             canRead: layout.isSample || AXIsProcessTrusted(),
                             readOnce: layout.isSample || layout.lastRefresh != nil,
                             complete: layout.isSample || layout.lastScanComplete,
                             hiddenOwners: ((layout.lanes[.hidden] ?? []) + (layout.lanes[.alwaysHidden] ?? [])).map(\.item.ownerBundleID))
    }

    private var summary: String {
        guard modules.isOn(.menuBarHider) || layout.isSample else { return "Hiding is off — turn it on in General, or follow the Setup Guide." }
        guard layout.isSample || AXIsProcessTrusted() else { return "Allow Accessibility to read menu bar items." }
        guard layout.isSample || layout.lastRefresh != nil else { return "Waiting for the first menu bar scan." }
        guard layout.isSample || layout.lastScanComplete else { return "The last scan was incomplete — refresh to check all items." }
        let lanes = layout.lanes
        let hidden = (lanes[.hidden] ?? []).count, always = (lanes[.alwaysHidden] ?? []).count
        if hidden + always == 0 { return "Nothing hidden in the last scan — drag icons to Hidden in Menu Bar Items." }
        return "\(hidden) item\(hidden == 1 ? "" : "s") hidden · \(always) always hidden · click ❮ in the menu bar to show them"
    }
}

/// Preview flags for the isolated renderer: `--aom-preview-menubar-tab <pane>`
/// and `--aom-preview-menubar-setup`.
enum MenuBarPreviewFlags {
    static var tab: String? {
        guard PresetManager.isUIPreview else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--aom-preview-menubar-tab"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static var setup: Bool { PresetManager.isUIPreview && ProcessInfo.processInfo.arguments.contains("--aom-preview-menubar-setup") }
}

/// Common entry point for status-item context menus and other in-app controls.
@MainActor
enum MenuBarNavigation {
    /// The Menu Bar page; `setup` opens its Setup guide on top.
    static func open(setup: Bool = false, tab: MenuBarSettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: MenuBarSettingsTab.key) }
        AppDelegate.current?.appState?.selectedMainTab = .menuBar
        AppDelegate.current?.showMainWindow()
        if setup { NotificationCenter.default.post(name: .aomMenuBarSetup, object: nil) }
    }
}

extension Notification.Name {
    static let aomMenuBarSetup = Notification.Name("AOMMenuBarOpenSetup")
}

/// 7.15: the Menu Bar page's panes as a vertical list (Bartender 7's and
/// Ice's preference panes), with ↑/↓ moving between them.
struct MenuBarPaneNavigation: View {
    @Binding var selection: MenuBarSettingsTab
    @State private var hovered: MenuBarSettingsTab?
    @FocusState private var focusedTab: MenuBarSettingsTab?
    static let width: CGFloat = 184
    /// Below this page width the list becomes a pop-up above the pane.
    static let sideBySideWidth: CGFloat = 860

    /// Pure (V06): side by side from 868 pt, stacked below 852 pt, and in
    /// between whatever it already was.
    static func sideBySide(width: CGFloat, current: Bool) -> Bool {
        if width >= sideBySideWidth + 8 { return true }
        if width < sideBySideWidth - 8 { return false }
        return current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MenuBarSettingsTab.allCases) { tab in
                let selected = tab == selection
                Button { selection = tab; focusedTab = tab } label: {
                    HStack(spacing: AOMSpace.x2) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                            .foregroundStyle(selected ? AOMColor.accent : AOMColor.textSecondary)
                        Text(tab.title)
                            .font(AOMFont.body.weight(selected ? .semibold : .regular))
                            .foregroundStyle(AOMColor.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AOMSpace.x2)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? AOMColor.accent.opacity(0.13) : (hovered == tab ? AOMColor.surfaceHover : .clear)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedTab, equals: tab)
                .onHover { hovered = $0 ? tab : (hovered == tab ? nil : hovered) }
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(AOMSpace.x1)
        .background(AOMColor.surface, in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
        .focusable()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu Bar settings")
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let all = MenuBarSettingsTab.allCases
        guard let index = all.firstIndex(of: selection) else { return .ignored }
        let next = min(max(index + offset, 0), all.count - 1)
        selection = all[next]
        focusedTab = all[next]
        return .handled
    }

    /// The narrow form: one pop-up naming the pane.
    struct Compact: View {
        @Binding var selection: MenuBarSettingsTab

        var body: some View {
            Picker("Show", selection: $selection) {
                ForEach(MenuBarSettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .padding(.horizontal, AOMSpace.rowInset)
        }
    }
}

/// 7.16 (GPT V07): the Menu Bar page's headline, pure for the tests.
enum MenuBarHeadline {
    static func text(hidingOn: Bool, canRead: Bool, readOnce: Bool, complete: Bool = true, hiddenOwners: [String?]) -> String {
        guard hidingOn else { return "Menu bar hiding is off" }
        guard canRead else { return "AOM can't read the menu bar" }
        guard readOnce else { return "Reading the menu bar…" }
        guard complete else { return "Menu bar scan incomplete" }
        let apps = Set(hiddenOwners.compactMap { $0 }.filter { !$0.isEmpty }).count
        let unknown = hiddenOwners.filter { $0 == nil || $0 == "" }.count
        if unknown > 0 { return "\(apps) known app\(apps == 1 ? "" : "s") · \(unknown) unidentified hidden item\(unknown == 1 ? "" : "s")" }
        return apps == 0 ? "Nothing is hidden" : (apps == 1 ? "1 app is hidden" : "\(apps) apps are hidden")
    }
}
