import AppKit
import SwiftUI

/// Clipboard library: the full, searchable history and pinboards in the main
/// window (the ⇧⌘V shelf is the quick-paste surface). Native search field,
/// segmented type filter, pinboard chips and an adaptive card grid whose
/// image thumbnails decode off the main thread.
struct ClipboardStudioView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @State private var searchQuery = ""
    @State private var selectedKind: ClipboardEntry.Kind? = nil
    @State private var selectedBoardID: UUID? = nil
    @State private var hoveredCardID: UUID? = nil
    @State private var showingSettings = false
    @State private var showingNewBoardSheet = false
    @State private var newBoardName = ""
    @State private var newBoardColor = "blue"
    @StateObject private var toast = AOMToastModel()

    private let boardColors = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "gray"]

    private var filteredEntries: [ClipboardEntry] {
        store.filtered(query: searchQuery, kind: selectedKind, source: nil, board: selectedBoardID, since: nil)
    }

    private var subtitle: String {
        let count = store.entries.count
        var parts = ["\(count) item\(count == 1 ? "" : "s")", "\(store.boards.count) pinboard\(store.boards.count == 1 ? "" : "s")"]
        if store.paused { parts.append("recording paused") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let entries = filteredEntries
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                AOMPageHeader("Clipboard", subtitle: subtitle, systemImage: "doc.on.clipboard.fill",
                              tint: store.paused ? .gray : .indigo) {
                    headerControls
                }
                HStack(spacing: 12) {
                    pinboardsBar
                    Picker("Type", selection: $selectedKind) {
                        Text("All").tag(ClipboardEntry.Kind?.none)
                        ForEach(ClipboardEntry.Kind.allCases) { kind in
                            Image(systemName: kind.symbol)
                                .help(kind.displayName)
                                .accessibilityLabel(kind.displayName)
                                .tag(Optional(kind))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.horizontal, AOMDesign.pagePadding)
            .padding(.top, AOMDesign.pagePadding)
            .padding(.bottom, 12)

            Divider()

            if entries.isEmpty {
                if store.entries.isEmpty {
                    AOMEmptyState("Your Clipboard Is Empty", systemImage: "doc.on.clipboard",
                                  message: store.paused ? "Recording is paused. Resume to keep what you copy."
                                  : "Copy text, links, colors, images or files and they appear here — searchable, pinnable and encrypted on this Mac.") {
                        if store.paused { Button("Resume Recording") { store.resume() }.buttonStyle(.borderedProminent) }
                    }
                } else if !searchQuery.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                } else {
                    AOMEmptyState(selectedBoardID == nil ? "No Matching Items" : "Pinboard Is Empty",
                                  systemImage: selectedBoardID == nil ? "line.3.horizontal.decrease.circle" : "pin",
                                  message: selectedBoardID == nil ? "No items of this type yet." : "Pin items from a card's menu to keep them here.") {
                        Button("Show All Items") { selectedKind = nil; selectedBoardID = nil }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)], spacing: 14) {
                        ForEach(entries) { entry in
                            ClipboardStudioCard(
                                entry: entry,
                                isHovered: hoveredCardID == entry.id,
                                boards: store.boards,
                                onCopy: { copy(entry) },
                                onTogglePin: { board in togglePin(entry, board) },
                                onDelete: {
                                    withAnimation(AOMDesign.animation()) { store.delete(entryID: entry.id) }
                                    showToast("Deleted item")
                                }
                            )
                            .onHover { isHovering in
                                if isHovering { hoveredCardID = entry.id } else if hoveredCardID == entry.id { hoveredCardID = nil }
                            }
                        }
                    }
                    .padding(AOMDesign.pagePadding)
                }
                .suppressScrollerReservation()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search Clipboard")
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 0) {
                ClipboardSettingsView()
                Divider()
                HStack { Spacer(); Button("Done") { showingSettings = false }.keyboardShortcut(.defaultAction) }
                    .padding(12)
            }
            .frame(minWidth: 600, idealWidth: 660, minHeight: 520, idealHeight: 600)
        }
        .sheet(isPresented: $showingNewBoardSheet) { newBoardSheet }
        .aomToast(toast.message)
    }

    // MARK: - Header

    private var headerControls: some View {
        HStack(spacing: 8) {
            Button {
                ClipboardPanelController.shared.show()
            } label: {
                Label("Open Shelf", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help("Open the quick-paste shelf (⇧⌘V)")
            if store.paused {
                Button {
                    store.resume()
                    showToast("Clipboard recording resumed")
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
            } else {
                Menu {
                    Button("For 5 Minutes") { store.pause(for: 300) }
                    Button("For 15 Minutes") { store.pause(for: 900) }
                    Button("For 1 Hour") { store.pause(for: 3600) }
                    Divider()
                    Button("Until Resumed") { store.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .fixedSize()
                .help("Temporarily stop recording copied items")
            }
            Menu {
                Button("Clear Unpinned Items") {
                    store.clearUnpinned()
                    showToast("Cleared unpinned items")
                }
                Button("Clear All History", role: .destructive) {
                    store.delete(entryIDs: store.entries.map(\.id))
                    showToast("Cleared clipboard history")
                }
                Divider()
                Button("Clipboard Settings…") { showingSettings = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Pinboards Bar

    private var pinboardsBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(title: "All Items", count: store.entries.count, color: nil, symbol: "tray.full",
                     selected: selectedBoardID == nil) { selectedBoardID = nil }
                ForEach(store.boards) { board in
                    let count = store.entries.filter { $0.pinboardIDs.contains(board.id) }.count
                    chip(title: board.name, count: count, color: colorForBoard(board.color), symbol: nil,
                         selected: selectedBoardID == board.id) {
                        selectedBoardID = selectedBoardID == board.id ? nil : board.id
                    }
                    .contextMenu {
                        Button("Delete Pinboard…", role: .destructive) {
                            if selectedBoardID == board.id { selectedBoardID = nil }
                            store.deleteBoard(id: board.id)
                        }
                    }
                }
                Button {
                    newBoardName = ""
                    newBoardColor = "blue"
                    showingNewBoardSheet = true
                } label: {
                    Label("New Pinboard", systemImage: "plus")
                        .font(.callout)
                        .padding(.horizontal, 10).frame(height: 26)
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                            .foregroundStyle(.secondary.opacity(0.6)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(title: String, count: Int, color: Color?, symbol: String?, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(AOMDesign.animation()) { action() }
        } label: {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                if let symbol { Image(systemName: symbol).font(.caption) }
                Text(title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - New Board Sheet

    private var newBoardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Pinboard").font(.headline)
            TextField("Name (e.g. Snippets, Colors, Work)", text: $newBoardName)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(boardColors, id: \.self) { colorName in
                        Button { newBoardColor = colorName } label: {
                            Circle()
                                .fill(colorForBoard(colorName))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.primary, lineWidth: newBoardColor == colorName ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(colorName.capitalized)
                        .accessibilityAddTraits(newBoardColor == colorName ? .isSelected : [])
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showingNewBoardSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    _ = store.createBoard(name: trimmed, color: newBoardColor)
                    showingNewBoardSheet = false
                    showToast("Created pinboard “\(trimmed)”")
                }
                .buttonStyle(.borderedProminent)
                .disabled(newBoardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Helpers

    private func copy(_ entry: ClipboardEntry) {
        do {
            _ = try store.write(entryIDs: [entry.id], plainText: false, playSound: true)
            showToast("Copied “\(entry.title.prefix(40))”")
        } catch {
            showToast("Could not copy: \(error.localizedDescription)")
        }
    }

    private func togglePin(_ entry: ClipboardEntry, _ board: ClipboardPinboard) {
        if entry.pinboardIDs.contains(board.id) {
            store.unpin(entryID: entry.id, boardID: board.id)
            showToast("Unpinned from \(board.name)")
        } else {
            store.pin(entryID: entry.id, boardID: board.id)
            showToast("Pinned to \(board.name)")
        }
    }

    private func showToast(_ message: String) { toast.show(message) }

    private func colorForBoard(_ name: String) -> Color {
        switch name.lowercased() {
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        default: return .gray
        }
    }
}

// MARK: - Clipboard Studio Card

private struct ClipboardStudioCard: View {
    let entry: ClipboardEntry
    let isHovered: Bool
    let boards: [ClipboardPinboard]
    let onCopy: () -> Void
    let onTogglePin: (ClipboardPinboard) -> Void
    let onDelete: () -> Void
    @State private var thumbnail: ClipboardThumbnailCache.Preview?

    private var appIcon: NSImage? { AppMetadataCache.shared.icon(for: entry.sourceBundleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: entry.kind.symbol).font(.caption).foregroundStyle(.tint)
                }
                Text(entry.sourceName ?? entry.kind.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !entry.pinboardIDs.isEmpty {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                        .accessibilityLabel("Pinned")
                }
                Spacer(minLength: 4)
                Text(AOMRelativeTime.string(entry.lastCopiedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            preview
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipped()

            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isHovered {
                    Group {
                        Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                            .help("Copy")
                        Menu {
                            if boards.isEmpty { Text("No pinboards yet") }
                            ForEach(boards) { board in
                                Button {
                                    onTogglePin(board)
                                } label: {
                                    if entry.pinboardIDs.contains(board.id) {
                                        Label(board.name, systemImage: "checkmark")
                                    } else {
                                        Text(board.name)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: entry.pinboardIDs.isEmpty ? "pin" : "pin.fill")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Pin to a pinboard")
                        Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                            .help("Delete")
                    }
                    .buttonStyle(.borderless)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
        .aomSurface(radius: AOMDesign.tileRadius, padding: nil, highlighted: isHovered)
        .clipShape(RoundedRectangle(cornerRadius: AOMDesign.tileRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AOMDesign.tileRadius, style: .continuous))
        .onTapGesture(count: 2, perform: onCopy)
        .contextMenu {
            Button("Copy", action: onCopy)
            if !boards.isEmpty {
                Menu("Pinboards") {
                    ForEach(boards) { board in
                        Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") {
                            onTogglePin(board)
                        }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .task(id: entry.id) {
            guard entry.kind == .image, let data = entry.imageData else { return }
            thumbnail = await ClipboardThumbnailCache.shared.preview(id: entry.id, data: data)
        }
        .animation(AOMDesign.animation(.easeOut(duration: 0.12)), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.kind.displayName): \(entry.title)")
    }

    @ViewBuilder private var preview: some View {
        switch entry.kind {
        case .color:
            let hex = entry.text ?? "#000000"
            Rectangle().fill(Color(hex: hex))
                .overlay {
                    Text(hex.uppercased())
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                }
        case .image:
            if let image = thumbnail?.image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .padding(6)
                    .overlay(alignment: .bottomTrailing) {
                        if let size = thumbnail?.dimensions {
                            Text(size).font(.caption2.weight(.medium))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                        }
                    }
            } else {
                Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
            }
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                Label(URL(string: entry.text ?? "")?.host ?? "Link", systemImage: "safari")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Text(entry.text ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .file:
            VStack(spacing: 6) {
                if let url = entry.fileURLs.first {
                    Image(nsImage: AppMetadataCache.shared.fileIcon(for: url)).resizable().scaledToFit().frame(width: 48, height: 48)
                } else {
                    Image(systemName: "doc.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
                Text(entry.fileURLs.count > 1 ? "\(entry.fileURLs.first?.lastPathComponent ?? "") +\(entry.fileURLs.count - 1)"
                     : entry.fileURLs.first?.lastPathComponent ?? "File")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text:
            let text = String(entry.previewText.prefix(600))
            Text(text)
                .font(.system(size: 12, design: Self.isLikelyCode(text) ? .monospaced : .default))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(6)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private static func isLikelyCode(_ text: String) -> Bool {
        ["func ", "struct ", "class ", "import ", "const ", "var ", "let ", "def ", "return ", "{", "}"].contains { text.contains($0) }
    }
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
