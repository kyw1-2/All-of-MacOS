import AppKit
import SwiftUI

/// Clipboard library: the full, searchable history and pinboards in the main
/// window (the ⇧⌘V shelf is the quick-paste surface). Native search field,
/// segmented type filter, pinboard chips and an adaptive card grid whose
/// image thumbnails decode off the main thread.
struct ClipboardStudioView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @StateObject private var search = ClipboardPanelState()
    @AppStorage("AOMClipboardGridLayout") private var gridLayout = false
    @State private var selectedEntryID: UUID?
    @State private var boardCounts: [UUID: Int] = [:]
    @State private var hoveredCardID: UUID? = nil
    @State private var showingSettings = false
    @State private var showingNewBoardSheet = false
    @State private var newBoardName = ""
    @State private var newBoardColor = "blue"
    @StateObject private var toast = AOMToastModel()

    private let boardColors = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "gray"]

    private var filteredEntries: [ClipboardEntry] {
        search.displayedResults(in: store)
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
                HStack(spacing: 8) {
                    AOMSearchField(prompt: "Search text, links and files", text: $search.query)
                    Picker("Layout", selection: $gridLayout) {
                        Image(systemName: "list.bullet").tag(false).help("List and preview")
                        Image(systemName: "square.grid.2x2").tag(true).help("Gallery")
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HStack(spacing: 12) {
                    pinboardsBar
                    Picker("Type", selection: $search.kind) {
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
            .padding(.bottom, 14)

            // The library sits on one sheet, like Capture's.
            Group {
                if search.isSearchPending {
                    ProgressView("Searching clipboard…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    if store.entries.isEmpty {
                        AOMEmptyState("Your Clipboard Is Empty", systemImage: "doc.on.clipboard",
                                      message: store.paused ? "Recording is paused. Resume to keep what you copy."
                                      : "Copy text, links, colors, images or files and they appear here — searchable, pinnable and encrypted on this Mac.") {
                            if store.paused { Button("Resume Recording") { store.resume() }.buttonStyle(.borderedProminent) }
                        }
                    } else if !search.query.isEmpty {
                        ContentUnavailableView.search(text: search.query)
                    } else {
                        AOMEmptyState(search.board == nil ? "No Matching Items" : "Pinboard Is Empty",
                                      systemImage: search.board == nil ? "line.3.horizontal.decrease.circle" : "pin",
                                      message: search.board == nil ? "No items of this type yet." : "Pin items from a card's menu to keep them here.") {
                            Button("Show All Items") { search.kind = nil; search.board = nil }
                        }
                    }
                } else {
                    library(entries)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .aomCardStyle(.paper, radius: 22, padding: 0)
            .padding(.horizontal, AOMDesign.pagePadding)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AOMWorkspaceBackground())
        .task(id: store.revision) {
            let entries = store.entries
            let counts = await Task.detached(priority: .userInitiated) {
                var counts: [UUID: Int] = [:]
                for entry in entries { for id in entry.pinboardIDs { counts[id, default: 0] += 1 } }
                return counts
            }.value
            guard !Task.isCancelled else { return }
            boardCounts = counts
        }
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

    private func library(_ entries: [ClipboardEntry]) -> some View {
        GeometryReader { geometry in
            if gridLayout {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12)], spacing: 12) {
                        ForEach(entries) { entry in libraryCard(entry) }
                    }.padding(20)
                }.suppressScrollerReservation()
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Content")
                            Spacer()
                            Text("\(entries.count) items")
                        }
                        .aomSectionCaps()
                        .padding(.horizontal, 22).frame(height: 40)
                        List(selection: $selectedEntryID) {
                            ForEach(entries) { entry in
                                libraryRow(entry)
                            }
                        }.listStyle(.inset).scrollContentBackground(.hidden)
                    }.frame(maxWidth: .infinity)
                    if geometry.size.width >= 660, let entry = entries.first(where: { $0.id == selectedEntryID }) ?? entries.first {
                        AOMDivider(axis: .vertical)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Preview").aomSectionCaps()
                                libraryCard(entry).id(entry.id)
                                if let text = entry.text, !text.isEmpty {
                                    Text(String(text.prefix(16000))).font(.system(size: 13.5)).textSelection(.enabled)
                                        .foregroundStyle(AOMTheme.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if text.count > 16000 {
                                        Text("Preview shortened. Copy includes the full text.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.padding(20)
                        }.frame(width: min(340, geometry.size.width * 0.4))
                    }
                }
            }
        }
    }

    private func libraryRow(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.symbol).font(.system(size: 15))
                .foregroundStyle(AOMTheme.textSecondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.system(size: 14, weight: .medium)).foregroundStyle(AOMTheme.text).lineLimit(1)
                Text([entry.sourceName, AOMRelativeTime.string(entry.lastCopiedAt)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(AOMTheme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !entry.pinboardIDs.isEmpty { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(AOMTheme.orange) }
            Button { copy(entry) } label: { Image(systemName: "doc.on.doc").font(.system(size: 13)) }
                .buttonStyle(.borderless).help("Copy item").accessibilityLabel("Copy \(entry.title)")
        }
        .frame(minHeight: 48).contentShape(Rectangle()).tag(entry.id)
        .simultaneousGesture(TapGesture(count: 2).onEnded { copy(entry) })
        .contextMenu {
            Button("Copy") { copy(entry) }
            Menu("Pinboards") {
                ForEach(store.boards) { board in
                    Button(entry.pinboardIDs.contains(board.id) ? "Unpin from \(board.name)" : "Pin to \(board.name)") { togglePin(entry, board) }
                }
            }
            Button("Delete", role: .destructive) { store.delete(entryID: entry.id) }
        }
    }

    private func libraryCard(_ entry: ClipboardEntry) -> some View {
        ClipboardStudioCard(entry: entry, isHovered: hoveredCardID == entry.id, boards: store.boards,
            onCopy: { copy(entry) }, onTogglePin: { board in togglePin(entry, board) },
            onDelete: { store.delete(entryID: entry.id); showToast("Deleted item") })
            .onHover { hovering in
                if hovering { hoveredCardID = entry.id } else if hoveredCardID == entry.id { hoveredCardID = nil }
            }
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
                     selected: search.board == nil) { search.board = nil }
                ForEach(store.boards) { board in
                    let count = boardCounts[board.id] ?? 0
                    chip(title: board.name, count: count, color: colorForBoard(board.color), symbol: nil,
                         selected: search.board == board.id) {
                        search.board = search.board == board.id ? nil : board.id
                    }
                    .contextMenu {
                        Button("Delete Pinboard…", role: .destructive) {
                            if search.board == board.id { search.board = nil }
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
                        .font(.system(size: 13.5, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 30)
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                            .foregroundStyle(AOMTheme.textTertiary.opacity(0.7)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AOMTheme.textSecondary)
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
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 13.5, weight: selected ? .semibold : .medium)).lineLimit(1)
                Text("\(count)").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(AOMTheme.textTertiary)
            }
            .foregroundStyle(selected ? AOMTheme.text : AOMTheme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(selected ? AOMTheme.paper : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? AOMTheme.hairline : .clear, lineWidth: 0.75))
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
        Task {
            do {
                _ = try await store.writeAsync(entryIDs: [entry.id], plainText: false, playSound: true)
                showToast("Copied “\(entry.title.prefix(40))”")
            } catch { showToast("Could not copy: \(error.localizedDescription)") }
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            preview
                .frame(height: 108)
                .frame(maxWidth: .infinity)
                .background(AOMTheme.cardAlt)
                .clipped()

            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Group {
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
            .padding(.horizontal, 16)
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
