import AppKit
import ApplicationServices
import SwiftUI

// 7.10: the panes of the Menu Bar page, each after its Bartender 7 pane —
// General (GeneralPreferences.nib), Bar (BartenderBarSettingsView), Hotkeys
// (HotKeysPreferences.nib) and Advanced (AdvancedPreferences.nib), with the
// same labels where AOM does the same thing.

/// A settings value written through on change and read again whenever the
/// defaults change (❮'s right-click menu changes some of the same settings).
private struct Pref<Value: Equatable>: DynamicProperty {
    @State private var value: Value
    private let read: () -> Value
    private let write: (Value) -> Void

    init(read: @escaping () -> Value, write: @escaping (Value) -> Void) {
        _value = State(initialValue: read())
        self.read = read
        self.write = write
    }

    var binding: Binding<Value> {
        Binding(get: { value }, set: { value = $0; write($0) })
    }

    func sync() {
        let fresh = read()
        if fresh != value { value = fresh }
    }
}

private let defaultsChanged = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)

// MARK: - General

struct MenuBarGeneralPane: View {
    @ObservedObject private var modules = AOMModuleSwitches.shared
    private let click = Pref(read: { MenuBarPrefs.showOnEmptyClick }, write: { MenuBarPrefs.showOnEmptyClick = $0; MenuBarTriggers.shared.reconfigure() })
    private let scroll = Pref(read: { MenuBarPrefs.showOnScroll }, write: { MenuBarPrefs.showOnScroll = $0; MenuBarTriggers.shared.reconfigure() })
    private let hover = Pref(read: { MenuBarHider.hoverReveal }, write: { MenuBarHider.hoverReveal = $0 })
    private let hoverShow = Pref(read: { MenuBarPrefs.hoverShowDelay }, write: { MenuBarPrefs.hoverShowDelay = $0 })
    private let hoverHide = Pref(read: { MenuBarPrefs.hoverHideDelay }, write: { MenuBarPrefs.hoverHideDelay = $0 })
    private let rehide = Pref(read: { MenuBarHider.rehideSeconds }, write: { MenuBarHider.shared.setRehideSeconds($0) })
    private let bar = Pref(read: { MenuBarHider.revealMode == .bar }, write: { MenuBarHider.revealMode = $0 ? .bar : .menuBar })
    private let icon = Pref(read: { MenuBarPrefs.toggleIcon }, write: { MenuBarPrefs.toggleIcon = $0; MenuBarHider.shared.refreshAppearance() })
    private let wide = Pref(read: { MenuBarPrefs.showAllWiderThan }, write: { MenuBarPrefs.showAllWiderThan = $0; MenuBarTriggers.shared.applyWideRule() })
    @State private var spacing = SystemToolsModel.MenuBarSpacing.current(spacing: SystemToolsModel.MenuBarSpacing.Store.live.read("NSStatusItemSpacing"))
    @State private var spacingBusy = false
    @State private var spacingMessage: String?

    private var on: Bool { modules.isOn(.menuBarHider) }

