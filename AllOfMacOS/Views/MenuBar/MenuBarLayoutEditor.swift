import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

// 7.9: the menu bar pulled down into three lanes (Bartender's Layout, Ice's
// Menu Bar Layout). Each lane looks like a strip of the real menu bar — its
// colour, each item's own picture, right-aligned — and an icon dragged to
// another lane is moved in the real menu bar. Click an icon to name it or
// open it; locked ones (Clock, Control Center) show why.

struct MenuBarLayoutEditor: View {
    @ObservedObject private var model = MenuBarLayoutModel.shared
    @ObservedObject private var aliases = AOMMenuBarAliasStore.shared
    @ObservedObject private var modules = AOMModuleSwitches.shared
    @State private var selection: String?
    @State private var targeted: MenuBarSection?
    @State private var renaming = false

    private var hiderOn: Bool { modules.isOn(.menuBarHider) || model.isSample }
    private var sections: [MenuBarSection] {
        hiderOn ? MenuBarSection.allCases : [.shown]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if !AXIsProcessTrusted() && !model.isSample {
                permissionNotice
            } else {
                let lanes = model.lanes
                VStack(spacing: 8) {
                    ForEach(sections) { section in
                        lane(section, items: lanes[section] ?? [])
                    }
                }
                if !hiderOn {
                    Text("Turn on Hide Icons to give the menu bar a Hidden and an Always Hidden lane.")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
                inspector
            }
        }
        .onAppear { if model.lastRefresh == nil { model.refresh() } }
    }

