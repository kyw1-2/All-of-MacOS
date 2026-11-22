import AppKit
import SwiftUI

// 7.8 (Codex MB-02): one menu bar item as a row — the person's name and
// symbol (or macOS's), its current value, and what it belongs to — with an
// editor for the name, symbol and group. The name and symbol are AOM's:
// they show in the Shelf, the Strip, the launcher and AOM's menu; the item
// in the real menu bar keeps the picture its app draws.

struct MenuBarItemRow: View {
    let item: AOMMenuShelfItem
    @ObservedObject var shelf: AOMMenuShelfController
    @ObservedObject private var aliases = AOMMenuBarAliasStore.shared
    @State private var editing = false

    var body: some View {
        HStack(spacing: 10) {
            MenuBarItemGlyph(item: item, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if let group = item.group {
                        Text(group).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(AOMColor.sunken, in: Capsule())
                    }
                }
                Text(subtitle).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
            }
            Spacer()
            Button { shelf.togglePinned(item) } label: {
                Image(systemName: shelf.pinned.contains(item.pinKey) ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .help(shelf.pinned.contains(item.pinKey) ? "Remove from favorites" : "Favorite: first in the Shelf and Strip")
            Button { editing = true } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .disabled(item.stableKey == nil)
                .help(item.stableKey == nil ? "This item has no lasting identity to remember a name by" : "Name, symbol and group")
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    MenuBarItemAliasEditor(item: item) { editing = false }
                }
            Button("Open") { shelf.activate(item) }
                .controlSize(.small)
                .help(item.canShowMenu ? "Opens its own menu" : "Clicks the item once")
        }
        .contextMenu {
            Button("Open Its Menu") { shelf.activate(item) }
            Button("Rename…") { editing = true }.disabled(item.stableKey == nil)
            if item.alias != nil, let key = item.stableKey {
                Button("Restore Name and Symbol") { aliases.set(nil, for: key) }
            }
            Divider()
            Button(shelf.pinned.contains(item.pinKey) ? "Remove from Favorites" : "Add to Favorites") { shelf.togglePinned(item) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.displayName)
    }

    /// The value it shows now and who owns it ("80 % · Control Center").
    private var subtitle: String {
        var parts: [String] = []
        if item.displayName != item.baseName { parts.append(item.baseName) }
        if let detail = item.detail { parts.append(detail) }
        parts.append(item.ownerName)
        return parts.joined(separator: " · ")
    }
}

/// The item's symbol (the person's or macOS's) or else its app's icon.
struct MenuBarItemGlyph: View {
    let item: AOMMenuShelfItem
    var size: CGFloat = 18

    var body: some View {
        if let symbol = item.displaySymbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.72, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(AOMColor.text)
                .accessibilityHidden(true)
        } else if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Image(systemName: "app").frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

struct MenuBarItemAliasEditor: View {
    let item: AOMMenuShelfItem
    let done: () -> Void
    @ObservedObject private var aliases = AOMMenuBarAliasStore.shared
    @State private var name = ""
    @State private var symbol = ""
    @State private var group = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol.isEmpty ? (item.identity?.symbol ?? "app") : symbol)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(AOMColor.sunken, in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? item.baseName : name).font(.headline)
                    Text("Original: \(item.baseName) · \(item.ownerName)").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                }
            }
            LabeledContent("Name") {
                TextField(item.baseName, text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            LabeledContent("Group") {
                HStack(spacing: 4) {
                    TextField("None", text: $group).textFieldStyle(.roundedBorder).frame(width: 150)
                    if !aliases.groups.isEmpty {
                        Menu {
                            ForEach(aliases.groups, id: \.self) { name in Button(name) { group = name } }
                        } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            Text("Symbol").font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 10), spacing: 4) {
                ForEach(AOMMenuBarSymbolChoices.all, id: \.self) { choice in
                    Button { symbol = symbol == choice ? "" : choice } label: {
                        Image(systemName: choice)
                            .frame(width: 26, height: 24)
                            .background(symbol == choice ? AOMColor.accent.opacity(0.22) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(choice)
                    .accessibilityLabel(choice)
                    .accessibilityAddTraits(symbol == choice ? .isSelected : [])
                }
            }
            Text("Shown in the Shelf, Strip, launcher and AOM's menu. The real menu bar keeps the app's own picture.")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Restore Default") {
                    if let key = item.stableKey { aliases.set(nil, for: key) }
                    done()
                }
                .disabled(item.alias == nil)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let key = item.stableKey {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        aliases.set(AOMMenuBarAlias(name: trimmed.isEmpty || trimmed == item.baseName ? nil : trimmed,
                                                    symbol: symbol.isEmpty ? nil : symbol,
                                                    group: group.trimmingCharacters(in: .whitespaces).isEmpty ? nil : group.trimmingCharacters(in: .whitespaces)),
                                    for: key)
                    }
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            let alias = item.alias
            name = alias?.name ?? ""
            symbol = alias?.symbol ?? ""
            group = alias?.group ?? ""
        }
    }
}