    var body: some View {
        AOMSection("Hiding") {
            AOMToggleRow("Hide menu bar icons", detail: on ? "❮ in the menu bar shows and hides them" : "Off — every icon stays in the menu bar",
                         symbol: "eye.slash",
                         isOn: Binding(get: { modules.isOn(.menuBarHider) }, set: { _ = modules.set(.menuBarHider, on: $0) }))
            AOMSettingRow("Right now", symbol: "hand.tap") {
                HStack(spacing: 6) {
                    Button("Show Hidden") { MenuBarHider.shared.revealFromTrigger() }
                    Button("Show All") { MenuBarHider.shared.revealFromTrigger(includeAlways: true) }
                    Button("Hide") { MenuBarHider.shared.hideFromTrigger() }
                }
                .controlSize(.small)
            }
            .disabled(!on)
        }
        AOMSection("Show hidden menu bar items when:") {
            AOMSettingRow("Clicking ❮ in the menu bar", detail: "Always on · ⌥-click shows Always Hidden too", symbol: "chevron.left") {
                Image(systemName: "checkmark").foregroundStyle(AOMColor.textTertiary)
            }
            AOMToggleRow("Click on empty menu bar space", symbol: "cursorarrow.click", isOn: click.binding)
            AOMToggleRow("Swipe or scroll in menu bar", detail: "Down shows, up hides", symbol: "scroll", isOn: scroll.binding)
            AOMToggleRow("Hover over empty menu bar space", symbol: "cursorarrow.motionlines", isOn: hover.binding)
            AOMSettingRow("Delay before showing on hover", symbol: "timer", indent: true) {
                seconds(hoverShow.binding, [0, 0.2, 0.3, 0.5, 1, 2])
            }
            .disabled(!hover.binding.wrappedValue)
            AOMSettingRow("Delay before hiding after hover", symbol: "timer", indent: true) {
                seconds(hoverHide.binding, [0.5, 1, 2, 3, 5])
            }
            .disabled(!hover.binding.wrappedValue)
        }
        .disabled(!on)
        AOMSection("Automatically rehide") {
            AOMSettingRow("Hide again after", detail: "Waits while a menu is open or the pointer is on the menu bar", symbol: "arrow.uturn.backward") {
                Picker("Hide again after", selection: rehide.binding) {
                    ForEach(MenuBarHider.rehideChoices, id: \.self) { Text($0 == 0 ? "Never" : "\(Int($0)) s").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
        .disabled(!on)
        AOMSection("Bar") {
            AOMToggleRow("Show menu bar items in a bar below the menu bar",
                         detail: "Instead of putting the hidden icons back into the menu bar", symbol: "menubar.dock.rectangle",
                         isOn: bar.binding)
        }
        .disabled(!on)
        AOMSection("AOM menu bar item") {
            AOMSettingRow("Menu bar icon", detail: "The button that shows and hides the icons", symbol: "photo") {
                Picker("Menu bar icon", selection: icon.binding) {
                    ForEach(MenuBarPrefs.ToggleIcon.allCases) { choice in
                        Label(choice.title, systemImage: choice.symbols.collapsed).tag(choice)
                    }
                }
                .labelsHidden().fixedSize()
            }
            AOMSettingRow("Menu bar item spacing", detail: spacingMessage ?? "Tighter spacing fits more beside the notch", symbol: "arrow.left.and.right") {
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
        AOMSection("Displays") {
            AOMSettingRow("Show all menu bar items when the active screen is wider than", symbol: "display") {
                Picker("Wider than", selection: wide.binding) {
                    Text("Off").tag(0.0)
                    Text("1920 pt").tag(1920.0)
                    Text("2560 pt").tag(2560.0)
                    Text("3008 pt").tag(3008.0)
                    Text("3440 pt").tag(3440.0)
                }
                .labelsHidden().fixedSize()
            }
        }
        .disabled(!on)
        .onReceive(defaultsChanged) { _ in
            for pref in [click, scroll, hover, bar] { pref.sync() }
            rehide.sync(); icon.sync(); wide.sync(); hoverShow.sync(); hoverHide.sync()
        }
    }

    private func seconds(_ value: Binding<Double>, _ choices: [Double]) -> some View {
        Picker("Seconds", selection: value) {
            ForEach(choices, id: \.self) { Text($0 == 0 ? "None" : "\($0.formatted()) s").tag($0) }
        }
        .labelsHidden().fixedSize()
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
                // MenuBarAgent restarted: ask macOS again for the hiding (Gemini 7.10).
                if saved { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MenuBarNativeHiding.shared.renewHold() } }
            }
        }
    }
}

// MARK: - Bar

struct MenuBarBarPane: View {
    @ObservedObject private var shelf = AOMMenuShelfController.shared
    @ObservedObject private var modules = AOMModuleSwitches.shared
    private let bar = Pref(read: { MenuBarHider.revealMode == .bar }, write: { MenuBarHider.revealMode = $0 ? .bar : .menuBar })
    private let atMouse = Pref(read: { MenuBarPrefs.barAtMouse }, write: { MenuBarPrefs.barAtMouse = $0 })
    private let autohide = Pref(read: { MenuBarPrefs.barAutohide }, write: { MenuBarPrefs.barAutohide = $0 })
    private let leave = Pref(read: { MenuBarPrefs.barLeaveDelay }, write: { MenuBarPrefs.barLeaveDelay = $0 })

    var body: some View {
        AOMSection("Bar", detail: "Your hidden icons in a bar below the menu bar", padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    MenuBarBarPreview()
                    Spacer()
                }
                .padding(.vertical, 18)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.38, blue: 0.68).opacity(0.35), .clear],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                Text("Click an icon in the Bar to open its menu: AOM brings that icon back into the menu bar for a moment, clicks it, and hides it again when you're done. ← → choose, ↩ opens, 1–9 open the first nine.")
                    .font(.system(size: 11.5)).foregroundStyle(AOMColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open the Bar") { MenuBarStripController.shared.show() }.controlSize(.small)
                    Button("Search Icons…") { shelf.show() }.controlSize(.small)
                }
            }
        }
        AOMSection("Behaviour") {
            AOMToggleRow("Show hidden icons in the Bar", detail: "Instead of swapping them into the menu bar (also in General)",
                         symbol: "menubar.dock.rectangle", isOn: bar.binding)
            AOMToggleRow("Show the Bar at the mouse", detail: "Otherwise under ❮", symbol: "cursorarrow", isOn: atMouse.binding)
            AOMToggleRow("Hide the Bar when your pointer leaves it", symbol: "rectangle.portrait.and.arrow.right", isOn: autohide.binding)
            AOMSettingRow("After", symbol: "timer", indent: true) {
                Picker("After", selection: leave.binding) {
                    ForEach([0.5, 1, 2, 3, 5], id: \.self) { Text("\($0.formatted()) s").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            .disabled(!autohide.binding.wrappedValue)
            AOMToggleRow("Open the search at the top center", detail: "When the pointer rests there", symbol: "arrow.up.to.line",
                         isOn: $shelf.hoverEnabled)
                .disabled(!AXIsProcessTrusted())
        }
        .disabled(!modules.isOn(.menuBarHider))
        .onReceive(defaultsChanged) { _ in
            bar.sync(); atMouse.sync(); autohide.sync(); leave.sync()
        }
    }
}

// MARK: - Hotkeys

struct MenuBarHotkeysPane: View {
    @ObservedObject private var store = PaletteHotkeyStore.shared
    @ObservedObject private var model = MenuBarLayoutModel.shared
    @State private var recording: String?
    @State private var monitor: Any?
    @State private var problem: String?
    @State private var pendingActivation: [String: MenuBarHotkeys.Activation] = [:]
    @State private var adding: [String] = []

    var body: some View {
        AOMSection("Hotkeys", footer: problem) {
            ForEach(MenuBarHotkeys.Action.allCases) { action in
                AOMSettingRow(action.title + ":", detail: action.detail, symbol: action.symbol) {
                    recorder(action.itemID, title: action.title).frame(width: 262)
                }
            }
        }
        AOMSection("Menu bar item hotkeys", detail: "A key that shows an icon and clicks it", padding: 0) {
            itemTable
        }
        .onDisappear { stopRecording() }
        // Recording suspends every AOM key; never leave them off when AOM goes to the back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
    }

    private var itemBindings: [PaletteHotkey] {
        store.bindings.filter { MenuBarHotkeys.parseItem($0.itemID) != nil }.sorted { $0.title < $1.title }
    }

    private var itemTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Menu Bar Item").frame(maxWidth: .infinity, alignment: .leading)
                Text("Hot Key").frame(width: 262, alignment: .leading)
                Text("Activation").frame(width: 210, alignment: .leading)
                Color.clear.frame(width: 24)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(AOMColor.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            ForEach(itemBindings) { binding in
                if let parsed = MenuBarHotkeys.parseItem(binding.itemID) { row(binding, parsed) }
            }
            ForEach(adding, id: \.self) { key in pendingRow(key) }
            HStack {
                Menu {
                    let entries = model.items.filter { $0.item.pid != ProcessInfo.processInfo.processIdentifier }
                    if entries.isEmpty { Text("Read the menu bar first (Menu Bar Items)") }
                    ForEach(entries) { entry in
                        Button(entry.item.displayName + " — " + entry.item.ownerName) {
                            if !adding.contains(entry.imageKey) { adding.append(entry.imageKey) }
                        }
                    }
                } label: { Label("Add menu bar item hot key", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .overlay(alignment: .top) { Rectangle().fill(AOMColor.hairline).frame(height: 0.5) }
        }
        .onAppear { if model.lastRefresh == nil, AXIsProcessTrusted() { model.refresh(quietly: true, reveal: false) } }
    }

    private func entry(for key: String) -> MenuBarLayoutItem? {
        model.items.first { $0.imageKey == key || $0.item.stableKey == key }
    }

    private func itemLabel(_ key: String, fallback: String) -> some View {
        HStack(spacing: 8) {
            if let entry = entry(for: key) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(model.laneColor)
                    MenuBarItemPicture(entry: entry, height: 14, ink: model.ink)
                }
                .frame(width: 34, height: 22)
            }
            Text(entry(for: key)?.item.displayName ?? fallback).font(.system(size: 12.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ binding: PaletteHotkey, _ parsed: (activation: MenuBarHotkeys.Activation, key: String)) -> some View {
        itemRow(key: parsed.key, title: binding.title, id: binding.itemID, activation: parsed.activation,
                choose: { change(binding, to: $0, key: parsed.key) }, remove: { store.remove(binding.itemID) })
    }

    /// A new row before its key is recorded.
    private func pendingRow(_ key: String) -> some View {
        let activation = pendingActivation[key] ?? .leftClick
        return itemRow(key: key, title: entry(for: key)?.item.displayName ?? key,
                       id: MenuBarHotkeys.itemID(key, activation: activation), activation: activation,
                       choose: { pendingActivation[key] = $0 }, remove: { adding.removeAll { $0 == key } },
                       saved: { adding.removeAll { $0 == key } })
    }

    private func itemRow(key: String, title: String, id: String, activation: MenuBarHotkeys.Activation,
                         choose: @escaping (MenuBarHotkeys.Activation) -> Void, remove: @escaping () -> Void,
                         saved: (() -> Void)? = nil) -> some View {
        HStack {
            itemLabel(key, fallback: title)
            recorder(id, title: title, saved: saved).frame(width: 262)
            Picker("Activation", selection: Binding(get: { activation }, set: choose)) {
                ForEach(MenuBarHotkeys.Activation.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 210)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).frame(width: 24)
                .help("Delete menu bar item hot key")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(AOMColor.hairline).frame(height: 0.5) }
    }

    /// Changing how an item is clicked keeps its key under a new id.
    private func change(_ binding: PaletteHotkey, to activation: MenuBarHotkeys.Activation, key: String) {
        let shortcut = binding.shortcut
        store.remove(binding.itemID)
        do { try store.set(shortcut, for: MenuBarHotkeys.itemID(key, activation: activation), title: binding.title) }
        catch {
            // Put the old key back rather than lose it (Gemini 7.10).
            _ = try? store.set(shortcut, for: binding.itemID, title: binding.title)
            problem = error.localizedDescription
        }
    }

    private func recorder(_ id: String, title: String, saved: (() -> Void)? = nil) -> some View {
        AOMShortcutRecorderField(shortcut: store.binding(for: id)?.shortcut, recording: recording == id,
                                 start: { startRecording(id, title: title, saved: saved) },
                                 stop: { stopRecording() },
                                 clear: { store.remove(id) })
    }

    private func startRecording(_ id: String, title: String, saved: (() -> Void)?) {
        stopRecording()
        recording = id
        problem = nil
        store.suspend()
        KeyboardMonitor.beginShortcutRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let shortcut = KeyboardShortcut(keyCode: event.keyCode, modifiers: flags)
            stopRecording()
            do {
                try store.set(shortcut, for: id, title: title)
                saved?()
            } catch {
                problem = "\(shortcut.displayString): \(error.localizedDescription)"
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if recording != nil {
            KeyboardMonitor.endShortcutRecording()
            store.resume()
        }
        monitor = nil
        recording = nil
    }
}

// MARK: - Advanced

struct MenuBarAdvancedPane: View {
    @ObservedObject private var modules = AOMModuleSwitches.shared
    private let commandDrag = Pref(read: { MenuBarPrefs.commandDragShowsAll }, write: { MenuBarPrefs.commandDragShowsAll = $0; MenuBarTriggers.shared.reconfigure() })
    private let noRoom = Pref(read: { MenuBarPrefs.barWhenNoRoom }, write: { MenuBarPrefs.barWhenNoRoom = $0 })
    private let temporary = Pref(read: { MenuBarPrefs.temporaryShowSeconds }, write: { MenuBarPrefs.temporaryShowSeconds = $0 })
    private let always = Pref(read: { MenuBarHider.alwaysSectionOn }, write: { MenuBarHider.shared.setAlwaysSection($0) })
    @State private var confirmReset = false

    var body: some View {
        AOMSection("Advanced") {
            AOMToggleRow("When ⌘+dragging menu bar items, show all sections", detail: "So any icon can be put in place", symbol: "command",
                         isOn: commandDrag.binding)
            AOMToggleRow("Show hidden icons in the Bar when there isn't room for them",
                         detail: "The menu bar can't fit them beside the notch or the app's menus", symbol: "rectangle.compress.vertical",
                         isOn: noRoom.binding)
            AOMSettingRow("Delay before hiding temporarily shown menu bar items from the Bar", symbol: "hourglass") {
                Picker("Delay", selection: temporary.binding) {
                    ForEach([2.0, 5, 10, 15, 30, 60], id: \.self) { Text("\(Int($0)) Seconds").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if !MenuBarHider.shared.native {
                AOMToggleRow("Always-hidden divider", detail: "Older macOS: a second divider for the Always Hidden section", symbol: "lock",
                             isOn: always.binding)
            }
        }
        .disabled(!modules.isOn(.menuBarHider))
        .onReceive(defaultsChanged) { _ in
            commandDrag.sync(); noRoom.sync(); temporary.sync(); always.sync()
        }
        AOMSection("Hiding method") {
            AOMSettingRow(MenuBarNativeHiding.isAvailable ? "macOS menu bar restriction" : "Divider",
                          detail: MenuBarNativeHiding.isAvailable
                            ? "macOS 27 hides every app not on AOM's list and keeps its own icons; an app's icons hide together"
                            : (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
                               ? "Move All of MacOS to /Applications to use macOS's own hiding"
                               : "Icons left of AOM's divider are pushed off the menu bar"),
                          symbol: "gearshape.2") {
                Image(systemName: MenuBarNativeHiding.isAvailable ? "checkmark.seal.fill" : "info.circle")
                    .foregroundStyle(MenuBarNativeHiding.isAvailable ? AOMColor.successText : AOMColor.textTertiary)
            }
            AOMSettingRow("Reset menu bar layout", detail: "Every app back to Shown; presets stay", symbol: "arrow.counterclockwise") {
                Button("Reset…") { confirmReset = true }.controlSize(.small)
            }
            AOMSettingRow("Setup guide", detail: "Permissions and how to show hidden icons", symbol: "questionmark.circle") {
                Button("Show") { NotificationCenter.default.post(name: .aomMenuBarSetup, object: nil) }.controlSize(.small)
            }
        }
        .confirmationDialog("Show every app's icons again?", isPresented: $confirmReset) {
            Button("Reset Layout", role: .destructive) {
                // An applied preset is let go too, or removing it later would
                // bring the old layout back (Gemini 7.10).
                UserDefaults.standard.removeObject(forKey: MenuBarPresets.appliedKey)
                UserDefaults.standard.removeObject(forKey: MenuBarPresets.baseKey)
                MenuBarSectionStore.replaceAll([:])
                MenuBarLayoutModel.shared.reloadSections()
                MenuBarHider.shared.reapply()
            }
        } message: {
            Text("All apps go back to Shown. Your presets are kept.")
        }
    }
}

// MARK: - Weather and AOM's menu (AOM's own panes)

struct MenuBarWeatherPane: View {
    @ObservedObject private var modules = AOMModuleSwitches.shared
    @ObservedObject private var weather = MenuBarWeather.shared

    var body: some View {
        AOMSection("Weather", detail: "Open-Meteo · no location permission", padding: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show in menu bar", isOn: Binding(get: { modules.isOn(.weather) }, set: { _ = modules.set(.weather, on: $0) }))
                        .toggleStyle(.switch)
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(AOMColor.textSecondary)
                        Text(weather.city?.name ?? "No city").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button(weather.city == nil ? "Choose…" : "Change…") { MenuBarWeather.openCityPicker() }.controlSize(.small)
                    }
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
                WeatherMenuCard(city: weather.city, reading: weather.current, problem: weather.problem)
                    .background(AOMColor.overlaySurface, in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous).strokeBorder(AOMColor.hairline, lineWidth: 0.5))
                    .accessibilityLabel("Weather menu preview")
            }
        }
        AOMSection("Beside the icon", detail: "Tick what the menu bar shows; ↑↓ sets the order", padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                // The same formatter as the menu bar itself.
                HStack(spacing: 6) {
                    Text("Menu bar").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    HStack(spacing: 5) {
                        Image(systemName: weather.current.map { MenuBarWeather.symbol(code: $0.code, isDay: $0.isDay) } ?? "cloud.sun")
                        Text(previewLine.isEmpty ? "(icon only)" : previewLine).monospacedDigit()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help(MenuBarWeather.line(previewReading, fields: weather.fields).full)
                }
                ForEach(orderedFields, id: \.self) { field in
                    let index = weather.fields.firstIndex(of: field)
                    HStack(spacing: 8) {
                        Toggle(field.title, isOn: Binding(get: { index != nil }, set: { on in
                            if on { if !weather.fields.contains(field) { weather.fields.append(field) } }
                            else { weather.fields.removeAll { $0 == field } }
                        }))
                        .toggleStyle(.checkbox)
                        Spacer()
                        if let index {
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(index == 0)
                                .accessibilityLabel("Move \(field.title) up")
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(index == weather.fields.count - 1)
                                .accessibilityLabel("Move \(field.title) down")
                        }
                    }
                }
                Text("Untick everything for the icon alone. A long line drops its last items first; the tooltip and the weather menu show all of it.")
                    .font(.system(size: 11)).foregroundStyle(AOMColor.textTertiary)
            }
        }
    }

    /// Ticked fields in their order, then the others.
    private var orderedFields: [MenuBarWeather.Field] {
        weather.fields + MenuBarWeather.Field.allCases.filter { !weather.fields.contains($0) }
    }

    /// The live reading, or Seoul's sample when there is none yet.
    private var previewReading: WeatherReading? {
        weather.current ?? WeatherReading(cityID: 0, temperature: 12, feelsLike: 10, code: 3, isDay: true, low: 7, high: 15,
                                          rainChance: 30, fetchedAt: Date(), unit: .celsius, humidity: 64, windSpeed: 11)
            .converted(to: weather.unit)
    }

    private var previewLine: String { MenuBarWeather.line(previewReading, fields: weather.fields).text }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard weather.fields.indices.contains(index), weather.fields.indices.contains(target) else { return }
        weather.fields.swapAt(index, target)
    }
}

struct MenuBarAOMMenuPane: View {
    @ObservedObject private var menuStore = AOMStatusMenuStore.shared

    var body: some View {
        AOMSection("AOM menu") {
            AOMSettingRow("Click panel and right-click menu", detail: summary, symbol: "slider.horizontal.below.rectangle") {
                Button("Edit…") { AOMMenuEditorNavigation.open() }.controlSize(.small)
            }
        }
    }

    private var summary: String {
        let menu = menuStore.layout.menu == nil ? "standard menu" : "your menu"
        let panel = menuStore.layout.panel == nil ? "Workspace's quick actions" : "\(menuStore.layout.panel?.count ?? 0) quick commands"
        return "\(panel.prefix(1).uppercased() + panel.dropFirst()) · \(menu)"
    }
}
