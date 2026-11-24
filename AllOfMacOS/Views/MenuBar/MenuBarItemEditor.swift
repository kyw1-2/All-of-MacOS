import AppKit
import SwiftUI

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
