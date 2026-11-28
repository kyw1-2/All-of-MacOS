import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

// 7.10: Bartender 7's "Menu Bar Items" pane, laid out as its nib
// (MenuBarLayoutPreferences.nib): the title, two lines on how to arrange,
// the applied preset, then "Shown / Hidden / Always Hidden menu bar items" —
// each a 60 pt strip in the menu bar's colour, icons right-aligned as in the
// menu bar and dragged between strips — and the paragraph that explains the
// three sections and the New Menu Bar Items pill. The per-app list is its
// own pane (`MenuBarItemSettingsList`, Bartender's MenuItemsPreferences).

/// What can be dropped on a strip: an icon's id, or the New Items pill.
private enum LayoutDrag {
    static let pill = "aom.pill.newItems"
}

struct MenuBarLayoutEditor: View {
    @ObservedObject private var model = MenuBarLayoutModel.shared
    @ObservedObject private var modules = AOMModuleSwitches.shared
    @State private var targeted: MenuBarSection?
    @State private var hovered: String?
    /// The hovered icon's app: on macOS 27 its other icons move with it.
    @State private var hoveredApp: String?
    @State private var renaming: String?
    @State private var newItems = MenuBarPrefs.newItemsSection
    @State private var presets = MenuBarPresets.all
    @State private var applied = MenuBarPresets.applied
    @State private var naming = false
    @State private var presetName = ""
    /// D23: the icon whose settings show under the lanes.
    @State private var selectedID: String?

