import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

// 7.10: Bartender's Menu Bar Items page. Three bars that look like the menu
// bar — its colour, each icon's own picture without a box — for Shown,
// Hidden and Always Hidden; drag an icon from one bar to another. Under them
// every app with an icon, one row each, with the same three choices as a
// segmented control (Bartender's item list), a menu for rename and open.
// On macOS 27 a change applies at once (an app's icons move together);
// macOS's own items always stay shown.

struct MenuBarLayoutEditor: View {
    @ObservedObject private var model = MenuBarLayoutModel.shared
    @ObservedObject private var aliases = AOMMenuBarAliasStore.shared
    @ObservedObject private var modules = AOMModuleSwitches.shared
    @State private var targeted: MenuBarSection?
    @State private var hovered: String?
    @State private var renaming: String?

    private var hiderOn: Bool { modules.isOn(.menuBarHider) || model.isSample }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !AXIsProcessTrusted() && !model.isSample {
                permissionNotice
            } else {
                let lanes = model.lanes
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(MenuBarSection.allCases) { section in
                        bar(section, items: lanes[section] ?? [])
                    }
                }
                itemList
            }
        }
        .onAppear { if model.lastRefresh == nil { model.refresh() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hiderOn ? "Drag icons between the bars, or choose a section for each app below."
                             : "Turn on Hide icons below, then drag icons into Hidden.")
                    .font(.system(size: 12.5))
                if let status = model.status {
                    Text(status).font(AOMFont.caption).foregroundStyle(AOMColor.accent).lineLimit(1)
                } else {
                    Text("Hidden icons come back when you click ❮ or open the Bar. macOS keeps its own icons shown.")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if model.busy { ProgressView().controlSize(.small) }
            if !MenuBarItemImager.hasPermission && !model.isSample {
                Button("Show Real Icons…") { _ = CGRequestScreenCaptureAccess() }
                    .controlSize(.small)
                    .help("Allow Screen Recording so AOM can draw each icon as it looks in the menu bar")
            }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.busy)
                .help("Read the menu bar again")
                .accessibilityLabel("Refresh")
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(AOMColor.warningText)
            Text("AOM needs Accessibility to read the menu bar.").font(AOMFont.callout)
            Spacer()
            Button("Allow…") { AOMMenuShelfController.shared.requestPermission() }
        }
        .padding(12)
        .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
    }

    // MARK: The three bars

    private func bar(_ section: MenuBarSection, items: [MenuBarLayoutItem]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let isTarget = targeted == section
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: section.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(AOMColor.textSecondary)
                Text(section.title + " Items").font(.system(size: 12, weight: .semibold))
                Text("\(items.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(AOMColor.textTertiary)
                Text("· " + section.caption).font(.system(size: 11)).foregroundStyle(AOMColor.textTertiary).lineLimit(1)
            }
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        if items.isEmpty {
                            Text(isTarget ? "Drop here" : "Drag icons here")
                                .font(.system(size: 11)).foregroundStyle(laneInk.opacity(0.55))
                                .padding(.horizontal, 10)
                        }
                        ForEach(items) { entry in icon(entry) }
                    }
                    .padding(.horizontal, 8)
                    .frame(minWidth: geometry.size.width, minHeight: 30, alignment: .trailing)
                }
            }
            .frame(height: 30)
            .background(laneColor, in: shape)
            .overlay(shape.strokeBorder(isTarget ? AOMColor.accent : Color.black.opacity(0.08), lineWidth: isTarget ? 2 : 0.5))
            .clipShape(shape)
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                model.move(id, to: section)
                return true
            } isTargeted: { inside in
                targeted = inside ? section : (targeted == section ? nil : targeted)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(section.title) items, \(items.count)")
        }
    }

    private var laneColor: Color {
        if let color = model.barColor { return Color(nsColor: color.withAlphaComponent(1)) }
        return Color(nsColor: .windowBackgroundColor)
    }

    /// Text that reads on the sampled bar colour.
    private var laneInk: Color {
        guard let color = model.barColor?.usingColorSpace(.sRGB) else { return AOMColor.text }
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance > 0.55 ? .black : .white
    }

    /// An icon as it looks in the menu bar: its picture, no box; hover lights
    /// it like the menu bar does; locked ones are dimmed.
    private func icon(_ entry: MenuBarLayoutItem) -> some View {
        let lit = hovered == entry.id
        return picture(entry, height: 20)
            .padding(.horizontal, 5)
            .frame(height: 24)
            .background(lit ? laneInk.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(entry.lockedReason == nil ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
            .help("\(entry.item.displayName) — \(entry.item.ownerName)" + (entry.lockedReason.map { "\n\($0)" } ?? ""))
            .modifier(DraggableUnlessLocked(id: entry.id, locked: entry.lockedReason != nil, preview: { picture(entry, height: 20) }))
            .contextMenu { itemMenu(entry) }
            .accessibilityElement()
            .accessibilityLabel("\(entry.item.displayName), \(entry.section.title)")
    }

    @ViewBuilder
    private func picture(_ entry: MenuBarLayoutItem, height: CGFloat) -> some View {
        if let image = model.images[entry.imageKey] {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(maxWidth: 80, maxHeight: height)
        } else {
            MenuBarItemGlyph(item: entry.item, size: height * 0.85)
                .foregroundStyle(laneInk)
        }
    }

    @ViewBuilder
    private func itemMenu(_ entry: MenuBarLayoutItem) -> some View {
        Button("Open Its Menu") { open(entry) }
        Button("Rename…") { renaming = entry.id }.disabled(entry.item.stableKey == nil)
        if entry.lockedReason == nil {
            Divider()
            ForEach(MenuBarSection.allCases.filter { $0 != entry.section }) { section in
                Button("Move to \(section.title)") { model.move(entry.id, to: section) }
            }
        }
    }

    // MARK: Every app, one row (Bartender's item list)

    private var itemList: some View {
        let apps = model.apps
        return VStack(alignment: .leading, spacing: 0) {
            Text("Apps in the menu bar").font(.system(size: 12, weight: .semibold)).padding(.bottom, 6)
            ForEach(Array(apps.enumerated()), id: \.element.bundle) { index, app in
                let first = app.items[0]
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(laneColor)
                        picture(first, height: 16)
                    }
                    .frame(width: 34, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.items.count == 1 ? first.item.displayName : app.name)
                            .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(app.items.count == 1 ? app.name : "\(app.items.count) icons · \(app.items.map(\.item.displayName).joined(separator: ", "))")
                            .font(.system(size: 11)).foregroundStyle(AOMColor.textSecondary).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let locked = first.lockedReason {
                        Text(locked).font(.system(size: 11)).foregroundStyle(AOMColor.textTertiary).lineLimit(1)
                    } else {
                        Picker("Section", selection: Binding(get: { first.section },
                                                             set: { model.move(first.id, to: $0) })) {
                            ForEach(MenuBarSection.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .disabled(!hiderOn && !model.isSample)
                    }
                    Menu {
                        itemMenu(first)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .popover(isPresented: Binding(get: { renaming.map { id in app.items.contains { $0.id == id } } ?? false },
                                                  set: { if !$0 { renaming = nil } }), arrowEdge: .trailing) {
                        if let id = renaming, let entry = app.items.first(where: { $0.id == id }) {
                            MenuBarItemAliasEditor(item: entry.item) { renaming = nil }
                        }
                    }
                }
                .padding(.vertical, 6)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(AOMColor.hairline).frame(height: 0.5) }
                }
            }
            if apps.isEmpty {
                Text(model.busy ? "Reading the menu bar…" : "No icons read yet — Refresh.")
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
            }
        }
    }

    private func open(_ entry: MenuBarLayoutItem) {
        guard !model.isSample else { return }
        MenuBarStripController.shared.openItem(entry.item, section: entry.section)
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
            ForEach(entries.prefix(10)) { entry in
                Group {
                    if let image = model.images[entry.imageKey] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 60, maxHeight: 18)
                    } else {
                        MenuBarItemGlyph(item: entry.item, size: 15)
                    }
                }
                .help(entry.item.displayName)
            }
            if entries.count > 10 {
                Text("+\(entries.count - 10)").font(.system(size: 10, weight: .semibold)).foregroundStyle(AOMColor.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(model.barColor.map { Color(nsColor: $0.withAlphaComponent(1)) } ?? AOMColor.sunken, in: shape)
        .overlay(shape.strokeBorder(AOMColor.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bar preview, \(entries.count) hidden icons")
    }
}
