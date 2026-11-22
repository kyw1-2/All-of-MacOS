import AppKit
import ApplicationServices
import SwiftUI

/// 7.9: the Menu Bar page, after Bartender's settings — the layout first
/// (the real menu bar pulled down into lanes you drag between), then how
/// hidden icons come back, the Bar, weather, AOM's own menu and spacing.
/// One line of explanation where a control needs it, none where it doesn't.
struct MenuBarControlPage: View {
    @ObservedObject private var modules = AOMModuleSwitches.shared
    @ObservedObject private var weather = MenuBarWeather.shared
    @ObservedObject private var shelf = AOMMenuShelfController.shared
    @ObservedObject private var layout = MenuBarLayoutModel.shared
    @ObservedObject private var menuStore = AOMStatusMenuStore.shared
    @State private var spacing = SystemToolsModel.MenuBarSpacing.current(spacing: SystemToolsModel.MenuBarSpacing.Store.live.read("NSStatusItemSpacing"))
    @State private var spacingBusy = false
    @State private var spacingMessage: String?
    @State private var alwaysHidden = MenuBarHider.alwaysSectionOn
    @State private var rehide = MenuBarHider.rehideSeconds
    @State private var revealMode = MenuBarHider.revealMode
    @State private var hover = MenuBarHider.hoverReveal

    private func module(_ id: AOMModuleSwitch) -> Binding<Bool> {
        Binding(get: { modules.isOn(id) }, set: { _ = modules.set(id, on: $0) })
    }

    private var hiderOn: Bool { modules.isOn(.menuBarHider) }