    private var hiderOn: Bool { modules.isOn(.menuBarHider) || model.isSample }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !hiderOn {
                AOMNotice(.info, "Hiding is off", detail: "Turn it on to hide the icons you put in Hidden and Always Hidden.") {
                    Button("Turn On") { _ = modules.set(.menuBarHider, on: true) }.controlSize(.small)
                }
            }
            if let applied { presetRow(applied) }
            if !AXIsProcessTrusted() && !model.isSample {
                permissionNotice
            } else {
                let lanes = model.lanes
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(MenuBarSection.allCases) { section in
                        strip(section, items: lanes[section] ?? [])
                    }
                }
                // D23: the lanes and the selected icon's settings together.
                selectedItemPanel(lanes)
            }
        }
        .onAppear { if model.lastRefresh == nil { model.refresh() } }
        .sheet(isPresented: $naming) { presetSheet }
    }

    static let help = """
    Drag your menu bar items to the Shown section to keep them in the menu bar. Drag them to the Hidden section to hide them until you click ❮ (or empty menu bar space). Drag them to the Always Hidden section to keep them hidden until you ⌥-click ❮ or choose Show All. Set where new menu bar items go by moving the New Menu Bar Items pill to any section. On macOS 27 hiding works by app, so an app's icons move together, and macOS's own icons (clock, Control Center) stay shown.
    """

    // MARK: Title and the two lines under it

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                // 7.18: one line; the full explanation sits behind ⓘ.
                HStack(spacing: AOMSpace.x1) {
                    Text("Menu Bar Items").font(AOMFont.title)
                    AOMInfoButton(Self.help, topic: "Arranging menu bar items", textStyle: AOMFont.title)
                }
                Text("Drag icons between sections, or ⌘-drag them in the menu bar.")
                    .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                // 7.19 (N08): how fresh the picture of the menu bar is.
                if !model.isSample, let read = model.lastRefresh {
                    (Text("Read ") + Text(read, style: .relative) + Text(" ago")
                        + Text(model.lastScanComplete ? "" : " · some items couldn't be read"))
                        .font(AOMFont.caption)
                        .foregroundStyle(model.lastScanComplete ? AOMColor.textTertiary : AOMColor.warningText)
                }
                if let status = model.status {
                    Text(status).font(AOMFont.caption).foregroundStyle(AOMColor.accent).lineLimit(2).padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if model.busy { ProgressView().controlSize(.small) }
            if !MenuBarItemImager.hasPermission && !model.isSample {
                Button("Show Real Icons…") { _ = CGRequestScreenCaptureAccess() }
                    .controlSize(.small)
                    .help("Allow Screen Recording so AOM can draw each icon as it looks in the menu bar")
            }
            presetMenu
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.busy)
                .help("Read the menu bar again")
                .accessibilityLabel("Refresh")
        }
    }

    private var permissionNotice: some View {
        AOMNotice(.warning, "AOM needs Accessibility to read the menu bar",
                  detail: "System Settings › Privacy & Security › Accessibility › All of MacOS.") {
            Button("Allow…") { AOMMenuShelfController.shared.requestPermission() }.controlSize(.small)
        }
    }

    // MARK: Presets (Bartender: "Preset:" row and its menu)

    private var presetMenu: some View {
        Menu {
            if presets.isEmpty { Text("No presets yet") }
            ForEach(presets) { preset in
                Button(preset.name + (applied == preset.name ? " ✓" : "")) { MenuBarPresets.apply(preset.name); reloadPresets() }
            }
            Divider()
            Button("Save Current Layout as Preset…") { presetName = ""; naming = true }
            if !presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(presets) { preset in Button(preset.name) { MenuBarPresets.delete(preset.name); reloadPresets() } }
                }
            }
        } label: {
            Label("Presets", systemImage: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Save this layout and switch between layouts")
    }

    private func presetRow(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Preset:").font(.system(size: 13, weight: .semibold))
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(AOMColor.accent)
                Text(name).font(.system(size: 13))
                Spacer()
                Button("Remove Applied Preset") { MenuBarPresets.removeApplied(); reloadPresets() }.controlSize(.small)
            }
            Text("Changes made here while a preset is applied are not saved to the default menu bar layout or to the preset.")
                .font(.system(size: 11)).foregroundStyle(AOMColor.textTertiary)
        }
        .padding(10)
        .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
    }

    private var presetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Preset").font(.headline)
            Text("Keeps which section every app is in.").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            TextField("Preset name (e.g. Work, Presenting)", text: $presetName).textFieldStyle(.roundedBorder).frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel") { naming = false }.keyboardShortcut(.cancelAction)
                Button("Save") { MenuBarPresets.saveCurrent(as: presetName); naming = false; reloadPresets() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
    }

    private func reloadPresets() {
        presets = MenuBarPresets.all
        applied = MenuBarPresets.applied
    }

    // MARK: The three strips

    private func strip(_ section: MenuBarSection, items: [MenuBarLayoutItem]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let isTarget = targeted == section
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.stripTitle).font(AOMFont.section)
                Text("\(items.count)").font(AOMFont.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(AOMColor.textTertiary)
                Spacer()
                Text(section.caption).font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).lineLimit(1)
            }
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 2) {
                        if newItems == section { pill }
                        Spacer(minLength: 0)
                        if items.isEmpty {
                            Text(isTarget ? "Drop here" : "Drag icons here")
                                .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                                .padding(.horizontal, 12)
                        } else {
                            // 7.19: the bar's own colour only behind the icons — a
                            // small strip of menu bar on a calm lane — so captured
                            // icons keep the background they were drawn for.
                            HStack(spacing: 2) { ForEach(items) { entry in icon(entry) } }
                                .padding(.horizontal, 6)
                                .frame(height: 34)
                                .background(laneColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .trailing)
                }
                // Like the menu bar, the right end shows first (Gemini 7.10).
                .defaultScrollAnchor(.trailing)
            }
            .frame(height: 50)
            .background(isTarget ? AOMColor.dropWash : AOMColor.sunken, in: shape)
            .overlay(shape.strokeBorder(isTarget ? AOMColor.accent : AOMColor.hairline, lineWidth: isTarget ? 2 : 0.5))
            .clipShape(shape)
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                if id == LayoutDrag.pill {
                    newItems = section
                    MenuBarPrefs.newItemsSection = section
                    return true
                }
                model.move(id, to: section)
                return true
            } isTargeted: { inside in
                targeted = inside ? section : (targeted == section ? nil : targeted)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(section.stripTitle), \(items.count)")
        }
    }

    /// Bartender's "New Menu Bar Items" pill: where apps seen for the first time go.
    private var pill: some View {
        Label("New Menu Bar Items", systemImage: "sparkles")
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(AOMColor.accent))
            .draggable(LayoutDrag.pill) {
                Label("New Menu Bar Items", systemImage: "sparkles").font(.system(size: 11, weight: .semibold))
                    .padding(6).background(Capsule().fill(AOMColor.accent)).foregroundStyle(.white)
            }
            .help("Apps that show a menu bar icon for the first time go to this section. Drag the pill to another section.")
            .accessibilityLabel("New Menu Bar Items go to this section")
    }

    /// The selected icon: where it is, why it can't move if it can't, and
    /// the same moves as dragging it, for the keyboard and VoiceOver.
    @ViewBuilder private func selectedItemPanel(_ lanes: [MenuBarSection: [MenuBarLayoutItem]]) -> some View {
        let all = MenuBarSection.allCases.flatMap { lanes[$0] ?? [] }
        if let entry = all.first(where: { $0.id == selectedID }) {
            // 7.18 (D07): a group under the lanes, not a card inside the card.
            VStack(alignment: .leading, spacing: AOMSpace.x2) {
                AOMDivider()
                Text("Selected Item").font(AOMFont.section).foregroundStyle(AOMColor.textSecondary)
                VStack(alignment: .leading, spacing: AOMSpace.x2) {
                    HStack(spacing: AOMSpace.x2) {
                        MenuBarItemGlyph(item: entry.item, size: 22)
                        VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                            Text(entry.item.displayName).font(AOMFont.headline)
                            Text(entry.item.ownerName).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                        }
                        Spacer(minLength: AOMSpace.x2)
                        Button("Rename…") { renaming = entry.id }.controlSize(.small)
                        AOMIconButton("xmark", label: "Deselect") { selectedID = nil }
                    }
                    AOMInspectorRow("Section", text: entry.section.title)
                    if MenuBarNativeHiding.isAvailable {
                        AOMInspectorRow("Moves with", text: "Every icon of \(entry.item.ownerName) (macOS 27 hides by app)")
                    }
                    if let reason = entry.lockedReason {
                        Label(reason, systemImage: "lock")
                            .font(AOMFont.callout)
                            .foregroundStyle(AOMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: AOMSpace.x2) {
                            Text("Move to").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                            ForEach(MenuBarSection.allCases) { section in
                                Button(section.title) { model.move(entry.id, to: section) }
                                    .controlSize(.small)
                                    .disabled(section == entry.section)
                            }
                        }
                    }
                }
            }
        }
    }

    private var laneColor: Color { model.laneColor }
    private var laneInk: Color { model.ink }

    /// An icon as it looks in the menu bar, a little larger: its picture, no
    /// box; hover lights it as the menu bar does; locked ones are dimmed.
    private func icon(_ entry: MenuBarLayoutItem) -> some View {
        let lit = hovered == entry.id
        let sibling = !lit && MenuBarNativeHiding.isAvailable && hoveredApp == entry.item.ownerBundleID
        return MenuBarItemPicture(entry: entry, height: 22, ink: laneInk)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(lit ? laneInk.opacity(0.16) : (sibling ? laneInk.opacity(0.08) : .clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(entry.lockedReason == nil ? 1 : 0.5)
            .overlay {
                if selectedID == entry.id {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AOMColor.accent, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            // D23: a click selects the icon; its settings show under the lanes.
            .onTapGesture { selectedID = entry.id }
            .onHover { inside in
                hovered = inside ? entry.id : (hovered == entry.id ? nil : hovered)
                hoveredApp = inside ? entry.item.ownerBundleID : (hovered == nil ? nil : hoveredApp)
            }
            .help("\(entry.item.displayName) — \(entry.item.ownerName)" + (entry.lockedReason.map { "\n\($0)" } ?? "\nDrag to another section"))
            .modifier(DraggableUnlessLocked(id: entry.id, locked: entry.lockedReason != nil, preview: { MenuBarItemPicture(entry: entry, height: 22, ink: laneInk) }))
            .contextMenu { MenuBarItemMenu(entry: entry, rename: { renaming = entry.id }) }
            .popover(isPresented: Binding(get: { renaming == entry.id }, set: { if !$0 { renaming = nil } }), arrowEdge: .bottom) {
                MenuBarItemAliasEditor(item: entry.item) { renaming = nil }
            }
            .accessibilityElement()
            .accessibilityLabel("\(entry.item.displayName), \(entry.section.title)")
            .accessibilityAddTraits(selectedID == entry.id ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selectedID = entry.id }
    }
}

extension MenuBarSection {
    /// Bartender's strip titles.
    var stripTitle: String {
        switch self {
        case .shown: return "Shown menu bar items"
        case .hidden: return "Hidden menu bar items"
        case .alwaysHidden: return "Always Hidden menu bar items"
        }
    }

    /// Bartender's "Menu bar item should:" choices.
    var shouldTitle: String {
        switch self {
        case .shown: return "Show"
        case .hidden: return "Hide"
        case .alwaysHidden: return "Always Hide"
        }
    }
}

extension MenuBarLayoutModel {
    /// The menu bar's sampled colour (the window's colour until it is read).
    var laneColor: Color {
        laneNSColor.map { Color(nsColor: MenuBarLaneColor.calmed($0)) } ?? Color(nsColor: .windowBackgroundColor)
    }

    /// 7.24: the read bar colour, or a slate when only light pictures are cached.
    var laneNSColor: NSColor? {
        barColor ?? laneFallback
    }

    /// Ink that reads on `laneColor` (Gemini 7.10: white glyphs vanished on light bars).
    var ink: Color {
        guard let color = laneNSColor.map(MenuBarLaneColor.calmed)?.usingColorSpace(.sRGB) else { return AOMColor.text }
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance > 0.55 ? .black : .white
    }
}

/// The icon's own picture, or its glyph until a picture is taken.
struct MenuBarItemPicture: View {
    let entry: MenuBarLayoutItem
    var height: CGFloat = 20
    var ink: Color = AOMColor.text
    @ObservedObject private var model = MenuBarLayoutModel.shared

    var body: some View {
        if let image = model.images[entry.imageKey], image.size.height > 0 {
            // Its own width at this height (a fixed frame: `.fit` with a max
            // width spread the icons across the strip).
            let width = min(height * 4, max(height * 0.6, height * image.size.width / image.size.height))
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: width, height: height)
        } else {
            MenuBarItemGlyph(item: entry.item, size: height * 0.85).foregroundStyle(ink)
        }
    }
}

/// Right-click menu of an icon, in the strips and the list.
struct MenuBarItemMenu: View {
    let entry: MenuBarLayoutItem
    let rename: () -> Void

    var body: some View {
        Button("Open Its Menu") {
            guard !MenuBarLayoutModel.shared.isSample else { return }
            MenuBarStripController.shared.openItem(entry.item, section: entry.section)
        }
        Button("Rename…", action: rename).disabled(entry.item.stableKey == nil)
        if entry.lockedReason == nil {
            Divider()
            ForEach(MenuBarSection.allCases.filter { $0 != entry.section }) { section in
                Button("Move to \(section.title)") { MenuBarLayoutModel.shared.move(entry.id, to: section) }
            }
        }
    }
}

/// Locked items can't be picked up; the drag shows the bare icon.
private struct DraggableUnlessLocked<Preview: View>: ViewModifier {
    let id: String
    let locked: Bool
    @ViewBuilder let preview: () -> Preview

    func body(content: Content) -> some View {
        if locked { content } else { content.draggable(id) { preview() } }
    }
}

// MARK: - Item Settings (Bartender's MenuItemsPreferences)

/// Every app with a menu bar icon, one group each: "Menu bar item should:"
/// for the app, and under it each icon with its search name.
struct MenuBarItemSettingsList: View {
    @ObservedObject private var model = MenuBarLayoutModel.shared
    @ObservedObject private var modules = AOMModuleSwitches.shared
    @State private var filter = ""
    @State private var open: Set<String> = []
    @State private var renaming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AOMColor.textTertiary)
                TextField("Filter apps and icons", text: $filter).textFieldStyle(.plain)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Refresh Items") { model.refresh() }.controlSize(.small).disabled(model.busy)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            Text("Sets what AOM should do with each app's menu bar items. When searching for menu bar items you can give an icon its own name.")
                .font(.system(size: 11.5)).foregroundStyle(AOMColor.textSecondary)
            let apps = filtered
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.bundle) { index, app in
                    appGroup(app, first: index == 0)
                }
            }
            .background(AOMColor.field.opacity(0.5), in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous).strokeBorder(AOMColor.hairline, lineWidth: 0.5))
            if apps.isEmpty {
                Text(model.busy ? "Reading the menu bar…" : (filter.isEmpty ? "No icons read yet — Refresh Items." : "Nothing matches “\(filter)”."))
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
            }
        }
        .onAppear { if model.lastRefresh == nil { model.refresh() } }
    }

    private var filtered: [(bundle: String, name: String, items: [MenuBarLayoutItem])] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.apps }
        return model.apps.filter { app in
            app.name.lowercased().contains(query) || app.items.contains { $0.item.displayName.lowercased().contains(query) }
        }
    }

    @ViewBuilder
    private func appGroup(_ app: (bundle: String, name: String, items: [MenuBarLayoutItem]), first: Bool) -> some View {
        let lead = app.items[0]
        let expanded = open.contains(app.bundle)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { toggle(app.bundle) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain).foregroundStyle(AOMColor.textSecondary)
                .accessibilityLabel(expanded ? "Collapse \(app.name)" : "Expand \(app.name)")
                AppIconView(bundle: app.bundle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(app.items.count == 1 ? "1 menu bar item" : "\(app.items.count) menu bar items")
                        .font(.system(size: 11)).foregroundStyle(AOMColor.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { toggle(app.bundle) }
                if let locked = lead.lockedReason {
                    Text(locked).font(.system(size: 11)).foregroundStyle(AOMColor.textTertiary).lineLimit(1)
                } else {
                    Text("Menu bar item should:").font(.system(size: 12)).foregroundStyle(AOMColor.textSecondary)
                    Picker("Menu bar item should", selection: Binding(get: { lead.section }, set: { model.move(lead.id, to: $0) })) {
                        ForEach(MenuBarSection.allCases) { Text($0.shouldTitle).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!modules.isOn(.menuBarHider) && !model.isSample)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if expanded {
                ForEach(app.items) { entry in itemRow(entry) }
            }
        }
        .overlay(alignment: .top) { if !first { Rectangle().fill(AOMColor.hairline).frame(height: 0.5) } }
    }

    private func itemRow(_ entry: MenuBarLayoutItem) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(model.laneColor)
                MenuBarItemPicture(entry: entry, height: 16, ink: model.ink)
            }
            .frame(width: 40, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.item.displayName).font(.system(size: 12.5)).lineLimit(1)
                Text("Text search name: " + (AOMMenuBarAliasStore.shared.alias(for: entry.item.stableKey)?.name ?? "—"))
                    .font(.system(size: 11)).foregroundStyle(AOMColor.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Rename…") { renaming = entry.id }
                .controlSize(.small)
                .disabled(entry.item.stableKey == nil)
                .popover(isPresented: Binding(get: { renaming == entry.id }, set: { if !$0 { renaming = nil } }), arrowEdge: .leading) {
                    MenuBarItemAliasEditor(item: entry.item) { renaming = nil }
                }
            Button("Open") { MenuBarStripController.shared.openItem(entry.item, section: entry.section) }
                .controlSize(.small)
                .disabled(model.isSample)
        }
        .padding(.leading, 48).padding(.trailing, 12).padding(.vertical, 6)
        .background(AOMColor.sunken.opacity(0.5))
    }

    private func toggle(_ bundle: String) {
        if open.contains(bundle) { open.remove(bundle) } else { open.insert(bundle) }
    }
}

