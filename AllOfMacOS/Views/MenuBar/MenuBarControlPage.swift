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

    private var tab: MenuBarSettingsTab { MenuBarSettingsTab(rawValue: tabRaw) ?? .layout }

    var body: some View {
        AOMPage {
            AOMPageHeader("Menu Bar", subtitle: summary) {
                Button { setup = true } label: { Label("Setup Guide", systemImage: "questionmark.circle") }
                    .controlSize(.small)
            }
            MenuBarTabStrip(selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue }))
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
        .aomPage("Menu Bar")
        .sheet(isPresented: $setup) { MenuBarSetupGuide { setup = false } }
        .onReceive(NotificationCenter.default.publisher(for: .aomMenuBarSetup)) { _ in setup = true }
        .onAppear {
            if let raw = MenuBarPreviewFlags.tab { tabRaw = raw }
            if MenuBarPreviewFlags.setup || (!MenuBarPrefs.setupDone && !PresetManager.isUIPreview) { setup = true }
        }
        .aomPageLifecycle(minimumInterval: 20, onActivate: {
            if AXIsProcessTrusted() { layout.refresh(quietly: true) }
        })
    }

    /// One line under the title: is hiding on, and how many apps are where.
    private var summary: String {
        guard modules.isOn(.menuBarHider) || layout.isSample else { return "Hiding is off — turn it on in General, or follow the Setup Guide." }
        let lanes = layout.lanes
        let apps = { (section: MenuBarSection) in Set((lanes[section] ?? []).map(\.item.ownerBundleID)).count }
        let hidden = apps(.hidden), always = apps(.alwaysHidden)
        if hidden + always == 0 { return "Nothing hidden yet — drag icons to Hidden in Menu Bar Items." }
        return "\(hidden) app\(hidden == 1 ? "" : "s") hidden · \(always) always hidden · click ❮ in the menu bar to show them"
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

/// The pane switcher: Bartender's sidebar as a row of icon tabs.
struct MenuBarTabStrip: View {
    @Binding var selection: MenuBarSettingsTab
    @State private var hovered: MenuBarSettingsTab?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MenuBarSettingsTab.allCases) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 15, weight: selected ? .semibold : .regular))
                        Text(tab.title).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(selected ? AOMColor.accent : AOMColor.textSecondary)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? AOMColor.accent.opacity(0.13) : (hovered == tab ? AOMColor.surfaceHover : .clear)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? tab : (hovered == tab ? nil : hovered) }
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
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