    var body: some View {
        AOMPage {
            AOMPageHeader("Menu Bar", subtitle: "Arrange, hide and reach every icon.")
            AOMSection("Layout", detail: "Drag icons between lanes", padding: 14) {
                MenuBarLayoutEditor()
            }
            AOMSection("Hidden icons") {
                AOMToggleRow("Hide icons", detail: "A ❮ button and a divider; icons left of it hide", symbol: "eye.slash",
                             isOn: module(.menuBarHider))
                AOMSettingRow("Show them", symbol: "rectangle.topthird.inset.filled") {
                    Picker("Show them", selection: Binding(get: { revealMode }, set: { revealMode = $0; MenuBarHider.revealMode = $0 })) {
                        ForEach(MenuBarHider.RevealMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .disabled(!hiderOn)
                AOMSettingRow("Hide again after", symbol: "timer") {
                    Picker("Hide again after", selection: Binding(get: { rehide }, set: { rehide = $0; MenuBarHider.shared.setRehideSeconds($0) })) {
                        Text("Never").tag(0.0)
                        Text("10 s").tag(10.0)
                        Text("15 s").tag(15.0)
                        Text("30 s").tag(30.0)
                        Text("60 s").tag(60.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .disabled(!hiderOn)
                AOMToggleRow("Reveal on hover", detail: "Rest the pointer on ❮", symbol: "cursorarrow.motionlines",
                             isOn: Binding(get: { hover }, set: { hover = $0; MenuBarHider.hoverReveal = $0 }))
                    .disabled(!hiderOn)
                AOMToggleRow("Always Hidden lane", detail: "Shown only with ⌥-click or Show All", symbol: "lock",
                             isOn: Binding(get: { alwaysHidden }, set: { alwaysHidden = $0; MenuBarHider.shared.setAlwaysSection($0) }))
                    .disabled(!hiderOn)
                AOMSettingRow("Right now", symbol: "hand.tap") {
                    HStack(spacing: 6) {
                        Button("Show All") { MenuBarHider.shared.expand(all: true, holdOpen: true) }
                        Button("Hide") { MenuBarHider.shared.collapse() }
                    }
                    .controlSize(.small)
                }
                .disabled(!hiderOn)
            }
            AOMSection("Bar", detail: "Hidden icons in a bar under the menu bar") {
                AOMSettingRow("Preview", symbol: "menubar.dock.rectangle") {
                    HStack(spacing: 8) {
                        MenuBarBarPreview()
                        Button("Open") { MenuBarStripController.shared.show() }.controlSize(.small)
                    }
                }
                AOMToggleRow("Open at the top center", detail: "When the pointer rests there", symbol: "arrow.up.to.line",
                             isOn: $shelf.hoverEnabled)
                    .disabled(!AXIsProcessTrusted())
                AOMSettingRow("Search every icon", symbol: "magnifyingglass") {
                    Button("Search…") { shelf.show() }.controlSize(.small)
                }
            }
            AOMSection("Weather", detail: "Open-Meteo · no location permission", padding: 14) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show in menu bar", isOn: module(.weather)).toggleStyle(.switch)
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse").foregroundStyle(AOMColor.textSecondary)
                            Text(weather.city?.name ?? "No city").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Button(weather.city == nil ? "Choose…" : "Change…") { MenuBarWeather.openCityPicker() }.controlSize(.small)
                        }
                        Picker("Menu bar", selection: $weather.display) {
                            Text("Temp").tag(MenuBarWeather.Display.temperature)
                            Text("Feels").tag(MenuBarWeather.Display.feelsLike)
                            Text("Icon").tag(MenuBarWeather.Display.iconOnly)
                        }
                        .pickerStyle(.segmented)
                        Picker("Units", selection: $weather.unit) {
                            Text("°C").tag(MenuBarWeather.Unit.celsius)
                            Text("°F").tag(MenuBarWeather.Unit.fahrenheit)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Button("Refresh") { weather.refresh(force: true) }
                                .controlSize(.small)
                                .disabled(weather.city == nil || !modules.isOn(.weather))
                            if let issue = weather.problem {
                                Text(issue.message).font(AOMFont.caption).foregroundStyle(AOMColor.warningText).lineLimit(1)
                            }
                        }
                    }
                    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                    WeatherMenuCard(city: weather.city, reading: weather.reading.flatMap { $0.cityID == weather.city?.id ? $0 : nil },
                                    problem: weather.problem)
                        .background(AOMColor.overlaySurface, in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous).strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                        .accessibilityLabel("Weather menu preview")
                }
            }
            AOMSection("AOM menu") {
                AOMSettingRow("Click panel and right-click menu", detail: menuSummary, symbol: "slider.horizontal.below.rectangle") {
                    Button("Edit…") { AOMMenuEditorNavigation.open() }.controlSize(.small)
                }
            }
            AOMSection("Icon spacing") {
                AOMSettingRow("Spacing", detail: spacingMessage ?? "Tighter spacing fits more beside the notch", symbol: "arrow.left.and.right") {
                    HStack(spacing: 6) {
                        if spacingBusy { ProgressView().controlSize(.small) }
                        Picker("Spacing", selection: Binding(get: { spacing }, set: { changeSpacing($0) })) {
                            ForEach(SystemToolsModel.MenuBarSpacing.allCases, id: \.self) { choice in
                                Text(choice.title.components(separatedBy: " — ").first ?? choice.title).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .disabled(spacingBusy)
                    }
                }
            }
        }
        .aomPage("Menu Bar")
        // Gemini 7.9: ❮'s right-click menu and a move can change these too.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            if alwaysHidden != MenuBarHider.alwaysSectionOn { alwaysHidden = MenuBarHider.alwaysSectionOn }
            if rehide != MenuBarHider.rehideSeconds { rehide = MenuBarHider.rehideSeconds }
            if revealMode != MenuBarHider.revealMode { revealMode = MenuBarHider.revealMode }
            if hover != MenuBarHider.hoverReveal { hover = MenuBarHider.hoverReveal }
        }
        .aomPageLifecycle(minimumInterval: 20, onActivate: {
            if AXIsProcessTrusted() { layout.refresh(quietly: true) }
            spacing = SystemToolsModel.MenuBarSpacing.current(spacing: SystemToolsModel.MenuBarSpacing.Store.live.read("NSStatusItemSpacing"))
            alwaysHidden = MenuBarHider.alwaysSectionOn
            rehide = MenuBarHider.rehideSeconds
            revealMode = MenuBarHider.revealMode
            hover = MenuBarHider.hoverReveal
        })
    }

    private var menuSummary: String {
        let menu = menuStore.layout.menu == nil ? "standard menu" : "your menu"
        let panel = menuStore.layout.panel == nil ? "Workspace's quick actions" : "\(menuStore.layout.panel?.count ?? 0) quick commands"
        return "\(panel.prefix(1).uppercased() + panel.dropFirst()) · \(menu)"
    }

    private func changeSpacing(_ choice: SystemToolsModel.MenuBarSpacing) {
        guard !spacingBusy else { return }
        let previous = spacing
        spacing = choice
        spacingBusy = true
        spacingMessage = nil
        DispatchQueue.global(qos: .utility).async {
            let saved = choice.apply(to: .live)
            var restarted = 0
            if saved {
                // macOS 27 hosts system items in MenuBarAgent (Gemini 7.9).
                for name in ["ControlCenter", "SystemUIServer", "MenuBarAgent"] {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                    task.arguments = [name]
                    task.standardError = FileHandle.nullDevice
                    do { try task.run(); task.waitUntilExit(); if task.terminationStatus == 0 { restarted += 1 } }
                    catch { /* next login applies saved preferences */ }
                }
            }
            DispatchQueue.main.async {
                spacingBusy = false
                if !saved { spacing = previous; spacingMessage = "Spacing failed; original values were restored." }
                else { spacingMessage = restarted >= 2 ? "Applied." : "Saved; any remaining icons update at next login." }
            }
        }
    }
}


/// Common entry point for status-item context menus and other in-app controls.
@MainActor
enum MenuBarNavigation {
    static func open() {
        AppDelegate.current?.appState?.selectedMainTab = .menuBar
        AppDelegate.current?.showMainWindow()
    }
}