/// An app's Finder icon (the macOS group shows the gear).
struct AppIconView: View {
    let bundle: String
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: Self.icon(bundle)).resizable().frame(width: size, height: size)
    }

    /// AOM's shared (bounded) app icon cache; macOS's own items show System Settings.
    @MainActor
    static func icon(_ bundle: String) -> NSImage {
        let owner = MenuBarSectionStore.systemOwners.contains(bundle) ? "com.apple.systempreferences" : bundle
        return AppMetadataCache.shared.icon(for: owner) ?? NSWorkspace.shared.icon(for: .application)
    }
}

/// The Bar as it will look, drawn from the same pictures (Settings preview).
struct MenuBarBarPreview: View {
    @ObservedObject private var model = MenuBarLayoutModel.shared
    @ObservedObject private var modules = AOMModuleSwitches.shared

    var body: some View {
        let entries = MenuBarStripController.shared.entries
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 6) {
            if entries.isEmpty {
                Text("Nothing hidden").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).padding(.horizontal, 8)
            }
            ForEach(entries.prefix(12)) { entry in
                MenuBarItemPicture(entry: entry, height: 18, ink: model.ink).help(entry.item.displayName)
            }
            if entries.count > 12 {
                Text("+\(entries.count - 12)").font(.system(size: 10, weight: .semibold)).foregroundStyle(AOMColor.textSecondary)
            }
            Rectangle().fill(model.ink.opacity(0.25)).frame(width: 1, height: 16)
            ForEach(["eye", "magnifyingglass", "gearshape"], id: \.self) { symbol in
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(model.ink.opacity(0.85))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(model.barColor.map { Color(nsColor: $0.withAlphaComponent(1)) } ?? AOMColor.sunken, in: shape)
        .overlay(shape.strokeBorder(AOMColor.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bar preview, \(entries.count) hidden icons")
    }
}