    // MARK: Pieces

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.status ?? footnote)
                .font(AOMFont.caption).foregroundStyle(model.status == nil ? AOMColor.textSecondary : AOMColor.text)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if !MenuBarItemImager.hasPermission && !model.isSample {
                Button { _ = CGRequestScreenCaptureAccess() } label: { Label("Show Real Icons", systemImage: "photo") }
                    .help("Allow Screen Recording so AOM can draw each item's own picture")
            }
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.busy)
                .help("Read the menu bar again")
        }
        .controlSize(.small)
    }

    private var footnote: String {
        "\(model.items.count) items · drag an icon to another lane to move it in the menu bar"
    }

    private var permissionNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(AOMColor.warningText)
            Text("AOM needs Accessibility to read and arrange the menu bar.").font(AOMFont.callout)
            Spacer()
            Button("Allow…") { AOMMenuShelfController.shared.requestPermission() }
        }
        .padding(12)
        .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
    }

    private func lane(_ section: MenuBarSection, items: [MenuBarLayoutItem]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(section.title, systemImage: section.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                Text(section.caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 138, alignment: .leading)
            laneStrip(section, items: items)
        }
    }

    /// One strip of menu bar: the sampled bar colour, icons right-aligned.
    private func laneStrip(_ section: MenuBarSection, items: [MenuBarLayoutItem]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let isTarget = targeted == section
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                if items.isEmpty {
                    Text(isTarget ? "Drop to move it here" : "Drag icons here")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                        .padding(.horizontal, 10)
                }
                ForEach(items) { entry in
                    tile(entry)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first, id != entry.id else { return false }
                            model.move(id, to: section, before: entry.id)
                            return true
                        }
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 34, alignment: .trailing)
        }
        .frame(height: 38)
        .background(laneColor, in: shape)
        .overlay(shape.strokeBorder(isTarget ? AOMColor.accent : AOMColor.hairline, lineWidth: isTarget ? 2 : 0.5))
        .clipShape(shape)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            model.move(id, to: section)
            return true
        } isTargeted: { inside in
            targeted = inside ? section : (targeted == section ? nil : targeted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title) lane, \(items.count) items")
    }

    private var laneColor: Color {
        if let color = model.barColor { return Color(nsColor: color) }
        return AOMColor.sunken
    }

    private func tile(_ entry: MenuBarLayoutItem) -> some View {
        let selected = selection == entry.id
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = model.images[entry.imageKey] {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 44, maxHeight: 22)
                } else {
                    MenuBarItemGlyph(item: entry.item, size: 17)
                }
            }
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, 3)
            if entry.lockedReason != nil {
                Image(systemName: "lock.fill").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(AOMColor.textSecondary)
                    .offset(x: 1, y: 1)
                    .accessibilityHidden(true)
            }
        }
        .background(selected ? AOMColor.accent.opacity(0.25) : .clear, in: shape)
        .overlay(shape.strokeBorder(selected ? AOMColor.accent : .clear, lineWidth: 1.5))
        .contentShape(shape)
        .onTapGesture(count: 2) { open(entry) }
        .onTapGesture { selection = selected ? nil : entry.id }
        .help("\(entry.item.displayName) · \(entry.item.ownerName)" + (entry.lockedReason.map { " — \($0)" } ?? ""))
        .modifier(DraggableUnlessLocked(id: entry.id, locked: entry.lockedReason != nil))
        .accessibilityElement()
        .accessibilityLabel("\(entry.item.displayName), \(entry.section.title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var inspector: some View {
        if let id = selection, let entry = model.items.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                Group {
                    if let image = model.images[entry.imageKey] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 40, maxHeight: 22)
                    } else {
                        MenuBarItemGlyph(item: entry.item, size: 20)
                    }
                }
                .frame(width: 40, height: 28)
                .background(laneColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.item.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([entry.item.ownerName, entry.item.detail, entry.lockedReason].compactMap { $0 }.joined(separator: " · "))
                        .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                .frame(minWidth: 120, alignment: .leading)
                .layoutPriority(1)
                Spacer(minLength: 8)
                if entry.lockedReason == nil, hiderOn {
                    Menu {
                        ForEach(MenuBarSection.allCases.filter { $0 != entry.section }) { section in
                            Button { model.move(entry.id, to: section) } label: { Label("Move to \(section.title)", systemImage: section.symbol) }
                        }
                    } label: { Text("Move") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Button("Rename…") { renaming = true }
                    .disabled(entry.item.stableKey == nil)
                    .popover(isPresented: $renaming, arrowEdge: .bottom) {
                        MenuBarItemAliasEditor(item: entry.item) { renaming = false }
                    }
                Button("Open") { open(entry) }
            }
            .controlSize(.small)
            .padding(10)
            .background(AOMColor.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
        } else {
            Text("Click an icon to name or open it. Double-click opens its menu.")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
        }
    }

    private func open(_ entry: MenuBarLayoutItem) {
        guard !model.isSample else { return }
        MenuBarStripController.shared.openItem(entry.item, section: entry.section)
    }
}

/// Locked items can't be picked up.
private struct DraggableUnlessLocked: ViewModifier {
    let id: String
    let locked: Bool

    func body(content: Content) -> some View {
        if locked { content } else { content.draggable(id) }
    }
}

/// The Bar as it will look, drawn from the same pictures (Settings preview).
struct MenuBarBarPreview: View {
    @ObservedObject private var model = MenuBarLayoutModel.shared

    var body: some View {
        let entries = MenuBarStripController.shared.entries
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 2) {
            if entries.isEmpty {
                Text("Nothing hidden").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).padding(.horizontal, 8)
            }
            ForEach(entries.prefix(10)) { entry in
                Group {
                    if let image = model.images[entry.imageKey] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 40, maxHeight: 20)
                    } else {
                        MenuBarItemGlyph(item: entry.item, size: 15)
                    }
                }
                .frame(minWidth: 24, minHeight: 24)
                .help(entry.item.displayName)
            }
            if entries.count > 10 {
                Text("+\(entries.count - 10)").font(.system(size: 10, weight: .semibold)).foregroundStyle(AOMColor.textSecondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(model.barColor.map { Color(nsColor: $0) } ?? AOMColor.sunken, in: shape)
        .overlay(shape.strokeBorder(AOMColor.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bar preview, \(entries.count) hidden icons")
    }
}
