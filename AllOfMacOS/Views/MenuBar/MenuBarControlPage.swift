import AppKit
import ApplicationServices
import SwiftUI

/// A discoverable home for AOM's menu bar features. Foreign icons are only
/// queried through Accessibility; AOM does not move or modify their windows.
struct MenuBarControlPage: View {
    @ObservedObject private var modules = AOMModuleSwitches.shared
    @ObservedObject private var weather = MenuBarWeather.shared
    @ObservedObject private var shelf = AOMMenuShelfController.shared
    @State private var spacing = SystemToolsModel.MenuBarSpacing.current(spacing: SystemToolsModel.MenuBarSpacing.Store.live.read("NSStatusItemSpacing"))
    @State private var spacingBusy = false
    @State private var spacingMessage: String?
    @State private var alwaysHidden = MenuBarHider.alwaysSectionOn
    @State private var rehide = MenuBarHider.rehideSeconds

    private func module(_ id: AOMModuleSwitch) -> Binding<Bool> {
        Binding(get: { modules.isOn(id) }, set: { _ = modules.set(id, on: $0) })
    }

    var body: some View {
        AOMPage {
            AOMPageHeader("Menu Bar", subtitle: "One place for weather, icon search, visibility and spacing.")
            AOMSection("Find menu bar items", detail: "Ice / Bartender-style access", padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("Show Icon Strip") { MenuBarStripController.shared.show() }
                        Button("Open Searchable Shelf") { shelf.show() }
                        Button("Refresh") { shelf.refresh() }.disabled(shelf.loading)
                    }
                    Text("The strip gathers reachable icons (even some hidden by the notch). Search and favorite items in the Shelf, without moving another app's icon.")
                        .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    if !AXIsProcessTrusted() {
                        Label("Other apps' icons require Accessibility access.", systemImage: "lock.shield")
                        Button("Request Access") { shelf.requestPermission() }
                    } else {
                        HStack {
                            Text("\(shelf.items.count) items · \(shelf.pinned.count) favorites")
                            if shelf.loading { ProgressView().controlSize(.small) }
                        }.font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                        if let message = shelf.message { Text(message).font(AOMFont.caption) }
                    }
                    Toggle("Open Shelf when hovering at the top center", isOn: $shelf.hoverEnabled)
                        .disabled(!AXIsProcessTrusted())
                    Text("Hover is optional and adds no global keyboard tap.")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
            }
            AOMSection("Hide and reveal icons", detail: "AOM divider and chevron", padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Menu Bar Hider", isOn: module(.menuBarHider))
                    Text("⌘-drag icons left of AOM's divider to hide them; click the chevron to reveal them. AOM moves only its divider, never another app's icon.")
                        .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    Toggle("Additional always-hidden section", isOn: Binding(get: { alwaysHidden }, set: {
                        alwaysHidden = $0; MenuBarHider.shared.setAlwaysSection($0)
                    })).disabled(!modules.isOn(.menuBarHider))
                    Text("Place the faint divider left of the normal divider. ⌥-click the chevron to reveal all.")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    Picker("Hide again after", selection: Binding(get: { rehide }, set: {
                        rehide = $0; MenuBarHider.shared.setRehideSeconds($0)
                    })) {
                        Text("Never").tag(0.0)
                        Text("10 seconds").tag(10.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("60 seconds").tag(60.0)
                    }.disabled(!modules.isOn(.menuBarHider))
                    HStack {
                        Button("Reveal All Now") { MenuBarHider.shared.expand(all: true, holdOpen: true) }
                        Button("Hide Now") { MenuBarHider.shared.collapse() }
                    }.disabled(!modules.isOn(.menuBarHider))
                }
            }
            AOMSection("Weather", detail: "Open-Meteo · chosen city, no location permission", padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show in menu bar", isOn: module(.weather))
                    HStack {
                        Image(systemName: weather.reading.map { MenuBarWeather.symbol(code: $0.code, isDay: $0.isDay) } ?? "cloud.sun")
                            .font(.system(size: 24, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(weather.city?.label ?? "No city chosen").font(.headline)
                            if let reading = weather.reading, reading.cityID == weather.city?.id {
                                Text("\(MenuBarWeather.title(reading, display: .temperature)) · \(MenuBarWeather.describe(code: reading.code)) · \(reading.fetchedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                            }
                        }
                        Spacer()
                        Button("Choose City…") { MenuBarWeather.openCityPicker() }
                    }
                    Picker("Show", selection: $weather.display) {
                        Text("Temperature").tag(MenuBarWeather.Display.temperature)
                        Text("Feels like").tag(MenuBarWeather.Display.feelsLike)
                        Text("Icon only").tag(MenuBarWeather.Display.iconOnly)
                    }
                    Picker("Units", selection: $weather.unit) {
                        Text("Celsius").tag(MenuBarWeather.Unit.celsius)
                        Text("Fahrenheit").tag(MenuBarWeather.Unit.fahrenheit)
                    }
                    HStack {
                        Button("Refresh Now") { weather.refresh(force: true) }.disabled(weather.city == nil || !modules.isOn(.weather))
                        if let issue = weather.problem { Text(issue.message).font(AOMFont.caption).foregroundStyle(AOMColor.warningText) }
                    }
                    Text("The icon stays legible offline; click it for the update time, range and hourly trend.")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
            }
            AOMSection("Icon spacing", detail: "Fit more items beside the notch", padding: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    Picker("Spacing", selection: Binding(get: { spacing }, set: { changeSpacing($0) })) {
                        ForEach(SystemToolsModel.MenuBarSpacing.allCases, id: \.self) { choice in Text(choice.title).tag(choice) }
                    }.disabled(spacingBusy)
                    Text("System-wide preferences; Control Center and SystemUIServer restart. Third-party icons may update after their app relaunches.")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    if spacingBusy { ProgressView("Applying…") }
                    if let spacingMessage { Text(spacingMessage).font(AOMFont.caption) }
                }
            }
            AOMSection("Favorite individual items", detail: "Accessibility inventory · on demand", padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pin items to show first in the Shelf; this is not a per-app hide switch. Other apps' status items cannot be reliably hidden through supported macOS APIs.")
                        .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                    if shelf.items.isEmpty { Text("Refresh above to find accessible icons.").font(AOMFont.caption) }
                    ForEach(Array(shelf.visibleItems.prefix(24))) { item in
                        HStack(spacing: 10) {
                            if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
                                Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                            } else { Image(systemName: "app").frame(width: 20) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.ownerName).font(.system(size: 12, weight: .semibold))
                                Text(item.title).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            Button { shelf.togglePinned(item) } label: {
                                Image(systemName: shelf.pinned.contains(item.pinKey) ? "star.fill" : "star")
                            }.buttonStyle(.borderless).help("Favorite")
                            Button("Open") { shelf.activate(item) }.controlSize(.small)
                        }
                    }
                    if shelf.visibleItems.count > 24 {
                        Text("24 of \(shelf.visibleItems.count) shown. Search the rest in the Shelf.").font(AOMFont.caption)
                    }
                }
            }
        }
        .aomPage("Menu Bar")
        .aomPageLifecycle(minimumInterval: 20, onActivate: {
            if AXIsProcessTrusted() { shelf.refresh() }
            spacing = SystemToolsModel.MenuBarSpacing.current(spacing: SystemToolsModel.MenuBarSpacing.Store.live.read("NSStatusItemSpacing"))
            alwaysHidden = MenuBarHider.alwaysSectionOn
            rehide = MenuBarHider.rehideSeconds
        })
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
                for name in ["ControlCenter", "SystemUIServer"] {
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
                else { spacingMessage = restarted == 2 ? "Applied \(choice.title)." : "Saved; any remaining icons update at next login." }
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
